# 任务书:OpenRouter 候选模型评测(GLM-4.5-air / GLM 5.x / Gemini 3.5 Flash)

> ⚠️ **已被 `docs/openrouter-eval-round2-task.md` 取代**(2026-10-22)。本文档未按原样执行,保留作记录。

> 2026-10-22 起草。本文档是**交给执行者的任务书**。完成后把结果写进
> `docs/openrouter-eval-results.md`(格式见 §9),交回审查。
>
> ⏰ **硬截止**:评测只能在 **UTC 周二到周四**运行(原因见 §4.6)。
> 本轮窗口在 **2026-10-23(周五)北京时间 08:00**(= UTC 2026-10-23 00:00)关闭;
> 错过就要等下一轮:北京时间 **2026-10-27(周二)08:00** 到 **10-30(周五)08:00**。

---

## 0. 目标

用现有的 75 条评测集(`AIProxy/eval/`),通过 OpenRouter 测 3 个候选模型的**解析准确率、延迟和单次成本**,
为「把生产后台从 GLM Coding Plan 换成 OpenRouter 按量付费」选出**主力**和**备用**。

## 1. 背景(为什么要测)

- 生产后台现在用的是 GLM Coding Plan 订阅的 Key,按 z.ai 使用政策不能用作 App 后台,上线前必须换掉。
- 2026-10-17 改过提示词的 few-shot 示例,`AIProxy/eval/README.md` §6 明确要求「按新 prompt 重跑全模型」。
  **09-22 的旧结果(air 97.2% 等)不能再拿来比较**,本轮的 `or-glm-4.5-air` 就是新基线。
- OpenRouter 会把同一个模型分给不同托管商,有的可能是量化版本,质量和延迟都可能和 z.ai 不同,必须实测。

## 2. 候选模型

| 标签(`--label`) | OpenRouter 模型 ID | 角色 |
|---|---|---|
| `or-glm-4.5-air` | 以 §4.1 查到的为准(预期 `z-ai/glm-4.5-air`) | 现主力同款,本轮基线 |
| `or-gemini-3.5-flash` | 以 §4.1 查到的为准(预期在 `google/` 下) | 用户指定的新候选,不同模型族,适合做备用 |
| `or-glm-5.x` | 以 §4.1 查到的为准(`z-ai/` 下的 GLM 5 系列;现备用经人工核实为 GLM 5.2) | 现备用同款 |

规则:
- **模型 ID 必须从 OpenRouter 模型列表里查到原文**,不要凭记忆拼写。查不到某个模型就在结果文档里记录「未上架」并跳过它,**不要静默换成别的模型**。
- 标签里的版本号按实际 ID 写(例如实际是 GLM 5.2 就用 `or-glm-5.2`)。
- 本轮**全部使用默认参数**(不传推理开关、不指定托管商),因为生产代码目前也传不了这些参数(见 §7)。
- 跑的顺序:`or-glm-4.5-air` → `or-gemini-3.5-flash` → `or-glm-5.x`。时间不够时,至少保证前两个跑完。

## 3. 前置检查(任何一项不满足就停下来问人,不要绕过)

| # | 检查 | 方法 |
|---|---|---|
| 1 | 环境里有 OpenRouter 的 Key | 环境变量 `OPENROUTER_API_KEY` 非空。**不要打印它的值**,检查时只看是否非空:`[ -n "$OPENROUTER_API_KEY" ] && echo set` |
| 2 | 能访问 `openrouter.ai` | `curl -sS -o /dev/null -w '%{http_code}\n' https://openrouter.ai/api/v1/models` 应为 `200`。如果是 `000`、代理报 403 或 `connect_rejected`,说明所在环境的网络策略没放行 `openrouter.ai`,停下来请人在环境设置的 Allowed domains 里加上它 |
| 3 | Node ≥ 18、依赖已装 | `node -v`;`cd AIProxy && npm ci` |
| 4 | 在评测窗口内 | `date -u '+%A'` 是 Tuesday / Wednesday / Thursday |
| 5 | 预算 | 3 个模型 × 75 条 × 约 6k 输入 token ≈ 135 万输入 token,按常见的 Flash 级价格大约 1 到 2 美元。确认这个 Key 有足够余额或额度上限 |

**禁止**:用 z.ai / GLM Coding Plan 的任何 Key 跑本次评测(违反其使用政策);把 Key 写进任何会被提交的文件;
在日志、结果文档里出现 Key 原文。

## 4. 执行步骤

