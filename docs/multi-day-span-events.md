# 跨天事件（multi-day span）支持 —— v1 数据层 + 显示

> 状态：**待实施**。文档创建于 2026-08-08。
> 行号基准：`c71c73c`（当前分支 `claude/multi-day-event-assessment-bf9x5r` HEAD）。
> 实施后请在此处补「实施落地记录」节，并把状态改为「已实施」（沿用
> `docs/day-clock-day-boundary-inconsistencies.md` / `docs/month-grid-known-issues.md` 的体例）。
> 相关文件：`Store/SwiftDataModels.swift`、`Store/TodoQueryActor.swift`、
> `Protocols/Models.swift`、`Protocols/Domain/WidgetTodoFilter.swift`、
> `UI/Home/HomeMonthGridButton.swift`、`UI/Detail/TodoDetailView.swift`、
> `App/SystemCalendarEventImporter.swift`、`App/SystemCalendarWriter.swift`
>
> ⚠️ **实施方注意**：本文档的四条产品决策（范围 / 完成语义 / 月历显示 / 与重复互斥）
> 已经拍板，不要重新讨论或"顺手做得更完整"。超出「不在本次范围」一节的改动一律不做。

---

## Context

VoiceTodo 目前的时间模型只有**一个时间点**：`TodoItem.dueDate`（`Store/SwiftDataModels.swift:13`）。
它能表达两种场景：

1. **单次单天** —— "明天下午 3 点开会"，一个 `dueDate`。
2. **重复事件** —— "每周三和周五锻炼"，`RecurrenceRule` 在多个日期各产生一个**独立** occurrence。

它表达不了第三种：**跨天事件** —— "周五出发周日回来的出游"、"周一到周三的会议"、
"周四 22:00 到周五 02:00 的通宵"。

跨天的关键特征是**连续**：从开始到结束这段时间事件一直在进行，中间每一天都"属于"它。
这与重复事件有本质区别 —— "周三和周五锻炼"是两次独立的事，中间隔了一天。

用户目前只能：

- 拆成 3 条独立 todo（丢失"这是同一件事"的语义），或
- 建成"每天重复 3 次"（语义错误，这 3 天不是 3 个独立 occurrence，且完成语义也不对）

### 为什么现在做

这不是"未来可能有的场景"，是**现在就在丢数据的路径**。

`App/SystemCalendarEventImporter.swift:21-31` 从 iOS 日历导入事件时直接扔掉 `event.endDate`：

```swift
if event.isAllDay {
    dueDate = calendar.startOfDay(for: event.startDate)
} else {
    dueDate = event.startDate            // endDate 消失
}
```

用户 iOS 日历里的"周五到周日出游"，导进 VoiceTodo 只剩周五一天。

而 EventKit 边界的另外两侧**已经有跨天语义**：

- `App/SystemCalendarReader.swift:97-101` 在做区间 overlap 判定
  （`max(todoStart, event.startDate) < min(todoEnd, event.endDate)`）
- `App/SystemCalendarWriter.swift:18-19` 的 `CalendarEventDraft` 本来就有
  `startDate` / `endDate`，只是永远被合成（定时 = `due + 1 小时`，全天 = `startOfDay + 1 天`，
  见 `:34-46`）

也就是说跨天概念只在 `TodoItem` 这个中间层被掐断。

补充：App 尚未发布，此刻改 schema 没有存量数据负担，是成本最低的时点。

### 为什么这一版**不做**语音解析

日语上线（`docs/mvp-japanese-launch/plan.md`）还没开始：

- `Resources/Localizable.xcstrings` 里 `zh-Hans` 有 532 条，`ja` 只有 15 条
- `AIProxy/worker.js:1606` 的 `normalizeLocale` 仍把 `ja` 吞成 `en`
- `JAPANESE_SYSTEM_PROMPT` 不存在

而 AI prompt 是跨天改动里最贵、最险的一块：现有 prompt 已有一个顶层 `recurrence_end`
（**重复系列的终点**，见 `AIProxy/src/adapters/base.js:196` 规则 5b），再加一个 `end_date`
（**单个事件的跨天终点**）语义极易混淆 —— "月底前交税"这类一次性任务很可能被错标成跨天事件。
15 条 few-shot × 3 语言 + 全量提取回归，压在日语 prompt 还没写的时候做是自找麻烦。

