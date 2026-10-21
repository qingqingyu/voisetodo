# 任务书:早高峰并发加固——429 不计熔断 + 并发压测

> 2026-10-21 起草。本文档是**交给执行者的任务书**,不是结果。
> 执行者完成后,把结果写进 `docs/concurrency-hardening-results.md`(格式见 §6),
> 再交回审查。

---

## 0. 背景(执行前必读)

### 0.1 线上容量

| 顺序 | provider id | 模型 | key | 并发上限 | 单次成本 |
|---|---|---|---|---|---|
| 主力(admin 钉头) | `ZAI_ANTHROPIC_AIR` | glm-4.5-air | `PROVIDER_KEY_ZAI_ANTHROPIC` | **10**(z.ai 控制台实查) | ≈$0.0014 |
| 备胎 | `ZAI_ANTHROPIC` | claude-sonnet-4-5 | `PROVIDER_KEY_ZAI_ANTHROPIC_2` | 未知(待确认是否独立账号) | ≈$0.021 |
| 停用 | `CLAWTO_OPENAI` / `GETTOKEN_OPENAI` | — | — | — | 评测不过线 |

单次解析 ≈ 6 秒(流式,连接全程占用),主力 ≈ 每分钟 100 次吞吐。

### 0.2 超限时的现有链路

1. 上游返回 429 → `classifyHttpRetryable`(`AIProxy/src/adapters/base.js:95`)判为 retryable,
   `errorType = "status_429"` → `executeWithFailover`(`AIProxy/src/provider.js`)切下一家。
2. **同时** `healthStore.recordFailure(provider.id, "status_429")`(`provider.js` 非 2xx 分支,
   约 `:193`)→ 计入 `consecutiveFailures`。
3. 连续 5 次 → 熔断 `open`(`AIProxy/src/health.js`),冷却 10s;half-open 试探失败则冷却翻倍,
   上限 5 分钟。
4. 两家都 open → `pickCandidates` 返回空 → `worker.js:345` 直接 503,**一次上游都不打**。
5. 客户端收到 503 → `.serviceUnavailable` → 退避 1s/2s(带抖动)重试,共 3 次
   (`Extractor/TodoExtractorService.swift:55`)→ 仍失败则原文落 pending,前台恢复时补解析。

### 0.3 要解决的问题

429 的含义是「**此刻忙**」(并发/速率),不是「坏了」。把它计入熔断,会把几十秒的
并发高峰放大成「两家都熔断 → 数分钟内所有请求 0 尝试直接 503」,而那段时间主力
其实陆续有空位。客户端 3 次重试再把同时请求数放大约 3 倍。

---

## 1. 任务 A:429 不计熔断

### 1.1 目标行为

| 上游响应 | failover 到下一家 | 计入熔断(recordFailure) | 备注 |
|---|---|---|---|
| 429,**忙**(并发/速率) | ✅ 是(现状不变) | ❌ **否**(本次修改) | 也不算成功,不重置 `consecutiveFailures`,不改变 half-open 状态 |
| 429,**余额/额度耗尽** | ✅ 是 | ✅ **是**(保持熔断) | 不会自己恢复,必须熔断,否则每个请求都先白打一次 |
| 5xx / timeout / network / invalid_response | ✅ 是 | ✅ 是 | 现状不变 |
| 401/403 | ✅ 是 | ✅ 是 | 现状不变 |

### 1.2 实现约束

1. **区分两种 429**:复用 `base.js` 现有的 `AUTH_REASON_PATTERNS` 里
   `insufficient_balance` 那组关键词(`insufficient_quota` / `exceeded your current quota` /
   `余额不足` / `欠费` 等)。命中 → 新 errorType(建议 `quota_exhausted`),计熔断;
   未命中 → `status_429`,不计熔断。**先查 z.ai 文档里 429 的错误体格式**,把它真实
   使用的关键词/错误码补进去,并在结果文档里写明出处。
2. **改动点集中在一处**:在 provider.js 调 `recordFailure` 前加判断,或给 classification
   加一个 `countsTowardCircuit` 字段由 base.js 统一决定。**不要**在 health.js 里按
   errorType 字符串特判(那样分类逻辑会散落两处)。
3. 三个 adapter(anthropic / openai / gemini)都走 `classifyHttpRetryable`,确认改动对三者
   同时生效。
4. 日志:429 忙的那次 attempt 仍要进 `providerAttempts[]` 和 `logProviderFailure`,
   errorType 保持 `status_429`,方便上线后在 D1/日志里统计「上游忙」次数。
5. **不改**:客户端 Swift 代码、`AI_PROVIDER_MAX_ATTEMPTS`、熔断阈值/冷却参数、
   `wrangler.toml` 的 provider 列表。

### 1.3 必须新增的测试(写进 `AIProxy/worker.test.js`,沿用现有 P4 熔断测试的写法)

1. 主力连续 10 次 429(忙)→ 熔断保持 `closed`;每次都 failover 到备胎且备胎成功。
2. 主力连续 5 次 429 且错误体含余额不足关键词 → 熔断 `open`。
3. half-open 状态下试探遇到 429(忙)→ **不**重新 open、冷却**不**翻倍。
4. 主力 429(忙)+ 备胎 429(忙)→ 本次请求 503;再发一次请求,主力**仍然**是第一候选
   (证明没被摘除)。
5. 5xx 连续 5 次仍会熔断(回归,证明没误伤原有行为)。

**红绿验证**:对第 1、3、4 条,先在未改代码上跑出红,再改代码跑绿。结果文档里贴两次
输出的关键行。

### 1.4 验收

- `cd AIProxy && npm test` 全绿,贴通过数(当前基线以执行时为准,记录前后对比)。
- `git diff` 只涉及 `AIProxy/src/`、`AIProxy/worker.test.js` 和文档。