所有命令都在仓库根目录下的 `AIProxy/` 里执行,除非另有说明。

### 4.1 查模型 ID 和价格

```bash
curl -sS https://openrouter.ai/api/v1/models \
  | jq -r '.data[] | select(.id | test("glm|gemini"; "i")) | "\(.id)\tprompt=\(.pricing.prompt)\tcompletion=\(.pricing.completion)"'
```

把三个候选的**确切 ID** 和每 token 单价抄进结果文档。

### 4.2 直连预检(每个模型一次,确认 JSON 模式可用)

生产代码发给 OpenAI 兼容接口的请求带 `response_format: {"type": "json_object"}` 和 `temperature: 0`
(`AIProxy/src/adapters/openai.js`),预检用同样的参数:

```bash
MODEL_ID="<4.1 查到的 ID>"
curl -sS https://openrouter.ai/api/v1/chat/completions \
  -H "Authorization: Bearer $OPENROUTER_API_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"$MODEL_ID\",\"temperature\":0,\"response_format\":{\"type\":\"json_object\"},\"messages\":[{\"role\":\"system\",\"content\":\"Return JSON only: {\\\"ok\\\": true}\"},{\"role\":\"user\",\"content\":\"ping\"}]}" \
  | jq '{provider, model, usage, content: .choices[0].message.content, error}'
```

通过条件:HTTP 200、`content` 是合法 JSON。记录返回的 `provider`(实际托管商)。
如果返回 400 且和 `response_format` 有关,**记录原文并跳过这个模型**,不要改生产代码去适配(那是另一个任务)。

### 4.3 生成单模型的评测配置

评测期间 `PROVIDERS` 只能有一条(`eval/README.md` §1.1:多条会在超时时静默切换,导致结果混样)。
下面的脚本从 `wrangler.toml` 生成 `wrangler.eval.toml`(已 gitignore),做两件事:

- 只保留一个指向 OpenRouter 的条目;
- 把额度闸门调大。**这一步不能省**:本地所有请求都来自同一个 IP,而 `IP_RATE_PER_MINUTE = 10`,
  评测脚本每 300ms 发一次请求,不调大就会被 429 拦下。

```bash
cat > /tmp/gen_eval_toml.py <<'PY'
import re, sys
model = sys.argv[1]
s = open("wrangler.toml", encoding="utf-8").read()
overrides = {
    "DAILY_REQUEST_LIMIT": "1000",
    "IP_RATE_PER_MINUTE": "100000",
    "IP_DAILY_LIMIT": "100000",
    "GLOBAL_DAILY_LIMIT": "100000",
    "GLOBAL_PRO_DAILY_LIMIT": "100000",
}
for key, value in overrides.items():
    s, n = re.subn(rf'(?m)^{key}\s*=\s*"[^"]*"', f'{key} = "{value}"', s)
    assert n == 1, f"{key}: expected exactly 1 match, got {n}"
entry = (
    "[\n  {\n"
    '    "id": "OPENROUTER_EVAL",\n'
    '    "type": "openai",\n'
    '    "url": "https://openrouter.ai/api/v1/chat/completions",\n'
    f'    "model": "{model}",\n'
    '    "priority": 1,\n'
    '    "weight": 10,\n'
    '    "enabled": true,\n'
    '    "secretName": "PROVIDER_KEY_OPENROUTER",\n'
    '    "timeoutMs": 30000\n'
    "  }\n]"
)
s, n = re.subn(r"(?ms)^PROVIDERS\s*=\s*'''.*?'''", lambda m: "PROVIDERS = '''\n" + entry + "\n'''", s)
assert n == 1, f"PROVIDERS block: expected 1, got {n}"
open("wrangler.eval.toml", "w", encoding="utf-8").write(s)
print("wrangler.eval.toml written, model =", model)
PY
python3 /tmp/gen_eval_toml.py "$MODEL_ID"
```

`timeoutMs` 保持和生产一致的 30 秒:单条超过 30 秒本身就说明这个模型不适合做实时解析,应当作为结果暴露出来,而不是调大超时掩盖。

### 4.4 写本地密钥文件 `.dev.vars`(已 gitignore)

用环境变量写入,**不要把 Key 原文粘贴进命令**:

```bash
umask 077
cat > .dev.vars <<EOF
APP_TOKEN=$(openssl rand -hex 16)
LOG_HASH_SALT=$(openssl rand -hex 32)
PROVIDER_KEY_OPENROUTER=${OPENROUTER_API_KEY}
EOF
APP_TOKEN_LOCAL=$(grep '^APP_TOKEN=' .dev.vars | cut -d= -f2)
```

