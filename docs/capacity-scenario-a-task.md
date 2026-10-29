# 任务书:A 场景容量——1000 人/分钟(多服务商 Key 池 + 每 Key 并发闸门)

> 2026-10-21 起草。本文档是**交给执行者的任务书**,不是结果。
> 完成后把结果写进 `docs/capacity-scenario-a-results.md`(格式见 §8),交回审查。
> 前置任务:`docs/concurrency-hardening-task.md`(429 忙不计熔断,已合 main `b9597c4`)。

---

## 0. 背景(执行前必读)

### 0.1 目标:A 场景

**1000 个用户在同一分钟内各发起一次解析,几乎都能即时拿到结果。**

| 量 | 估算 | 依据 |
|---|---|---|
| 到达率 | ≈17 次/秒 | 1000 / 60s |
| 单次占用 | ≈6s | `PROMOTION_PLAN.md` 实测,流式全程占连接 |
| 同时在途 | ≈100,按 30% 余量配置 **≥130 个并发名额** | 在途数 = 到达率 × 占用时长 |
| 输入 token | ≈6k/次 → **约 600 万 token/分钟** | `AIProxy/eval/README.md` §5 |
| 输出 token | ≈250/次 → 约 25 万 token/分钟 | 同上 |

B 场景(1000 人同一秒、排队 + SSE 心跳)**不在本任务范围**,另起任务书。

### 0.2 当前上游不能用于生产(人工处理,不归执行者)

- 线上两个 provider 都用的是 **GLM Coding Plan 订阅**的 Key。z.ai 的使用政策规定
  Coding Plan 只能在官方支持的编程工具里使用,SDK 接入、第三方集成属于违规,
  FAQ 也写明套餐额度不能用于这些工具以外的 API 调用;违规累计 3 次封号。
  **App 后台必须换成按量付费的 API**,这是上线阻断项,由人工决定服务商并开通账号。
- `ZAI_ANTHROPIC` 条目名义上是 `claude-sonnet-4-5`,经人工核实 z.ai 实际映射为 **GLM 5.2**。
- 每个 Coding Plan 账号并发上限 10(控制台实查),两个账号独立。

### 0.3 现有代码的限制(执行者要改的)

| 限制 | 位置 | 对 A 场景的影响 |
|---|---|---|
| 一个 provider 条目只能配 1 个 key(`secretName`) | `AIProxy/src/config.js` | 多账号只能复制条目,运维混乱 |
| 同模型多条目按 EWMA 延迟排序 | `AIProxy/src/selector.js` warm 桶 | 流量几乎全压到「最快」那一个 key,其余闲置 |
| 每请求最多尝试 2 个条目 | `AI_PROVIDER_MAX_ATTEMPTS = 2` | 13 个 key 只会试 2 个 |
| 没有按 key 的并发上限 | — | 只能靠上游 429 才知道满了,高峰期大量白打 |

已有、可复用的:
- `openai` adapter 是标准 Chat Completions(`response_format: json_object`、`temperature: 0`),
  可对接 OpenRouter 及国内各家 OpenAI 兼容平台(`AIProxy/src/adapters/openai.js`)。
- system prompt 静态部分在前、日期与词汇提示在末尾(`base.js` `buildSystemPrompt`),
  对上游前缀缓存友好,**不要改这个顺序**。
- 429 忙/余额耗尽已分流(`base.js` `classifyHttpRetryable`,`countsTowardCircuit`)。
- 进程内压测脚本 `AIProxy/loadtest/run.mjs`。

---

## 1. 任务 A1:一个 provider 条目支持多个 key

### 1.1 配置格式(向后兼容)

```jsonc
{
  "id": "GLM_AIR_POOL",
  "type": "openai",
  "url": "https://<兼容 OpenAI 的地址>/v1/chat/completions",
  "model": "<模型名>",
  "priority": 1,
  "enabled": true,
  "secretNames": ["PROVIDER_KEY_POOL_1", "PROVIDER_KEY_POOL_2", "..."], // 新增
  "maxConcurrencyPerKey": 10,   // 新增,可选;不配 = 不限(例如 OpenRouter 按量付费)
  "timeoutMs": 30000
}
```

- 旧的 `secretName`(单数)继续有效,等价于只有一个元素的 `secretNames`。两者同时出现 → 配置错误。
- 某个 secret 缺失:跳过该 key 并沿用现有 `onSecretMissing` 日志;整组都缺失才视为条目不可用。
- `wrangler-config.test.js` 增加校验:`maxConcurrencyPerKey` 若配置必须是正整数。

### 1.2 行为要求

