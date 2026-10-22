# 任务书:OpenRouter 评测第二轮——查明 glm-4.5-air 掉分原因 + 补测 Gemini 3.5 Flash / GLM 5.x

> 2026-10-22 起草。本文档是**交给执行者的任务书**,取代 `docs/openrouter-eval-task.md`(那份未按原样执行)。
> 完成后把结果写进 `docs/openrouter-eval-round2-results.md`(格式见 §9),交回审查。
>
> ⏰ **硬截止**:评测只能在 **UTC 周二到周四**跑(测试集按「周三」计算相对日期,runner 在其他日子会直接报错)。
> 本轮窗口到 **UTC 2026-10-23 00:00(北京时间周五 08:00)**;错过就在下一轮
> **UTC 2026-10-27 00:00 – 10-30 00:00(北京时间周二 08:00 – 周五 08:00)** 里跑。
> 同一个实验不要跨窗口 `--resume`:换周后基准日不同,runner 会中止。

---

## 0. 为什么要第二轮

第一轮(`claude/capacity-scenario-a` 分支 `docs/capacity-scenario-a-results.md` §4)有四个问题:

1. **glm-4.5-air 只有 76.0%(57/75)、P95 17.6 秒**,而 9 月 22 日在 z.ai 上是 97.2%、平均 3.7 秒。
   差距的来源没分开,有两种可能:
   - **提示词改动**:9 月 22 日之后,抽取提示词改过三次——`58b2a4e`(10-06,时段相关示例)、
     `54a6be2`(10-17,一周改为从周日开始 + 日文「今度」规则)、`37006ac`(10-17,示例 7 的日期)。
   - **OpenRouter 的路由**:同一个模型可能被转给第三方托管商(可能是量化版本,也可能默认开着推理)。
2. **用户点名的两个模型没测**:Gemini 3.5 Flash、GLM 5.x。
3. **Gemini 被地区封锁**:第一轮是从中国大陆的出口 IP 发的请求,OpenRouter 对 Google、Anthropic 的模型直接返回 403(`region_blocked`)。
4. **「关闭思考」的参数写错了**:模板里用的是 GLM 原生的 `"thinking": {"type": "disabled"}`,
   而 OpenRouter 的统一参数名是 `reasoning`。所以「关闭思考组」实际上很可能没关。

---

## 1. 实验清单

| 编号 | 标签(`--label`) | 模型 | 托管商 | 提示词 | 推理 | 目的 |
|---|---|---|---|---|---|---|
| **E1** | `r2-air-zai` | glm-4.5-air | **固定为 Z.AI 官方** | 当前(新) | 默认 | 排除第三方托管商的影响 |
| **E2** | `r2-air-zai-oldprompt` | glm-4.5-air | 固定为 Z.AI 官方 | **9 月 22 日版(旧)** | 默认 | 和 E1 对比,单独看提示词改动的影响 |
| E3 | `r2-air-zai-noreason` | glm-4.5-air | 固定为 Z.AI 官方 | 当前 | **关闭** | 只在 E1 的预检显示有推理 token、或 E1 的 P95 > 8 秒时才跑 |
| **E4** | `r2-gemini-3.5-flash` | Gemini 3.5 Flash | 默认 | 当前 | 默认 | 用户点名 |
| E4b | `r2-gemini-3.5-flash-noreason` | 同上 | 默认 | 当前 | 关闭 | 只在 E4 预检显示有推理 token 时才跑 |
| **E5** | `r2-glm-5.x` | GLM 5.x(按实际 ID 命名,例如 `r2-glm-5.2`) | 有 Z.AI 官方就固定为它,否则默认 | 当前 | 默认 | 用户点名(现备用实际映射到 GLM 5.2) |
| E5b | `r2-glm-5.x-noreason` | 同上 | 同上 | 当前 | 关闭 | 只在 E5 预检显示有推理 token 时才跑 |
| E0(可选) | `r2-air-default` | glm-4.5-air | 默认(不固定) | 当前 | 默认 | 复现第一轮的 76%,确认结果稳定 |

