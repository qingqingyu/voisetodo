# VoiceTodo iOS 可靠性审查报告（8 支柱）

- **审查日期**：2026-10-12（报告落盘 2026-10-13）
- **审查者**：Claude Code（/ios-reliability-review skill）
- **审查基线**：子模块工作区 @ `001d659`（2026-10-12）。当时唯一未提交改动为 `Resources/Localizable.xcstrings` 新增空键 `"success"`，不影响本报告任何结论
- **审查范围**：`VoiceTodo/{App,Protocols,Extractor,Store,UI,Voice,widget}` iOS 源码；`AIProxy/` 仅做交叉核对（TraceID / 缓存两处），未全面审查；测试代码不作为证据来源
- **性质**：只读审查，未修改任何代码

## 审查标准（判定口径，供 double review 对齐）

8 支柱 = 后端可靠性概念映射到 iOS 等价物：①线程池隔离 ②熔断重试 ③Sidecar 旁路治理 ④TraceID 串联 ⑤入参校验 ⑥链路统一时间 ⑦序列化 ⑧Cache-Aside。

关键防误判规则（来自 skill red-flags）：

- `timeoutIntervalForRequest` 是单请求超时 ≠ 熔断器；熔断器必须有跨请求失败计数 + 状态机
- `@MainActor` 保证线程安全 ≠ 主线程不被阻塞；要看重活（decode/IO/全量 fetch）跑在哪
- 生成 UUID ≠ TraceID；必须**传播**（HTTP 头 + 日志 + 遥测）才能串联
- `URLCache.shared` 默认存在 ≠ Cache-Aside；要代码层显式 读缓存→miss 取源→写回→失效
- 状态只有 4 个值：`已落实` / `部分落实` / `未发现` / `不适用 (N/A)`；无证据 = `未发现`，不脑补

---

## 1. 结论摘要

> 整体 **部分合格**。最强项是熔断重试（真实三态熔断器 + 指数退避 + 完整降级链路）与入参校验（全边界 trim/isEmpty/UUID 校验 + AI 输出系统化消毒）。最薄弱项是 Cache-Aside（iOS 端完全缺失，全靠服务端缓存）与 Sidecar 旁路治理（零件都在，但 **BGTask identifier 代码与 Info.plist 不一致，后台遥测上传实际跑不起来**）。关键风险：遥测数据管道形同虚设——购买漏斗、MetricKit 崩溃计数等决策数据依赖的批量上报通道已断链。

## 2. 逐项结果表

