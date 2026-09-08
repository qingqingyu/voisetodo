# VoiceTodo Alerting 设计文档

VoiceTodo 的告警系统解决一个问题：**「有真实用户此刻连不上 AI」这件事，怎么在几分钟内推到维护者手机上。**

## 为什么需要这个

现有的失败兜底做得很扎实——AI 不通 → 转写存进 pending 队列 → 回前台自动重试 → 用户还能在「没能识别」卡片上手动点「重新解析」。**没人会丢话。**

但有个盲区：**这一切发生时，维护者不知道。**

| 现状 | 盲区 |
|------|------|
| `runProviderHealthCheck`（`AIProxy/worker.js`）每 30 分钟探活所有 provider | 结果只落一行 `logInfo("health_check.completed")`。日志进 Cloudflare 日志流，没人 `wrangler tail` 就等于没有 |
| 客户端 `extract_failed` / `extractor_circuit_changed` 遥测 | 要等 `BGProcessingTask` 在**充电 + 联网**时才上报，最早 1 小时后，实际可能隔天 |
| 用户点「重新解析」还是不通 | 服务端**完全看不见**——请求根本没到 |

最后一行是最要命的：**故障最严重的时候，恰恰是服务端信息最少的时候**。

## 与 TELEMETRY.md 的分工

两套系统数据源不同、用途不同，**不要互相替代**：

| | 遥测（`TELEMETRY.md`） | 告警（本文档） |
|---|---|---|
| 时效 | 事后。充电 + 联网才上报，最快 1 小时 | 实时。秒级推手机 |
| 用途 | 统计失败率、看趋势、复盘 | 发现「现在正在出事」 |
| 通道 | `ai.saydo.org/v1/telemetry/events` | `feedback.saydo.org/v1/incident` + Telegram |
| 数据量 | 全量事件，落 D1 | 只有故障，聚合去重后推送 |
| 故障时可用性 | ❌ 与故障链路同域名，一起挂 | ✅ 独立域名，绕开故障链路 |

遥测回答「上周失败率多少」，告警回答「现在是不是挂了」。

## 三条核心设计决策

### 1. 告警通道必须与故障通道分离

客户端信标发往 **`feedback.saydo.org`**（feedback-relay worker），**不是** `ai.saydo.org`。

要报的正是「`ai.saydo.org` 不通」——发往同一个域名的信标会和故障一起死掉。两个 hostname、两个 worker，能扛住：

- 单 hostname 被 DNS 污染（`AIProxy/wrangler.toml` 里已注明 workers.dev 在国内被污染，才绑的自定义域名）
- AIProxy 坏部署
- AIProxy 配额/预算打满返 503
- 上游 AI provider 全挂

feedback-relay 已经配好 Telegram 推送到维护者手机，是现成的独立通道。

### 2. 只在状态跃迁时告警，不是每次失败都告警

告警疲劳会导致 bot 被静音，等于白做。规则：

- 正常 → 故障：推一条
- 故障 → 恢复：推一条（带故障总时长）
- 故障持续中：每 6 小时提醒一次
- 其余情况：不推

### 3. 死人开关兜底

「告警系统自己挂了谁来告警？」——AIProxy 整个死了，它的 cron 也发不出告警。

healthchecks.io 收不到心跳会**反过来**告警。这是唯一能覆盖「告警系统自身故障」的办法。

## 架构

```
                            ┌── 层 B: AIProxy cron 30min 探活 provider
                            │      状态跃迁 → 🚨 Telegram
                            │      每次跑完 → ping healthchecks.io
   [Telegram Bot 手机] ←────┤
                            │
                            └── 层 A/D: feedback-relay POST /v1/incident
                                   ← App 故障信标（独立域名，绕开故障链路）
                                     KV 聚合去重 → 🚨 Telegram

   [UptimeRobot] ──→ GET ai.saydo.org/v1/health（无鉴权，只读 KV，零 AI 成本）
   [healthchecks.io] ←── cron 心跳；心跳断了它告警
```

四层的覆盖范围互不重叠：

| 层 | 覆盖什么 | 谁也覆盖不了它 |
|---|---|---|
| A 客户端信标 | **真实用户的真实网络**连不上 | 服务端任何手段都看不见这个 |
| B cron 熔断告警 | 上游 AI provider 挂了 / 恢复了 | —— |
| C 健康探针 + 死人开关 | Worker 整个挂了、域名不通、cron 死了 | 此时 A 和 B 都发不出告警 |
| D pending 积压 | 用户「点重试还是不通」的持续痛感 | 单次失败信号看不出持续性 |

