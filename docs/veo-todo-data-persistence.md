# 跨设备数据持久化：换设备后数据不丢

> 状态：**待实施**（设计方案，尚未落任何代码）。
> 行号基准：`9e12fdb`。
> 本文回答两个问题：(1) 换设备丢数据这件事该怎么解；(2) 作为独立开发者的第一版 MVP，
> 这个功能该不该上、不上的话什么阶段上合适。
> 结论先行：**v1 只做导出/导入 + 零成本的未来保险，CloudKit 同步推到 1.2~1.3**。

## Context

VoiceTodo 目前没有账户体系，所有数据只存在本机的 App Group 容器里
（`<group.com.voicetodo.shared>/VoiceTodo.sqlite`，见 `Store/AppGroupConfig.swift:131`）。
担心的问题是：用户换设备后，之前的待办、个人词库、纠错记录全部丢失。

### 风险的真实边界（先纠正一个前提）

仓库中**没有任何 `isExcludedFromBackup` 调用**（全仓 grep 无命中），
App Group 容器默认包含在 iCloud 备份内。因此走「快速开始 / 从 iCloud 备份恢复」
的常规换机流程，`VoiceTodo.sqlite` 会跟着迁移过去。

真正会丢数据的场景只有三个：

1. 用户删除 App 后重装（容器被系统清空，备份不会自动回填单个 App）
2. 用户没开 iCloud 备份，换机时手动重新下载
3. 想在 iPhone + iPad 上同时用（这是「没有」，不是「丢」）

**结论：v1 不做同步 ≠ 所有换机用户数据全丢。风险等级低于直觉。**
这个判断是下面分期结论的基础。

### 现状盘点

| 数据 | 位置 | 换设备后 |
| --- | --- | --- |
| 待办 / 重复任务完成记录 | SwiftData，`<AppGroup>/VoiceTodo.sqlite` | 走备份恢复能保住；删 App 重装则丢 |
| 个人词库 `VoiceTodoUserVocabularyTerms` | App Group UserDefaults，`Protocols/UserVocabulary.swift:43` | 同上 |
| 个人术语 `VoiceTodoPersonalGlossaryEntries` | App Group UserDefaults，`Protocols/PersonalGlossary.swift:52` | 同上 |
| 纠错记录 `VoiceTodoTitleCorrections` | App Group UserDefaults，`Protocols/CorrectionTracker.swift:48` | 同上 |
| 一天起点 `VoiceTodoDayStartHour` | App Group UserDefaults，`Protocols/Domain/DayClock.swift:16` | 同上 |
| Pro 订阅状态 | StoreKit 2，`App/EntitlementManager.swift` | **本来就跟 Apple ID 走，不受影响** |
| 语音音频 | 不落盘（`AVAudioEngine` tap 直接喂识别器） | 无需迁移 |

### 已确认的决策

| 决策项 | 结论 |
| --- | --- |
| 跨端范围 | 只在 Apple 设备之间 → 走 iCloud，不自建后端、不做账户系统 |
| 无 iCloud 兜底 | 手动导出 / 导入 JSON 文件 |
| 付费门槛 | 免费，不做成 Pro 专属 |

付费门槛这条值得展开：「换手机不丢数据」是保底预期而非增值功能，收费容易招差评；
且 CloudKit 私有库占的是用户自己的 iCloud 配额，对开发者零存储成本，没有收费的成本动机。

---

## 分期结论

### v1.0：导出 / 导入 + 未来保险

**不上 CloudKit 同步**，三个理由：

1. **CloudKit 的失败模式是静默的，且无法从用户端复现。** 同步循环、重复条目、
   schema mismatch 导致容器起不来——症状是「任务变成两份了」「任务不见了」，
   恰恰是最伤评分的那类。对独立开发者，这类 bug 的排查成本极高。
2. **CloudKit production schema 一旦 deploy 就只能加不能删。** v1 是数据模型最不稳定的
   时候（1.1 / 1.2 还会加字段、改结构），现在锁死等于把最不成熟的 schema 永久化。