**必须完成的**:E1、E2、E4、E5。带 b 的和 E3 按条件执行;时间不够时优先保证 E1、E2(它们回答的问题最紧急,见 §7)。

---

## 2. 前置条件(任何一项不满足就停下来问人,不要绕过)

| # | 条件 | 怎么确认 |
|---|---|---|
| 1 | **出口不在中国大陆和香港** | 推荐在 Claude Code 云端会话里执行。Gemini 的预检(§4.3)返回 200 而不是 403 `region_blocked`,就说明出口符合要求 |
| 2 | 能访问 `openrouter.ai` | `curl -sS -o /dev/null -w '%{http_code}\n' https://openrouter.ai/api/v1/models` 返回 `200`。返回 `000` 或代理报 403 / `connect_rejected`,说明网络策略没放行,请人在环境设置的 Allowed domains 里加上 `openrouter.ai` |
| 3 | 有 OpenRouter Key | 环境变量 `OPENROUTER_API_KEY` 非空。只检查是否非空:`[ -n "$OPENROUTER_API_KEY" ] && echo set`,**不要打印值** |
| 4 | 代码版本 | 从 `origin/claude/capacity-scenario-a` 拉出工作分支。第二轮要用这个分支新增的进程内评测(`--provider-file` / `--key-env`)和条目级 `extraBody` |
| 5 | 在评测窗口内 | `date -u '+%A'` 是 Tuesday / Wednesday / Thursday |
| 6 | 预算 | 每个实验约 75 条 × 6k 输入 token ≈ 45 万 token。8 个实验以内,glm-4.5-air 合计不到 1 美元;Gemini、GLM 5.x 价格以 §4.1 查到的为准 |

**禁止**:使用 z.ai / GLM Coding Plan 的任何 Key;把 Key 写进任何文件或命令行参数;
提交 `eval/results/`、`.dev.vars`;修改 `AIProxy/src/` 或 `wrangler.toml`
(E2 对提示词的改动只在临时 worktree 里做、不提交,见 §4.5)。

---

## 3. 本轮的参数约定

- **超时**:`timeoutMs` 用 **50000**(和第一轮一致,保证慢模型也能拿到准确率数据)。
  但生产环境的单次超时是 30 秒,所以结果里**必须**另外报告「耗时超过 30 秒的用例数」:
  在生产环境这些用例都会失败。
- **固定托管商**:在 provider 文件里加 `extraBody.provider`,只允许指定的托管商、不允许回退。字段格式:
  `{"provider": {"order": ["<托管商名>"], "allow_fallbacks": false}}`。托管商名必须从 §4.2 查到的原文抄。
- **关闭推理**:用 OpenRouter 的统一参数 `reasoning`,具体字段和取值**以 OpenRouter 官方文档为准**,
  在结果文档里写明用了什么、出处是哪里。**是否真的关掉了,要用 §4.3 的预检验证**,不能只看参数发没发出去。
- 不传其他任何额外参数。

---

## 4. 执行步骤

所有命令都在 `AIProxy/` 下执行,除非另有说明。

### 4.1 查模型 ID 和价格

```bash
curl -sS https://openrouter.ai/api/v1/models \
  | jq -r '.data[] | select(.id | test("glm|gemini"; "i")) | "\(.id)\tprompt=\(.pricing.prompt)\tcompletion=\(.pricing.completion)"'
```

抄下 glm-4.5-air、Gemini 3.5 Flash、GLM 5.x 的**确切 ID 和单价**。查不到某个模型就在结果文档里记为「未上架」并跳过,
**不要换成别的模型顶替**(第一轮用 gemini-2.5-flash 顶替了 3.5,这次不允许)。

### 4.2 查每个模型有哪些托管商

```bash
curl -sS "https://openrouter.ai/api/v1/models/<ID>/endpoints" | jq '.data.endpoints[] | {provider_name, quantization, context_length}'
```

(如果这个接口的路径或返回格式和上面不同,以 OpenRouter 文档为准,并在结果文档里注明实际用的方法。)
确认 glm-4.5-air 和 GLM 5.x 的托管商里有没有 Z.AI 官方,记下名字原文和量化精度。