## 实施状态

| 层 | 状态 | 说明 |
|---|------|------|
| B cron 熔断告警 | **已实施 + 5 处缺陷已修复，待重新部署** | 代码 + 测试已落地（`src/notify.js` / `src/alertState.js` / `runProviderHealthCheck`）；第一轮 review 的 5 处缺陷已修复，第二轮 review 另发现 3 处遗留待修 |
| C 健康探针 + 死人开关 | **已实施 + 5 处缺陷已修复，待重新部署** | 同上（`/v1/health` + `handleScheduled` 心跳）；遗留 1 影响本层 |
| A 客户端信标 | 待发版 | 要过审核 + 等用户升级，实际生效晚得多 |
| A/D feedback-relay 接收端 | 待发版 | 没有层 A 发信标，先建接收端没意义 |
| D pending 积压 | 待发版 | 随层 A 一起 |

> ⚠️ **线上正在跑修复前的版本（2026-09-05 部署），需尽快 `wrangler deploy` 重新部署。** 修复前版本有 3 处会让故障变得不可见（探针把 `half-open` 当健康、secret 全缺时三层同时报绿、停用 provider 稀释故障判定）——会让人以为「没收到告警 = 没出事」。
>
> **别等第二轮的 3 处遗留修完再部署。** 已修好的版本严格优于线上版本：线上 `half-open` 全绿、secret 全缺三层全绿；已修版本 `half-open` 已红、secret 全缺已有 cron 告警 + `/fail` 心跳（只剩探针那一层没红）。先部署拿到大部分覆盖，遗留 3 处随下一轮走。
>
> 缺陷明细、修复与两轮 review 见 **`docs/alerting-layer-bc-review-fixes.md`**。

**B/C 先做的理由：** 它们不依赖发版，且覆盖的「上游 AI 全挂」和「Worker/域名整个不可达」是影响面最大的两类故障。层 A 价值最高但生效最慢，两件事不冲突——B/C 先把服务端的眼睛装上。

下面各层的小节里，**层 B / C 已经写到可直接照着实现的粒度**（函数签名、挂接点、边界与降级行为）；层 A / D 仍是设计口径，实施前需要再细化一轮。

---

## 层 A：客户端故障信标（最关键的一层）

这是**唯一**能测到「真实用户的真实网络」的信号。

### 新增 `App/IncidentReporter.swift`

`project.yml` 的 sources 按目录 glob（`- path: App`），XcodeGen 自动收录新文件，无需改配置。

### 触发点

「AI 不通 → 存起来」有**两条独立的落库路径**，信标必须都挂上：

1. **App 内录音**：`App/TranscriptProcessingFlow.swift` 的 `saveOffline()`——`networkUnavailable` / `apiTimeout` / `circuitOpen` / `apiServerError` / `rateLimited` / `ipRateLimited` / `serviceUnavailable` 全部经过它。加 `incidentReason: String?` 参数，各 catch 分支把已有的 `voiceError` case 名传进来。
2. **Siri / AppIntent**：`App/Intents/AddTodoIntent.swift` 的兜底分支**不经过 `saveOffline`**——它直接 `TodoItem.rawTranscript(...)` + `context.insert`，是独立实现。而 Siri 恰是 app 不在前台时的故障场景，这条路径漏了，层 A 就有盲区。该分支按同一 reason 口径触发信标；Intent 进程随时可能退出，发不出去没关系——`pendingReport` 标记在 App Group 里，下次打开 app 会补发。

> **`quotaExhausted` 走漏斗但不触发信标**（两条路径同口径）。它是付费墙事件——用户个人配额耗尽，不是连通性故障，遥测已覆盖。更不能混进来的原因：免费额度打满的那天，大量设备会同时走这条路径，会把层 A「多台设备同时失败 = 服务真挂了」的判别维度直接污染掉。

> `saveManual()` 路径（确定性解析失败）**不触发**信标——那是 AI 通了但解析不了，不是连通性问题。

### 本地累计状态

存 App Group UserDefaults（复用 `Store/AppGroupConfig.swift`）：

```
{ consecutiveFailures, firstFailureAt, lastReason, lastReportedAt, pendingReport }
```