| # | 能力 | 状态 | 证据 / 位置 | iOS 等价物 |
|---|------|------|-------------|------------|
| 1 | 线程池隔离 | 部分落实 | 重解码全在 nonisolated async（SE-0338 切后台：TodoExtractorService.swift:229,296,352,549,693；NetworkClient.swift:221,301）；重查询下沉 `@ModelActor TodoQueryActor`（Store/TodoQueryActor.swift:13-14，TodoStore.swift:550 async 透传）；词库学习唯一 `Task.detached`（App/AppCoordinator.swift:816）。**但** TodoStore 主上下文 CRUD + 全量 fetch 仍在主线程（Store/TodoStore.swift:824 diagnosticsAllItems 全量取库、:758）；TelemetryQueue/PersonalGlossary/CorrectionTracker/UserVocabulary/ReviewSessionStore/ReviewPinningStore 六个 NSLock 存储在调用方线程同步编解码（Protocols/TelemetryQueue.swift:213,222 等） | `@MainActor` / `@ModelActor` / `Task.detached` |
| 2 | 熔断重试 | 已落实 | 真三态熔断器 `actor ExtractorCircuitBreaker`（Extractor/ExtractorCircuitBreaker.swift:12-17，closed/open(until:)/halfOpen）；阈值 5 / 冷却 15s（Protocols/Constants.swift:39,44）；指数退避 base×2^(n-1) 封顶 8s + 0~30% jitter（TodoExtractorService.swift:589-595）；错误分类可重试/不可重试（:109-126，quota/json 类抛出、429 按 Retry-After 与上限门控）；取消三来源识别（:623-628）；超时 55s 对齐 Worker 45s failover 预算（Constants.swift:28，NetworkClient.swift:298）；取消链完整（AppCoordinator.swift:123,1138 → AsyncStream onTermination NetworkClient.swift:249-252）；离线降级落库 needsAIProcessing=true → 前台恢复（App/TranscriptProcessingFlow.swift:233，并发 3：Constants.swift:69）。主路径流式**零重试**为文档化取舍（Constants.swift:37-38 注释明示） | 无原生熔断器（自建 actor 补齐） |
| 3 | Sidecar | 部分落实 | MetricKit 诊断订阅 4 类计数（App/CrashDiagnosticsSubscriber.swift:20,36-56，crashes/hangs/diskWrites/cpuExceptions，全 0 不入队）；BGTask 遥测上传已注册（App/TelemetryUploader.swift:52）**但 identifier 断链（见 🔴-1）**；OSLog 单 subsystem 12 category + task-local 上下文（Protocols/VoiceTodoLog.swift:5-26）；无采样/限量机制；无 NSURLProtocol 生产注册（仅测试 stub，VoiceTodoTests/Extractor/ExtractorTests.swift:1139——按判定规则可 N/A） | MetricKit / BGTaskScheduler / OSLog |
| 4 | TraceID 串联 | 部分落实 | 三层 ID：requestID `proxy-XXXXXXXX` → `X-Request-ID` 头（NetworkClient.swift:74,294）；extractID → `X-Extract-ID`（:295，`makeID("extract")`）；flowID 批级贯穿 pending 恢复（App/PendingRecoveryFlow.swift:212-235，task-local 注入 :215-216）；sessionID 每启动新建进全部遥测事件（Protocols/Telemetry.swift:34-35,57）。**断点**：AIProxy 源码对 `X-Request-ID` 零引用（已 grep 核验，不回传不消费）；遥测 payload 无 requestID/flowID 字段（Telemetry.swift:53-64）；旁路 2 出口不带 trace 头（TelemetryUploader.swift:148-159、UI/Shared/FeedbackSubmitter.swift:95）；无 OSLog signpost（全库零匹配） | UUID / X-Request-ID / @TaskLocal |
| 5 | 入参校验 | 已落实 | 表单 trim+isEmpty+disabled（UI/Home/BottomInputPanelView.swift:49-54,377；UnparsedTranscriptEditSheet.swift:22-25,111）；Siri 入口空串+AI 同意校验（App/Intents/AddTodoIntent.swift:21-37）；Widget 打勾 UUID 校验（App/Intents/ToggleTodoIntent.swift:23-24）；decode 失败显式抛错分流 transcriptTooLong/jsonParsingFailed（TodoExtractorService.swift:690-708）；AI 输出系统化消毒：空标题从 detail 派生+截 200（Protocols/Models.swift:353-361）、伪 null hint 过滤（:367）、dueDate 解析失败归 nil、reminderTimes 非法 HH:mm 过滤（:285）、enum tolerant 表外值回落（:430-431）；force-unwrap 量级：try! 3 处全在 Preview（UI/Review/ReviewView.swift:659,696,723）、as! 0、外部输入路径无 precondition | Form disable / init throws / tolerant decode |
| 6 | 链路统一时间 | 部分落实 | 网络链路统一 epoch 毫秒（Protocols/JSONCoding.swift:23 encoder `.millisecondsSince1970`）；SwiftData 全用 `Date`（Store/SwiftDataModels.swift:13,22,38,39）；日界走 DayClock 设备时区+自定义 startHour+DST 安全（Protocols/Domain/DayClock.swift:83-99）；X-Local-Date 设备时区 yyyy-MM-dd POSIX（Protocols/Quota.swift:184-193）。**但**存在第二套 iso8601 口径（Protocols/ReviewSessionStore.swift:284,306，本地存储自洽但双配置源）；DateFormatter 每次新建 3 处（Quota.swift:185、RecurrenceRule.swift:81、RecurrenceEndResolver.swift:95） | Date / dateEncodingStrategy / POSIX formatter |
| 7 | 序列化 | 部分落实 | 网络主链路全走 `JSONCoding` 工厂（JSONCoding.swift:14-23；引用点：NetworkClient.swift:221,301,360、TodoExtractorService.swift:229,352,690、TelemetryUploader.swift:43）；key 策略不对称（响应 `.convertFromSnakeCase` / 请求 camelCase）与两端契约一致且有注释说明。**旁路**：DeepRead 裸 new（TodoExtractorService.swift:282,296——**已核验** DeepReadResponse 仅 String/[String:String] 字段，无 Date，无实际风险）；6+ 本地存储点裸 new（均无 Date，低风险）；reminderTimes 独立静态实例（SwiftDataModels.swift:277-278，内容 [String] 无策略影响） | JSONDecoder strategy 单一工厂 |
| 8 | Cache-Aside | 未发现 | iOS 端无 NSCache（app 目录全库零命中）、无显式 URLCache 配置、相同 transcript 无本地去重——reextract/pending 重试每次真实打网络（AppCoordinator.swift:895-916）。缓存责任全在服务端：AIProxy/src/extractionCache.js（KV，`CACHE_TTL_SECONDS = 3600`，key 含 today 跨天失效，仅覆盖非流式无 personalHints 请求） | NSCache / URLCache（均未用） |

