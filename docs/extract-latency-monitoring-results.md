# 结果：解析耗时监控

> 执行分支 `jiankong`（从 main @ `6b27080` 拉出）。任务书见 `docs/extract-latency-monitoring-task.md`。
> 执行方未部署、未对线上 D1 执行任何语句（§9 约束遵守）。

## 1. 改动摘要与提交

| 提交 | 部分 |
|---|---|
| `22d140c` | 任务书文档带入（cherry-pick 自 `claude/pre-launch-review-jy86zk` 的 `48ace75`，方便对照） |
| `b4609a5` | **A. 代理端**（部署即生效，不等 App 审核） |
| `7cb3cf9` | **B. App 端**（随下一版 App 发布） |
| （本提交） | 结果文档 |

### A. 代理端（`b4609a5`）

| 文件 | 改动 |
|---|---|
| `AIProxy/schema.sql` | 新表 `extract_requests` + 3 个索引 + 迁移注释 + 常用查询（按模型成功率/按 Key 429/与 telemetry_events 联查） |
| `AIProxy/src/extractMetrics.js`（新） | X-Extract-ID 校验（≤64 字符，`[A-Za-z0-9_\-.:]`）；D1 写入包装（失败只 logWarn）；P50/P95 汇总；告警评估 —— 全部纯函数可单测 |
| `AIProxy/worker.js` | `makeRequestContext` 读 `X-Extract-ID`（进全部日志 + D1 行）；每请求恰好一行的采集器 `createExtractMetrics`（11 个终态出口）；`handleScheduled` 加 extract_requests GC + 最近 30 分钟告警；新增 `GET /v1/admin/extract-metrics` |
| `AIProxy/src/provider.js` | `attempt.keySlot` 成功也携带：单 key 条目 = secretName，多 key = `条目id#secretName`（此前仅失败日志且仅多 key） |
| `AIProxy/src/alertState.js` | `AlertStateStore` 支持自定义 KV key（解析告警两条独立状态机复用同一去重逻辑） |
| `AIProxy/wrangler.toml` | `[vars]` 增 `ALERT_EXTRACT_P95_MS = "20000"` / `ALERT_EXTRACT_SUCCESS_MIN = "0.9"`（带注释）；cron 注释更新 |
| `TELEMETRY.md` | 补 `extract_requests` 表一节（口径、查询入口、告警阈值） |
| `AIProxy/worker.test.js` | 新增 13 条测试（§6.1 全部 11 项 + 11 拆三）；既有 GC 测试的假 D1 适配第二个 DELETE |

### B. App 端（`7cb3cf9`）

| 文件 | 改动 |
|---|---|
| `Protocols/ExtractTiming.swift`（新） | `ExtractTimingTracker`（T0~T3，NSLock first-write-wins）+ `ExtractTimingInfo`（纯函数差值推导）+ `ExtractPath` 常量 |
| `Protocols/VoiceTodoLog.swift` | 新 task-local `$extractTiming`（与 `$extractID`/`$requestPath` 同模式） |
| `Protocols/Telemetry.swift` | `extractOutcome` 加 `timing`（path + 3 个可选毫秒参数）；`recordingOutcome` 加 `extractID` |
| `Protocols/VoiceInputProtocol.swift` | 增 `sessionExtractID` / `consumeExtractContext()`；三个实现（VoiceInputManager / UITest / Preview mock）同步 |
| `Voice/VoiceInputManager.swift` | 录音会话 mint extractID；`finishRecording()` 记 T0；6 处 `recording_outcome` 带 extractID |
| `App/AppCoordinator.swift` | `processTranscript` 接收语音提取上下文（extractID + T0），按 live_voice/keyboard 建计时器下传 |
| `App/TranscriptProcessingFlow.swift` | 绑定 `$extractTiming` task-local 包住 `extractStreaming` |
| `Extractor/NetworkClient.swift` | 流式/非流式两处请求发出前 `markRequestSent`（T1） |
| `Extractor/TodoExtractorService.swift` | 首次 yield 部分待办 `markFirstTodo`（T2）；**补齐流式成功的 extract_outcome 事件**（此前主路径成功零事件）；全部 extract_outcome 带 timing |
| `VoiceTodoTests/` | 新增 10 条计时测试；既有 Telemetry 测试适配新 case 签名 |

## 2. `outcome` 与代码分类的对应

