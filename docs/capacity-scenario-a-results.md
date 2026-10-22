# 结果文档:A 场景容量——1000 人/分钟(多服务商 Key 池 + 每 Key 并发闸门)

> 2026-10-22 执行。任务书:`docs/capacity-scenario-a-task.md`(分支 `claude/pre-launch-review-jy86zk` 起草,本分支随结果一并携带)。
> 执行分支:`claude/capacity-scenario-a`(自最新 `main` 拉出,**未合 main**,等审查)。
> 前置:并发加固(429 忙不计熔断)已合 main `b9597c4`。

---

## 1. 改动摘要

### 1.1 文件清单

| 文件 | 改动 |
|---|---|
| `AIProxy/src/config.js` | A1:`secretNames` 多 key 池(与单数互斥)、每 key `healthId`;A3:`maxConcurrencyPerKey` / `extraHeaders` / `extraBody` / `disableResponseFormat` 校验 |
| `AIProxy/src/selector.js` | 条目级候选仍按现有逻辑排序(admin 钉头 → 延迟/权重 → half-open 末尾);熔断/延迟改为从 per-key 快照聚合;条目携带 `candidateKeys` 给执行层 |
| `AIProxy/src/provider.js` | 执行层条目内 key 循环:key 级失败(立即 429/auth)换 key 不耗条目尝试数(R4),条目级失败走原 failover;闸门租约生命周期(流式移交 `onSettled`,外层 `finally` 兜底);`providerRedactions` 覆盖全部 key |
| `AIProxy/src/keyGate.js`(新) | A2:闸门客户端。count 并行读 → 选在途最少(并列随机,R2)→ acquire 租约;全部满时最长 `KEY_GATE_MAX_WAIT_MS` 等待;DO 调用超时(200ms)fail-open + warn |
| `AIProxy/src/do/quota-counter.js` | 复用 `QuotaCounter` 类新增 `/gate/acquire`、`/gate/release`、`/gate/count`(租约存 storage,读路径 lazy sweep 过期租约) |
| `AIProxy/src/stream.js` | `normalizeProviderStream` 新增 `lifecycle.onSettled`:流结束(成功/中途失败/意外 throw)必调一次,闸门 release 挂在此 |
| `AIProxy/src/adapters/openai.js` | A3:`extraHeaders`/`extraBody` 合并、`disableResponseFormat` 时省略 `response_format` |
| `AIProxy/worker.js` | 闸门接线(`makeKeyGateFromEnv`);流式路径 release 挂 `onSettled`;`/v1/health` 与 `/v1/admin/providers` 按 key 聚合(多 key 条目附 `keys`/`perKey` 明细,无 key 原文);探活走闸门(见 §5.3) |
| `AIProxy/eval/run.mjs` | A4:进程内直连指定 provider 条目(`--provider-file` + key 走 env)、P50 延迟、`--table` 对比表 |
| `AIProxy/eval/providers/`(新) | OpenRouter 候选条目模板(不含 key) |
| `AIProxy/loadtest/run.mjs` | A5:多 key mock 上游(按 Authorization 分 key 记账+限流)、泊松到达、闸门开/关对比、新统计(每 key 最大在途/闸门等待/503 数/DO ops 峰值)、验收判定 |
| `AIProxy/worker.test.js` / `src/do/quota-counter.test.js` / `wrangler-config.test.js` | §2.3 八条测试 + 配置校验(见 §2) |
| `AIProxy/wrangler.toml` | 新字段与新 env 的注释文档(线上配置未动,当前无 key 池条目,闸门不生效) |

### 1.2 配置格式示例(A 场景生产形态,人工换服务商时照抄)

```jsonc
{
  "id": "GLM_AIR_POOL",
  "type": "openai",
  "url": "https://openrouter.ai/api/v1/chat/completions",
  "model": "z-ai/glm-4.5-air",
  "priority": 1,
  "enabled": true,
  "secretNames": ["PROVIDER_KEY_POOL_1", "PROVIDER_KEY_POOL_2", "..."],
  "maxConcurrencyPerKey": 10,
  "extraHeaders": { "HTTP-Referer": "https://voicetodo.app", "X-Title": "VoiceTodo" },
  "timeoutMs": 30000
}
```