| # | 要求 |
|---|---|
| R1 | **熔断按 key 记账**。一个 key 余额耗尽(`quota_exhausted`)或 401/403,只摘这个 key,同条目其他 key 照常服务。健康记录的 key 用 `条目id#序号`,**日志与 `/v1/health` 里不得出现 key 原文** |
| R2 | **条目内选 key**:选当前在途数最少的 key,并列时随机。不再用延迟 EWMA 在同一条目的 key 之间排序 |
| R3 | **条目之间**:沿用现有逻辑(admin 钉头 → 延迟/权重 → half-open 末尾)。即条目是「一家服务商 + 一个模型」,key 池是条目内部的事 |
| R4 | **key 级重试不占尝试次数**:某个 key 返回忙 429 时,换同条目另一个 key 重试,不消耗 `AI_PROVIDER_MAX_ATTEMPTS`;上限 = 条目内可用 key 数。只对**立即返回的 429** 这样做;超时、5xx 仍按现有规则走条目级 failover(保护客户端 55s 超时预算,见 `Protocols/Constants.swift` `apiTimeout` 注释) |
| R5 | 现有单 key 配置下,行为与改前**完全一致**;现有测试全部保持通过 |

---

## 2. 任务 A2:每个 key 的并发闸门(跨 isolate 生效)

### 2.1 为什么要做

没有闸门时,proxy 只能把请求打出去、等上游回 429 才知道满了。A 场景下 130 个名额、
每秒 17 个新请求,随机分配会有大量白打的 429,而且一部分用户会被分到满的 key 上。
闸门让 proxy **在本地就知道哪个 key 有空位**。

### 2.2 设计要求

1. 每个 key 一个 Durable Object(复用现有 `QUOTA_COUNTER_DO` 绑定或新增 class 均可,说明理由),
   负责该 key 的在途计数。天然按 key 分片,不形成全局单点。
2. **租约制**:acquire 返回一个带过期时间的租约(过期时间 = 该条目 `timeoutMs` + 10s);
   请求结束(成功、失败、客户端断开)都要 release。Worker 崩溃或漏 release 时,租约到期自动回收,
   名额不会永久泄漏。
3. 选 key 时读取各 key 的在途数(R2 依赖这个值)。读取方式自定,但每个请求对 DO 的调用次数要在
   结果文档里写明,并估算 A 场景下单个 DO 的每秒操作数。
4. **全部 key 满时**:短暂等待空位,最长 `KEY_GATE_MAX_WAIT_MS`(默认 3000,可配);
   等到了就发出,等不到返回 503 并带 `Retry-After: 2`。等待期间**不发 SSE 心跳**(那是 B 场景)。
   3 秒不会触发客户端 55 秒的空闲超时。
5. **DO 不可用时 fail-open**:闸门调用失败或超时(建议 200ms)就跳过闸门、直接打上游并记 warn 日志。
   闸门是优化,不能变成新的单点故障;上游 429 的现有处理会兜底。
6. 未配置 `maxConcurrencyPerKey` 的条目不走闸门。
7. 定时探活(`runProviderHealthCheck`)同样要走闸门,或者把每个 key 的上限留 1 个名额给它,二选一并说明。

### 2.3 必须新增的测试(`AIProxy/worker.test.js`,沿用现有 fake env 写法)

1. 3 个 key、每个上限 2,并发 6 个请求 → 每个 key 恰好 2 个在途,上游 429 次数为 0。
2. 第 7 个请求在 `KEY_GATE_MAX_WAIT_MS` 内等到有人 release → 成功;等不到 → 503 + `Retry-After`。
3. 请求中途客户端断开 → 名额被 release(在途数回到原值)。
4. 模拟漏 release → 租约到期后名额回收。
5. 一个 key 返回余额耗尽 → 只这个 key 熔断,后续请求分配到其余 key。
6. 一个 key 返回忙 429 → 换 key 重试且不消耗 `AI_PROVIDER_MAX_ATTEMPTS`(断言总尝试条目数)。
7. 闸门 DO 抛错 → fail-open,请求照常成功,有 warn 日志。
8. 单 key 旧配置 → 行为不变(可以用现有测试的整体通过来证明)。

第 1、2、6 条要求先在改前代码上跑出失败,再改代码跑通过,结果文档里贴关键输出。

---

## 3. 任务 A3:为换服务商做好准备(不需要账号也能做)

1. `openai` 类型条目新增两个**可选**的非敏感配置:
   - `extraHeaders`:附加请求头(例如 OpenRouter 建议的 `HTTP-Referer`、`X-Title`)。
   - `extraBody`:合并进请求体的字段(例如关闭思考/推理、指定上游路由偏好)。
     **不要在代码里写死任何一家的参数名**,具体字段由人工按服务商文档在 `wrangler.toml` 里配。
   - 两者都不得覆盖 `model`、`messages`、`stream`,覆盖时报配置错误。
