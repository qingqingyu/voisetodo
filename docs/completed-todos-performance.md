# 完成项增长导致的卡顿：不删数据的性能治理

> 状态：**待实施**。本文档是实施指引 + 设计决策记录。
> 核心约束：**不删除任何已完成数据**。统计需要历史数据，而性能并不需要删除历史数据。
> 主要落点：`Store/SwiftDataModels.swift`、`Store/TodoStore.swift`、`Store/TodoQueryActor.swift`、
> `UI/Home/HomeView.swift`、`UI/Home/HomeCalendarState.swift`、`UI/Review/ReviewView.swift`、
> `App/VoiceTodoApp.swift`

---

## 1. 背景与结论

### 现象

App 用得越久越卡。未完成任务会自然流转（完成、删除、改期），数量有上限；已完成任务只增不减，
所以随使用时长线性增长，最终把首屏和交互拖慢。

### 被否决的方案

有一个方案提议「加 `purgeCompletedBefore(cutoff:)`，把 30 天前的完成项物理删除」。

**否决理由**：`UI/Review/ReviewView.swift` 的「回顾」统计完全建立在 `TodoItem.isCompleted` /
`completedAt` / `categoryRaw` 和 `TodoOccurrenceCompletion` 之上。删掉历史完成项 = 删掉统计的
数据源。这是拿产品资产去换一笔本来就不需要付的性能开销。

### 结论

**把日期过滤下推到 SQL 谓词 + 给热字段加索引**，让查询成本只与「窗口内的数据量」相关，
与库里存了 10 条还是 10 万条无关。原始数据一条不删，统计口径一个字不改。

同时要修正一个诊断偏差：`refreshTodos()` 的全量 fetch 确实是问题，但它只排**第三**。
最贵的一处是每帧对全量 todos 做深 hash，跟「进前台刷新」完全无关。

---

## 2. 开销分布

按严重程度排序。

| # | 位置 | 触发频率 | 代价 |
|---|---|---|---|
| ① | `UI/Home/HomeView.swift:1451` | **每次 body 求值**（含折叠拖拽 60fps） | `.task(id: CalendarRefreshKey(anchor:todos:revision:))` —— key 里塞了整个 `store.todos`（`HomeCalendarState.swift:349`）。`.task(id:)` 每次求值都要 hash + 比较 id，而 `TodoItemData` 的 `Hashable` 合成自 22 个字段（`Protocols/Models.swift:467`），**含 `rawTranscript` 整段语音原文**。等于每帧把全库每条待办的所有字符串 hash 一遍，外加整数组拷进 key struct |
| ② | `UI/Home/HomeView.swift:1150-1157` | 每次 body 求值 | `monthHomeView` 里 `let state = HomeCalendarState.make(...)`，没有记忆化。构造器（`HomeCalendarState.swift:163-188`）对全量 todos 跑 6 趟 filter + 1 次 sort，其中 `completedUnscheduledTodos` 那趟带 per-item `DayClock.isSameUserDay`（`Calendar` 桥接，有实际开销） |
| ②b | `UI/Home/HomeView.swift:847-853` | 每次 header 渲染 | `selectedDayStats()` 的 `completedUnscheduledToday` 那趟全量 filter **在缓存命中分支之外**（:827 的 `if let cached` 只覆盖前半段），所以快路径也照跑，且带 per-item `Calendar` 运算 |
| ③ | `Store/TodoStore.swift:627-642` | 每次进前台 | `refreshTodos()` 无谓词、无 `fetchLimit` 的全表 fetch，接一个 N × `toData()`。`toData()`（`SwiftDataModels.swift:153-178`）里 `recurrenceRule` 要重解 weekday 字符串（split + compactMap + Set + sort），`reminderTimes` 在 `reminderTimesRaw != nil` 时**每条新建一个 `JSONDecoder`**。全程 `@MainActor` |
| ③b | `App/VoiceTodoApp.swift:335` | 每次进前台 | `refreshStoreIfNeededFromExternalChanges(force: true)` —— `force: true` 把 `refreshIfStale` 的 `lastSyncedExternalChangeVersion` 门闩（`TodoStore.swift:30, 637, 650`）整个架空了。这个门闩的设计意图就是「外部无变更就跳过」，结果唯一的生产调用方绕过了它。用户只是划开通知中心再回来，也要付一次全表 fetch |
| ④ | `UI/Review/ReviewView.swift:66-79` | 打开回顾时 | 三个 `@Query`，其中 `allTodos` 是**完全不过滤的全表 `[TodoItem]`**，拉进来只为建一张 `UUID → TodoCategory` 映射（:135）。日期过滤全在 Swift 侧做（`ReviewAggregator.swift:80-83`），SQL 层无任何日期谓词。且 `summary` 是 computed property（:147），被 `dailyTrendData` / `pastZeroDays` / `xAxisDates` / `categoryChartData` 各调一次 → 同一份聚合算 4 遍 |
| ⑤ | `Store/TodoStore.swift:44-46` | **每次冷启动** | 三个 migration 无「已执行」标记。`purgeLegacyVoiceCaptureRecords`（:691-705）全表拉 `VoiceCaptureRecord` 只为发现它是空的；`migrateOldSortOrder`（:708-729）全表拉 `TodoItem` 只为判 `allSatisfy { $0.sortOrder == 0 }` |
| ⑥ | `Store/SwiftDataModels.swift` | — | `TodoItem` 上**零索引**，唯一的 `@Attribute` 是 `.unique var id`（:9）。热查询排序/过滤用的 `sortOrder` / `isCompleted` / `completedAt` / `dueDate` / `needsAIProcessing` 全裸奔 |

