# VoiceTodo Telemetry 设计文档

VoiceTodo 的遥测系统采集**匿名诊断数据**用于线上质量监控和功能使用统计。所有数据脱敏，不含 PII（个人可识别信息）。

## 设计目标

1. **生产可观测性**：用户设备上的崩溃/错误/失败率可见，弥补本地 OSLog 看不到的盲区
2. **PII 红线**：录音内容、Todo 标题、日历事件等一律不上报原文
3. **用户控制**：仅 WiFi + 充电批量上报（电量友好），可随时关闭
4. **零第三方依赖**：自建接收端，复用 AIProxy Cloudflare Worker 基础设施

## 架构

```
iOS App                                AIProxy Cloudflare Worker
─────────────                          ─────────────────────────
调用点（9 个事件）                       POST /v1/telemetry/events
  ↓                                       ↓
Telemetry.record(event)                 validate X-App-Token
  ↓                                       ↓
TelemetryQueue（AppGroup UD）           enforceTelemetryQuota
  ↓                                       (每设备 500/天，RATE_LIMIT_KV)
BGProcessingTask                          ↓
（充电 + 网络满足时触发）                 batch insert to D1
                                          ↓
                                       telemetry_events 表
                                       （90 天 Cron GC）
```

## 9 个核心事件

### A 类：功能使用

| 事件名 | 触发点 | 脱敏参数 |
|--------|--------|----------|
| `app_launch` | App 启动 | `coldLaunch: Bool`, `hasCompletedOnboarding: Bool` |
| `recording_started` | 录音开始 | `source: button / action_button` |
| `recording_outcome` | 录音结束 | `outcome: success / interrupted / silence_timeout / watchdog_expired`, `durationMS: Int`, `transcript: textSummary` |
| `extract_outcome` | AI 抽取结束 | `outcome: success / failed / offline_fallback`, `todosCount`, `durationMS`, `attempts` |
| `todo_saved` | Todo 保存 | `source: confirm / siri_add`, `count` |
| `first_voice_trial` | 首次语音试用引导进度 | `stage: armed / hint_shown / dismissed / completed` |
| `paywall_shown` | paywall 曝光 | `source: first_wow / recording_count / quota_exhausted / manual` |

#### `first_voice_trial` 口径限制（分析必读）

1. **`hint_shown` 是会话级曝光，不是展示次数**。hint 触发集有 5 个入口
   （挂载/切 tab/关面板/关 confirm sheet/回前台），同一会话会反复展示；
   事件已做会话内去重（每次启动最多一条）。
2. **`completed` 混入键盘输入，不能直接当语音激活数**。完成钩子不区分
   语音/键盘来源；还原真实语音激活率需用 `todo_saved(source:)` 与本事件的
   时序关联。权限未齐直接落 `.dismissed` 的路径也记 `armed`（其特征是
   永不出现 `hint_shown`）。
3. **`dismissed` 率是本功能的必盯指标**（`dismissed / armed`）。「知道了」
   一点即永不重提；若该比值偏高，说明显式出口在吞激活，需要二次 arm 策略。

#### `paywall_shown` 与弹点决策

四来源由 `AppCoordinator.presentPaywall(source:)` 统一收口——新增曝光入口
必须走该方法，否则来源维度漏记。它是「wow 后立即弹 vs 撞墙后弹」
（docs/onboarding-first-voice-trial.md §1.5.1，PROMOTION_PLAN 漏斗偏差决策）
的度量基础：`first_wow` 与 `quota_exhausted` 两列对比即 A/B 弹点的对照组。

### B 类：线上质量

| 事件名 | 触发点 | 脱敏参数 |
|--------|--------|----------|
| `recording_failed` | 录音失败 | `reason: case 名`, `errorCode: nil` |
| `extract_failed` | AI 抽取失败 | `reason: case 名`, `attempt` |
| `widget_load_failed` | Widget 读取失败 | `reason: case 名` |
| `intent_failed` | AppIntent 失败 | `operation: add / toggle`, `stage: container / fetch_todo / fetch_completion / save / unknown` |

## PII 红线

### ❌ 绝不上报

- 录音 transcript 原文
- Todo title / detail
- 日历事件内容（EventKit notes/title）
- 用户名 / 邮箱 / 电话
- 设备原始标识（IDFV/IDFA/MAC 地址）

### ✅ 可上报（脱敏后）

- 事件名 + 时间戳
- 匿名 session ID（每次启动 UUID，**不持久化**，仅本次会话内关联）
- 设备 ID（sha256 哈希，复用 AIProxy 已有匿名标识）
- 系统信息（iOS 版本、App 版本）
- 计数与时长（todosCount、durationMS、attempts）
- 文本摘要（`VoiceTodoLog.textSummary()`：chars / lines / exceedsLimit）