### 上报条件

任一满足，**且**距上次上报 > 30 分钟：

- 连续失败 ≥ 2 次
- 单次 pending 恢复批次里失败 ≥ 3 条
- 最老的 pending 卡了 > 30 分钟仍未恢复（层 D）

> 三条都只能在 app 活着时（前台 / BGTask）评估。用户录完失败就退出 app，信标要等下次打开才发——客户端信标的固有限制，「失败当下立刻发」已覆盖主场景。

### 发送时机——「快速察觉」的关键

1. **失败当下立刻尝试发。** 多数故障场景下 `ai.saydo.org` 不通但 `feedback.saydo.org` 通（上游 AI 挂、配额打满、单 hostname 被污染），能秒达。
2. **发不出去 → 置 `pendingReport` 标记**，在 `AppCoordinator.handleAppForeground()` 和 `NetworkMonitor`（`Protocols/NetworkMonitor.swift`）恢复连通时补发。这就是「网络回来的第一时间」。

即使用户处于完全断网状态，信标也会在他重新联网的第一时间到达——而不是等充电时的 BGTask。

### payload 与 PII 红线

```
kind, reason, consecutiveFailures, pendingCount, oldestPendingAgeMinutes,
networkType, isExpensive, isConstrained, circuitState,
deviceId(复用已有 sha256 匿名标识), appVersion, osVersion, locale
```

**红线与 `TELEMETRY.md` 完全一致——绝不上报：**

- ❌ 录音 transcript 原文
- ❌ Todo title / detail
- ❌ 日历事件内容
- ❌ 用户名 / 邮箱 / 电话
- ❌ 设备原始标识（IDFV/IDFA/MAC）

信标只回答「通不通」，不回答「用户说了什么」。

### 实现约束

照 `UI/Shared/FeedbackSubmitter.swift` 的形态：独立 ephemeral `URLSession` + `X-App-Token`，**不复用 `NetworkClient`**（后者是为 SSE 流式 + 熔断 + 重试设计的，套上去反而要绕开那些逻辑）。

两点关键差异：

- **超时设 8s，落在新常量**（如 `Protocols/Constants.swift` 新增 `IncidentConfig.reportTimeout`）。不是 `NetworkConfig.apiTimeout` 的 55s，也别照抄 `FeedbackSubmitter` 读的 `FeedbackConfig.requestTimeout`（30s）——告警不该拖着用户，也不该在故障时反复捶。
- **失败不重试**，只置 `pendingReport` 标记等下次机会。故障时反复重试会加重问题。

端点复用已有的 `FeedbackConfig.endpoint`（`Protocols/Constants.swift`），无需新增构建配置。

---

## 层 A/D 服务端：信标接收 + 聚合

### `POST /v1/incident`（feedback-relay/worker.js）

沿用已有的 `validateAppToken`。新增 KV namespace `INCIDENT_KV` 做 **10 分钟聚合窗口**：

- 窗口内**第一条立刻推 Telegram**——要的是「快速察觉」，不能等汇总
- 同窗口后续只累加计数，静默
- 下一个窗口的第一条推送时，带上一个窗口的汇总

> 不加 cron 结算窗口。第一条已经推了，持续性由层 B 的 6 小时 reminder 覆盖，够用。

### 关键判别维度：unique device 数

- **1 台设备反复失败** = 某个用户网络烂（可能是他的 ISP、他的 VPN、他的公司网络）
- **10 台设备同时失败** = 服务真挂了，需要立刻处理

消息里必须区分这两者，否则无法判断要不要立刻起来处理。

### D1 归档

`feedback-relay/schema.sql` 加 `incidents` 表，便于事后 SQL 分析（哪个 iOS 版本 / 哪种网络类型集中出问题）。

写失败**不阻断** Telegram 推送——与现有 feedback 路径同款容错。

返回 200 即可，不让客户端重试。

---

## 层 B：cron 健康状态告警

改动全部集中在 `AIProxy/`，不碰 `feedback-relay/`，不碰 iOS 端。

### 新增 `AIProxy/src/notify.js`（约 40 行）

```js
sendTelegramAlert(env, text, fetchImpl = fetch) → { ok, skipped? }
```

照 `feedback-relay/worker.js` 的 `deliverToTelegram` 抄同款 `sendMessage`。