### 一句话总结

①②②b 是**每帧 O(N)**，③③b 是**每次进前台 O(N)**，④ 是**打开回顾 O(全表)**，
⑤ 是**每次冷启动 O(全表)**，⑥ 让上面每一项都比应有的更慢。

---

## 3. 实施步骤

六步，建议**分步提交**，每步可独立回滚。

### Step 1 —— 给 SwiftData 模型加索引

**文件**：`Store/SwiftDataModels.swift`

部署目标是 iOS 26（`project.yml:4-5`），`#Index` 宏（iOS 18+）可用。

在 `TodoItem`（:5-243）类体内加：

```swift
#Index<TodoItem>([\.sortOrder], [\.isCompleted], [\.completedAt], [\.dueDate], [\.needsAIProcessing])
```

在 `TodoOccurrenceCompletion`（:407-433）类体内加：

```swift
#Index<TodoOccurrenceCompletion>([\.completedAt], [\.occurrenceDate], [\.todoId])
```

**为什么安全**：纯 additive，走 SwiftData 轻量迁移，不需要 `VersionedSchema` /
`SchemaMigrationPlan` —— 与 `SwiftDataModels.swift:40-47` 已记录的迁移约定完全一致。
`VoiceTodoSchema.schema`（:533-540）注册的仍是同一批类，无需改动；主 App
（`App/VoiceTodoApp.swift:65-142`）和 Widget / AppIntent
（`Store/AppGroupModelContainerProvider.swift:40-49`）从同一个 schema 字面量建容器，自动同步。

**验证点**：`#Index` 首次打开旧库会触发一次索引构建。确认（a）冷启动无异常，
（b）Widget 侧的 `readOnly()` 容器仍能正常打开旧库——只读容器遇到需要写索引的迁移时可能失败，
这是本步唯一的真实风险，必须在模拟器上用**已有数据的旧库**实测，不能只用空库验证。

---

### Step 2 —— `refreshTodos()` 窗口化

**文件**：`Store/TodoStore.swift:627-642`、`App/VoiceTodoApp.swift:335`

只加载「工作集」= 全部未完成 + 最近 N 天已完成。N 取 90，定义为常量：

```swift
/// 内存工作集里保留的已完成项时间窗（天）。
/// 窗口外的已完成项仍在库里，由 TodoQueryActor 按需查询（见 Step 3）。
static let completedWindowDays = 90
```

改写为两次谓词 fetch 再归并：