### 4.3 直连预检(每个实验配置一次)

用和生产一致的参数(`temperature: 0`、`response_format: json_object`),加上本实验的 `provider` / `reasoning` 设置,**非流式**请求一次:

```bash
curl -sS https://openrouter.ai/api/v1/chat/completions \
  -H "Authorization: Bearer $OPENROUTER_API_KEY" -H "Content-Type: application/json" \
  -d @/tmp/preflight.json \
  | jq '{provider, model, usage, content: .choices[0].message.content, error}'
```

`/tmp/preflight.json` 里放 model、temperature、response_format、一条简短的 messages,以及本实验的 extraBody 字段。检查并记录:

- HTTP 200,`content` 是合法 JSON;
- `provider`:实际托管商。固定托管商的实验必须等于指定的那家;
- `usage` 里的推理 token 数(字段名以实际返回为准,常见为 `completion_tokens_details.reasoning_tokens`)。
  **「关闭推理」的实验,这个数必须是 0 或字段不存在**,否则说明参数没生效,停下来在结果文档里记录。

### 4.4 写 provider 文件

在 `eval/providers/` 下新建本轮用的文件(**不提交**,建议放 `/tmp`)。示例(E1):

```json
{
  "type": "openai",
  "url": "https://openrouter.ai/api/v1/chat/completions",
  "model": "<4.1 查到的 glm-4.5-air ID>",
  "timeoutMs": 50000,
  "extraHeaders": { "HTTP-Referer": "https://voicetodo.app", "X-Title": "VoiceTodo" },
  "extraBody": { "provider": { "order": ["<4.2 查到的 Z.AI 托管商名>"], "allow_fallbacks": false } }
}
```

### 4.5 E2 专用:在临时 worktree 里恢复 9 月 22 日的提示词

```bash
cd <仓库根目录>
git worktree add /tmp/oldprompt origin/claude/capacity-scenario-a
cd /tmp/oldprompt
for c in 37006ac 54a6be2 58b2a4e; do
  git show $c -- AIProxy/src/adapters/base.js | git apply -R
done
git diff --stat            # 应只有 AIProxy/src/adapters/base.js 一个文件变化
cd AIProxy && npm ci       # 或者软链接主工作区的 node_modules
```

起草时已验证:按这个顺序反向应用三个提交能干净地撤回,撤回后的抽取提示词与 9 月 22 日基线
(`8c4f980` 时的 `base.js`)**逐字一致**(多出来的复盘解读提示词与抽取无关)。
E2 的评测命令在 `/tmp/oldprompt/AIProxy/eval` 下运行。**这个 worktree 不提交,用完删除**:
`git worktree remove --force /tmp/oldprompt`。

**注意**:10 月 17 日同时往评测集里加了三条「周日边界」用例——`en-031`、`zh-025`、`ja-019`。
旧提示词按「一周从周一开始」计算,在这三条上按设计就会错。E2 的结果要报告两个口径:
全部 75 条,以及剔除这三条后的 72 条。

### 4.6 跑评测

```bash
cd eval
node run.mjs --provider-file /tmp/r2-air-zai.json --key-env OPENROUTER_API_KEY --label r2-air-zai
```

每个实验约 6 到 15 分钟。把 runner 结束时打印的汇总(准确率、各语言、字段准确率、延迟)完整抄进结果文档。
全部跑完后生成对比表:

```bash
node run.mjs --table results/r2-*.scored.json
```

### 4.7 基础设施错误

某个实验的 `infra_error` 超过 3 条,就查 `results/*.json` 里的 `error` 找原因。偶发就整组重跑一次;
持续出现(例如固定超时、固定的报错)就作为结论写进结果文档。

---

## 5. 评分口径与过关线

评分口径不变,见 `AIProxy/eval/README.md` §3。过关线:

