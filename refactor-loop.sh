#!/usr/bin/env bash
#
# refactor-loop.sh
#   三个重构候选,每个独立走:Codex 改 → Claude 双 review 收敛循环 → 提交
#   外层:Bash 管三个候选(顺序 2→3→4)
#   内层:Claude 在一次 -p 会话里自己跑「Three Check↔code-review-expert」直到收敛/满10轮
#
# 用法:  cd 你的VoiceTodo仓库 && /path/to/refactor-loop.sh
#
set -euo pipefail

# ───────────────────────── 配置区 ─────────────────────────
WORKDIR="$(pwd)"
LOG_DIR="$WORKDIR/.refactor-logs"

# VoiceTodo 没跑测试,改用「能编译」当客观门。设成空字符串则完全不校验(只靠两个 skill 收敛)。
# 你的 scheme/项目名按实际改。常见形式:
#   xcodebuild -scheme VoiceTodo -destination 'platform=iOS Simulator,name=iPhone 15' build
VERIFY_CMD="${VERIFY_CMD:-}"   # 留空 = 跳过编译校验

CODEX="codex exec --full-auto"
CLAUDE="claude -p --permission-mode acceptEdits"
# ──────────────────────────────────────────────────────────

mkdir -p "$LOG_DIR"
log() { printf '\n\033[1;36m[refactor %s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf '\n\033[1;31m[FATAL]\033[0m %s\n' "$*" >&2; exit 1; }

command -v codex  >/dev/null || die "找不到 codex"
command -v claude >/dev/null || die "找不到 claude"
git rev-parse --git-dir >/dev/null 2>&1 || die "当前不是 git 仓库"

# 强烈建议在独立分支跑
CUR_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
log "当前分支:$CUR_BRANCH(建议先 git checkout -b refactor-loop 再跑)"

# ───────── 三个候选的任务书(你给的 spec 原样放进来)─────────
read -r -d '' CAND_2 <<'EOF' || true
【候选 2:收窄 TodoStoreProtocol 的 interface】
涉及文件:Protocols/TodoStoreProtocol.swift、Store/TodoStore.swift、UI/Home/HomeView.swift、App/AppCoordinator.swift

Problem:TodoStoreProtocol 同时暴露 CRUD、pending、Widget 查询、日历 occurrence、排序、刷新、系统日历 ID。
interface 的知识量接近实现复杂度,属于偏 shallow。

Solution:按 caller 需求拆成更窄的 facade,例如 TodoListReadable、TodoMutationWriting、
PendingTranscriptStore、CalendarOccurrenceStore。底层仍由同一个 TodoStore adapter 实现。

要求:调用者只看到自己需要的窄 interface。底层实现不变,只拆协议 + 让各 caller 依赖窄协议。
EOF

read -r -d '' CAND_3 <<'EOF' || true
【候选 3:从 Models.swift 拆出日期/重复规则 domain module】
涉及文件:Protocols/Models.swift、Store/TodoStore.swift、UI/Home/HomeView.swift、Widget

Problem:DTO、自然语言日期解析、重复规则解析、Widget 过滤都放在一个文件。
加一种重复规则或日期语义时,Store、Home、Widget 都会被间接牵动。

Solution:把 RecurrenceRule、TodoDueDateResolver、RecurrenceRuleResolver、WidgetTodoFilter
拆成独立 domain module,并用专门测试覆盖它们的 interface。

要求:DTO 留在 Models,日期/重复/Widget 筛选各自成 module。
EOF

read -r -d '' CAND_4 <<'EOF' || true
【候选 4:把 HomeView 的日历计算和动作处理移出 View】
涉及文件:UI/Home/HomeView.swift、Store/TodoStore.swift

Problem:HomeView 同时负责渲染、日历计算、录音按钮动作、手动输入动作、toggle/delete 错误反馈。
UI 变化和业务动作变化会挤在一个 view。

Solution:先提取纯 view 子块和 HomeCalendarState,不急着引入大型 MVVM。
只把真正反复修改的逻辑移出。

要求:View 专注渲染,日历状态和动作有更小 module。不要引入大型 MVVM 框架。
EOF

# ───────── 你的双 review 收敛 prompt(已按 VoiceTodo 适配测试部分)─────────
# 用占位符 __VERIFY_DESC__ 注入"测试" or "编译"的描述
build_review_prompt() {
  local cand_name="$1"
  local verify_desc="$2"
  cat <<EOF
请对当前项目刚完成的【${cand_name}】这次重构改动,执行以下双 review 循环,直到收敛为止。

循环流程:
  1. 用 Three Check 对代码做一轮 review,记录所有问题
  2. 修复 Three Check 发现的所有问题
  3. 修复完成后,${verify_desc}。如果不通过,先修到通过,再继续
  4. 用 code-review-expert 对代码做一轮 review,记录所有问题
  5. 修复 code-review-expert 发现的所有问题
  6. 修复完成后,再次${verify_desc},确保通过
  7. 回到第 1 步

退出条件(满足任一即停止):
  - 某一轮 Three Check 和 code-review-expert 都没有发现任何问题 → 正常收敛,输出最终报告
  - 已经运行满 10 轮 → 停止并输出剩余问题清单,由我来决定后续处理

每轮 review 的重要要求:
  请完全忽略上一轮的判断和修复结论,从头重新审视所有代码,就像你第一次看到这些代码一样。
  不要因为"这是上一轮刚改过的"就默认它是对的。

冲突处理:
  如果发现 Three Check 和 code-review-expert 的建议互相矛盾(A 要求改成 X,B 又要求改回 Y),
  不要反复横跳。请:立即停止循环;输出矛盾点的具体描述、两个 skill 各自的理由;等我裁决后再继续。

每轮结束后请输出:当前第几轮 / 本轮 Three Check 发现与修复数 / 本轮 code-review-expert 发现与修复数 /
${verify_desc} 的状态 / 是否进入下一轮或已满足退出条件。

最终报告应包含:总共跑了多少轮 / 累计发现和修复数(按 skill 分类)/ 最终状态 /
若因满 10 轮停止,列出剩余未解决问题清单。

现在开始执行。如果启动测试环境时权限被阻止了,就跳过该步骤。
EOF
}

# 客观门描述 + 实际执行
if [[ -n "$VERIFY_CMD" ]]; then
  VERIFY_DESC="运行编译校验(项目对应命令)确认能编译通过"
else
  VERIFY_DESC="(本项目跳过测试/编译,以两个 skill 均无问题为准)"
fi

run_verify() {  # 返回0=通过/跳过
  [[ -z "$VERIFY_CMD" ]] && { log "跳过校验(VERIFY_CMD 为空)"; return 0; }
  log "校验:$VERIFY_CMD"
  eval "$VERIFY_CMD"
}

# ───────── 外层:三个候选顺序跑 ─────────
process_candidate() {
  local num="$1" spec="$2" name="$3"
  log "════════ 候选 $num:$name 开始 ════════"

  # 1. Codex 改代码
  log "Codex 实现候选 $num"
  $CODEX "$(cat <<EOF
你是资深 iOS/Swift 工程师。请对当前 VoiceTodo 项目执行下面这一次重构,只做这一项,不要顺手改别的:

$spec

完成后,如果环境允许,自己尝试编译确认没有破坏构建。
EOF
)" > "$LOG_DIR/cand${num}-codex.log" 2>&1 \
     || die "Codex 改候选 $num 失败,看 $LOG_DIR/cand${num}-codex.log"

  # 2. Codex 改完先过一次客观门(若启用)
  run_verify > "$LOG_DIR/cand${num}-verify-after-codex.log" 2>&1 \
     || die "候选 $num Codex 改完编译不过,看该 log。停下避免错上加错。"

  # 3. Claude 双 review 收敛循环(Claude 在这一次调用里自己跑满循环)
  log "Claude 双 review 收敛循环(候选 $num,内部最多 10 轮)"
  build_review_prompt "$name" "$VERIFY_DESC" | $CLAUDE \
     > "$LOG_DIR/cand${num}-review.log" 2>&1 \
     || die "Claude review 循环出错,看 $LOG_DIR/cand${num}-review.log"

  # 4. Claude 收敛后再过一次客观门
  run_verify > "$LOG_DIR/cand${num}-verify-after-review.log" 2>&1 \
     || die "候选 $num review 后编译不过,看该 log。"

  # 5. 提交
  if git diff --quiet && git diff --cached --quiet; then
    log "候选 $num 无改动,跳过提交"
  else
    git add -A
    git commit -m "refactor: candidate $num - $name

Codex implement + Claude dual-review (Three Check / code-review-expert)" \
       > "$LOG_DIR/cand${num}-commit.log" 2>&1
    log "候选 $num 已提交 ✅"
  fi

  log "════════ 候选 $num 完成,review 报告见 $LOG_DIR/cand${num}-review.log ════════"
}

process_candidate 2 "$CAND_2" "收窄 TodoStoreProtocol interface"
process_candidate 3 "$CAND_3" "拆出日期/重复规则 domain module"
process_candidate 4 "$CAND_4" "HomeView 计算与动作移出 View"

log "🎉 三个候选全部跑完。每个的双 review 最终报告:"
log "   cand2 → $LOG_DIR/cand2-review.log"
log "   cand3 → $LOG_DIR/cand3-review.log"
log "   cand4 → $LOG_DIR/cand4-review.log"
log "提示:候选 3/4 涉及拆 module,建议你人工核对一遍最终 diff 再 merge 回主干。"
