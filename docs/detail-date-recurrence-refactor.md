# 待办详情页：消解「日期」与「重复」的语义冲突

> 状态：设计已确认，待实施
> 基线 commit：`5a83a93`（feat(detail): 详情页加双周/三周 chip + 修 interval 丢失 bug）
> 本文所有文件路径 + 行号均以该 commit 为准

---

## 1. 背景

`origin/main` 刚给重复规则加了「双周 / 三周 / 每月」三档。加完之后，详情页暴露出一个看起来无解的冲突：

用户既能在「时间」卡里选 **7 月 26 日**，又能在下面的「重复」卡里选 **每周一 / 每周二 / 每周日**。
两者同时存在时，系统到底按哪一个执行？

## 2. Review 结论：引擎层没有冲突

**核心事实：当 `recurrenceRule != nil` 时，`dueDate` 在引擎里已经是「重复的起始锚点（startDate）」，而不是「截止日」。**

这不是本次要新建的语义，而是代码里**早就存在**的语义。逐条证据：

### 2.1 展开 occurrence 时，重复规则显式优先

`Store/TodoQueryActor.swift:102-113`：

```swift
if let recurrenceRule = todo.recurrenceRule {
    let start = todo.dueDate ?? todo.createdAt
    for day in days where recurrenceRule.occurs(on: day, startDate: start, calendar: calendar) {
        // …展开成多个 occurrence
    }
} else if let dueDate = todo.dueDate,
          days.contains(where: { calendar.isDate($0, inSameDayAs: dueDate) }) {
    // …单次 occurrence
}
```

这是 `if / else if`，不是并列判断。有重复规则时，**`dueDate` 只作为 `startDate` 传进去，永远不会被当成一次性日期**。

### 2.2 `occurs()` 里锚点的实际作用

`Protocols/Domain/RecurrenceRule.swift:110-141`：

```swift
func occurs(on date: Date, startDate: Date, calendar: Calendar = .current) -> Bool {
    let day = calendar.startOfDay(for: date)
    let start = calendar.startOfDay(for: startDate)
    guard day >= start else { return false }
    …
    case .weekly:
        if weekdays.isEmpty {
            guard interval > 1 else { return false }
            let dayDiff = calendar.dateComponents([.day], from: start, to: day).day ?? 0
            return dayDiff % (interval * 7) == 0          // ← 锚点决定「哪一天」
        }
        guard weekdays.contains(calendar.component(.weekday, from: day)) else { return false }
        if interval > 1 {
            let dayDiff = calendar.dateComponents([.day], from: start, to: day).day ?? 0
            let weekDiff = dayDiff / 7
            return weekDiff % interval == 0               // ← 锚点决定「哪一周」
        }
        return true
    case .monthly:
        guard let dayOfMonth else { return false }
        return calendar.component(.day, from: day) == dayOfMonth   // ← dayOfMonth 自锚
}
```

按档位拆开看锚点的重要性差异极大，**这是整个设计的分界线**：

| 档位 | 锚点的作用 | 用户是否需要看见/控制 |
|---|---|---|
| 每天（`.daily`） | 只是下界（`day >= start`） | 否 |
| 每周（`.weekly` + `interval == 1` + 已选周几） | 只是下界 | 否 |
| **双周 / 三周（`.weekly` + `interval > 1`）** | **`weekDiff % interval` —— 决定从哪一周开始** | **是，必须** |
| 每月（`.monthly`） | `dayOfMonth` 自带锚定，`start` 只是下界 | 否 |

### 2.3 同一套锚点语义散落在所有消费端

- `Store/TodoStore.swift:348` — `toggleOccurrenceComplete` 用 `todoItem.dueDate ?? todoItem.createdAt`
- `Protocols/Domain/WidgetTodoFilter.swift:25` — `data.dueDate ?? data.createdAt`
- `App/Intents/ToggleTodoIntent.swift:125` — `item.dueDate ?? item.createdAt`
- `Protocols/Domain/NotificationPlanner.swift:140` — `rule.occurs(on: day, startDate: due, …)`
- `UI/MockStore.swift:161,190` — 同上

### 2.4 展示层早就把 dueDate 当隐形锚点了