> **刻意复制而非跨 worker 调用。** 告警链路的依赖越少越好——如果 AIProxy 要靠调 feedback-relay 才能告警，就多了一个能一起挂的环节。这是告警系统该有的偏执。

三条约束：

- **必须接受 `fetchImpl` 参数。** `handleScheduled(env, fetchImpl)` 已经是可注入签名，测试靠它拦截 Telegram 调用；不透传就会在跑测试时打真实网络。
- 未配 `TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID` → `logWarn` 后返回 `{ ok: false, skipped: true }`。
- 发送异常自己 catch 掉，同样只 log。**绝不抛异常打断 cron**——cron 还要做 telemetry GC，不能被告警拖垮。

### 新增 `AIProxy/src/alertState.js`（约 70 行）

沿用 `src/health.js` 的形态：KV 存取 + 纯函数判定，KV 失败时降级。

存储在已有的 `AI_PROVIDER_STATE_KV`，key `alert:provider_health`，值 `{ level, since, lastNotifiedAt }`。`alert:` 前缀与 `health:` / `config:` 共存，与现有做法一致。

```js
classifyLevel(succeeded, total) → "ok" | "degraded" | "down"
shouldNotify(previous, current, now) → { notify, kind }
// kind ∈ recovered | degraded | down | reminder
```

- level 变化 → 推
- 上次通知未成功送达（`previous.lastNotifiedLevel !== current`）→ 重推，直到送达为止。**与「送达后才写」配套**：`notifyProviderHealthTransition` 必须先发送、送达（或未配 `TELEGRAM_*` 的 skipped）才落盘 `lastNotifiedLevel` / `lastNotifiedAt`；`level`/`since` 照常落盘（否则恢复消息的故障时长会算错）。只做一半没用——先发送后落盘但无重推规则，degraded 告警会永久丢失（它没有 reminder 兜底）；有重推规则但先落盘，重推永远不会触发。

  > **判据用 `lastNotifiedLevel`，不要用「`lastNotifiedAt` 是否为 0」。** 后者在 `ok` 上失效：首跑 ok 的 `lastNotifiedAt` 本来就是 0（正常不推），无法与「恢复消息发送失败待补发」区分，于是只能把 `ok` 排除在重推之外——结果是 ✅ 恢复消息一旦发送失败就永久丢失，收到 🚨 的人一直以为故障还在。`lastNotifiedLevel` 表达「用户最后被成功告知的是哪个 level」，对 down / degraded / recovered 三种 kind 统一生效；初值取 `"ok"`，首跑 ok 不推自然成立。`lastNotifiedAt` 则退回只负责 6h reminder 计时，两个字段各司其职。详见 `docs/alerting-layer-bc-review-fixes.md` 遗留 2。
- 仍是 `down` 且距 `lastNotifiedAt` ≥ 6h → 推 `reminder`
- 其余 → 不推

两条边界：

- **KV 读失败时返回 `notify: true`**——宁可多推一条，不可漏报。这条要有测试守着。
- **全部 provider 缺 secret / adapter 判为 `down`。** 这是 100% 的服务不可用——用户此刻一个字都提取不出来——不是「配置问题可以不告警」。用独立 reason 让告警文案说清是配置问题（该去改 secret，不是查上游），**区分的是文案，不是告不告警**。两边代价不对等：误报一次只是瞥一眼 Telegram，漏报一次是全部用户不可用而没人知道。

  > `classifyLevel` 的 `total <= 0 → null` 纯函数兜底可以保留，实际到不了——`loadProviders` 对空 `PROVIDERS` 直接抛错，走 `providers_failed` 早退。
  >
  > 早期方案曾写成「secrets 全缺不告警，避免配置问题被误报成服务故障」，那是错的：密钥轮换写错一个字符就会让层 B/C-1/C-2 同时报健康。详见 `docs/alerting-layer-bc-review-fixes.md` 缺陷 2。

- **单个 provider 缺 secret（`no_key`）/ 缺 adapter 计入 failed → `degraded`。** 与上一条是不同口径且有意并存：failover 容量减半是维护者该知道的事，且失败明细里带 `no_key` 一眼可辨——别当成误报修掉。只有「全部缺」才升级为 `down`。
- **只统计 `enabled !== false` 的 provider。** 与 `selector.js` 的 `pickCandidates` 口径对齐（它用同一个谓词跳过停用项）。停用的 provider 不承接任何流量，计入分母会把总故障稀释成局部故障：唯一在跑的挂了却算成 `degraded`(1/2)，于是不推 🚨、无 6h reminder、心跳照发成功。注意 `loadProviders` **不过滤**停用项，只是给 `enabled` 赋值，得在调用侧自己滤。