1. **case 全对率 ≥ 98%**:剔除白名单 `zh-017`、`ja-014` 后的 73 条里最多错 1 条(ja 自 10-17 起计入)。
2. **日期组**:`due_date`、`due_time`、`recurrence_rule` 三列字段准确率各自报告。
3. **延迟**:报告 mean / P50 / P95,以及**耗时超过 30 秒的用例数**。P95 超过 10 秒的标注「不适合做实时主力」。
4. 原 README §4.1 第 3 条(与 Sonnet 基线比)**不适用**。

---

## 6. 选型建议规则(结果文档给建议,由人拍板)

| 情况 | 建议 |
|---|---|
| 多个模型过关 | **主力**按「准确率 → P95 → 单次成本」选;**备用**选另一个模型族(GLM 与 Gemini 互为备用) |
| 只有一个过关 | 它做主力,备用暂缺并写明 |
| 都没过关 | 不建议切换,列出失败集中的字段和用例 |
| 准确率过关但 P95 > 10 秒 | 看有没有对应的「关闭推理」实验;都没有就写明需要补测 |

---

## 7. 实验结果怎么解读(请在结果文档里明确给出属于哪种情况)

| E1(固定 Z.AI,新提示词) | E2(固定 Z.AI,旧提示词) | 结论 |
|---|---|---|
| 接近 97% | — | 第一轮的 76% 来自**第三方托管商**。生产上用 OpenRouter 时必须固定托管商 |
| 明显低于 97% | 接近 97%(72 条口径) | **提示词改动造成了退步**。⚠️ 如果这些改动已经部署到线上,**现在的生产环境质量可能已经下降**,要在结果文档开头单独醒目标出 |
| 明显低于 97% | 也明显低于 97% | 两个因素都不是主因,可能是 OpenRouter 上的 Z.AI 托管与 z.ai 直连不同。写明数据,交人判断 |

E1 与 E2 的比较要按 72 条口径(剔除三条周日边界用例),两边才可比。

---

## 8. 约束

- 不改 `AIProxy/src/`、`wrangler.toml`、评测集;E2 的提示词改动只存在于临时 worktree。
- 不部署,不碰线上配置和管理接口。
- 不提交 `eval/results/`、provider 临时文件、`.dev.vars`。
- 结果文档提交到**从 `origin/claude/capacity-scenario-a` 拉出的新分支**,推送后**不合并**。
- 评测结束后提醒人撤销这个临时 Key。

---

## 9. 结果文档格式(`docs/openrouter-eval-round2-results.md`)

1. **运行信息**:UTC 日期、基准日 `anchorToday`、执行环境与出口地区(Gemini 预检是否 200)。
2. **模型与托管商表**:每个实验的模型 ID、托管商(预检返回的原文)、量化精度、输入与输出单价、推理设置及其文档出处。
3. **预检结果**:每个实验一行——HTTP 状态、JSON 是否合法、推理 token 数。
4. **结果总表**:每个实验一行——case 全对率(总体、en / zh / ja;E2 另加 72 条口径)、`infra_error` 数、日期组三列准确率、
   mean / P50 / P95、超过 30 秒的用例数、单次成本估算、错误用例 ID。
5. **各实验 runner 的原始汇总输出**(终端打印的那段)。
6. **§7 的结论**:属于哪种情况,依据是哪几行数据。
7. **选型建议**(§6)。
8. **偏离任务书的地方**及理由(没有就写「无」)。
9. **待人工处理**:例如模型未上架、参数无效、需要撤销的 Key 等。

---

## 10. 人工待办(不归执行者)

1. **确认 9 月 22 日之后的三次提示词改动有没有部署到线上**:在 `AIProxy/` 下运行
   `npx wrangler deployments list`,对照部署时间和三个提交的日期(10-06、10-17)。如果 §7 的结论是「提示词退步」,这一项决定生产环境现在是否受影响。
2. **Gemini 的地区条款与生产出口**:第一轮证明 OpenRouter 会按调用方出口 IP 限制 Google 的模型。
   线上的 Worker 是从 Cloudflare 的边缘节点出口的,中国用户的请求可能从香港等地出去。
   如果要在生产上用 Gemini,必须先通过部署好的 Worker 实测一次,必要时调整 Worker 的运行区域。