`Protocols/Domain/TodoTimeDisplayComposer.swift` 的 `compose(...)`：

```swift
if let rule = recurrenceRule {
    parts.append(rule.displayTextWithEndDate)
}
// recurrenceRule 自带日期范围展示，不重复加 relativeDateText
if recurrenceRule == nil, let date = relativeDateText…  { parts.append(date) }
```

也就是说，首页卡片、日历条目、ConfirmSheet、Siri 全都**不显示** dueDate —— 只显示「每周 周一 周二 · 10:10」。

### 2.5 结论

> **「7 月 26 日 + 每周一/二/日」今天的真实行为是：从 7/26 起，每周一、二、日重复。定义完全明确。**
>
> 冲突感**只**来自详情页把这个字段标成「日期」，读起来像一次性截止日，跟下面的重复卡片打架。
> 这是 UI 的表达问题，不是引擎缺陷。

## 3. 另一个硬约束：持久化模型没有独立的「钟点」字段

`Protocols/Models.swift` 里持久化的 `TodoItemData` 只有三个时间字段：

```swift
var dueDate: Date?          // 日期 + 钟点烘在一起
var hasDueTime: Bool        // 上面那个 Date 的钟点部分是否有意义
var timeBucket: TimeBucket? // 随时 / 上午 / 下午 / 晚上
```

`ExtractedTodo.dueTime: String?`（`"HH:mm"`）只存在于**入库前**，由 `TodoDueTimeResolver.combine(date:dueTime:)` 合并进 `dueDate`。

而且 `TodoDetailUpdate.init`（`Protocols/Models.swift:404-437`）会强制归一化：

```swift
let normalizedHasDueTime = dueDate != nil && hasDueTime
```

**推论：「只有 10:10、没有任何日期」在当前 schema 下无法表达。**
要支持用户需求 #2（只加钟点/时段、不定日期，与「每周一二三」共存），只有两条路：

- (A) 加持久化字段 + SwiftData 迁移 —— 成本高
- (B) **用隐形锚点承载钟点** —— 零模型改动、零迁移，且与 §2 的既有引擎语义天然一致

本方案选 **(B)**。

---

## 4. 已确认的设计

**不做互斥，做语义重构。** 日期行的形态由重复档位派生，不新增任何持久化字段：

| 重复状态 | 日期行形态 | 理由 |
|---|---|---|
| 无重复 | 「日期」DatePicker + ✕ 清除（**保持原行为不变**） | 单次任务，dueDate 就是截止日 |
| **双周 / 三周**（`.weekly` && `interval > 1`） | 「**起始日期**」DatePicker，**不提供 ✕** | 见 §2.2 —— `weekDiff % interval` 完全依赖锚点。清掉会退回 `createdAt`，用户既看不见也控制不了「从哪一周开始」 |
| 每天 / 每周(`interval == 1`) / 每月 | **整行隐藏**，已有 dueDate 静默保留为锚点 | 锚点只是下界或自锚，暴露出来只会跟重复卡片语义打架 |

配套三条规则：

1. **钟点 + 时段在所有重复档位下都可用**（用户需求 #2）。时段区不再以 `editedDueDate != nil` 为开关。
2. 切到双周/三周且 `editedDueDate == nil` 时，**自动补今天**（`DayClock.startOfUserDay(for: Date())`）作为锚点。
3. 被隐藏的锚点通过重复卡底部**一行摘要**显式化，不留黑盒：
   `从 7月30日 起 · 双周 周一 · 10:10`

### 为什么不采用「选了日期就把重复卡片置灰」

那是最初的直觉方案，但它会**直接削弱刚加的双周/三周功能**：
禁止 dueDate 之后，`occurs()` 的锚点静默退回 `createdAt`，
用户既无法表达「从下周一开始的双周」，也看不出为什么某一周不出现。
「起始日期」的重构在消除冲突的同时保住了这个能力，且与引擎既有语义 100% 对齐。

---

## 5. 逐点改动清单

### 5.1 新增 `Protocols/Domain/RecurrenceAnchorPolicy.swift`