## 3. 具体问题清单

### 🔴 严重

- **[R-1] BGTask identifier 不一致，后台遥测上传整链失效**
  位置：`App/TelemetryUploader.swift:19` vs `VoiceTodo/Info.plist:7`（及 `project.yml:125`）
  现象：代码注册 `com.voicetodo.app.telemetry-upload`，Info.plist 声明的是 `com.qingqingyu.voicetodo.telemetry-upload`。
  后果：identifier 未在 BGTaskSchedulerPermittedIdentifiers 声明 → `BGTaskScheduler.submit` 抛错（TelemetryUploader.swift:84-85 只记 `telemetry.upload.schedule_failed` 日志）→ 购买漏斗、onboarding 分步、MetricKit 崩溃计数（CrashDiagnosticsSubscriber 入队的全部事件）的批量上报**从不执行**，运营/崩溃决策数据静默缺失，且事件队列只增不减。

### 🟡 中等

- **[R-2] 主路径流式零重试**
  位置：`Protocols/Constants.swift:37-38`（注释自认）、重试循环仅在非流式 `extract()`（TodoExtractorService.swift:55）
  现象：`extractStreaming` 一次失败即终，仅靠熔断器计数与离线兜底。
  后果：弱网瞬时抖动时录音直接落离线库或报错，用户需等下次前台或手动重试；主流程恢复能力弱于旁路（pending 批处理反而走带重试的非流式路径）。

- **[R-3] TodoStore 主线程全量 fetch**
  位置：`Store/TodoStore.swift:824`（diagnosticsAllItems 全量取库 + toData() 映射在 @MainActor 主上下文同步执行）、CRUD 全在主 context
  后果：500+ 条时前台诊断/刷新路径卡主线程（CLAUDE.md 自认瓶颈 #3）。`refreshIfStale` 外部版本门控只降低触发频率，不改单次成本。

- **[R-4] TraceID 三方无法 join**
  位置：`Protocols/Telemetry.swift:53-64`（payload 无 requestID/flowID）+ AIProxy 源码对 `X-Request-ID` 零引用（已核验）
  后果：排查一次线上失败时，OSLog / 遥测 / 代理日志三方只能靠 deviceID + 时间戳模糊对齐，无法精确串联。