3. **v1 的生死线不在这里。** 对语音待办 App，决定去留的是「说一句话能不能准确变成
   对的任务、对的时间」——第一次用就见分晓。同步是「用久了才会遇到」的问题。
   把 v1 有限的测试预算投给同步，是投在留存曲线的尾部。

**上导出 / 导入**，理由：成本极低（`TodoItemData` 已经是 `Codable`），
但它是唯一让**用户能自救、开发者能回应用户**的手段——有人来问换机怎么办时，
有一句可执行的回答而不是「抱歉」。而且它顺带是将来做 CloudKit 时的迁移与调试工具。

### v1.2 ~ 1.3：CloudKit 同步（用信号触发，不用版本号）

三个信号同时满足再动手：

- **A（必要）** 数据模型连续 2 个版本无结构性变更 → 说明核心体验定型了
- **B（必要）** 手上有 2 台真机可做双端对拍，且愿意留 1–2 周 TestFlight beta
  （CloudKit 不能只在模拟器上验）
- **C（需求）** 用户开始主动问 iPad / 换机 / Mac，或准备做 iPad 版

排在提取准确率与留存打磨之后。设计要点见文末「Phase 1 预研」。

---

## Phase 0 实施：备份导出 / 导入

### 0.1 备份数据格式

新建 `Store/TodoBackup.swift`。设计成 **backend-agnostic**——将来无论走 CloudKit
还是自建后端，这套 DTO 都能直接复用。

```swift
struct TodoBackupDocument: Codable, Sendable {
    static let currentSchemaVersion = 1
    var schemaVersion: Int = Self.currentSchemaVersion
    var exportedAt: Date
    var appVersion: String          // CFBundleShortVersionString + build
    var todos: [TodoItemData]       // 直接复用 Protocols/Models.swift 的 Codable DTO
    var occurrenceCompletions: [TodoOccurrenceBackupEntry]
    var settings: BackupSettings?   // 可选，缺失时导入跳过
}

struct TodoOccurrenceBackupEntry: Codable, Sendable {
    var todoId: UUID
    var occurrenceDate: Date
    var completedAt: Date
}

struct BackupSettings: Codable, Sendable {
    var vocabularyTerms: [UserVocabularyTerm]?        // Protocols/UserVocabulary.swift:22
    var glossaryEntries: [PersonalGlossaryEntry]?     // Protocols/PersonalGlossary.swift:13
    var titleCorrections: [TitleCorrection]?          // Protocols/CorrectionTracker.swift:6
    var dayStartHour: Int?
    var speechRecognitionLanguage: String?
    var calendarWriteMode: String?
}
```

三个 settings 结构体都**已经是 `Codable`**，直接嵌进来即可，不需要新写 DTO。

**明确不导出**：

- `systemCalendarEventIdentifier` —— 设备本地的 EventKit 标识，换设备后无法解析。
  带过去会让第二台设备尝试更新/删除一个不存在的日历事件（见
  `App/SystemCalendarWriter.swift` / `App/CalendarSyncService.swift`）。
- telemetry 队列（`VoiceTodoTelemetryQueue`）、`VoiceTodoProxyDeviceIdentifier`
  （匿名设备标识，`Protocols/Constants.swift:31`）、onboarding / paywall 状态标记。

> ⚠️ `TodoItemData` 本身**含有** `systemCalendarEventIdentifier` 字段。
> 必须在 export 路径上逐条置 nil，**不要改 `TodoItemData` 的定义**——
> 它被 Widget / AppIntent / UI 层广泛依赖。

#### JSON 编解码：不要复用 `JSONCoding`

`Protocols/JSONCoding.swift` 里的两个工厂方法是**服务端契约专用**的
（`makeResponseDecoder` 用 `.convertFromSnakeCase`；`makeRequestEncoder` 用
`.millisecondsSince1970`），文件注释明确写了「不要给请求编码器加 `.convertToSnakeCase`，
否则会破坏与代理的契约」。