**为什么抽出来**：`TodoDetailView` 是没有 view-model 的 SwiftUI View，状态机内联在里面无法单测。
本仓已有同类惯例 —— `TimeBucketResolver` / `TodoScheduleDefaults`（同在 `Protocols/Domain/TimeBucket.swift:25,58`）、
`TodoDueTimeResolver`、`RecurrenceEndResolver` 都是这种「纯判定 enum」。

```swift
/// 详情页「日期行」形态的判定策略。
///
/// 依据:引擎层在 recurrenceRule != nil 时,dueDate 已经是 occurs(on:startDate:) 的 startDate,
/// 不是截止日(见 TodoQueryActor.calendarOccurrences / RecurrenceRule.occurs)。
/// 这里只是把详情页 UI 对齐到这套既有语义,不引入任何新的持久化字段。
enum RecurrenceAnchorPolicy {
    enum DateRowMode {
        /// 无重复:普通「日期」选择器 + 清除按钮(原行为)
        case dueDate
        /// 双周/三周:「起始日期」选择器,不可清除
        case startAnchor
        /// 每天/每周(interval==1)/每月:锚点对行为无实质影响,隐藏日期行
        case hidden
    }

    static func dateRowMode(frequency: RecurrenceFrequency?, interval: Int) -> DateRowMode
    static func canAddClockTime(dueDate: Date?, frequency: RecurrenceFrequency?) -> Bool
    static func showsAnchorPrefix(
        mode: DateRowMode,
        anchor: Date?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool
}
```

判定规则：

- `dateRowMode`：`frequency == nil → .dueDate`；`frequency == .weekly && interval > 1 → .startAnchor`
  （含 AI fallback 的 `interval >= 4`）；其余 → `.hidden`
- `canAddClockTime`：`dueDate != nil || frequency != nil`
- `showsAnchorPrefix`：`.startAnchor` 恒 `true`；`.hidden` 仅当 `anchor` 严格晚于今天才 `true`
  （锚点是今天/过去时，「从今天起 · 每天」纯属噪音）；`.dueDate` 恒 `false`

### 5.2 `UI/Detail/TodoDetailView.swift`（主改动）

#### a. 时间卡日期区（当前 158-196 行）

现状是 `if editedDueDate != nil { DatePicker + ✕ } else { 「添加日期」按钮 }`。改为 switch `dateRowMode`：

- `.dueDate` → **完全保留现有两分支**（`.date` DatePicker + ✕ / 「添加日期」按钮）
- `.startAnchor` → 标题走新 key `detail.start_date`，`.date` DatePicker；
  **不渲染 ✕、不渲染「添加日期」按钮**（进入这个 mode 时锚点必然已补齐，见 5.2.c）
- `.hidden` → 整个日期区（含「添加日期」按钮）不渲染

#### b. 时段区（当前 213-222 行 + `timeRowWithDueDate` 411-492 行）

现状：`if editedDueDate != nil { timeRowWithDueDate } else { chipRow(TimeBucket) }`，
`timeRowWithDueDate` 内部再按 `editedHasDueTime` 分两支。

合并为单个 `timeSection`（把 `timeRowWithDueDate` 改名），**主分支改成 `editedHasDueTime`**：

- `editedHasDueTime == true` → **现有钟点分支原样保留**：`.hourAndMinute` DatePicker（把 hour/minute 合并进
  `editedDueDate` 的 y/m/d）+ `TimeBucketResolver.effective` 只读派生标签 + ✕ 只清 `hasDueTime`
- `editedHasDueTime == false` →
  - 「添加钟点」按钮可见性改为 `RecurrenceAnchorPolicy.canAddClockTime(dueDate:frequency:)`
  - **TimeBucket chipRow 恒显示**

「添加钟点」的现有实现是 `calendar.dateComponents([.year,.month,.day], from: editedDueDate ?? now)`，
**天然支持 `dueDate == nil`** —— 顺手把今天写成锚点，无需改动这段代码。

不变式：`editedHasDueTime == true ⇒ editedDueDate != nil`（UI 侧维持，`TodoDetailUpdate.init` 再兜一层）。

#### c. `recurrenceModeButton` 的 action（当前 587-603 行）