2. 确认 `response_format: {type: "json_object"}` 在目标平台不被支持时的行为:如果上游因此返回 400,
   当前会被判为 `request_body` 不重试、直接 502。给出处理建议(例如允许在条目里关闭
   `response_format`,改为靠 prompt 约束 JSON),**实现前先在结果文档里写清楚取舍**。
3. 补测试:`extraHeaders` / `extraBody` 生效;试图覆盖保留字段时报错。

---

## 4. 任务 A4:评测脚本支持任意条目(为选服务商提供数据)

1. 让 `AIProxy/eval/run.mjs` 能针对指定的 provider 条目跑 72 条 golden,同时记录**每条的耗时**,
   输出 P50/P95 耗时和准确率。
2. 产出一张对比表模板:服务商 × 模型 × 是否关闭思考 → 准确率、P50、P95、每次 token 数。
3. **只有人工提供了 key 才实际跑**;没有 key 就交付脚本和使用说明,不得用 Coding Plan 的 key 跑
   (违反其使用政策)。

---

## 5. 任务 A5:压测扩展到 A 场景

在 `AIProxy/loadtest/run.mjs` 上扩展:

1. mock 上游支持「多个 key,每个 key 独立并发上限」;配置示例:13 个 key × 10,或 2 个 key × 65。
2. 新增到达模式:1000 人在(缩放后的)60 秒内**泊松到达**。
3. 闸门开 / 关两组对比(关闸门 = 只靠上游 429 + key 级重试)。
4. 统计项在原有基础上增加:每个 key 的最大在途数(用来证明闸门从未超限)、闸门等待时间的
   P50/P95、因等待超时返回的 503 数、每个闸门 DO 的每秒操作数峰值。
5. **验收线**(总名额 130、泊松到达 1000 人/分钟):最终成功率 ≥ 99%,即时成功率 ≥ 95%,
   用户侧 P95 ≤ 10 秒(换算回真实时间),闸门开启时上游忙 429 ≈ 0。达不到就写清楚差多少、瓶颈在哪。
6. 再跑一组「总名额只有 100」,看余量不足时的退化程度。

---

## 6. 约束

- **不改客户端 Swift 代码。** A 场景只靠代理侧即可完成,不需要发新版 App。
- **不部署。** 不用任何真实 key 做压测;评测只在人工提供 key 后进行。
- **不用 Coding Plan 的 key 做任何新的自动化调用。**
- 从最新 `main` 拉新分支(名字自定),完成后推送分支,**不合 main**,等审查。
- 不在范围内(看到只记录):B 场景排队与 SSE 心跳、客户端排队提示、端侧模型、全局预算数值调整。

---

## 7. 风险提示

- **租约泄漏是最大风险**:任何一个 return/throw 路径漏了 release,名额就会少一个,直到租约过期。
  建议用 `try/finally` 统一 release,并在测试里覆盖流式中途出错、客户端断开、上游超时三条路径。
- **名额要按「上游实际的并发口径」配**:有的平台限的是每分钟请求数或 token 数而不是并发,
  这时 `maxConcurrencyPerKey` 只是近似;保留上游 429 兜底,不要因为有了闸门就删掉现有处理。
- **key 原文不得进日志、健康接口、遥测**,包括报错信息里的截断片段(现有 `providerRedactions` 要覆盖到多 key)。

---

## 8. 结果文档格式(`docs/capacity-scenario-a-results.md`)

1. **改动摘要**:改了哪些文件,配置格式示例,每请求的 DO 调用次数与 A 场景下的每秒操作数估算。
2. **测试**:`npm test` 前后通过数;§2.3 第 1、2、6 条的失败与通过输出关键行。
3. **压测结果**:§5 的每组一行,闸门开/关并排;是否达到验收线。
4. **A3 的取舍**:`response_format` 的处理建议。
5. **偏离任务书的地方**及理由(没有就写「无」)。
6. **待人工处理**:按需列出(见 §9)。

---

## 9. 人工待办(不归执行者,列在这里便于跟踪)

1. **选定按量付费的服务商并开通账号**,替换 Coding Plan 的 key(上线阻断项)。向对方确认三个数:
   并发上限、每分钟请求数、每分钟 token 数(A 场景约需 130 并发、约 1000 次/分钟、约 600 万输入 token/分钟)。
2. 用 A4 的评测脚本对候选服务商和模型跑一遍,确认准确率不低于现在的基线、P95 耗时可接受。
3. 如果上中国区 App Store:确认 App 备案(ICP)以及生成式 AI 相关的备案/登记要求;选用的模型是否已在国内备案会影响后者。
4. 重新设定全局预算(`GLOBAL_DAILY_LIMIT` 等):现在免费档每天 5000 次,在 A 场景下几分钟就会用完。