```swift
func refreshTodos() {
    let startedAt = Date()
    let cutoff = DayClock.startOfUserDay(for: Date())
        .addingTimeInterval(-Double(Self.completedWindowDays) * 86_400)

    let pending = FetchDescriptor<TodoItem>(
        predicate: #Predicate { !$0.isCompleted },
        sortBy: [SortDescriptor(\.sortOrder, order: .forward)]
    )
    let recentDone = FetchDescriptor<TodoItem>(
        predicate: #Predicate { $0.isCompleted && ($0.completedAt ?? .distantPast) >= cutoff },
        sortBy: [SortDescriptor(\.sortOrder, order: .forward)]
    )

    do {
        let items = try modelContext.fetch(pending) + modelContext.fetch(recentDone)
        // 两批各自有序，合并后按 sortOrder 重排，保持与原实现一致的全局顺序
        todos = items.sorted { $0.sortOrder < $1.sortOrder }.map { $0.toData() }
        lastSyncedExternalChangeVersion = AppGroupConfig.currentExternalChangeVersion()
        VoiceTodoLog.store.debug("store.refresh.success count=\(self.todos.count) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
    } catch {
        VoiceTodoLog.store.error("store.refresh.failed durationMS=\(VoiceTodoLog.durationMS(since: startedAt)) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
    }
}
```

**为什么拆两次 fetch 而不是写一个带 `||` 的复合谓词**：让 SQLite 各自命中 `isCompleted` /
`completedAt` 索引。复合 `OR` 谓词通常退化成全表扫描，白费 Step 1。

**`#Predicate` 兜底写法**：`#Predicate` 对 `Date?` 的 `??` 支持在 SwiftData 上并非无条件成立。
先按上面写法编译；不通过就依次降级，三种写法语义等价，任选可编译的一种：

```swift
// 兜底 1
$0.isCompleted && $0.completedAt != nil && $0.completedAt! >= cutoff
// 兜底 2（把常量提到闭包外，避免宏内构造 Date）
let floor = Date.distantPast
... $0.isCompleted && ($0.completedAt ?? floor) >= cutoff
```

**同时修 `force: true`**：`App/VoiceTodoApp.swift:335` 的
`refreshStoreIfNeededFromExternalChanges(force: true)` 改成 `force: false`，让
`refreshIfStale`（`TodoStore.swift:648-657`）的版本号门闩真正生效。Widget / AppIntent 写回时会调
`AppGroupConfig.markExternalDataChanged()` 推进版本号（`Store/AppGroupConfig.swift:34-40`），
不会漏刷。

#### 影响面核查清单（必须逐条确认）

| 消费方 | 是否受窗口影响 | 处理 |
|---|---|---|
| 月网格 occurrence（`HomeView.swift:1464` → `TodoStore.calendarOccurrences` → `TodoQueryActor.swift:86-135`） | **否** —— actor 内自行 fetch，不依赖 `store.todos` | 无需改动 |
| `unscheduledTodos` / `pendingDateTodos` / `unparsedTodos`（`HomeCalendarState.swift:164-173`） | **否** —— 全部带 `!$0.isCompleted` 条件 | 无需改动 |
| `completedUnscheduledTodos`（`HomeCalendarState.swift:183-188`） | **是** | Step 3 接管 |
| `selectedDayStats()` 的 `completedUnscheduledToday`（`HomeView.swift:847-853`） | **是** | Step 3 接管 |
| `hasTodos`（`HomeCalendarState.swift:189`）与 `calendarLoadState` 的 `store.todos.isEmpty` 判定（`HomeView.swift:1459, 1474`） | **边缘** —— 只有「库里全是窗口外的已完成项」时会误判为空态 | 实测确认；若需要，改用 `todos.isEmpty && !hasAnyCompleted` 之类的判据，或接受此边缘行为并在代码注释里写明 |
| `AppCoordinator.swift:613/670/761/799`、`CalendarSyncService.swift:170` 的 `.first(where:)` / `.filter` | **需逐个核对** | 若某处可能命中窗口外的已完成项，改走 `TodoStore.findTodoItem`（`TodoStore.swift:770-773`，已带 `fetchLimit = 1`）单条查库 |
| `App/TodoNotificationSync.swift:17-35`（订阅 `$todos` 重排通知） | **否** —— 只给未完成项排提醒 | 无需改动；且工作集变小后这条路径顺带变快 |

---