| outcome | 来源（代码既有分类） |
|---|---|
| `success` | 非流式 / 流式 200 且解析出非空 todos |
| `empty_todos` | 200 + 合法 JSON 但 `todos=[]`（`classifyExtractOutcome` parseOk 且无待办；退款 reason `empty_todos` 同源） |
| `unparseable_output` | 200 但 JSON 解析失败（退款 reason `unparseable_output` 同源） |
| `upstream_failed` | `executeWithFailover` 抛出（全部候选耗尽 503 / 非重试 502 / 响应无效 / 意外异常发生在上游调用之后），`error_type` 保留最终 attempt 的 errorType（`status_429`/`timeout`/`network`/…） |
| `stream_failed` | 流式已返回 200 后中途失败（`proxy.provider.stream_failed`），非客户端断连 |
| `client_disconnected` | 请求信号 abort：上游调用前（499）或流中途（`proxy.client.disconnected`）。**成功率统计排除出分母** |
| `quota_rejected` | 上游调用前被拒：`quota_exceeded` / `subscription_quota_exceeded` / `rate_limited`（velocity+ip_daily）/ `global_budget_exceeded`(_pro) / `key_pool_full` / `deepread_limit_exceeded`（`error_type` 保留具体类别） |
| `no_provider` | `providers_config_invalid` / `providers_empty`（500）/ `no_providers_available`（503，selector 空） |
| `cache_hit` | 提取缓存命中（零模型成本） |
| `proxy_error` | **任务书枚举外的扩展值**：上游未调用的代理自身错误（`invariant_violation` 500、未预期异常）。单独归类避免污染 `upstream_failed` 语义 |

**写行范围**：鉴权失败（401）与 payload 校验失败（缺 transcript/超长/非法 mode）**不写行** —— 那些不是解析尝试，进分母会把攻击流量/客户端 bug 算成「解析失败率」。assist 模式（split/reflect/deep-read）不写行（任务书 §2.1）。

**成功率口径**（管理接口与告警同源）：`success`/`cache_hit`/`empty_todos` 计成功；`client_disconnected` 出分母（用户取消不是故障，与 iOS 端 `ExtractOutcome.cancelled` 必须与 failed 分开统计同口径）；其余计失败。

## 3. 测试

### 3.1 代理端（`cd AIProxy && npm test`）

**改前 376/376 → 改后 389/389 全绿**（含 `wrangler-config.test.js` 24/24 与 subscription/quota-counter 套件）。

§6.1 每条对应的测试名：

| §6.1 | 测试名 |
|---|---|
| 1 | `extract metrics 1: 非流式成功写一行,provider/model/key_slot/attempts/outcome/todos_count 全正确` |
| 2 | `extract metrics 2: 主力失败备用成功只写一行,attempts=2 failover=1 provider 是备用` |
| 3 | `extract metrics 3: 流式成功 total_ms 按流结束时刻计算,todos_count 来自 fullText`（延迟 80ms 的 SSE，断言 total_ms − 首字节 ≥ 50ms） |
| 4 | `extract metrics 4: 流式中途客户端断开 outcome=client_disconnected` |
| 5 | `extract metrics 5: 额度拒绝也写一行,provider_id 为 NULL` |
| 6 | `extract metrics 6: 合法 X-Extract-ID 进 D1 与日志,非法值视为未携带`（超长 65 字符 + 含空格两种） |
| 7 | `extract metrics 7: Key 的值不出现在 D1 参数与日志的任何地方`（canary 假 Key，成功+失败+多 key 三场景，扫描全部 D1 bind 参数与全部日志行） |
| 8 | `extract metrics 8: D1 写入抛错不影响请求,只记 write_failed 日志` |
| 9 | `extract metrics 9: TELEMETRY_DB 未配置时请求照常,不报错` |
| 10 | `extract metrics 10: 管理接口鉴权 401 / 分组与百分位 / hours 超 168 按 168`（含缺省 hours=24） |
| 11 | `extract metrics 11a`（P95 超阈值触发一次、重跑不重复、恢复推「已恢复」）、`11b`（成功率告警 + 断连不进分母：10/20=50%）、`11c`（样本 19 次不告警） |

既有测试适配一处：`scheduled handler deletes events older than retention` 的假 D1 原来只记最后一次 `bind` 首参，被新增的告警查询 bind 覆盖；改为记录全部 bind 参数并断言两个 GC（telemetry_events + extract_requests）都按 90 天窗口删。