### 改 `runProviderHealthCheck`

在末尾、现有 `logInfo("health_check.completed")` 之后接告警。它已经算好了 `succeeded` / `total` / `failed`（`failed` 含 `providerId` + `reason`），直接喂给 `classifyLevel` + `shouldNotify`。

**该函数改为返回 level**，供层 C-2 的心跳判断用。

消息带上定位所需的全部信息：哪个 provider、错误类型（`http_503` / `timeout` / `network`）、熔断状态、已持续多久。恢复消息带故障总时长（`now - previous.since`）。

### 向后兼容

现有测试里的 `handleScheduled({})` 和 `handleScheduled({ TELEMETRY_DB: db })` 都没配 `TELEGRAM_*` / `HEALTHCHECK_PING_URL`，两个新分支都会跳过，不会打真实网络。

---

## 层 C-1：公开健康探针

### `GET /v1/health`（AIProxy，无鉴权）

在 `handleRequest` 里 `const url = new URL(...)` 之后、紧挨现有 `/v1/telemetry/events` 分支加一支。**必须放在 `validateAppToken` 之前**——拨测服务不带 token。

接受 `GET` 和 `HEAD`（UptimeRobot 可能用 HEAD），其余方法 405。

```json
{ "status": "ok", "providers": [{ "id": "ZAI_ANTHROPIC", "state": "closed" }], "ts": 1756900000000 }
```

四条硬约束：

1. **不复用 `handleAdminGetProviders`。** 那个返回 `type` / `model` / `priority` / `timeoutMs` / 完整 `health` 快照。新写精简版，**只出 `id` + `state`**，其余一律不出。
2. **不调用上游 AI。** 只读 KV 里的熔断状态——`src/health.js` 的 `snapshot(providerId, now)` 是 per-provider 签名，实现时遍历 `loadProviders(env)` 的结果逐个取。否则这个无鉴权端点会变成刷爆 AI 账单的入口。
3. **HTTP 状态码本身携带语义**：全部 provider **不健康** → 503，否则 200。这样拨测服务不用解析 body 就能告警。body 的 `status` 字段取值：`ok` / `degraded`（部分不健康）/ `down`（全部不健康，503）/ `misconfigured`（配置非法，503）。

   > **「不健康」= `open` **或** `half-open` **或** `unconfigured`（缺 key / 缺 adapter），只有 `closed` 算健康。**
   >
   > `half-open` 不是独立存储的状态，是 `health.js` 的 `classifyState()` 在熔断打开、冷却期一过就返回的**读时派生状态**（默认初始冷却 10s，上限 5min），语义是「曾经挂了，尚未证明恢复」——恢复要靠 `recordSuccess` 写回 `closed`。
   >
   > **`unconfigured` 必须单独判，不能指望熔断状态。** 缺 key 的 provider 在 `runProviderHealthCheck` 里是提前 return（`reason: "no_key"`），**从不调 `recordFailure`**，所以熔断记录压根不存在、`load()` 回落到 `freshRecord()` 的 `closed`。只读熔断状态的话，「secret 全缺」这个场景下 cron 告警和 `/fail` 心跳都响了，探针却仍是 `200 ok` —— 缺陷 2 就只修好了三分之二。判定谓词要与 cron 的 `probeable`（`no_key` / `no_adapter` 算配置性跳过）同源。详见 `docs/alerting-layer-bc-review-fixes.md` 遗留 1。
   >
   > 只判 `open` 会让探针在故障中报绿：稳态下每 30 分钟只有约 5 分钟窗口是 `open`，故障刚发生时窗口只有 10 秒；夜间无流量时不会触发新的 `recordFailure`，`half-open` 一直挂着，探针永远绿。这正是层 C-1 存在的意义所在，必须算不健康。详见 `docs/alerting-layer-bc-review-fixes.md` 缺陷 1。
4. `Cache-Control: max-age=30` 提示拨测客户端降低轮询频率。注意 Cloudflare **默认不缓存 Worker 响应**（边缘缓存需显式用 Cache API），该头挡不住恶意轮询 —— `/v1/health` 是唯一无鉴权且读 KV 的端点，Worker 内另有 15s isolate 结果缓存兜住 KV 读频率。