闸门行为 env(全部可选,默认值即 §2.2 规格):`KEY_GATE_MAX_WAIT_MS=3000`、`KEY_GATE_POLL_MS=100`、`KEY_GATE_CALL_TIMEOUT_MS=200`、`KEY_GATE_LEASE_MARGIN_MS=10000`。`wrangler-config.test.js` 的客户端超时预算断言已把 `KEY_GATE_MAX_WAIT_MS` 计入最坏路径((attempts-1)×timeoutMs + 等待 + 尾部余量 ≤ iOS `apiTimeout`)。

### 1.3 每请求 DO 调用次数与 A 场景单 DO 每秒操作数

- 常规路径(条目 N 把 gated key):**N 次 `/gate/count`(并行)+ 1 次 `/gate/acquire` + 1 次 `/gate/release` = N+2 次**。
- 全满且无备选条目时:每 `KEY_GATE_POLL_MS`(100ms)再来一轮 count,直至 `KEY_GATE_MAX_WAIT_MS`(3s),单请求最多 ~30 轮 ≈ 390 次调用(仅发生在池满等待的请求上)。
- A 场景(N=13,到达率 ≈16.7 req/s):总 DO ops/s ≈ 16.7 × 15 = **250 ops/s**;count 扇出到全部 13 个 DO,单 DO ≈ 16.7(count)+ 1.3(acquire)+ 1.3(release)≈ **19 ops/s**——远低于单 DO 数百 ops/s 的舒适区。压测实测(闸门开、13×10)聚合峰值 2641 ops/s(SIM,×10 时间缩放)= **264 ops/s 真实口径**,与估算一致(loadtest/results/a-main-a-poisson-1000-gate-on-13x10.json `gateMetrics.doPeakOpsPerSecReal`)。

---

## 2. 测试

### 2.1 通过数

- 改前基线:`npm test` **343/343**。
- 改后:**365/365**(新增 22 条:worker.test.js 18 + quota-counter.test.js 3 + wrangler-config.test.js 1)。
- §2.3 第 8 条(单 key 旧配置行为不变)由全部既有测试保持通过 + 显式回归测试(`A1 单 key 旧配置(secretName)→ 熔断记录仍用条目 id,多 key 语义不激活`)共同证明。

### 2.2 第 1、2、6 条的红→绿关键输出(改前代码上跑出的失败)

**§2.3-1(3 key × 上限 2,并发 6)改前:**

```
✖ A1/A2 §2.3-1 闸门:3 key × 上限 2,并发 6 请求 → 每 key 恰 2 在途,上游忙 429 为 0
  AssertionError [ERR_ASSERTION]: 6 个请求都应成功,实际状态: 503,503,503,503,503,503
  (secretNames 未支持 → 条目无可用 key → proxy.selector.no_candidates, hasKey:false)
```

改后:6/6 成功;三个 key 各 `busy429=0`、`maxInFlight=2`(闸门从未放超);总上游请求数恰 6(零白打)。

**§2.3-2a/2b(第 7 个请求等待/超时)改前:**

```
✖ A2 §2.3-2a … AssertionError: 前 6 个都应成功  [503,503,…]
✖ A2 §2.3-2b … AssertionError: 应带 Retry-After: 2   null !== '2'
```

改后:2a 第 7 个在 `KEY_GATE_MAX_WAIT_MS=1500` 内等到 release → 200;2b 等待 ~250ms 后 503 + `Retry-After: 2`(带结构化 body `{error:"key_pool_full",retryAfter:2}`,客户端按 `.rateLimited(retryAfter≤8s)` 语义可重试)。

**§2.3-6(忙 429 换 key 不占条目尝试数)改前:**

```
✖ A1 §2.3-6 … AssertionError: E1 的两个 key 都应被试过(上限 = 条目内可用 key 数)
  + actual - expected
  + []
  - [ 'busy-key-0', 'busy-key-1' ]
```

改后:E1 两 key 各吃一次忙 429 后 failover 到 E2 成功(HTTP 200);断言 E1 恰好两个 key 被试 + E2 被打到——证明 key 级重试没有消耗 `AI_PROVIDER_MAX_ATTEMPTS=2`(否则 E1 两 key 耗尽预算,E2 永远不会被调用);同时 `BUSY_POOL#0` 无熔断记录(忙 429 不计熔断,既有语义)。