### 3.2 App 端

- `arch -arm64 swift test`：**371 例，唯一失败 = `TodoDueDateShifterTests.testDSTSpringForward_fallsBackToMidnight`（CLAUDE.md 记录的已知基线红灯，CN 时区 Mac 必红，非回归）**。新增 10 条（§6.2）：差值计算 / 缺 T0 / 缺 T2 / 取消 done=nil / path 映射 / first-write-wins / 任务域解析（绑定与回退两支）。
- `xcodebuild test -only-testing:VoiceTodoTests`（iPhone 17 Pro 模拟器）：**827 例，1 失败 = 同一已知 DST 红灯**，2 skipped。
- §6.2 真机核对（说完→出第一条在几秒量级）**未做**——语音链路模拟器不可测（CLAUDE.md），留给上线前真机走查。

## 4. 管理接口示例返回（测试数据）

`GET /v1/admin/extract-metrics?hours=999`（`X-Admin-Token` 鉴权；999 → 168）：

```json
{
  "hours": 168,
  "sinceMs": 1768600000000,
  "rowCount": 6,
  "sampled": false,
  "rowLimit": 20000,
  "requests": 6,
  "successRate": 0.8333,
  "p50Ms": 300,
  "p95Ms": 30000,
  "failoverCount": 1,
  "byProvider": [
    { "key": "A|ma", "requests": 5, "successRate": 1, "p50Ms": 300, "p95Ms": 500, "status429": 0 },
    { "key": "B|mb", "requests": 1, "successRate": 0, "p50Ms": 30000, "p95Ms": 30000, "status429": 1 }
  ],
  "byKeySlot": [
    { "key": "PROVIDER_KEY_A", "requests": 5, "successRate": 1, "p50Ms": 300, "p95Ms": 500, "status429": 0 },
    { "key": "PROVIDER_KEY_B", "requests": 1, "successRate": 0, "p50Ms": 30000, "p95Ms": 30000, "status429": 1 }
  ],
  "byOutcome": [
    { "outcome": "success", "count": 5 },
    { "outcome": "upstream_failed", "count": 1 }
  ]
}
```

（`byProvider` 的 key 为 `provider_id|model`；P50/P95 为 nearest-rank；窗口行数超 20000 时 `sampled: true`。）

## 5. App 端 4 个时间点的挂载位置

| 时间点 | 函数 | 说明 |
|---|---|---|
| T0 说完话 | `Voice/VoiceInputManager.finishRecording()` | 手动停止（`stopRecordingAndProcess`）、静音自动提交、达时长上限三条收尾路径的**公共汇点**；存 `speechEndedInstant`，`consumeExtractContext()` 消费后清空 |
| T1 请求发出 | `Extractor/NetworkClient`（两处） | 非流式 `session.data(for:)` 前 + 流式 `session.bytes(for:)` 前；tracker first-write-wins，重试只记首请求 |
| T2 第一条待办 | `Extractor/TodoExtractorService.extractStreaming` 内首次 yield partial | `tryParsePartialTodos` 解出首条并向确认面板 yield 的时刻（渲染晚一帧，不可测） |
| T3 解析完成 | `Extractor/TodoExtractorService` 各 `extract_outcome` 落账点 | 流式 = 最终解析完成后；非流式 = 响应解析后；**取消路径 done=nil**（取消不是完成，不带 speechToDoneMS） |

传递链：`AppCoordinator.processTranscript` 建计时器（语音路径带 T0 + 复用录音会话 extractID，键盘路径 path=keyboard）→ `TranscriptProcessingFlow.process` 绑 `VoiceTodoLog.$extractTiming`（task-local，随 Task 继承）→ extractor / NetworkClient 读写。补解析（`pending_batch`）/Siri（`siri`）/重新解析（`reextract`）不绑定计时器，`path` 从 `requestPath` 映射。

`recording_outcome` 的 `extractID` 在**参数列**（录音发生在 extractID 任务域之外，payload 的 extract_id 列拿不到；两列在 D1 里都可用 `extract_id`/`params.extractID` 关联）。

## 6. 上线步骤（由人执行，执行方未做）