两条边界：

- `loadProviders` 抛错（`PROVIDERS` 配置非法）→ **503 + `status: "misconfigured"`，不是 500**。对拨测服务而言「服务不可用」比「服务器错误」语义更准。
- `AI_PROVIDER_STATE_KV` 未绑定 → 照常返回，`state` 取内存态默认值 `closed`。
- **只列 `enabled !== false` 的 provider**，与层 B 的探活口径、`selector.js` 的 `pickCandidates` 三处一致。停用项既不承接流量也不该出现在探针结果里。

复用现有的 `finishRequest(response, requestContext, extra)` 保持日志一致。

## 层 C-2：healthchecks.io 死人开关

`handleScheduled` 末尾追加心跳，拿层 B 里 `runProviderHealthCheck` 返回的 level：

- `level === "down"` → ping URL 的 **pathname 追加 `/fail`**
- 其余（**含 KV 未绑定的早退**）→ ping URL 原样

> **用 `new URL()` 操作 pathname，不要字符串拼接。** `` `${base}/fail` `` 遇到带 query 的 ping URL（healthchecks.io 的 `?rid=` 形式、Uptime Kuma 的 push URL）会拼成 `...?rid=xxx/fail`——`/fail` 落进 query value，服务端收到的是一次普通成功心跳。故障信号被静默降级成健康信号，正是死人开关最不能出的错。

> KV 未绑定时 `runProviderHealthCheck` 会早退、算不出 level，但 **cron 本身是活的**，仍要发成功心跳——心跳测的是「cron 还在跑」，不是「provider 健康」。这两件事别混。

未配 `HEALTHCHECK_PING_URL` 时跳过。心跳失败只 log，不影响 cron 其余部分。

一旦 Worker 或 cron 整个死了、心跳断了，healthchecks.io 会在 grace 期后主动告警。

---

## 部署步骤

### 层 B / C（服务端，随本次实施）

1. **AIProxy 注入 Telegram secrets**（贴与 feedback-relay 相同的值）：
   ```bash
   cd AIProxy
   npx wrangler secret put TELEGRAM_BOT_TOKEN
   npx wrangler secret put TELEGRAM_CHAT_ID
   ```

2. **healthchecks.io 建 check**（period 30min、grace 15min），拿到 ping URL：
   ```bash
   cd AIProxy && npx wrangler secret put HEALTHCHECK_PING_URL
   ```
   > ping URL 含 uuid，等价于凭据，按 secret 处理，不写进 `wrangler.toml`。

3. **部署**：
   ```bash
   cd AIProxy && npx wrangler deploy
   ```

4. **UptimeRobot 加 HTTPS 监控** `https://ai.saydo.org/v1/health`，5 分钟间隔。

> **三个 secret 全是可选的。** 一个都不配，cron 与 `/v1/health` 照常工作，只是告警静默（每次跳过会 `logWarn`）。这是刻意的：告警配置缺失绝不能让核心 AI 链路挂掉。
>
> `wrangler.toml` 与 `.example` 里对这三个只留注释说明（照现有 `ADMIN_TOKEN` 那段的写法），不写明文值。

### 层 A / D（客户端，随下个版本）

5. **feedback-relay 创建 KV namespace**：
   ```bash
   cd feedback-relay
   npx wrangler kv namespace create INCIDENT_KV
   ```
   把返回的 id 填进 `wrangler.toml`。

6. **feedback-relay 初始化 incidents 表**：
   ```bash
   npx wrangler d1 execute voicetodo-feedback --remote --file=./schema.sql
   ```

7. **部署 feedback-relay**：
   ```bash
   cd feedback-relay && npx wrangler deploy
   ```

### 顺手确认一件既存问题

`AIProxy/wrangler.toml` 的 `[[d1_databases]] TELEMETRY_DB` 目前是**注释掉的**，意味着遥测事件被 worker 接收后直接丢弃。

这与告警系统独立，但它是「事后复盘为什么不通」的唯一数据源，建议一并按 `TELEMETRY.md` 的部署步骤建库并取消注释。

---

## 验证

### 层 B / C 单元测试（`AIProxy/worker.test.js`，`npm test`）

复用现有的 `makeFakeKV()` / `providersEnv(providers, secrets, extraEnv)` / `jsonResponse()` helper，以及现有那批 `handleScheduled` 健康检查测试的形态——它们是现成的模板。