> 同一条红线适用于 `ALERTING.md` 的客户端故障信标（`/v1/incident`）：信标只回答
> 「通不通」，不回答「用户说了什么」，绝不携带 transcript / Todo 标题。

## App Store Connect 隐私问卷

- 「追踪用户」：**否**
- 数据类型：按 Apple 口径（离开设备且被保留即算 collected）声明 4 类 ——
  Device ID（哈希）/ Purchase History / Other User Content / Other Usage Data，
  全部 App Functionality 或 Analytics 用途、不关联身份、不追踪。
  逐项答案与依据见 `APPSTORE_REVIEW_KIT.md` §2
- 关联文件：`VoiceTodo/PrivacyInfo.xcprivacy`（已按上述口径声明）

## 部署步骤（AIProxy）

1. **创建 D1 数据库**：
   ```bash
   wrangler d1 create voicetodo-telemetry
   ```
   把返回的 `database_id` 填入 `wrangler.toml`。

2. **初始化 schema**：
   ```bash
   wrangler d1 execute voicetodo-telemetry --file=./schema.sql
   ```

3. **配置 wrangler.toml**：
   - 取消注释 `[[d1_databases]]` 块，填入 `database_id`
   - 取消注释 `[triggers] crons = ["0 3 * * *"]`
   - 建议配置 `LOG_HASH_SALT`（不复用 APP_TOKEN）

4. **部署**：
   ```bash
   wrangler deploy
   ```

5. **验证**：
   ```bash
   # 触发 App 内事件后
   wrangler d1 execute voicetodo-telemetry --command "SELECT COUNT(*) FROM telemetry_events;"
   ```

## 查询示例

```sql
-- DAU
SELECT date(received_at / 1000, 'unixepoch') AS day,
       COUNT(DISTINCT device_id) AS dau
FROM telemetry_events
GROUP BY day ORDER BY day DESC LIMIT 14;

-- 事件计数（最近 7 天）
SELECT event_name, COUNT(*) AS count
FROM telemetry_events
WHERE received_at > (strftime('%s','now','-7 days') * 1000)
GROUP BY event_name ORDER BY count DESC;

-- 录音失败率
SELECT
  SUM(CASE WHEN event_name = 'recording_outcome' THEN 1 ELSE 0 END) AS total,
  SUM(CASE WHEN event_name = 'recording_failed' THEN 1 ELSE 0 END) AS failed,
  ROUND(100.0 * SUM(CASE WHEN event_name = 'recording_failed' THEN 1 ELSE 0 END) /
        NULLIF(SUM(CASE WHEN event_name = 'recording_outcome' THEN 1 ELSE 0 END), 0), 2) AS failure_rate
FROM telemetry_events
WHERE received_at > (strftime('%s','now','-7 days') * 1000);

-- 某设备最近事件流
SELECT event_name, event_timestamp, params
FROM telemetry_events
WHERE device_id = 'sha256:xxx'
ORDER BY received_at DESC LIMIT 50;
```

## 数据保留

- **D1 保留**：90 天，由 Cron Trigger（每天 03:00 UTC）自动清理
- **本地队列**：7 天 GC，超出容量 500 时丢老的
- **不上报到第三方**：所有数据留在 VoiceTodo 自己的 Cloudflare 账户

## 关闭遥测

用户可通过系统「设置 → VoiceTodo」（待实现）或 App 内设置（待实现）关闭遥测。关闭后：
- 本地 `Telemetry.record()` 仍可调用，但 `TelemetryUploader` 不再上报
- BGProcessingTask 不再 schedule

## 后续扩展（不在当前 plan）

- **漏斗分析（C 类）**：上线后观察 1-2 周再决定
- **看板**：D1 直接 SQL 查询足够，后续可接 Grafana Cloud 免费层
- **实时上报**：不做（仅 WiFi + 充电是用户决策）
- **A/B 测试**：未来需求

## 相关文件

| 文件 | 用途 |
|------|------|
| `Protocols/Telemetry.swift` | 事件枚举 + 入口 |
| `Protocols/TelemetryQueue.swift` | 持久化队列 |
| `App/TelemetryUploader.swift` | 批量上报 + BGTask |
| `VoiceTodo/PrivacyInfo.xcprivacy` | 隐私 manifest |
| `AIProxy/worker.js` | `/v1/telemetry/events` endpoint |
| `AIProxy/schema.sql` | D1 表结构 |
| `AIProxy/wrangler.toml.example` | 部署配置示例 |
| `LOGGING.md` | 本地日志规范（与遥测区分） |
| `ALERTING.md` | 实时告警设计（与遥测的分工见该文档「与 TELEMETRY.md 的分工」一节） |