1. **建表**（先本地试一遍再对线上执行）：
   ```bash
   cd AIProxy
   npx wrangler d1 execute voicetodo-telemetry --local --file=./schema.sql        # 本地先验证
   npx wrangler d1 execute voicetodo-telemetry --remote --file=./schema.sql       # 线上(幂等,IF NOT EXISTS)
   ```
   只执行新增建表部分也可以（文件其余语句同样幂等）。
2. **部署**：`npx wrangler deploy`（告警阈值已在 `wrangler.toml [vars]`，随部署生效）。
3. **验证**：用 App（真机）解析几次后：
   ```bash
   curl -s -H "X-Admin-Token: $ADMIN_TOKEN" "https://<proxy-host>/v1/admin/extract-metrics?hours=1"
   ```
   确认：有数据；`key_slot` 是 secret 名（如 `PROVIDER_KEY_ZAI_ANTHROPIC` 或 `ZAI_ANTHROPIC#PROVIDER_KEY_ZAI_ANTHROPIC_2`），**不是 Key 的值**；`extract_id` 与 App 埋点能对上。
   App 端参数（path/speechTo*MS）要等下一版 App 发布后才有。

## 7. 偏离任务书的地方及理由

1. **流式 `todos_count` 用 `stats.fullText` 解析，而非任务书提的 `stats.emittedCount`**——emittedCount 是增量文本块数（一次解析几十块），不是待办数；fullText 在同一回调（`onSuccess`）里可得，`classifyExtractOutcome` 已在算，直接取准确值。
2. **`attempts` / `providers_tried` 按条目去重**——同条目内 key 级重试（R4 路径）不重复计数，严格对齐「一共试了几个服务商」；providers_tried 保留首试顺序（如 `A,B`）。key 级重试的信息保留在日志（`attempt.keySlot`），不进本表。
3. **`key_slot` 多 key 条目记 `条目id#secret名`**（单 key 条目 = secret 名）——与 attempt.keySlot / healthId 现有格式同源，能区分不同条目下的同名 secret；任何形态都不含 Key 的值（§6.1.7 canary 专测）。
4. **outcome 增补 `proxy_error`**——任务书枚举没有「上游没被调用的代理自身错误」（invariant_violation / 未预期异常）的归属；归入 `upstream_failed` 会污染上游失败率，归入 `quota_rejected` 语义更错。
5. **鉴权失败 / payload 校验失败不写行**——任务书只要求「额度、IP 限流等在调用上游之前拒掉的请求」写行；401/400/413 不是解析尝试（多为攻击流量或客户端 bug），进分母会让失败率告警失真。已在 §2 写明。
6. **告警无 6h reminder**——复用的 `shouldNotify` 的 reminder 分支只在 `down` 触发；解析告警用 `degraded` 二值（breached/ok），持续故障只推一次不重推。任务书未要求 reminder，告警疲劳风险优先。
7. **样本 <20 次时告警状态按 `ok` 处理**——量太小没有意义（任务书原文）；副作用是流量骤降时会推一条「已恢复」，宁少勿吵的取舍。
8. **`path` 取值在任务书 4 个之外补了 `reextract` / `main`**——重新解析（`reextract`/`edit_reextract`）与离线降级 `fallbackExtract`（从未发请求）也存在且无 T0，需要来源标记；`main` 是无法细分时的兜底（仅离线降级与老调用路径会出现）。
9. **B 部分顺带补齐了流式成功的 `extract_outcome` 事件**——任务书 §5 默认该事件已存在，实际主路径（流式）成功时根本没有；不补则 `speechToDoneMS` 在生产主路径上永远缺失。事件的其余参数（outcome/durationMS/attempts）与非流式同构。
10. **App 端 T2 取「首次 yield 给确认面板」而非「面板渲染完成」**——渲染时刻不可观测（SwiftUI 无渲染回调）；yield → 渲染只差一帧（毫秒级），对秒级指标无影响。

## 8. 已知局限（不修，留档）

- 按 Key 的 429 次数只统计**终态**为 429 的行；被 failover 吸收的 429 记在最终成功行的 `providers_tried`/`failover` 里，不归属原 Key（表结构只存最终 key_slot）。
- 流式请求若客户端不读流且 Worker 被回收，理论上可能丢行（无终态回调）；非流式所有出口均有行。
- `upstream_first_byte_ms` 沿用任务书口径 = 最终 attempt 的 `durationMs`；非流式该值含 body 读取（「上游完成」而非严格首字节）。