- **[R-5] 时间序列化第二口径**
  位置：`Protocols/ReviewSessionStore.swift:284,306`（iso8601）vs `JSONCoding`（epoch 毫秒）
  后果：当前本地存储自洽无实害，但未来任何代码复用拿错工厂即产生时间漂移或 decode 失败，属漂移地雷。

### 🟢 低

- **[R-6]** `ExtractorCircuitBreaker.swift:99` `reset()` 零调用点，注释声称"用于回前台"与事实不符（注释撒谎型；实际恢复仅靠冷却到期→halfOpen）。
- **[R-7]** DateFormatter 每次新建 3 处：`Protocols/Quota.swift:185`、`Protocols/Domain/RecurrenceRule.swift:81`、`RecurrenceEndResolver.swift:95`（性能小瑕疵）。
- **[R-8]** `UI/Shared/FeedbackSubmitter.swift:95` 旁路请求不带任何 trace 头，反馈链路不可追踪。
- **[R-9]** AI 返回重复 todo 无客户端去重（Models.swift:353-431 仅字段级消毒）。
- **[R-10]** TelemetryQueue/PersonalGlossary 等 NSLock 存储在调用方线程同步编解码（TelemetryQueue.swift:213,222）——payload 小，主线程影响可忽略。

## 4. 建议修正项（本次未执行，仅列出）

1. **统一 BGTask ID**：`TelemetryUploader.swift:19` 改为 Info.plist 已声明的 `com.qingqingyu.voicetodo.telemetry-upload`（或反向改 plist + project.yml 同步）。验证口径：真机触发后日志不再出现 `schedule_failed`。
2. **TelemetryPayload 增加 `requestID`/`flowID` 可选公共字段**（默认 `"none"`，record 时从 `VoiceTodoLog` task-local 取值）。预期：遥测与 OSLog 可精确 join。
3. **ReviewSessionStore 收敛到 `JSONCoding`**：工厂内新增 `makeLocalDecoder/Encoder()`（iso8601 语义），删除散落裸配置。预期：全工程时间序列化单一配置源。
4. **`diagnosticsAllItems` 与全量 `toData()` 映射迁移到 `TodoQueryActor`**。预期：主线程只收 UI 状态，瓶颈 #3 关闭。
5. **熔断器 `reset()` 二选一**：在 `handleAppForeground` 接线调用，或删除方法并修正注释。

## 5. 不确定项（证据不足，未下结论）

- **流式路径与熔断器的喂线细节**：只确认流式入口有 `shouldShortCircuit` 短路（TodoExtractorService.swift:413），未逐行审计 SSE 循环内成功/失败如何调用 `recordSuccess/recordFailure`（半开探测是否会被流式半途失败误重开）。需补充：流式循环的熔断接线代码。
- **`AppGroupModelContainerProvider` 的 `nonisolated(unsafe)` 静态缓存**（Store/AppGroupModelContainerProvider.swift:7-8）：确认有 NSLock，但未审计跨进程（App/Widget/Intent）同时首次建容器的读写竞争窗口。
- **AIProxy 日志字段**：仅核验了 `X-Request-ID` 零引用，未全面审代理侧日志是否含 deviceID/时间戳可间接串联。

## 三层区分

| # | 支柱 | 层级 |
|---|------|------|
| 1 | 线程池隔离 | 🟡 概念相似但不完整（隔离零件齐全，主线程重活残留） |
| 2 | 熔断重试 | 🟢 真实实现（流式无重试为已文档化取舍） |
| 3 | Sidecar | 🟡 概念相似但不完整（零件在，BGTask 断链） |
| 4 | TraceID | 🟡 概念相似但不完整（生成传播有，跨系统 join 断） |
| 5 | 入参校验 | 🟢 真实实现 |
| 6 | 链路统一时间 | 🟡 概念相似但不完整（双口径） |
| 7 | 序列化 | 🟡 概念相似但不完整（工厂 + 多处裸 new 旁路） |
| 8 | Cache-Aside | 🔴 完全缺失（iOS 端；缓存责任在服务端） |