在现有 `if frequency == .weekly { editedInterval = interval; if interval == 1 && editedWeekdays.isEmpty {…} }` 之后补：

```swift
// 双周/三周靠起始锚点决定「从哪一周开始」(occurs 的 weekDiff % interval);
// 无 dueDate 时补今天,既给 occurs() 一个确定基准,也让「起始日期」行有值可显示。
if interval > 1 && editedDueDate == nil {
    editedDueDate = DayClock.startOfUserDay(for: Date())
}
```

紧随其后已有的 `checkForChanges()` 会因 `editedDueDate != todo.dueDate` 正确置 `hasChanges` —— **无需额外改动**。

#### d. 重复卡底部摘要（当前 566-570 行 validation 的位置）

改成二选一：`recurrenceValidationMessage != nil` 时显示 warning（原样），否则显示摘要 caption。

```swift
/// 重复生效后的完整语义摘要,让被隐藏的起始锚点不再是黑盒。例:「从 7月30日 起 · 双周 周一 · 10:10」。
/// 复用 TodoTimeDisplayComposer.compose 拼后半段 —— 它在有 rule 时会主动跳过日期,
/// 正好把「起始日」的表述让给这里的 detail.recurrence.starts_from 前缀,不会重复。
private var recurrenceSummary: String?
```

- 后半段：`TodoTimeDisplayComposer.compose(recurrenceRule: editedRecurrenceRule, relativeDateText: nil,
  timeText: <HH:mm 或 nil>, dueHint: nil, timeBucketText: <仅无钟点时传>)`
- 前缀：`showsAnchorPrefix(...)` 为 `true` 时，用 `TodoRelativeDateFormatter.format(anchor)`
  （已存在于 `Protocols/Domain/TodoTimeDisplayComposer.swift`）套新 key `detail.recurrence.starts_from`
- 钟点串：照抄 `UI/Home/WarmTodoCard.swift:195-203` 那个 `"HH:mm"` + `en_US_POSIX` formatter 的写法，
  在详情页内建同款 `private static let`。**不要**为这一行去改 `WarmTodoCard`

#### e. 明确不需要改动的部分（已逐个核对）

以下全部照旧 —— 本次只改 UI 呈现与锚点补齐，写库字段和比对逻辑不变：

| 成员 | 行号 |
|---|---|
| `editedRecurrenceRule` | 655-672 |
| `recurrenceValidationMessage` | 674-684 |
| `recurrenceStateChanged` | 686-703 |
| `checkForChanges` | 713-727 |
| `scheduleAutosave` | 736-743 |
| `persistChanges` | 772-829 |

### 5.3 `Resources/Localizable.xcstrings`

按文件现有格式（`localizations.<lang>.stringUnit.{state:"translated", value}`）新增 2 个 key：

| key | zh-Hans | en |
|---|---|---|
| `detail.start_date` | 起始日期 | Start date |
| `detail.recurrence.starts_from %@` | 从 %@ 起 | From %@ |

### 5.4 无障碍标识

给新增/改动的控件补 `.accessibilityIdentifier`，命名风格对齐现有的 `TodoDetailCloseButton`：

- `DetailStartDatePicker`
- `DetailAddTimeButton`
- `DetailRecurrenceSummary`

---

## 6. 状态迁移逐条预期

| 迁移 | 预期行为 |
|---|---|
| 无重复（已有 7/26）→ 每天 | 日期行消失；7/26 **静默保留**为锚点（不清空——清了会连钟点一起毁）。摘要显示「从 7月26日 起 · 每天」（锚点在未来）或「每天」（锚点今天/过去） |
| 无重复（无日期）→ 双周 | 自动补今天为锚点，「起始日期」行出现 |
| 双周 → 每天 | 锚点保留但隐藏；摘要按 `showsAnchorPrefix` 决定是否带「从 X 起」 |
| 每天 → 无重复 | 锚点重新以「日期」身份出现。**这是正确且可接受的**：那本来就是同一个字段的另一重身份，完全可逆（重新选重复它就变回锚点），且不丢数据 |
| 双周 → 无重复 | 同上 |
| 任意重复档位 + 「添加钟点」 | `editedDueDate ?? now` 建锚点、`hasDueTime = true`，满足「每周一二三 · 10:10，无具体日期」 |