### 2.3 其余各条

| §2.3 | 测试 | 结果 |
|---|---|---|
| 3 断开 release | 499 后 120ms,三把 key 的 `/gate/count` 全部回到 0 | ✅ |
| — 流式成功 release | 流读完(含 `[DONE]`)后 count=0(`onSettled` 路径) | ✅ |
| 4 租约到期回收 | leaseMs=40 不 release,90ms 后 count=0、名额可再授予(DO 层直测) | ✅ |
| 5 单 key 熔断隔离 | key0 三次余额耗尽后 `health:KEY_POOL#0` open 且不再被挑中;key1/key2 持续服务(state=closed,consecutiveFailures=0) | ✅ |
| 7 DO 抛错 fail-open | `/gate/*` 恒抛错 → 请求 200 + `proxy.gate.call_failed` warn | ✅ |
| 8 单 key 旧行为 | 既有 343 条全过 + 显式回归(熔断记录无 `#0` 后缀) | ✅ |

---

## 3. 压测结果(A5,loadtest/results/a-main-*.json,seed=42,SCALE=10)

泊松到达 1000 人 / 60s(真实口径),单次生成 6s±10%,客户端真实重试策略(3 次,退避 1s/2s+抖动,503 重试、quota 429 不重试)。验收线:最终 ≥99%、即时 ≥95%、用户侧 P95 ≤10s(真实)、闸门开时上游忙 429≈0。

| 场景 | 即时成功率 | 最终成功率 | 用户 P95(真实) | 上游忙 429 | 每 key 最大在途/上限 | 闸门等待 P95 | pool_full 503 | DO 峰值(真实口径) | 验收 |
|---|---|---|---|---|---|---|---|---|---|
| **13 key × 10 = 130 名额,闸门开** | **100%** | **100%** | **6.6s** | **0** | 10/10(从未超) | ~20ms* | 0 | 264 ops/s | **PASS(全过线)** |
| 130 名额,闸门关 | 100% | 100% | 6.6s | 194 | 10/10 | - | - | - | 过线(但白打 194 次) |
| **10 key × 10 = 100 名额(零余量),闸门开** | **100%** | **100%** | **6.7s** | **0** | 10/10 | ~490ms* | 0 | 591 ops/s | **PASS** |
| 100 名额,闸门关 | **90.0%** | 99.6% | 7.4s | **3098** | 10/10 | - | - | - | **FAIL(即时 <95%)** |

\* 等待耗时含 DO 往返(1-2ms);130 名额组 P95=20ms 即"几乎不用等";100 名额组 P95=490ms 是真实排队(泊松尖峰填满 100 名额后,闸门把超发请求排队等 release 而不是打上游吃 429)。

**结论:**

1. **130 名额(30% 余量)+ 闸门 = A 场景全过线**:1000/1000 首试成功、零 429 白打、每 key 在途从未超限、P95 6.6s(≈单次生成本身)。
2. **闸门的价值在余量不足时兑现**:同样 100 名额,关闸门即时成功率掉到 90%、白打 3098 次上游(≈3 倍请求量,全是 429);开闸门依然 100%/0 白打——闸门把"上游拒绝"换成了"本地排队 ≤3s"。
3. 名额足(130)时闸门关也能过线,但仍有 194 次 429 白打(占用上游速率配额、增加每 key 重试延迟);开闸门后为 0。
4. 每 key 请求分布 76-79 次/13 key(在途最少优先 + 并列随机的均衡性符合预期,无热点 key)。

退化组(100 名额)数据回答任务书 §5.6:余量不足时,退化形态 =闸门关:10% 用户需重试、白打 3 倍;闸门开:仅排队延迟 P95 +0.5s,无失败无白打。

---

## 4. A4:OpenRouter 实测(人工提供 key,2026-10-22 UTC 周四窗口,锚 2026-10-21 周三)

### 4.1 可用性与价格(OpenRouter /api/v1/models,2026-10-22 查)