### 4.5 启动本地 worker 并冒烟测试

```bash
npx wrangler dev -c wrangler.eval.toml --port 8787 > /tmp/wrangler-dev.log 2>&1 &
# 等健康检查返回(通常 10 秒内):
for i in $(seq 1 60); do curl -s -o /dev/null http://localhost:8787/v1/health && break; sleep 1; done
curl -sS http://localhost:8787/v1/health      # 应看到 providers 里只有 OPENROUTER_EVAL

curl -sS -N http://localhost:8787/v1/todo-extractions \
  -H "Content-Type: application/json" \
  -H "X-App-Token: $APP_TOKEN_LOCAL" \
  -H "X-Device-ID: eval-smoke-$(date +%s)" \
  -H "X-Local-Date: $(date -u +%F)" \
  -d '{"transcript":"明天下午三点开会","locale":"zh","stream":true}'
```

通过条件:输出若干行 `data: {"text": ...}`,最后是 `data: [DONE]`。

- 返回 `503 AI proxy failed`:看 `/tmp/wrangler-dev.log` 里 `proxy.provider` 开头的日志。如果是网络被拒,回到 §3 第 2 条。
- 日志里 `sparrow.cloudflare.com`、`workers.cloudflare.com` 连接失败、`Unable to fetch the Request.cf object` 的警告**可以忽略**
  (wrangler 的遥测和元数据请求,不影响评测)。

**停止 worker**:用 `kill <PID>`(`pgrep -f workerd` 或 `jobs -p` 查 PID)。
⚠️ 不要用 `pkill -f 'wrangler dev'`:如果你的命令行里本身包含这几个字,会把执行命令的 shell 一起杀掉。

### 4.6 跑评测

```bash
cd eval
node run.mjs --endpoint http://localhost:8787 --token "$APP_TOKEN_LOCAL" --label or-glm-4.5-air
cd ..
```

- 每个模型约 6 到 15 分钟。runner 结束时会打印准确率、各语言结果、字段准确率和延迟(mean / p95 / max),**把这段输出完整抄进结果文档**。
- 原始结果自动存到 `eval/results/<label>-<时间戳>.json`(已 gitignore,**不要提交**)。
- 为什么只能周二到周四跑:测试集里的相对日期按「周三」计算,runner 会在 UTC 今天前后 1 天内找一个周三作为基准日,
  而 worker 只接受和服务器日期相差不超过 1 天的 `X-Local-Date`。其他日子 runner 会直接报错退出。
- **不要跨窗口 `--resume`**:换一周后基准日不同,runner 会因为日期被拒而中止。没跑完的模型下一轮整个重跑。

**换下一个模型**:停掉 worker → 用新的 `MODEL_ID` 重新执行 §4.3 的生成脚本 → 回到 §4.5 启动并冒烟 → §4.6 换 `--label` 再跑。

### 4.7 处理基础设施错误

5xx、超时、429、JSON 解析失败会记为 `infra_error`,不计入准确率,runner 结束前会自动重试一次;仍失败时退出码是 2。

- 某个模型 `infra_error` 超过 3 条:这一轮结果的可信度不够。查 `results/*.json` 里的 `error` 字段找原因;
  如果是偶发,整个模型重跑一次;如果是持续超时或某种固定报错,作为结论写进结果文档。

### 4.8 (可选)记录实际成本

如果能查到这个 Key 的累计用量(OpenRouter 提供查询当前 Key 用量的接口,具体路径以 OpenRouter 文档为准),
就在每个模型跑之前和之后各读一次,差值除以用例数就是单次实际成本。查不到就用 §4.1 的单价估算:
单次成本 ≈ 6000 × 输入单价 + 250 × 输出单价,并在结果文档里注明是估算。

### 4.9 收尾

```bash
kill <worker PID>
rm -f .dev.vars wrangler.eval.toml
git status --short        # 不应该出现 .dev.vars、wrangler.eval.toml、eval/results/
```

## 5. 评分与过关线

评分口径不变,见 `AIProxy/eval/README.md` §3。过关线在 §4.1 基础上按本轮情况调整:

1. **case 全对率 ≥ 98%**:75 条剔除白名单 `zh-017`、`ja-014` 后的 73 条里,最多错 1 条。ja 自 10-17 起计入(README §6)。
2. **日期组不退步**:`due_date`、`due_time`、`recurrence_rule` 三列的字段准确率,都不低于本轮的 `or-glm-4.5-air`。
   如果 `or-glm-4.5-air` 本身没过第 1 条,则三列各自需 ≥ 98%。