### v1 范围（已确认，不再讨论）

| 决策 | 选择 |
|---|---|
| 范围 | 数据层 + 显示 + 手动编辑 + 系统日历导入/导出。**不动 AI prompt** |
| 完成语义 | **整体一次完成**：一个事件一个 `isCompleted`，任意一天打勾即全部完成 |
| 月历显示 | **每格一条 + 连续标记**，不做跨格连续横条 |
| 跨天 + 重复 | **v1 互斥**，设了一个就禁用另一个 |

预期产出：语音说"周五到周日出游"仍按单天处理（不回归、不阻塞日语）；但数据模型一次定死，
详情页可手动设结束日期，iOS 日历导入不再丢区间，月历 / 当日列表 / Widget 三处显示都正确。

---

## 核心设计

### 字段命名与语义

在 `TodoItem` 上新增：

```swift
/// 跨天事件的**闭区间**结束时刻。nil = 单天事件（绝大多数）。
/// 命名避开 endDate：本类已有 recurrenceEndDate（重复系列的终点），
/// RecurrenceRule 也有 endDate —— 三者语义完全不同，必须靠名字区分。
/// 覆盖天数 = [startOfDay(dueDate) ... startOfDay(eventEndDate)]。
/// 因此"周四 22:00 → 周五 02:00 通宵"天然覆盖周四 + 周五两天。
/// 带 Optional → SwiftData 轻量迁移，与 hasDueTime / extractionOutcomeRaw 同模式。
var eventEndDate: Date?
```

**不变式**（在写入侧统一归一化，见「实施步骤 1」的 `TodoSpan.normalized`）：

- `dueDate == nil` ⇒ `eventEndDate = nil`
- `recurrenceRule != nil` ⇒ `eventEndDate = nil`（v1 互斥）
- `startOfDay(eventEndDate) <= startOfDay(dueDate)` ⇒ `eventEndDate = nil`（退化为单天）
- 跨度上限 366 天（保护内存展开循环，越界则截断）

### 迁移

**不需要 `VersionedSchema` / `SchemaMigrationPlan`** —— 项目里根本没有迁移计划文件，
约定写在 `SwiftDataModels.swift:44-46`：新增带默认值 / Optional 的 stored property
走 SwiftData 轻量迁移即可（`hasDueTime`、`extractionOutcomeRaw`、`sourceRaw` 都是这么加的）。

`VoiceTodoSchema.schema`（`SwiftDataModels.swift:533-540`）注册的仍是同一个 `TodoItem` 类，
**无需改动**。

### 展开点

`Store/TodoQueryActor.swift:114-122` 的非重复分支是**唯一**把 todo 变成 per-day occurrence
的地方（recurring 分支不动，v1 互斥）。改成区间裁剪循环即可。

注意该 actor 本来就是全量 fetch 后内存过滤（`:92-96`，`dueDate` 上没有任何 `#Predicate`），
所以 DB 层零额外成本。

---

## 实施步骤

### 1. 新建纯函数 `Protocols/Domain/TodoSpan.swift`

跨天的日期计算全部收在这一个无依赖的 enum 里，供 store / widget / UI 共用，
风格对齐已有的 `Protocols/Domain/TodoDueDateShifter.swift` 与
`RecurrenceRule.occurs(on:startDate:calendar:)`。

```swift
enum TodoSpan {
    static let maxSpanDays = 366

    /// 事件覆盖的自然日序列（含两端）。非跨天返回 [startOfDay(dueDate)]。
    static func coveredDays(dueDate: Date, eventEndDate: Date?, calendar: Calendar) -> [Date]

    /// 某一天是否落在事件区间内（widget / 快速判定用，不建数组）。
    static func covers(day: Date, dueDate: Date, eventEndDate: Date?, calendar: Calendar) -> Bool

    /// 归一化：返回应当持久化的 eventEndDate（应用上面全部不变式）。
    static func normalized(eventEndDate: Date?, dueDate: Date?, hasRecurrence: Bool, calendar: Calendar) -> Date?

    /// 平移：dueDate 变化时保持跨度不变，返回新的 eventEndDate。
    static func shiftedEnd(originalDue: Date, originalEnd: Date?, newDue: Date, calendar: Calendar) -> Date?
}
```

