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

### 新增 `AIProxy/src/notify.js`

`sendTelegramAlert(env, text)`——从 `feedback-relay/worker.js` 的 `deliverToTelegram` 抄同款 `sendMessage` 实现，约 25 行。

> **刻意复制而非跨 worker 调用。** 告警链路的依赖越少越好——如果 AIProxy 要靠调 feedback-relay 才能告警，就多了一个能一起挂的环节。这是告警系统该有的偏执。

未配 `TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID` 时静默跳过 + `logWarn`，**绝不抛异常打断 cron**（cron 还要做 telemetry GC）。

### 新增 `AIProxy/src/alertState.js`

在已有的 `AI_PROVIDER_STATE_KV` 里用 `alert:` key 前缀存 `{ level, since, lastNotifiedAt }`。与 `health:` 前缀共存，跟 `src/health.js` 的做法一致。

`shouldNotify(previous, current, now)` → `{ notify, kind: "degraded"|"down"|"recovered"|"reminder" }`：

- level 变化 → 推
- level 仍是 `down` 且距上次推送 ≥ 6h → 推 reminder
- 其余 → 不推

**KV 读写失败时降级为「推送」**——宁可多推一条，不可漏报。

### 改 `runProviderHealthCheck`

它已经算好了 `succeeded` / `total` / `failed`，只需在末尾接告警：

```js
level = succeeded === 0 ? "down" : (succeeded < total ? "degraded" : "ok")
```

消息带上定位所需的全部信息：哪个 provider、错误类型（`http_503` / `timeout` / `network`）、熔断状态、已持续多久。恢复消息带故障总时长。

---

## 层 C-1：公开健康探针

### `GET /v1/health`（AIProxy，无鉴权）

在 `handleRequest` 里**必须放在 `validateAppToken` 之前**分发——拨测服务不带 token。放在现有 `/v1/telemetry/events` 分支旁边。

```json
{ "status": "ok", "providers": [{ "id": "ZAI_ANTHROPIC", "state": "closed" }], "ts": 1234567890 }
```

四条硬约束：

1. **不复用 `/v1/admin/providers`。** 那个返回完整配置含 url / model / secretName。新写精简版，只出 provider id + circuit state，其余一律不出。
2. **不调用上游 AI。** 只读 KV 里的熔断状态——`src/health.js` 的 `snapshot(providerId)` 是 per-provider 签名，实现时遍历 provider 列表逐个取。否则这个无鉴权端点会变成刷爆 AI 账单的入口。
3. **HTTP 状态码本身携带语义**：全部 provider `open` → 503，否则 200。这样拨测服务不用解析 body 就能告警。
4. `Cache-Control: max-age=30` 让 Cloudflare 边缘挡掉重复轮询。

## 层 C-2：healthchecks.io 死人开关

`handleScheduled` 末尾追加心跳：

- `level !== "down"` → `fetch(env.HEALTHCHECK_PING_URL)`
- `level === "down"` → `fetch(env.HEALTHCHECK_PING_URL + "/fail")`

心跳失败只 log，不影响 cron 其余部分。

一旦 Worker 或 cron 整个死了、心跳断了，healthchecks.io 会在 grace 期后主动告警。

---

## 部署步骤

1. **AIProxy 注入 Telegram secrets**（贴与 feedback-relay 相同的值）：
   ```bash
   cd AIProxy
   npx wrangler secret put TELEGRAM_BOT_TOKEN
   npx wrangler secret put TELEGRAM_CHAT_ID
   ```

2. **feedback-relay 创建 KV namespace**：
   ```bash
   cd feedback-relay
   npx wrangler kv namespace create INCIDENT_KV
   ```
   把返回的 id 填进 `wrangler.toml`。

3. **feedback-relay 初始化 incidents 表**：
   ```bash
   npx wrangler d1 execute voicetodo-feedback --remote --file=./schema.sql
   ```

4. **healthchecks.io 建 check**（period 30min、grace 15min），拿到 ping URL：
   ```bash
   cd AIProxy && npx wrangler secret put HEALTHCHECK_PING_URL
   ```
   > ping URL 含 uuid，按 secret 处理，不写进 `wrangler.toml`。

5. **UptimeRobot 加 HTTPS 监控** `https://ai.saydo.org/v1/health`，5 分钟间隔。

6. **部署两个 worker**：
   ```bash
   cd AIProxy && npx wrangler deploy
   cd ../feedback-relay && npx wrangler deploy
   ```

### 顺手确认一件既存问题

`AIProxy/wrangler.toml` 的 `[[d1_databases]] TELEMETRY_DB` 目前是**注释掉的**，意味着遥测事件被 worker 接收后直接丢弃。

这与告警系统独立，但它是「事后复盘为什么不通」的唯一数据源，建议一并按 `TELEMETRY.md` 的部署步骤建库并取消注释。

---

## 验证

### 单元测试

| 文件 | 覆盖 |
|------|------|
| `AIProxy/worker.test.js`（已有，追加） | `/v1/health` 三种状态的码与 body；无鉴权可访问；**不泄露 url/model/secretName**；告警状态跃迁只推一次；恢复推一次；`down` 持续需满 6h 才 reminder。用注入的 `fetchImpl` mock 掉 Telegram 与 healthchecks ping |
| `feedback-relay/worker.test.js`（新建） | 窗口内第一条推、后续静默、跨窗口带汇总、unique device 计数 |
| `VoiceTodoTests/App/IncidentReporterTests.swift`（新建） | 30 分钟节流；payload 不含 transcript/标题；离线时置 `pendingReport` 且恢复后补发一次（不重复发） |

> feedback-relay 的 README 里原本刻意没写测试，但聚合窗口是有状态逻辑、易错，值得破例覆盖。

### 端到端手测（最关键的一步）

精确复现「说完待办 → AI 不通 → 存起来 → 点重试还是不通」的场景。

把 `VOICETODO_AI_PROXY_ENDPOINT` 指向一个不存在的域名，真机说一条待办：

1. 待办应正常落进 pending（**原有兜底不能被破坏**——这是第一优先级）
2. 点「重新解析」再失败一次 → 触发连续失败 ≥ 2
3. **Telegram 应在秒级收到 🚨**（因为 `feedback.saydo.org` 仍然通）
4. 恢复端点配置，回前台 → pending 正常恢复，且**不再重复告警**

### 服务端手测

```bash
# 健康探针：应返回 200 + provider 状态，且 body 里搜不到 api.z.ai / secretName
curl -i https://ai.saydo.org/v1/health

# 本地触发 cron：把 provider url 改成不可达地址
cd AIProxy && npx wrangler dev
# wrangler 4.x 的 scheduled 触发入口（不是旧版的 /__scheduled）
curl "http://localhost:8787/cdn-cgi/handler/scheduled"
# → Telegram 应收到 down 告警；改回正常地址再触发 → 应收到恢复告警
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
| `TELEMETRY.md` | 遥测设计（事后统计，与本文档分工见上） |
| `LOGGING.md` | 本地日志规范 |
| `TROUBLESHOOTING.md` | 收到告警后的排查手册 |