### Step 3 —— 窗口外「已完成」按需查询

这是**保证功能零缩水**的关键一步：日历翻回半年前的某一天，那天的「已完成」分区必须照常显示。

#### 3a. `Store/TodoQueryActor.swift` 新增只读查询

沿用该文件既有的不变式（见文件头注释：只读、绝不写库、跨 actor 只返回值类型 DTO）：

```swift
/// 区间内完成的「无安排」任务（dueDate == nil && recurrenceRule == nil），按 completedAt 倒序。
/// - Note: 供首页「已完成」分区按需加载窗口外的历史数据，口径与
///   `HomeCalendarState.completedUnscheduledTodos` 严格一致。
func completedUnscheduled(from startDate: Date, to endDate: Date) throws -> [TodoItemData]
```

实现要点：
- 谓词 `isCompleted && completedAt >= startDate && completedAt < endDate`（命中 Step 1 的
  `completedAt` 索引）
- Swift 侧再滤 `dueDate == nil && recurrenceRule == nil`，按 `completedAt` 倒序
- 错误处理照抄同文件既有写法：`throw VoiceTodoError.wrapStorage(error, for: .read)` +
  `VoiceTodoLog.store.error` 打点，**不要静默吞成空数组**

#### 3b. 沿调用链透传（四处）

| 文件 | 改动 |
|---|---|
| `Store/TodoStore.swift` | 加 `async` 透传方法，照抄 `calendarOccurrences`（:355-357）的写法 |
| `Protocols/TodoStoreProtocol.swift`（:114 附近） | 加协议方法声明 |
| `UI/MockStore.swift`（:152 附近） | 加 stub |
| `VoiceTodoTests/Integration/PendingRecoveryFlowTests.swift`（:336 附近） | 加 stub |

#### 3c. `UI/Home/HomeView.swift` 按月加载

加 `@State private var completedUnscheduledByDay: [String: [TodoItemData]] = [:]`。

在 `:1451` **已有的那个 `.task`** 里，跟 `groupedCalendarOccurrences` 一起加载——
**一次覆盖整月的范围查询，不是每天一次**。key 用
`TodoOccurrenceData.dayKey(for:calendar:)`，与 `monthOccurrences` 同一套 key 生成逻辑。

按天分桶时必须用 `DayClock` 的用户日口径（`DayClock.userDayStart(onNaturalDay:calendar:)` +
`DayClock.isSameUserDay`），与 `HomeCalendarState.swift:182-187` 现有实现逐字对齐——
`VoiceTodoDayStartHour > 0` 时凌晨完成的任务要归到前一用户日。

#### 3d. `UI/Home/HomeCalendarState.swift` 改为查表

`make(store:...)`（:64-85）和 `makeForTests`（:89-110）增加 `completedUnscheduledByDay` 参数，
构造器里：

```swift
let dayKey = TodoOccurrenceData.dayKey(for: selectedDate, calendar: calendar)
self.completedUnscheduledTodos = completedUnscheduledByDay[dayKey] ?? []
```

取代 :183-188 的 filter + sort。

> **这一步同时消掉了 ② 里最贵的那趟**（带 `Calendar` 运算的 filter + sort），
> 是性能与正确性双赢——数据源从「在全量数组里捞」变成「按天直接取」。

#### 3e. `selectedDayStats()` 改 O(1)

`UI/Home/HomeView.swift:847-853` 的 `completedUnscheduledToday` 改成：

```swift
let completedUnscheduledToday = completedUnscheduledByDay[dayKey]?.count ?? 0
```

原代码注释里强调的「口径与 `HomeCalendarState.completedUnscheduledTodos` 同源」这条约束反而更强了
——现在字面上就是同一份数据，不再是两处各自维护的等价判断。

---

### Step 4 —— 渲染层 O(N) 消除

#### 4a. `CalendarRefreshKey` 去掉整数组（最高性价比）

`UI/Home/HomeCalendarState.swift:347-351` 改为：

```swift
struct CalendarRefreshKey: Hashable {
    let anchor: Date
    let todosRevision: Int
    let revision: Int
}
```

`Store/TodoStore.swift` 里给 `@Published var todos`（:27）加 `didSet`，并新增一个已发布的计数器：