**日口径用自然日 `calendar.startOfDay`，不用 `DayClock`** —— 与 `daysBetween`
（`TodoQueryActor.swift:138-149`）、`RecurrenceRule.occurs(on:)`、
`TodoOccurrenceData.dayKey`（`Protocols/Models.swift:114-117`）全部一致。

已知代价：用户日起点设为非 0 时，"通宵到次日 02:00"仍会渲染在次日。这与现有 occurrence
路径的口径一致，属于同一类已知限制，**本次不扩大战线去改**
（该问题类别的历史记录见 `docs/day-clock-day-boundary-inconsistencies.md`）。

### 2. 模型与 DTO 加字段

按 `hasDueTime` 的既有模式逐个补：

- **`Store/SwiftDataModels.swift`**：`TodoItem` 新 stored property + `init` 参数 +
  `toData()`（`:153`）+ `from(_ data:)`（`:307`）。
  `from(_ extracted:)`（`:253`）**不传** —— AI 不产出跨天，v1 保持不变。
- **`Protocols/Models.swift`**：
  - `TodoItemData`（`:467`）加 `eventEndDate`。
  - `TodoDetailUpdate`（`:428`）加 `eventEndDate`，在 `init` 里调
    `TodoSpan.normalized(...)`（和现有 `hasDueTime` / `timeBucket` 归一化放在一处）。
    **不给默认值** —— 让编译器强制审计所有调用点。
    文档注释（`:417-427`）补一行：`eventEndDate`：nil = 清除跨天区间。
  - `TodoOccurrenceData`（`:98`）加 span 位置元数据：

    ```swift
    let spanIndex: Int      // 0-based；单天恒 0
    let spanCount: Int      // 单天恒 1
    var isSpanning: Bool  { spanCount > 1 }
    var isSpanStart: Bool { spanIndex == 0 }
    var isSpanEnd: Bool   { spanIndex == spanCount - 1 }
    ```

    必须写显式 `init` 并给这两个参数默认值 `0` / `1`，否则现有构造点会编译失败：
    `UI/MockStore.swift:171,178`、`VoiceTodoTests/UI/HomeCalendarStateGroupingTests.swift:423`。
    `id`（`todoId-dayKey`，`:103-105`）语义不变，仍然每天唯一。
- **其余镜像**：`App/Intents/TodoEntity.swift`、`UI/MockStore.swift`、
  `TodoStore.seedForUITests`（`Store/TodoStore.swift:528-545`）。

### 3. 展开逻辑

- **`Store/TodoQueryActor.swift:114-122`** → 用 `TodoSpan.coveredDays` 展开，
  与查询窗口 `days` 求交，逐日 append 并带上 `spanIndex` / `spanCount`。
  ⚠️ `spanCount` 是**事件总天数**，不是窗口内天数 —— 跨月时"第 2/4 天"才不会算错。
  `isCompleted` 每天都取 `todo.isCompleted`（整体完成语义）。
- **`Protocols/Domain/WidgetTodoFilter.swift:54`** 的
  `calendar.isDate(data.dueDate ?? day, inSameDayAs: day)` → `TodoSpan.covers(...)`。

### 4. 完成语义 —— 基本无需改动

`Store/TodoStore.swift:373-403` 的 `toggleOccurrenceComplete(_:on:)` 已经在
`recurrenceRule == nil` 时短路到整条 `toggleComplete(id)`（`:374-377`）。
跨天事件（v1 与重复互斥）天然走这条路，**不写 `TodoOccurrenceCompletion` 记录**，
任意一天打勾三天同时变灰。

- `App/Intents/ToggleTodoIntent.swift:107-135` 同构，同样不用改。
- `Protocols/Domain/ReviewAggregator.swift` 基于 `completedAt` 事件流聚合，
  一个事件一条，整体完成语义下天然正确，**不用改**。

**唯一需要补的一处**：`UI/Home/HomeView.swift:823-840` 的 `selectedDayStats()`
同步兜底路径只按 `dueDate` 命中当天计数，跨天事件的中间日会漏计 —— 补上 `TodoSpan.covers`。

### 5. 显示