Telegram 与心跳调用靠注入的 `fetchImpl` 按 URL 前缀分流拦截（`api.telegram.org` / ping host），断言调用次数与消息内容。

**`/v1/health`**

- 全 closed → 200 + `status: "ok"`；部分不健康 → 200 + `"degraded"`；全部不健康 → **503**。**必须各有一条 half-open 用例**（部分 half-open → degraded；全 half-open → 503；open + half-open 混合 → 503）——只测 open 守不住「half-open 算不健康」这条口径
- 停用的 provider 不出现在 `entries` 里；全部停用 → 503 + `down`（与 cron 探活/心跳口径一致）
- **全部 provider 缺 key → 503 + `down`**（与「secrets 全缺 → cron 判 down」那条形成对照，三层口径必须一致）；部分缺 key → `degraded`。只测熔断状态守不住这条——缺 key 的 provider 熔断记录压根不存在，永远是 `closed`
- 不带 `X-App-Token` 也能访问（回归防线：别哪天被挪到 auth 后面）
- **body 里搜不到 `secretName` / provider url / model**——直接 `assert.ok(!text.includes("api.z.ai"))`。这是安全断言，必须有
- `PROVIDERS` 非法 → 503 + `misconfigured`，不是 500
- `POST /v1/health` → 405

**告警状态机**

- ok → down：推一次；同一 level 再跑一次（已送达、未满 6h）：**不重推**
- down → ok：推恢复消息，含故障时长
- down 持续 5h59m 不推、6h01m 推 reminder（**用可注入的 `now` 控时，别用真实时钟**）
- KV 读失败 → 仍然推（漏报比误报危险）
- secrets 全缺（无可探活 provider）→ **判 down 推告警 + 打 `/fail` 心跳 + 写告警状态**，文案明说这是配置问题（PROVIDERS 空数组在 `loadProviders` 抛错早退，那条路径才是「算不出 level 不推、心跳照发成功」）
- 停用的 provider 不计入分母：唯一启用的挂掉 → `down (0/1)` 而非 `degraded (0/2)`
- Telegram 发送失败 → `lastNotifiedLevel` 不写入，下次 cron 同 level **重推**；送达后同 level 未满 6h 不再重推
- **恢复消息（`recovered`）发送失败 → 下次 cron 同样重推 ✅**；这条与上一条必须都有——只测 down/degraded 会漏掉 `ok`，而 `ok` 正是「用 `lastNotifiedAt` 是否为 0 判待补发」失效的那个 level
- **首跑 ok 不推**（回归防线：防止 `lastNotifiedLevel` 初值取错导致开机就推一条 ✅）
- 旧 KV 记录（无 `lastNotifiedLevel` 字段）能被正确读取、不抛错
- 未配 `TELEGRAM_*`（skipped）→ 视为已处理，`lastNotifiedLevel` / `lastNotifiedAt` 照常写入（不无限重算）；不抛错，cron 其余部分照常完成（拿现有的 telemetry GC 测试断言这点）

**心跳**

- `down` → 打 `/fail` 端点；`ok` → 打 base URL
- ping URL 带 query（如 healthchecks.io 的 `?rid=`）→ `/fail` 必须落在 pathname 上、query 原样保留（`new URL()` 构造，不许字符串拼接）
- KV 未绑定早退时**仍发成功心跳**
- 心跳 fetch 抛错 → `handleScheduled` 不抛

### 层 A / D 单元测试（随下个版本）

| 文件 | 覆盖 |
|------|------|
| `feedback-relay/worker.test.js`（新建） | 窗口内第一条推、后续静默、跨窗口带汇总、unique device 计数 |
| `VoiceTodoTests/App/IncidentReporterTests.swift`（新建） | 30 分钟节流；payload 不含 transcript/标题；离线时置 `pendingReport` 且恢复后补发一次（不重复发） |

> feedback-relay 的 README 里原本刻意没写测试，但聚合窗口是有状态逻辑、易错，值得破例覆盖。

### 端到端手测（层 A，随下个版本）

精确复现「说完待办 → AI 不通 → 存起来 → 点重试还是不通」的场景。

把 `VOICETODO_AI_PROXY_ENDPOINT` 指向一个不存在的域名，真机说一条待办：