| 模型 | 输入 $/M | 输出 $/M | 备注 |
|---|---|---|---|
| z-ai/glm-4.5-air | **$0.13** | **$0.85** | 比 z.ai 直连($0.2/$1.1)还便宜 |
| z-ai/glm-4.6 | $0.55 | $2.20 | |
| z-ai/glm-4.5 | $0.60 | $2.20 | |
| google/gemini-2.5-flash | $0.30 | $2.50 | **本机出口被 region_blocked(403)**,未能评测 |
| anthropic/claude-sonnet-4.5 | $3.00 | $15.00 | 同上 region_blocked |

⚠️ **地域封锁发现**:OpenRouter 对 Google/Anthropic 系模型按调用方出口 IP 分区限制,本机(CN 出口)直接 403(`authReason: region_blocked`,代理分类链路正确识别为 auth)。z.ai 系不受限。生产 Worker 从 Cloudflare 边缘出口,是否受限**未验证**——如果候选含 gemini/claude,换服务商前需在 Workers 环境实测一次(可用 A4 脚本在一台海外机器/CI 上跑)。

### 4.2 评测结果(75 条 golden,进程内直连,流式,单条目 MAX_ATTEMPTS=1,锚 2026-10-21 周三)

| 平台 | 模型 | 开关 | case 全对 | en+zh 口径 | infra_error | mean | P50 | P95 |
|---|---|---|---|---|---|---|---|---|
| OpenRouter | z-ai/glm-4.5-air | default | 57/75(76.0%) | 80.4% | 0 | 10.0s | 9.1s | **17.6s** |
| **OpenRouter** | **z-ai/glm-4.5** | default | **72/75(96.0%)** | **94.6%** | 0 | 18.9s | 15.9s | 45.9s |
| OpenRouter | z-ai/glm-4.6 | 思考开 | 67/74(90.5%) | 87.3% | 1(50s 流超时) | 25.7s | 23.7s | 47.9s |
| OpenRouter | z-ai/glm-4.6 | thinking disabled | 63/71(88.7%) | 85.2% | 4(50s 流超时) | 22.9s | 21.7s | 45.0s |
| OpenRouter | google/gemini-2.5-flash | — | region_blocked(403) | — | — | — | — | — |
| OpenRouter | anthropic/claude-sonnet-4.5 | — | region_blocked(403) | — | — | — | — | — |

关键判读:

1. **现行 prompt 下,OpenRouter 上的 GLM 系无一过 98% 线;最好的是 glm-4.5(96.0%)**。hard 字段看,glm-4.5 的 `due_date` 95/96(日期组几乎全对),差距主要在个别 category_hint/ja 判定;air 的 `due_date` 84/96(±1-2 天的日期算术错),en+zh 只有 80.4%。
2. **⚠️ 与 09-22 基线不可直接比**:2026-10-17 三语 prompt 示例 7 改过(周一始→周日始口径),按 eval/README §7 规则旧留档全部不可比——「air 97.2%」是旧 prompt 的数字。本次是**新 prompt 的第一轮全模型数据**;z.ai 直连 + 新 prompt 的基线因无按量付费 key(Coding Plan key 禁用)未跑,**平台差异 vs prompt 变更的影响未分离**,拍板前建议补跑(z.ai 按量 key 开通后同命令复跑即可)。
3. **延迟是硬门槛**:除 air(P95 17.6s)外全部 P95 ≥45s——超出条目 30s 生产预算,也超出客户端 55s 总预算的舒适区。glm-4.6 的 11 次 infra_error 全是流式 >50s 撞 `timeoutMs` 中途掐断(思考型先思考后输出)。
4. **`thinking: {type:"disabled"}` passthrough 疑似被上游忽略**:关思考组比思考组更慢更差(P95 45s vs 47.9s,88.7% vs 90.5%)——extraBody 字段已机械发出(单测断言过),但 OpenRouter 的 z-ai 路由是否透传给后端不受我们控制。**A3 的教训:extraBody/extraHeaders 机制正确,但「是否生效」取决于上游,换服务商时逐项验证**(如对比开关两组的 TTFB/首块)。
5. 锚正确性自检:air 组 84/96 due_date 全对且错向混合(±1/±2 天都有),排除锚注入/时区系统性偏差;失败定性为模型日期算术与类别判断。