备份文件是给人看、给未来的自己看的，应当在同一个文件里**新增独立的一对**：

```swift
static func makeBackupEncoder() -> JSONEncoder   // .iso8601 + .prettyPrinted + .sortedKeys
static func makeBackupDecoder() -> JSONDecoder   // .iso8601，不做 key 转换
```

`.sortedKeys` 让两次导出的文件可以直接 diff，排查问题时很有用。

### 0.2 导出 / 导入服务

新建 `Store/TodoBackupService.swift`：

- `makeBackup(from:) throws -> TodoBackupDocument`
  - todos 取自 `TodoStore.todos`（`Store/TodoStore.swift:27`，已是 `[TodoItemData]`），
    逐条置空 `systemCalendarEventIdentifier`
  - occurrence completions 走 `modelContext.fetch(FetchDescriptor<TodoOccurrenceCompletion>())`
  - settings 从 `UserVocabularyStore` / `PersonalGlossaryStore` / `CorrectionTracker` /
    `DayClock` 的现有读取 API 取
- `encode(_:) throws -> Data` / `decode(_:) throws -> TodoBackupDocument`
  - decode 时校验 `schemaVersion <= currentSchemaVersion`，更高版本**明确报错**
    而不是静默丢字段（用户拿新版本导出的文件在旧版本上导入，必须给出可理解的提示）
- `merge(_:into:strategy:) throws -> ImportSummary`

**导入合并语义**（以 `TodoItem.id` 为主键）：

| 情况 | 处理 |
| --- | --- |
| 本机不存在该 id | 插入 |
| 本机已存在该 id | 默认**跳过**，保留本机版本；策略参数 `.preferBackup` 时覆盖 |
| occurrenceCompletion | 按 `TodoOccurrenceCompletion.key(todoId:occurrenceDate:)`（`Store/SwiftDataModels.swift:379`）去重后插入 |
| settings | 追加合并（词库 / 术语取去重并集），不覆盖本机已有条目 |

返回 `ImportSummary { insertedTodos, skippedTodos, insertedCompletions }`，用于导入后 toast。

**导入是纯增量的，任何情况下都不删除本机已有数据。** 这是刻意的保守选择：
用户导错文件的代价应该是「多了些任务」而不是「原来的没了」。

导入完成后必须依次：

1. `try saveOrRollback()` + `refreshTodos()`（`Store/TodoStore.swift:582`）
2. 重建通知计划（`App/TodoNotificationSync.swift`）
3. `AppGroupConfig.markExternalDataChanged()`（`Store/AppGroupConfig.swift:33`）
4. `WidgetCenter.shared.reloadAllTimelines()`

### 0.3 Store 层接口

- `Protocols/TodoStoreProtocol.swift`：新增 `TodoBackupWriting` 协议，
  含 `func importTodos(_ items: [TodoItemData], strategy: ImportStrategy) throws -> ImportSummary`
- `Store/TodoStore.swift`：实现之。批量插入后走一次 `saveOrRollback()`。

> ⚠️ `seedForUITests(_:)`（`Store/TodoStore.swift:496`）看起来是现成的模板——
> 它做的正是「`TodoItemData` → `TodoItem` 批量插入」。**但不能直接复用**：
> 它构造 `TodoItem` 时漏了 `completedAt`、`reminderTimes`、`extractionOutcome`
> 三个字段（对 UI 测试无所谓，对备份恢复是数据丢失）。
> 导入路径需要一个**完整**的 `TodoItemData → TodoItem` 转换。
>
> 建议顺手把这个转换抽成 `TodoItem.init(from: TodoItemData)`，
> 让 `seedForUITests` 也改用它——这样以后模型加字段只有一处要改，
> 不会再出现「某条路径悄悄丢字段」。

sortOrder 冲突（导入的任务和本机任务 sortOrder 撞车）用现有
`migrateOldSortOrder()`（在 `Store/TodoStore.swift:45` 被调用）的重排思路兜底。