```swift
@Published var todos: [TodoItemData] = [] {
    didSet { todosRevision &+= 1 }
}
/// todos 的变更代数。给 SwiftUI 当 task/onChange 的 id 用，
/// 避免拿整个 [TodoItemData] 做 Hashable（合成 hash 会遍历 rawTranscript 等全部字符串字段）。
@Published private(set) var todosRevision: Int = 0
```

一处 `didSet` 覆盖全部 11 条变更路径：`refreshTodos`（:635）、`add`（:64）、`addBatch`（:110）、
`addImportedBatch`（:142）、`addRawTranscript`（:161）、`toggleComplete`（:184-186）、
`delete`（:205）、`updateFull`（:248-250）、`updateRecurrence`（:343-345）、
`updateSystemCalendarEventIdentifier`（:569-571）、`replacePendingBatchWithExtracted`（:498-500）。

`UI/Home/HomeView.swift:1451` 相应改为传 `store.todosRevision`。

语义等价（内容变 → revision 变 → task 重跑），但从「深 hash 全部字符串 + 拷整数组」降到「比一个 Int」。

> 注意：`&+=` 用溢出加法，避免理论上的 `Int` 溢出崩溃。

#### 4b. `HomeCalendarState` 记忆化

`UI/Home/HomeView.swift:1150-1157` 的 `let state = HomeCalendarState.make(...)` 从 computed
property 里提出来，改成 `@State private var calendarState: HomeCalendarState?`，由 `.task(id:)`
用 `(selectedDate, visibleMonthAnchor, store.todosRevision, occurrenceRevision, monthOccurrences.count)`
组成的 key 驱动重建。

这样折叠拖拽时 `collapseProgress` 变化不再触发全量重算——这正是 `:1158-1160` 那段注释
（「避免 60fps 跟手时每帧重做 42 次 `isDate(inSameDayAs:)`」）已经在别处处理过的同一类问题。

**可独立回滚**：若引入的一帧延迟在视觉上不可接受，退回「保留 computed property」，
依赖 Step 2/3 把 N 和每趟的单价都降下来即可，仍有显著收益。

#### 4c. 明确「不做」的两处

以下两处看起来像 O(N²) / O(N)，但**不要改**：

1. **`UI/Home/HomeSelectedDayListView.swift:72-73`** 的每行 `firstIndex(where:)`。
   :68-71 已有注释说明：不能用 `enumerated()`，因为 `.onMove` 要求 `ForEach` 直接对
   `Identifiable` 集合迭代，元组数组会破坏 List 内置的 reorder 手势识别。而且
   `unscheduledTodos` 全是**未完成**项，不随完成数增长，注释里「通常 < 20 项」的前提依然成立。

2. **`HomeView.swift:39/48/893/2096/2134/2180/2230/2298` 等 8 处 `store.todos.first(where:)`**。
   这些是点击 / sheet 打开等**事件响应**路径，不是每帧路径，单次 O(N) 完全可接受。
   为它们建 id→todo 字典要在 `didSet` 里 O(N) 重建，反而是净亏。

---

### Step 5 —— 回顾统计改范围查询

**文件**：`Store/TodoQueryActor.swift`、`UI/Review/ReviewView.swift`

#### 5a. `TodoQueryActor` 新增两个只读查询

```swift
/// 区间内的完成事件（TodoItem 与 TodoOccurrenceCompletion 两个来源的并集）。
func completionEvents(from startDate: Date, to endDate: Date) throws -> [CompletionEvent]

/// 完成率所需的两个分母计数。用 fetchCount 走 SQL COUNT，不 materialize 任何行。
func dueCounts(rangeStart: Date, todayEnd: Date, upcomingEnd: Date) throws -> (dueByToday: Int, upcomingIn7Days: Int)
```

`completionEvents` 实现要点：
1. fetch `TodoItem` where `isCompleted && completedAt` 在区间内 → 映射成 `CompletionEvent`
2. fetch `TodoOccurrenceCompletion` where `completedAt` 在区间内
3. **只对第 2 批的 `todoId` 集合**做一次 `#Predicate { ids.contains($0.id) }` 批量查询取
   `category` —— 取代 `ReviewView.swift:135` 那张从全表 `allTodos` 建的映射。这是本步的主要收益：
   分类查表的成本从「全库条数」降到「窗口内规律任务完成数」