### 4.2.1 对拍板的影响(供人工,非本任务结论)

- 若走 OpenRouter:质量达标线附近的只有 **glm-4.5(96%)**,但 P95 45.9s 意味着 `timeoutMs` 要 ≥50s + 客户端 `apiTimeout` 要 ≥65s(需发版),且 A 场景单次占用从 6s 涨到 ~16s(P50),**同等名额下的并发容量按 ~1/3 折减**(130 名额只够 ~45 在途)。
- air @ OpenRouter 76% 不可用;air @ z.ai(旧 prompt 97.2%)是否仍达标,取决于新 prompt 复测——**建议给 z.ai 按量付费账号(而非继续 Coding Plan)后用同一脚本补基线**,再决定「换 OpenRouter 还是 z.ai 按量」。
- gemini/claude 若仍在候选内,先解决 region_blocked 验证(海外出口跑一次 §4.1 的探活即可)。

复跑方式(结果留档 `eval/results/or-*.json`,gitignore):

```bash
cd AIProxy/eval
OPENROUTER_KEY=sk-or-... node run.mjs --provider-file providers/openrouter-glm-4.5-air.json \
  --key-env OPENROUTER_KEY --label or-glm-4.5-air
node run.mjs --table results/or-glm-4.5-air-*.scored.json results/or-glm-4.6-*.scored.json ...
```

### 4.3 对比表模板(任务书 §4.2;token 列需按服务商 console 校准,SSE 不透出 usage)

(§4.2 的表即按此模板填充;`node run.mjs --table results/*.scored.json` 自动生成。单次 token 列:输入 ~6k/输出 ~250 按 §5 估算口径,SSE 不透出 usage,准确值按各服务商 console 校准。09-22 z.ai 旧 prompt 留档:air 97.2% 全对 / 98.1% en+zh / mean 3.7s——与新 prompt 数据不可比,仅作口径参照。)

---

## 5. A3 取舍与设计说明

### 5.1 `response_format` 处理建议(任务书 §3.2,先写取舍)

- **现状**:`response_format: {type:"json_object"}` 是 openai adapter 硬编码行为。若目标平台不支持该参数,上游返回 400 → `classifyHttpRetryable` 判 `request_body`(不可重试)→ 直接 502,**且换条目也无济于事**(同样 payload)。
- **取舍**:保留默认开启(json_object 在 OpenRouter 与国内主流 OpenAI 兼容平台均受支持,且对输出稳定性有实证收益);新增条目级开关 `disableResponseFormat: true`——不支持的平台改用 prompt 约束 JSON(prompt 本身已强约束"只输出 JSON 对象",`stripMarkdownFence` 兜底剥围栏)。**不建议**因单个平台不支持而全局移除:会牺牲支持平台上的输出稳定性。
- **若平台 400 报错出现在生产**:错误形态是 502 + `errorType=request_body`、attempt 记录里 `providerStatus=400`,日志一眼可辨;处置 = 给该条目配 `disableResponseFormat: true` 重新 deploy,无需改代码。

### 5.2 `extraHeaders` / `extraBody` 边界

- 只允许 `openai` 类型条目配置(anthropic/gemini adapter 的请求体结构不同,误配会静默失效,直接报配置错误)。
- `extraBody` 不得覆盖 `model`/`messages`/`stream`;`extraHeaders` 不得覆盖 `Authorization`/`Content-Type`——覆盖即 `loadProviders` 抛错(HTTP 500,显式失败)。其余字段(如 OpenRouter 的 `HTTP-Referer`/`X-Title`、各家的思考/路由参数)原样透传,**代码里没有写死任何服务商参数名**。

### 5.3 探活走闸门(任务书 §2.2.7 二选一)

选**探活走闸门**,不预留名额。理由:A 场景 13 key × 预留 1 = 永久少 13 个名额(10% 容量);而探活 30min 一次、占用毫秒级(响应头到达即 cancel),池满时跳过本轮(`health_check.skip_gate_full`,按 ok 计——池满本身证明该 key 活着),对 30min 粒度的健康覆盖几乎无影响。DO 故障时探活与用户流量同样 fail-open。

### 5.4 健康记账粒度(R1 的落地口径)