- **月网格** `UI/Home/HomeMonthGridButton.swift:173-215` 的
  `eventBar(_:isLast:overflow:)`：
  - 钟点前缀（`:183-188`）只在 `occurrence.isSpanStart` 时显示。
  - 非起始日在标题前加连续标记（`"↳ "` 或 `"→ "`），末日可用不同标记。
  - 改动**严格限制在这个函数内**，不碰 `HomeMonthHeaderView.allocateRowHeights`
    —— 该分配器刚修完两个高度分配 bug（见 `docs/month-grid-known-issues.md`），
    条数 / 行高不变量不要在本次改动里动。
- **当日列表** `UI/Home/WarmTodoCard.swift`：目前只收 `todo: TodoItemData`
  （见 `:110`、`:165`），需要把 span 位置传进来 —— 新增一个带默认值的参数，
  与已有的 `showsInlineTimePrefix` / `showsTimeBucketMetadata` 同风格。
  非起始日不显示钟点 chip，改显示"第 N/M 天"标记。
  文案走 `Resources/Localizable.xcstrings`，不要硬编码。
- **分层归组** `UI/Home/HomeCalendarState.swift:236-281` 的
  `tieredUncompletedOccurrences`：跨天事件的**非起始日**按「整天」层归组
  （它们没有有意义的钟点）；起始日仍按 `hasDueTime` / `timeBucket` 原规则归。

### 6. 编辑入口（只在详情页）

`UI/Detail/TodoDetailView.swift`：在日期区（`:217-262`）下面加一个「结束日期」行，
**结构照抄 `recurrenceEndDateEditor`（`:503-511+`）**：Toggle 控制"单天 / 跨天"，
on 时显示 `TodoDatePopoverTrigger`（`UI/Shared/TodoFieldEditors.swift:389`
—— 该组件已被「重复结束日期」复用过，直接可用）。

- 显示条件：`editedDueDate != nil && editedRecurrenceFrequency == nil`。
- 互斥：结束日期非空时禁用重复卡片（`:496` 附近），反之亦然，并给出一行说明文案。
- ⚠️ **`TodoDatePopoverTrigger` 的 a11y identifier 是硬编码的
  `"DetailDatePopoverTrigger"`（`TodoFieldEditors.swift:439`）** —— 同屏出现第三个实例
  会让 UI 测试定位歧义。给该组件补一个 `accessibilityIdentifier` 参数
  （默认值保持原字符串，零回归），新入口传 `"DetailEndDatePopoverTrigger"`。

`UI/ConfirmSheet/TodoDraftEditorPanel.swift` **本次不加** —— AI 不产出跨天，
确认页加入口价值低、改动面积大。

### 7. 「移到明天」平移

`UI/Home/HomeView.swift:2229` 的 `moveTodoToTomorrow`：

`TodoDueDateShifter.nextDay` 只算新 `dueDate`（`Protocols/Domain/TodoDueDateShifter.swift:26`，
锚点是 `baseDate` 而非原 `dueDate`）。新增
`TodoSpan.shiftedEnd(originalDue:originalEnd:newDue:)` 保持跨度不变，
把结果一起塞进 `TodoDetailUpdate`。

（该函数的注释契约"非 nil 字段显式重传"就是为这种情况写的，见 `:2225-2228`。）

### 8. 系统日历双向

- **导入** `App/SystemCalendarEventImporter.swift:21-31`：不再丢 `event.endDate`。

  ⚠️ 全天 `EKEvent` 的 `endDate` 是**次日 00:00（开区间）** —— 这一点
  `App/SystemCalendarReader.swift:97-98` 的注释已经写明。必须转成闭区间
  （减 1 天 / 减 1 秒后取 `startOfDay`），否则每个全天事件都会凭空多覆盖一天。

  仅当换算后跨越了不同的自然日才写 `eventEndDate`，否则保持 nil。
- **导出** `App/SystemCalendarWriter.swift:34-46`：`eventEndDate != nil` 时用真实区间；
  全天事件写回 EventKit 时再转回开区间（`startOfDay(end) + 1 day`）。
  单天路径（1 小时 / 1 天合成）完全不变。

### 9. 文案

`Resources/Localizable.xcstrings` 新增 key（`zh-Hans` + `en`；`ja` 缺失会回退英文，
与当前 532 条里 ja 只有 15 条的现状一致，不新增额外债务）：