`dueCounts` 用 `modelContext.fetchCount(_:)`，取代 `ReviewView.swift:155-170` 的两趟全量
`filter{}.count`。

> #### ⚠️ 边界安全铁律
>
> SQL 谓词的时间范围必须比 `ReviewAggregator` 的目标窗口**两端各放宽 1 天**。
>
> 原因：`DayClock` 的用户日起点小时可配置（App Group `UserDefaults` 键 `VoiceTodoDayStartHour`，
> 见 `Protocols/Domain/DayClock.swift:83-106`）。谓词按绝对时刻切，会削掉边界那天的事件。
>
> 精确过滤仍由 `ReviewAggregator.swift:80-83` 现有的 in-range filter 完成——
> **`Protocols/Domain/ReviewAggregator.swift` 一行都不要改**。它本来就是无 SwiftData 依赖的纯函数，
> 现有测试继续有效，正好当这次改动的回归基准。

#### 5b. `ReviewView` 去掉三个 `@Query`

删掉 `:66-79` 的 `completedTodos` / `recurringCompletions` / `allTodos`，改为：

```swift
@State private var summary: ReviewSummary?
```

由 `.task(id: selectedPeriod)` 异步加载。`summary` 从 computed（:147）变成 stored，
顺带修掉「被 `dailyTrendData` / `pastZeroDays` / `xAxisDates` / `categoryChartData`
各重算一次」的问题。

加载态 / 空态复用现有的 `review.empty.message` 文案与 `UI/Shared/EmptyStateView.swift`。

---

### Step 6 —— 启动 migration 加「已执行」门闩

**文件**：`Store/AppGroupConfig.swift`、`Store/TodoStore.swift:44-46`

在 `AppGroupConfig` 里加版本键（与既有的 `externalChangeVersionKey` / `currentExternalChangeVersion()`
同处，:8-31）：

```swift
static let storeMigrationVersionKey = "VoiceTodoStoreMigrationVersion"
static func currentStoreMigrationVersion() -> Int
static func markStoreMigrationCompleted(version: Int)
```

`TodoStore.init`（:36-49）改为：

```swift
if AppGroupConfig.currentStoreMigrationVersion() < Self.currentMigrationVersion {
    purgeLegacyVoiceCaptureRecords()
    migrateOldSortOrder()
    migrateDueDatesFromHints()
    AppGroupConfig.markStoreMigrationCompleted(version: Self.currentMigrationVersion)
}
refreshTodos()
```

**三个 migration 都可以安全上门闩**，依据：

| Migration | 行号 | 为什么是一次性的 |
|---|---|---|
| `purgeLegacyVoiceCaptureRecords` | :691-705 | `VoiceCaptureRecord` 是废弃模型，新代码从不创建（`SwiftDataModels.swift:437-440` 注释已写明），清一次就永远为空 |
| `migrateOldSortOrder` | :708-729 | 只在 `items.allSatisfy { $0.sortOrder == 0 }` 时才动手；一旦分配过就永远不满足条件 |
| `migrateDueDatesFromHints` | :732-764 | 新条目的创建路径 `TodoItem.from`（`SwiftDataModels.swift:269`）**已经**调 `TodoDueDateResolver.resolve` 补 `dueDate`，所以它不是新条目的兜底网。且 `resolve(referenceDate: item.createdAt)` 是确定性的——解不出来的条目再跑一万次也解不出来 |

> 实施时请**复核最后一条**：确认 `TodoItem.from` 的 resolve 覆盖了所有创建入口
> （`add` / `addBatch` / `addImportedBatch` / `addRawTranscript` / `replacePendingBatchWithExtracted`）。
> 若发现某条入口绕过了 resolver，就把 `migrateDueDatesFromHints` **排除在门闩之外**——
> 它已有谓词过滤（`dueDate == nil && dueHint != nil`），Step 1 的 `dueDate` 索引会让它很便宜。

---

## 4. 验收标准

### 构建