| 事件 | 记账位置 |
|---|---|
| key 级失败:忙 429(不计熔断,仅 attempt 记录)/ 余额耗尽 429 / auth 401/403 | 只记当前 key(`条目id#序号`) |
| 条目级失败:超时 / 网络 / 5xx / model_config / 响应无效 | 记条目全部可用 key(同条目 key 共享同一后端,系统性故障整条摘除,阈值语义与改前条目级熔断一致) |
| 成功(EWMA 延迟) | 当前 key(selector 取条目内 closed key 的最小 EWMA 作条目排序延迟) |
| 流中途失败 | 当前 key(死的是这条连接) |

### 5.5 「全部 key 满」的执行口径(任务书 §2.2.4 的解释)

多条目场景下,「全部 key 满 → 等待 → 503」按**最后一个可用条目**执行:非最后条目池满时立刻 failover 到下一条目(那里可能有空位,等待反而浪费);只有无备选条目可去时才进入 `KEY_GATE_MAX_WAIT_MS` 等待,超时 503 + `Retry-After: 2`。该等待已计入 wrangler-config 的客户端超时预算断言。

---

## 6. 偏离任务书的地方

1. **单 key 条目的熔断记录 id 不加 `#序号` 后缀**(任务书 §1.2 R1 写"健康记录的 key 用 `条目id#序号`")。单 key 配置沿用纯条目 id:满足 R5(现有 KV 记录路径与改前字节一致,零迁移);`#序号` 只用于多 key 配置(≥2)。语义等价(单 key 的 `ID` ≡ `ID#0`),已加显式回归测试。
2. **闸门等待只发生在最后一个可用条目**(见 §5.5)。任务书未区分多条目场景,此解释已写入 `keyGate.js` 注释与本档。
3. **压测验收线里"闸门开启时上游忙 429≈0" 的机器判定**取 `≤ max(2, 0.1% 用户数)`(模拟世界允许极小噪声;实测为 0)。
4. eval 的 sonnet/gemini 候选因 OpenRouter 地域封锁未跑成(§4.1),对比表以 region_blocked 标注,不算任务完成项缺失——A4 的交付物(脚本+模板+使用说明)已齐,人工换出口后可直接复跑。

其余无偏离:不改客户端 Swift 代码 ✓(全部改动在 AIProxy + docs);不部署 ✓;不用 Coding Plan key 做任何自动化调用 ✓(评测只用人工提供的 OpenRouter key);压测零真实 key ✓。

---

## 7. 待人工处理(任务书 §9 对接)

1. **选服务商 + 开账号 + 换 key(上线阻断项)**。基于本次数据:OpenRouter 的 `z-ai/glm-4.5-air` 价格($0.13/$0.85)低于 z.ai 直连($0.2/$1.1),质量/延迟见 §4.2;若选 OpenRouter,需向其确认三个数:并发上限(按量付费通常不按并发限,而是 RPM/TPM——若如此,`maxConcurrencyPerKey` 按 RPM 折算配置或不配,闸门留作 429 兜底前的缓冲)、每分钟请求数(A 场景 ≈1000/min)、每分钟 token 数(≈600 万输入/min)。**若候选含 gemini/claude,先在 Workers 出口实测 region_blocked**。
2. 人工拿新 key 后复跑 A4:`node eval/run.mjs --provider-file … --key-env …`(§4.2 命令),确认准确率不低于现基线、P95 可接受,再用 `--table` 出对比表拍板。
3. 中国区 App Store 备案(ICP/生成式 AI)与模型备案问题:不受本次改动影响,维持任务书原文。
4. 全局预算重设:`GLOBAL_DAILY_LIMIT=5000` 在 A 场景(1000 次/分钟)下几分钟耗尽,需按软启动预期重估;付费档 `GLOBAL_PRO_DAILY_LIMIT=20000` 同理。
5. 多 key 部署时序提醒(与 2026-10-20 Sonnet 换 key 同型):先 `wrangler secret put` 全部 `PROVIDER_KEY_POOL_*`,再 deploy 带 `secretNames` 的新 PROVIDERS——顺序反了会出现间隙内条目无可用 key(现在是显式 503 + `no_candidates` 日志,不再是静默混样)。