---

## 7. 测试要求

### 7.1 新增单测

写进 `VoiceTodoTests/Protocols/DomainModuleTests.swift`（与 `TodoDetailUpdate` / `TimeBucketResolver` 用例同文件）：

- **`dateRowMode`**：`nil → .dueDate`；`.weekly/1 → .hidden`；`.weekly/2 → .startAnchor`；
  `.weekly/3 → .startAnchor`；`.weekly/4 → .startAnchor`；`.daily → .hidden`；`.monthly → .hidden`
- **`canAddClockTime`**：`(nil, nil) → false`；`(date, nil) → true`；`(nil, .weekly) → true`
- **`showsAnchorPrefix`**：`.startAnchor` 恒 `true`；`.hidden` + 今天 → `false`；`.hidden` + 未来 → `true`
- **回归锁定（关键）**：构造 `RecurrenceRule(frequency: .weekly, interval: 2, weekdays: [2])`，
  用相差一周的两个 `startDate` 对同一个 `date` 调 `occurs(on:startDate:)`，断言结果**翻转** ——
  这条用例的存在本身就是「双周锚点必须可见可控」的证明，防止后人把 `.startAnchor` 改回 `.hidden`。
  测试必须传固定 `Calendar`（`Calendar(identifier: .gregorian)` + 固定 `timeZone`），
  参照同文件 `testTimeBucketResolverPrefersClockTimeOverConflictingExplicitBucket` 的写法。

### 7.2 不应破坏的现有测试

- `VoiceTodoTests/Protocols/ProtocolsTests.swift` → `testRecurrenceRuleDisplayTextHasThreeWeeklyBranches`
- `VoiceTodoTests/Protocols/DomainModuleTests.swift` → `testTodoDetailUpdateNormalizesClockTimeWithoutDueDate`
- `VoiceTodoTests/UI/HomeCalendarStateGroupingTests.swift` 全部

### 7.3 构建 / 跑测

```
./prepare_xcode_project.sh
xcodebuild -scheme VoiceTodo -destination 'platform=iOS Simulator,name=iPhone 16' build test
```

---

## 8. 影响面：详情页之外一律不动

| 模块 | 是否需改 | 依据 |
|---|---|---|
| `TodoQueryActor` / `TodoStore` / `WidgetTodoFilter` / `NotificationPlanner` / `ToggleTodoIntent` | 否 | 读的都是同一套 `dueDate ?? createdAt` 锚点语义，本方案没有改变任何持久化字段的含义 |
| `TodoTimeDisplayComposer` | 否 | 已在 `recurrenceRule != nil` 时跳过日期，行为正是本方案想要的 |
| `RecurrenceRuleResolver` | 否 | 只在提取 / 解码期运行，不参与详情页编辑 |
| ConfirmSheet | 否 | 不编辑 recurrence |
| Home `PendingDateTodoRow` / `TimeEditPopover` | 否 | 只作用于 `recurrenceRule == nil` 的分组（`UI/Home/HomeCalendarState.swift:163` 的 `noSchedule` filter） |
| SwiftData schema | 否 | **零模型改动、零迁移** |

---

## 9. 验收清单（模拟器手动路径）

1. 新建无日期待办 → 详情页选「每周」→ 勾周一/周二 → 「添加钟点」设 10:10 → 关闭重开：
   钟点仍在、日期行不出现、摘要为「每周 周一 周二 · 10:10」
2. 选「双周」→「起始日期」行出现且默认今天 → 改成下周一 → 回首页日历：
   确认只在**隔周**的周一出现，中间那周不出现
3. 已有 7/26 日期的待办 → 选「每天」→ 日期行消失、摘要显示「从 7月26日 起 · 每天」→
   取消重复 → 7/26 以「日期」身份回来，数据未丢
4. 只选「下午」时段 + 「每周三」，不设任何日期 → 保存后重开，两者共存（用户需求 #2 的正面用例）
5. 系统语言切到 English，重跑 1-4，确认 `detail.start_date` / `detail.recurrence.starts_from` 渲染正常