---

## 2. 任务 B:并发压测(进程内模拟,不打真实上游)

### 2.1 为什么进程内模拟

- `src/config.js:71` 要求 provider url 必须 `https://`,本地 mock 服务器接不进 `wrangler dev`。
- 不消耗 z.ai 真实额度和并发名额,结果可重复。
- `worker.test.js` 已经有 stub `fetch` + 伪造 env(KV/DO)的模式,直接复用。

### 2.2 要写的东西

新建 `AIProxy/loadtest/run.mjs`(纯 Node,零新依赖),做法:

1. import worker 的 `handleRequest`(或 default export 的 `fetch`),构造与 `worker.test.js`
   同口径的 env:两个 enabled provider(`AIR`、`SONNET`)、admin 钉头 = AIR、KV/DO 用测试里的内存实现。
2. stub `globalThis.fetch` 为「mock 上游」:
   - 每个 provider 独立一个并发计数器,**上限可配**(默认 AIR=10、SONNET=10);
   - 超过上限立即返回 429(忙),错误体用 z.ai 的真实格式;
   - 未超限则 `await sleep(latency)` 后返回一个合法的流式/非流式解析结果
     (latency 默认按比例缩小:真实 6s → 模拟 600ms,所有时间参数同比例缩,在报告里注明);
   - 可选开关:`--balance-exhausted AIR` 让 AIR 永远返回余额不足的 429。
3. 模拟客户端:N 个虚拟用户,每人独立 `X-Device-ID`、独立 `CF-Connecting-IP`
   (否则会先撞 IP 限流,测不到上游),按「客户端真实重试策略」发请求——
   503 时退避 1s/2s(+0~30% 抖动,同比例缩小),最多 3 次;3 次都失败记为「落 pending」。
4. 为避免撞到额度闸门而污染结论,模拟 env 里把 `DAILY_REQUEST_LIMIT`、`GLOBAL_DAILY_LIMIT`、
   `IP_RATE_PER_MINUTE` 调到足够大。**另跑一组「生产真实闸门值」**,单独报告闸门本身在高峰时拦掉多少。
5. 两种到达模式:
   - **同时到达**:N 个人在同一刻发起;
   - **一分钟内均匀到达**:N 个请求在(缩放后的)60 秒内均匀/泊松分布到达。

### 2.3 要跑的矩阵

| N(并发用户) | 到达模式 | 代码版本 |
|---|---|---|
| 20 / 50 / 100 / 200 / 1000 | 同时 | 改前(main)/ 改后(任务 A) |
| 100 / 200 / 500 | 一分钟内 | 改前 / 改后 |
| 100 | 同时 + AIR 余额耗尽 | 改后(验证 quota_exhausted 仍熔断) |

每组输出:

- 即时成功率(第 1 次尝试就成功)、最终成功率(含客户端重试)、落 pending 比例;
- 各 provider 接到的请求数、429 次数、熔断 open 次数与总时长;
- 用户侧耗时 P50 / P95(换算回真实时间);
- 「两家都熔断 → 0 尝试 503」发生的次数(改前预期 >0,改后预期 0)。

### 2.4 约束

- **不打真实 z.ai / 生产代理**。如果想做小规模真实验证(≤15 并发确认 z.ai 429 的真实错误体),
  先停下来问人,拿到许可和 key 再做。
- 不部署任何东西。
- `loadtest/` 不进 `npm test`(会拖慢 CI 式自测),单独用 `node loadtest/run.mjs` 跑。

---

## 3. 执行顺序

1. 从最新 `main` 拉分支(名字自定,例如 `bingfa`),**不要直接在 main 上改**。
2. 先写任务 B 的压测脚本,在**改前代码**上跑完矩阵,留存结果——这是对照组。
3. 做任务 A(先红后绿)。
4. 在改后代码上再跑一遍矩阵。
5. 写结果文档,提交、推送分支。**不合 main**,等审查。

---

## 4. 不在范围内(看到也只记录,不改)

- 代理侧排队/削峰(DO 信号量,超限请求等几秒再打而不是立刻失败)——数据证明需要再做。
- 客户端重试策略、超时、熔断参数。
- 向 z.ai 申请提额、确认 Sonnet 的 key 是否独立账号——这是人工动作,结果文档里只列为待办。
- 503 响应带 `Retry-After`。

---

## 5. 风险提示(执行时注意)

- **别把 429 变成「成功」**:不计熔断 ≠ recordSuccess。recordSuccess 会更新延迟 EWMA,
  一次瞬间返回的 429 记成成功会让 selector 误以为这家「极快」而把更多流量压过去。
- half-open 是「单次试探槽」:试探遇到 429(忙)时,确认下一次请求仍能再试探,
  不会卡死在 half-open 永远不放量。
- 余额耗尽的关键词匹配要大小写无关、中英文都覆盖;匹配不到时宁可当「忙」处理
  (最坏是每个请求多白打一次很快返回的 429),不要当「坏」处理。

---

## 6. 结果文档格式(`docs/concurrency-hardening-results.md`)

1. **改动摘要**:改了哪些文件、核心逻辑一句话、z.ai 429 错误体的出处。
2. **测试**:`npm test` 前后通过数;§1.3 五条测试的红绿输出关键行。
3. **压测结果表**:§2.3 矩阵每一行一条,改前/改后并排。
4. **结论**:改后在多少并发以内「最终成功率 ≥ 95%」;超过之后瓶颈在哪
   (上游并发 / 额度闸门 / 客户端重试)。
5. **偏离任务书的地方**及理由(没有就写「无」)。
6. **待人工确认/待办**(例如 z.ai 提额、Sonnet key 是否独立账号)。