1. 待办应正常落进 pending（**原有兜底不能被破坏**——这是第一优先级）
2. 点「重新解析」再失败一次 → 触发连续失败 ≥ 2
3. **Telegram 应在秒级收到 🚨**（因为 `feedback.saydo.org` 仍然通）
4. 恢复端点配置，回前台 → pending 正常恢复，且**不再重复告警**

### 服务端手测（层 B / C）

先跑全量测试，不只新增用例：

```bash
cd AIProxy && npm test
npx wrangler dev
```

两条手测：

```bash
# 1. 健康探针：200 + provider 状态，且 body 里搜不到 api.z.ai / secretName
curl -i "http://localhost:8787/v1/health"

# 2. cron 告警：把 wrangler.toml 的 provider url 改成不可达地址
#    (需先在本地 .dev.vars 配好 TELEGRAM_*)
# wrangler 4.x 的 scheduled 触发入口（不是旧版的 /__scheduled）
curl "http://localhost:8787/cdn-cgi/handler/scheduled"
# → Telegram 应收到 down 告警
# → 紧接着再触发一次 → 不应重复推送（状态跃迁去重生效）
# → 改回正常地址再触发 → 应收到恢复告警，且带故障时长
```

上线后确认一次线上探针：

```bash
curl -i https://ai.saydo.org/v1/health
```

---

## 告警口径速查

收到告警时，按这张表判断严重程度：

| 消息来源 | 含义 | 该怎么办 |
|---------|------|---------|
| 🚨 层 A，1 台设备 | 单个用户网络问题 | 观察。多半是他的网络环境 |
| 🚨 层 A，多台设备 | 服务真出事了 | 立刻查 `/v1/health` 和 `wrangler tail` |
| 🚨 层 B，`degraded` | 一个 provider 挂了，failover 还在兜 | 用户无感，但要盯着别恶化 |
| 🚨 层 B，`down` | 全部 provider 挂了 | 用户此刻全部受影响，最高优先级 |
| 🚨 healthchecks.io | Worker 或 cron 死了 | **层 A/B 此刻都发不出告警**，只能靠这条 |
| 🚨 UptimeRobot | 域名/Worker 从外部不可达 | 同上，且可能是 DNS 层面的问题 |

## 不做的事（故意不做的）

- **不做实时全量上报**：每次失败都推会导致告警疲劳、bot 被静音，等于白做
- **不做第三方 APM**（Sentry / Datadog）：现有基建（Cloudflare + Telegram）已经够用，引入第三方增加 PII 泄露面
- **不在信标里带 transcript**：即使对排查有帮助也不带，PII 红线优先。要看原文走用户主动提交的反馈路径（`FeedbackSheet`）
- **不给 feedback-relay 加 cron**：窗口结算靠「下一条进来时顺便结算」，零 cron 逻辑闭环。持续性告警由层 B 的 6 小时 reminder 覆盖

## 相关文件

| 文件 | 用途 |
|------|------|
| `App/IncidentReporter.swift` | 客户端信标：累计、节流、发送、离线补发 |
| `App/TranscriptProcessingFlow.swift` | 信标触发点（App 内录音的 `saveOffline` 漏斗） |
| `App/Intents/AddTodoIntent.swift` | 信标触发点（Siri 兜底路径，不经过 `saveOffline`） |
| `App/PendingRecoveryFlow.swift` | 层 D 的 pending 积压信号来源 |
| `Protocols/NetworkMonitor.swift` | 网络恢复时触发补发 |
| `feedback-relay/worker.js` | `/v1/incident` endpoint + 聚合 + Telegram 推送 |
| `feedback-relay/schema.sql` | `incidents` 表结构 |
| `AIProxy/src/notify.js` | Telegram 告警发送 |
| `AIProxy/src/alertState.js` | 告警状态机（跃迁判定 + 6h reminder） |
| `AIProxy/src/health.js` | 熔断器状态（告警的数据源） |
| `AIProxy/worker.js` | `/v1/health` endpoint + cron 告警接入 |
| `docs/alerting-layer-bc-review-fixes.md` | 层 B/C 实施后的 review 修复方案（5 处缺陷，含本文档两处口径修订的来由） |
| `TELEMETRY.md` | 遥测设计（事后统计，与本文档分工见上） |
| `LOGGING.md` | 本地日志规范 |
| `TROUBLESHOOTING.md` | 收到告警后的排查手册 |