### 0.4 UI 接入

`UI/Home/HomeSettingsSheet.swift` 新增一个 Section（放在「个性化」Section 之前，
即当前 `:115` 那个 Section 前面）：

```
Section {
    Button → 导出备份    .fileExporter, UTType.json
                        文件名 VoiceTodo-Backup-YYYY-MM-DD.json
    Button → 导入备份    .fileImporter, allowedContentTypes: [.json]
} header: {
    Text("settings.backup.title")
} footer: {
    Text("settings.backup.description")
}
```

- footer 文案要**明说**「数据保存在本机，换设备前请先导出一份」——
  这是把「数据在哪」这件事对用户透明化的唯一位置，比事后解释便宜得多
- 导入前弹 `confirmationDialog` 说明合并语义（不会删除现有任务）
- 导入结果用现有 `ToastView`（`UI/Shared/ToastView.swift`）展示 `ImportSummary`
- 文案加进 `Resources/Localizable.xcstrings`，key 前缀 `settings.backup.*`，中英双语
- 加 `accessibilityIdentifier`（`ExportBackupButton` / `ImportBackupButton`），
  与该文件现有约定一致（如 `:128` 的 `ClearVocabularyButton`）

### 0.5 未来保险（零成本，现在就做）

1. **确认备份未被排除**：已核查全仓无 `isExcludedFromBackup`，保持现状即可，
   今后也不要新增。这是白拿的「换机快速开始/从备份恢复」数据延续。
2. **新字段一律遵守 CloudKit 约束**：此后新增的 `@Model` 属性必须「可选 **或** 带默认值」，
   且不再新增 `@Attribute(.unique)`。这样将来开 CloudKit 时，迁移面只剩现有的
   3 个 unique 约束，不会继续扩大。建议把这条写进 `Protocols/CodingConventions.md`。
3. **备份 JSON 的 `schemaVersion` 从 1 开始**，后续任何字段变更都必须递增，
   并在 decode 处显式兼容旧版本。

第 2 条是这份方案里性价比最高的一项：现在写进规范是零成本，
等到 1.2 再来收拾会多出一堆需要迁移的字段。

### 0.6 测试

新建 `VoiceTodoTests/Store/TodoBackupTests.swift`，沿用现有 in-memory container 模式
（参考 `VoiceTodoTests/Store/StoreTests.swift:30`）：

- **round-trip**：构造含全部字段（recurrence / reminderTimes / timeBucket /
  extractionOutcome / completedAt）的 todo → encode → decode → 断言逐字段等价。
  这条测试同时是「以后加字段别忘了加进备份」的守门员
- `systemCalendarEventIdentifier` 在导出结果中恒为 nil
- 合并：id 重复时默认跳过；`.preferBackup` 时覆盖
- occurrenceCompletion 去重：同一 `occurrenceKey` 导入两次只留一条
- 版本校验：`schemaVersion = 999` 的文档 decode 抛错
- 健壮性：空文档、settings 缺失、todos 为空数组，都不应影响其余部分导入

---

## 验证方式

1. `xcodegen generate` 后按 `TESTING.md` 跑单测
   （`xcodebuild -scheme VoiceTodo -destination 'platform=iOS Simulator,name=iPhone 16' test`）
2. **模拟器端到端**：建若干任务（含重复任务、且已完成其中某一天）→ 设置页导出 →
   删除 App 重装 → 导入 → 核对任务数、重复规则、当天完成状态、个人词库
3. 导出的 JSON 用文本编辑器打开应可读，且 `systemCalendarEventIdentifier` 全为 null
4. **Widget**：导入后回桌面确认 Widget timeline 刷新出新任务
5. **负向**：随便挑一个非备份的 .json 文件导入，应给出明确错误提示且不改动任何数据

---

## Phase 1 预研：CloudKit 同步（不在本次范围）

留档。等信号 A / B / C 满足后再启动。以下是已核实的阻塞点，届时逐条处理。