```bash
./prepare_xcode_project.sh          # xcodegen 重新生成工程
xcodebuild -project VoiceTodo.xcodeproj -scheme VoiceTodo \
  -destination 'platform=iOS Simulator,name=iPhone 16' build
swift test                          # Protocols 包的纯逻辑测试
```

### 现有测试回归（重点）

| 测试文件 | 关注点 |
|---|---|
| `VoiceTodoTests/Store/StoreTests.swift` | 6 处 `refreshTodos()` 断言（:122 / :138 / :165 / :183 / :201 / :219）——**逐个检查是否隐含「所有已完成项都在 `todos` 里」的假设**。窗口化后需要相应调整断言，或给种子数据补上近期的 `completedAt` |
| `VoiceTodoTests/UI/HomeCalendarStateGroupingTests.swift` | `makeForTests` 签名变了，需要传新参数 |
| `VoiceTodoTests/Protocols/DayClockTests.swift`、`DayStartHourBoundaryTests.swift` | 验证 Step 5 的边界放宽没有破坏用户日口径 |
| `VoiceTodoTests/Integration/*` | `TodoStoreProtocol` 加方法后，所有 mock 都要补 stub |

### 新增测试

1. **窗口边界**：完成于 89 天前的项在 `store.todos` 里；91 天前的**不在**，但通过
   `TodoQueryActor.completedUnscheduled` 能查到
2. **统计等价性**：造一批跨越窗口的完成数据，断言新的 `completionEvents` + `ReviewAggregator`
   产出的 `ReviewSummary` 与「全量拉取再聚合」的旧口径**逐字段相等**。
   **必须包含 `VoiceTodoDayStartHour > 0` 的场景**，覆盖 Step 5 的边界放宽逻辑
3. **`dueCounts`**：`fetchCount` 结果与旧的 `allTodos.filter{}.count` 相等
4. **migration 门闩**：连跑两次 `TodoStore.init`，第二次不产生任何写操作
5. **按需查询口径**：`completedUnscheduled` 返回的分桶结果与旧的
   `HomeCalendarState` filter 逻辑在同一批数据上完全一致（含 `startHour > 0`）

### 手动验证（模拟器）

1. 用 `seedForUITests`（`TodoStore.swift:528-556`）或临时调试入口灌 **2000+ 条，其中 1500 条完成于半年前**
2. **冷启动** → Home 首屏出现时间；日历折叠拖拽是否掉帧
   （Instruments Time Profiler 看主线程还有没有 `Hashable` / `filter` 热点）
3. **切后台再切回前台** → 看 `store.refresh.success` 日志的 `durationMS` 和 `count`，应显著下降；
   且「没有外部变更时」应该看到 `store.refresh_if_stale.skip` 而不是真的刷新
4. **日历翻回半年前的某一天 → 「已完成」分区必须正常显示。**
   这是本方案「不删数据」的核心承诺，是最关键的一条验收项
5. **打开「回顾」** → 周/月两档的所有数值（总数 / 连续天数 / 完成率 / 分类占比 / 每日趋势 /
   最忙一天）与改动前**完全一致**；把 `VoiceTodoDayStartHour` 调成非 0 再验一遍边界那天

---

## 5. 给执行者的约束

1. **不得删除任何 `TodoItem` / `TodoOccurrenceCompletion` 数据。** 本方案的全部前提就是历史完成项
   一条不少地留在库里。任何形式的 purge / 归档 / 软删都不在范围内
2. **不得改动 `Protocols/Domain/ReviewAggregator.swift` 的聚合口径。** 它是纯函数、有测试覆盖，
   是这次改动的回归基准。只改「喂给它什么数据」，不改「它怎么算」
3. **分步提交**，六步各一个 commit，便于二分定位回归
4. 遇到 `#Predicate` 编译不过时，**按 Step 2 给出的兜底写法降级，不要改变查询语义**
   （比如不要偷偷把「近 90 天已完成」放宽成「全部已完成」）
5. Step 4b（`HomeCalendarState` 记忆化）如果引入视觉延迟，**单独回滚这一步**即可，
   不影响其余五步的收益
6. 每一步都要跑一遍现有测试，不要攒到最后一起跑