3. 原 README §4.1 第 3 条「与 Sonnet 基线差距 ≤ 1pp」**本轮不适用**(那个基线已经作废)。
4. **延迟**:p95 不超过 10 秒(生产实测 glm-4.5-air 约 5.5 到 6 秒)。超过的照常记录,并标注「不适合做实时主力」。

## 6. 选型建议规则(结果文档里给出建议,最终由人决定)

| 情况 | 建议 |
|---|---|
| 多个模型过关 | **主力**:按「准确率 → p95 延迟 → 单次成本」的顺序选最优;**备用**:选另一个模型族(GLM 与 Gemini 互为备用)里的过关者 |
| 只有一个过关 | 它做主力;备用暂缺,在结果文档里写明 |
| 都没过关 | 不建议切换;列出各模型失败集中在哪些字段和用例,供下一步改 prompt 参考 |
| 准确率过关但 p95 > 10 秒 | 先做 §7 的第二轮(关闭推理)再决定 |

## 7. 可选第二轮:关闭推理再测(需要先有代码支持)

Gemini 3.5 Flash 和 GLM 系列都可能默认开启推理(思考),这会拉长延迟、增加 token。
OpenRouter 有统一的推理控制参数(具体字段以 OpenRouter 文档为准),但生产代码目前**没办法**把额外参数传给上游。
`docs/capacity-scenario-a-task.md` 的任务 A3(`extraBody` 配置)合进 main 之后,才能在配置里关闭推理并重跑,
标签加后缀 `-noreason`。**本轮不要为此改代码。**

## 8. 约束

- 不改 `AIProxy/src/`、提示词和评测集;不改 `wrangler.toml`(只用生成出来的 `wrangler.eval.toml`)。
- 不部署,不碰线上配置和管理接口。
- 不提交 `.dev.vars`、`wrangler.eval.toml`、`eval/results/`。
- 结果文档在**从最新 main 拉出的新分支**上提交并推送,**不合 main**。
- 如果这是个临时 Key,评测结束后提醒人去 OpenRouter 后台撤销它。

## 9. 结果文档格式(`docs/openrouter-eval-results.md`)

1. **运行信息**:日期(UTC)、本次基准日 `anchorToday`、执行环境(云端会话还是本机)、实际跑了哪些模型。
2. **模型信息表**:标签、OpenRouter 模型 ID、预检返回的实际托管商、输入与输出单价。
3. **结果总表**:每个模型一行——case 全对率(总体与 en / zh / ja)、`infra_error` 数、`due_date` / `due_time` /
   `recurrence_rule` 字段准确率、延迟 mean / p95 / max、单次成本(注明实测还是估算)、错误用例 ID 列表。
4. **每个模型的 runner 原始汇总输出**(终端里打印的那段,不是 JSON)。
5. **是否过关**:按 §5 逐条判断。
6. **选型建议**:按 §6 给出主力和备用,并说明理由。
7. **偏离任务书的地方**及理由(没有就写「无」)。
8. **待人工处理**:例如某模型未上架、JSON 模式不被支持、Key 需要撤销等。

## 10. 起草时已在本仓库验证过的事项

- §4.3 的生成脚本能正确改写当前 `wrangler.toml`:5 个闸门值各命中一次,`PROVIDERS` 里的 JSON 能正常解析,
  `wrangler deploy --dry-run -c wrangler.eval.toml` 打包通过。
- `wrangler dev` 本地启动**不需要登录 Cloudflare**;`/v1/health` 正常,只列出 `OPENROUTER_EVAL`。
- §4.5 的冒烟请求格式能被 worker 正确接收,worker 会通过环境代理向 `openrouter.ai` 发请求。
  起草环境因为网络策略拒绝了 `openrouter.ai`,所以只验证到这一步,没有拿到真实的模型响应。

## 11. 给人看的提醒(不归执行者)

- **Gemini 的地区条款**:Google 的 Gemini API 也有支持地区的限制。如果评测后打算把它用在生产上,
  需要人工确认在你的情况(开发者所在地、用户所在地)下经 OpenRouter 使用是否符合 Google 的条款。这不影响本轮评测。
- 生产环境的 Key 应该另建一个长期 Key,由人用 `npx wrangler secret put PROVIDER_KEY_OPENROUTER` 注入,不要复用这个临时 Key。