### 模型改造（`Store/SwiftDataModels.swift`）

- **移除 3 处 `@Attribute(.unique)`**：`TodoItem.id`（`:9`）、
  `TodoOccurrenceCompletion.occurrenceKey`（`:358`）、`VoiceCaptureRecord.id`（`:389`）。
  CloudKit 镜像不支持唯一约束。
  → `occurrenceKey` 的去重语义必须改为 App 层去重：在 `TodoStore.init` 加一道 dedup pass，
  与现有的 `purgeLegacyVoiceCaptureRecords()` / `migrateOldSortOrder()` /
  `migrateDueDatesFromHints()` 同位置（`Store/TodoStore.swift:44-46`）。
- **所有非可选属性补默认值**：`TodoItem` 的 `id` / `title` / `priorityRaw` /
  `categoryRaw` / `isCompleted` / `createdAt` / `needsAIProcessing` / `sortOrder`，
  以及 `TodoOccurrenceCompletion` 的全部字段。CloudKit 要求每个属性可选或有默认值。
- **`VoiceCaptureRecord` 考虑直接从 `VoiceTodoSchema.schema`（`:484`）移除**。
  它是 legacy，启动时就被 purge，没必要把它推上 CloudKit production schema
  （推上去就删不掉了）。

目前仓库**没有 `VersionedSchema` / `SchemaMigrationPlan`**，全靠默认值走轻量迁移。
移除 unique 约束 + 补默认值理论上仍在轻量迁移范围内，但这是本方案里
**唯一有真实数据丢失风险的一步**，实施时必须先在装有真实数据的设备上验证升级路径。

### 配置

- 新增 entitlements。注意要**同时改两处**——`.entitlements` 文件**和** `project.yml`
  里的 inline `properties`（`project.yml:86-90` 与 `:163-167`），
  否则 XcodeGen 重新生成时会覆盖掉：
  - `com.apple.developer.icloud-container-identifiers`
  - `com.apple.developer.icloud-services: [CloudKit]`
  - `com.apple.developer.ubiquity-kvstore-identifier`
- `App/VoiceTodoApp.swift:99-113` 的 `ModelConfiguration` 加 `cloudKitDatabase: .private(...)`，
  并接进现有的三级 fallback ladder（`ModelContainerStartupPolicy`，`App/VoiceTodoApp.swift:436`）。
  **未登录 iCloud 时必须优雅降级到本地库，绝不崩溃、绝不丢数据。**
- `Store/AppGroupModelContainerProvider.swift` 的 Widget / AppIntent 容器建议保持
  `cloudKitDatabase: .none`：`allowsSave: false` 与 CloudKit 组合有已知问题，
  且扩展进程内存受限。扩展的写入靠 persistent history，由主 App 进程补推上云。

### 冲突与去重

CloudKit 镜像是 per-field last-writer-wins。本仓库会被咬到的具体位置：

- `sortOrder` —— 两台设备各自拖拽重排后合并，顺序会乱
- `isCompleted` —— Widget 侧切换完成状态（`App/Intents/ToggleTodoIntent.swift`）
  与主 App 侧并发
- 同 `occurrenceKey` 的重复完成记录 —— unique 约束移除后没有兜底

`systemCalendarEventIdentifier` 是设备本地标识，**不能跨设备同步**。
需要在第二台设备上视为 nil 重新建事件，否则会更新/删除到不存在的日历事件。

### 设置项同步

- → `NSUbiquitousKeyValueStore`（1 MB / 1024 key 上限）：`UserVocabulary`、
  `PersonalGlossary`、`DayClock.dayStartHour`、语音识别语言
- → 保持设备本地：telemetry 队列、`VoiceTodoProxyDeviceIdentifier`、
  onboarding 标记、权限派生状态

### 发布前必做

CloudKit Dashboard 把 schema **deploy 到 production**。
忘了这一步的典型症状是 TestFlight 一切正常、App Store 版本起不来——经典 ship blocker。