- `detail.end_date`
- `detail.add_end_date`
- `detail.span_recurrence_exclusive`（互斥说明）
- `span.day_progress_format`（"第 %1$d/%2$d 天"）

按项目 CLAUDE.md 的文本布局硬性要求，新标签要在 AX5 字号 + 中 / 英长文本下检查截断
（`lineLimit` + `minimumScaleFactor` + `fixedSize` + `ViewThatFits`）。

### 10. 新文件登记

`Protocols/Domain/TodoSpan.swift` 走 XcodeGen 的目录级 `sources`
（`project.yml:27+` 按目录声明），**无需改 `project.yml`**；
但 `.xcode_main_app_files.txt` / `.xcode_unit_test_files.txt` 是逐文件清单，
需要把新增的源文件与测试文件补进去。

---

## 明确不在本次范围

- **AI 语音解析跨天**（proxy JSON schema 加 `end_date` + 15 条 few-shot × 3 语言 +
  与 `recurrence_end` 消歧 + 全量提取回归）→ **等日语上线之后单独做**。
- 跨天 + 重复的组合（"每周五到周日值班"）。
- 月历真正的跨格连续横条（需要 overlay 层 + 重写
  `HomeMonthHeaderView.allocateRowHeights`）。
- 跨天事件在中间日发通知（`Protocols/Domain/NotificationPlanner.swift:44-60`
  仍只在起始日按 `hasDueTime` 排程）。
- ConfirmSheet 创建时设置跨天。
- 用户日起点非 0 时"通宵到次日 02:00"的归日口径。

---

## 验证

### 单元测试（新增）

- **`VoiceTodoTests/Protocols/TodoSpanTests.swift`**（纯函数，最重要）：
  单天（`eventEndDate == nil`）、两日、三日、通宵 22:00 → 次日 02:00 覆盖 2 天、
  结束早于开始退化为单天、跨度超 366 天截断、跨月 / 跨年、DST 跳变日、
  `normalized` 的四条不变式各一例、`shiftedEnd` 保持跨度。
- **`VoiceTodoTests/Store/StoreTests.swift`** 追加 `calendarOccurrences` 用例：
  - 三日事件产生 3 条 occurrence；
  - 查询窗口只覆盖中间一天时仍返回该天，且 `spanIndex == 1` / `spanCount == 3`
    （跨月场景的关键断言）；
  - span 事件打勾后三天全部 `isCompleted == true`，且**不产生**
    `TodoOccurrenceCompletion` 记录。
- **`VoiceTodoTests/WidgetTodoFilterTests.swift`**：中间日 widget 可见。
- **`VoiceTodoTests/UI/HomeCalendarStateGroupingTests.swift`**：非起始日归入「整天」层。
- **`VoiceTodoTests/Integration/SystemCalendarWriterTests.swift`**：
  跨天写出为真实区间；全天事件开 / 闭区间往返一致（导入 → 导出 → 再导入不漂移）。

### 零回归闸门

现有测试**一行不改**必须全绿 —— `eventEndDate == nil` 时所有路径必须与今天等价。
重点盯 `StoreTests`（现有 occurrence 用例）、`DayStartHourBoundaryTests`、
`HomeCalendarStateGroupingTests`、`TodoDueDateShifterTests`。

```bash
xcodebuild test -scheme VoiceTodo -destination 'platform=iOS Simulator,name=iPhone 15 Pro'
```

### 真机 / 模拟器人工回归

1. 详情页把一条任务设成「8/14 → 8/16」，回月历：三格都出现，14 号显示完整标题，
   15 / 16 带连续标记。
2. 在 15 号那天打勾 → 14 / 15 / 16 三格同时变灰 + 删除线。
3. 长按「移到明天」（选中日 = 15 号）→ 区间整体平移，跨度仍是 3 天。
4. 详情页开重复 → 结束日期入口被禁用；反向亦然。
5. iOS 日历建一个「8/21–8/23 全天」事件 → `CalendarImportView` 导入 →
   VoiceTodo 里正好覆盖 21 / 22 / 23 **三天，不是四天**（开闭区间验证点）。
6. 反向：VoiceTodo 里的跨天事件写入 iOS 日历 → 系统日历里显示的天数一致。
7. Widget 在中间日显示该事件。
8. AX5 字号 + 中 / 英长标题下，"第 2/3 天"标记与结束日期行不截断。