---

## 附 A：证据核验记录（审查者二次确认过的关键声明）

以下声明在报告产出前由审查者脱离子代理独立核验，置信度最高：

| 声明 | 核验方式 | 结果 |
|------|----------|------|
| R-1 BGTask ID 不一致 | grep 三个文件原文 | TelemetryUploader.swift:19 = `com.voicetodo.app.telemetry-upload`；Info.plist:7 与 project.yml:125 = `com.qingqingyu.voicetodo.telemetry-upload`。确认不一致 |
| 流式无重试注释 | sed Constants.swift:30-40 | 注释原文确认"主路径 `extractStreaming` **没有重试**（重试循环只在非流式 `extract()` 里）" |
| DeepReadResponse 无 Date | sed TodoExtractorService.swift:270-274 | 字段仅 `observation: String / draft: String / numbers: [String: String]`。裸解码无实际风险，R-5 不含此项 |
| AIProxy 不消费 X-Request-ID | grep AIProxy/src + worker.js | 零匹配。客户端发送但服务端不读不回传 |
| 熔断器 reset() 无调用 | grep Extractor/ App/ | 仅定义（ExtractorCircuitBreaker.swift:99），调用点只有 shouldShortCircuit（TodoExtractorService.swift:45,413） |
| reminderTimes 主线程 decode | sed SwiftDataModels.swift:255-265 | decode 在 @Model computed getter 内，但有 per-object cache（`reminderTimesCache`），仅首次访问解码，已缓解 |

## 附 B：给 double reviewer 的快速核验清单

按影响排序，每条给出最小核验动作：

1. **R-1（🔴 唯一严重项）**：`grep -n "telemetry-upload" VoiceTodo/App/TelemetryUploader.swift VoiceTodo/VoiceTodo/Info.plist VoiceTodo/project.yml`——三处 ID 是否一致；再读 TelemetryUploader.swift:78-90 确认 submit 失败路径确实只记日志。
2. **R-4 服务端断点**：`grep -rn "X-Request-ID" VoiceTodo/AIProxy/src VoiceTodo/AIProxy/worker.js`——应为零匹配。
3. **R-2**：读 `Protocols/Constants.swift:30-45`（retryCount 与熔断注释）+ `TodoExtractorService.swift:37-126`（extract 重试循环）+ 流式路径 `:400-560`（确认无 attempt 循环）。
4. **支柱 1 判定**：抽查 `Store/TodoStore.swift:824` 上下文（是否 @MainActor 同步 fetch）与 `Store/TodoQueryActor.swift:13`（@ModelActor 存在性），确认"部分落实"而非"已落实"或"未发现"。
5. **支柱 8 判定**：`grep -rn "NSCache\|URLCache" VoiceTodo/{App,Protocols,Extractor,Store,UI,Voice} --include="*.swift"`——应为零匹配（iOS 端）。
6. **R-5**：对比 `Protocols/JSONCoding.swift:16,23` 与 `Protocols/ReviewSessionStore.swift:284,306` 的 date 策略。
7. **附 A 表内 6 条**均已由审查者独立核验；子代理报告的其余 file:line 建议抽查 3-5 处再采信（子代理行号准确率一般高但非 100%）。

## 附 C：审查方法与局限

- 方法：4 个并行 Explore 子代理按支柱分组收集 file:line 证据 → 审查者对严重项与存疑项独立 grep/sed 二次核验（见附 A）→ 按 skill 模板汇总。
- 局限：①未运行任何测试或 Instruments，全部结论来自静态读码；②AIProxy 仅交叉核对两处，不构成对代理端的审查；③Widget 扩展与 Intent 进程只审了数据读取路径；④行号以 `001d659` 工作区为准，后续提交会漂移。
