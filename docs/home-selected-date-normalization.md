# `HomeView.selectedDate` 归一化口径不一致

> 状态：**待实施**。两项缺陷同一根因，应一并处理。
> 相关文件：`UI/Home/HomeView.swift`、`Protocols/Domain/DayClock.swift`
> 行号基准：`8813f07`（= 当前 `origin/main`）。
> 触发条件：**仅当用户把「一天起始时刻」设为非 0 值时出现**（设置项见 `4d49c44`）。

---

## 一句话

`selectedDate` 表达的是「用户选中了哪一个日历日」，但它的归一化口径在 5 个赋值点里
**分成两派**；而有两个下游消费者把它当「时刻」，又喂给 `DayClock.startOfUserDay`
做了**二次折算**。`startHour > 0` 时这两处各自错开一天。

其中一处让**长按「移到明天」原地不动**——是持久的数据错误，不是显示问题。

---

## 根因

### 赋值点分两派

| 位置 | 写入值 | 口径 |
|---|---|---|
| `HomeView.swift:197`（`@State` 初值） | `DayClock.startOfUserDay(for: Date())` | 用户日起点 |
| `:1698` `startEntranceAnimation` | `DayClock.startOfUserDay(for: Date(), calendar:)` | 用户日起点 |
| `:1758` `jumpToToday` | `DayClock.startOfUserDay(for: Date(), calendar:)` | 用户日起点 |
| `:1287` `selectDay` | `calendar.startOfDay(for: day)` | 自然日 0 点 |
| `:1751` `changeMonth` | `HomeCalendarState.startOfMonth(for:calendar:)` | 自然日 0 点 |

`startHour = 3` 时前三者写入 `03:00`、后两者写入 `00:00`。差的这 3 小时
**恰好跨越了用户日边界**——`00:00` 属于前一个用户日。

**`startHour = 0` 时两派完全重合**（`DayClock.startOfUserDay` 在 hour=0 时走
`calendar.startOfDay` 快路径，见 `DayClock.swift:49-52`）。这就是为什么这个不一致
一直没被发现：默认配置下它根本不表现出来。

### 消费者敏感度

**不敏感**（只取 y/m/d，或自己会再归一化一次，两种口径同结果）：

| 位置 | 为什么不敏感 |
|---|---|
| `:724` `TodoOccurrenceData.dayKey(for:)` | 内部 `startOfDay` + 只取 y/m/d（`Models.swift:99-102`） |
| `:957` → `HomeCalendarState.make` | `HomeCalendarState.swift:72` 会再 `calendar.startOfDay` 一次 |
| `:969` `visibleDays.firstIndex { isDate(_:inSameDayAs:) }` | 自然日比对 |
| `:1809` `setTodoHour` | 只取 `[.year, .month, .day]` |
| `:1855` `assignTodoToBucket` | `calendar.startOfDay(for: selectedDate)` |
| `HomeMonthHeaderView.swift:458,465` | 消费的是已归一化的 `state.selectedDate` |

**敏感 = 缺陷**（2 处）。两处形状完全相同：**对一个已经是「日」的值再折算一次**。

---

## 缺陷 1：「移到明天」原地不动（严重，持久数据错误）

### 现象

`startHour > 0` 时，在 calendar tab 点过任意日期格之后，长按任务选「移到明天」，
任务的 `dueDate` **停在当前选中日**，不动。

复现路径：设置「一天起始时刻」= 3:00 → calendar tab → 点**任意**日期格
（**包括今天那一格**）→ 长按任意任务 → 移到明天 → 任务仍在原来那天。

Today tab 不受影响：`jumpToToday` 给的是用户日起点，`startOfUserDay` 对它幂等。

### 数字复现

调用链：`HomeView.swift:1076` 的
`onMoveToTomorrow: { id in moveTodoToTomorrow(id, baseDate: selectedDate) }`
→ `:1907` → `TodoDueDateShifter.nextDay`（`Protocols/Domain/TodoDueDateShifter.swift:32`）。

设 `startHour = 3`，用户点了 3/15 那一格 ⇒ `selectedDate = 3/15 00:00`（`selectDay` 口径）：

```
baseDay  = DayClock.startOfUserDay(for: 3/15 00:00)
         → naturalMidnight = 3/15 00:00
         → candidateStart  = 3/15 03:00
         → 03:00 <= 00:00 ? 否 → 回退一天
         = 3/14 03:00                    ← 已经错了：选的是 15 号，算成了 14 号
tomorrow = 3/14 03:00 + 1 day = 3/15 03:00
返回值   = 3/15 03:00                     ← hasDueTime=false 直接返回 tomorrow
```

`dayKey(3/15 03:00)` = `"2026-03-15"` ⇒ 任务仍渲染在 **3/15**。期望是 3/16。

带钟点的情况一样：`hasDueTime = true` 且原 `dueDate = 3/15 14:30` 时，
`bySettingHour(14, 30, of: 3/15 03:00)` = `3/15 14:30`——同样原地不动。

`startHour = 0` 时 `baseDay = 3/15 00:00` → `tomorrow = 3/16 00:00`，正确。

### 归责：错在调用点，不在 `TodoDueDateShifter`

**不要去改 `nextDay`。** 它的 `baseDate` 契约是「**时刻**」，
且这个语义有单测显式锁定——`TodoDueDateShifterTests.swift:163`
`testCustomDayStartHour_baseDateBeforeHour_belongsToPreviousUserDay`：
`baseDate = 2026-07-24 01:00` + `startHour=3` → 期望 `07-24 03:00`
（凌晨 1 点属于用户日 7/23，它的明天是 7/24）。**这条断言是对的**。

问题在于 `HomeView` 传进去的不是「时刻」而是「已归一化的选中日」。
按时刻语义解读一个 `00:00`，结论必然是「前一个用户日」。

顺带说明：这个缺陷把 `2026-07-25` 那次修复（把 `Date()` 换成 `baseDate`，
使「移到明天」相对选中日而非真实今天，见 `TodoDueDateShifter.swift:7-11` 的设计注释）
在 `startHour > 0` 下**实质回退了**——症状甚至和当初描述的「原地不动」一模一样。

---

## 缺陷 2：进度环瞬态错开一天（轻微，仅显示）

### 现象

`startHour > 0` 时，跨月切换或冷启动的瞬间，页头进度环的 `n/m`
按**前一天**的任务算，几十 ms 后恢复正常。

### 数字复现

`selectedDayStats()`（`HomeView.swift:723-738`）的兜底分支：

```swift
let day = DayClock.startOfUserDay(for: selectedDate, calendar: calendar)   // :731
let onDay = store.todos.filter { todo in
    guard let due = todo.dueDate else { return false }
    return DayClock.isSameUserDay(due, day, calendar: calendar)            // :734
}
```

`startHour = 3` + `selectedDate = 3/15 00:00`：`day = 3/14 03:00`，
于是统计区间变成 `[3/14 03:00, 3/15 03:00)`——**页头写着 3/15，数字却是 3/14 的**。

### 为什么只是瞬态

该分支只在 `monthOccurrences[dayKey]` 未命中时走到（`:725`）。主分支走缓存，
而 `dayKey` 对两派口径都产出同一个 key，所以**缓存命中时完全正确**。
未命中窗口 = 冷启动 / 跨月切换后 `.task(id:)`（`:1191`）重算完成之前的几十 ms，
`:719-722` 的注释已自陈这是「已知瞬态」。

注意跨月切换恰好同时满足两个条件——`changeMonth` 写的是自然日 0 点，
且缓存刚失效——所以这是最容易看到的场景。

---

## 为什么现有单测没抓到

- `TodoDueDateShifterTests` 只在 `:163` 一条用例里 `setStartHour(3)`，
  且它验的是**工具本身**的时刻语义（正确的那部分）。其余用例全在 `startHour = 0` 上跑。
- `DayStartHourBoundaryTests.swift` 的覆盖面写在文件头注释里（`:9-12`）：
  `TodoDueDateResolver` / `ReviewAggregator` / `WidgetTodoFilter`——**不含 HomeView**。
- 两个缺陷都在 **HomeView 的调用点**，而 `HomeView` 是个 SwiftUI View，
  当前没有针对 `selectedDate` 归一化的测试挂点。

⇒ 修复时应把新用例放进 `DayStartHourBoundaryTests`（它已有 `setStartHour` +
`tearDown` 清理的现成骨架），并把可测逻辑从 View 里抽成纯函数。

---

## 修复建议

### 第一步：定一个口径 —— `selectedDate` = 选中日的**自然日 0 点**

理由：

1. 6 个「不敏感」消费者**已经全部按自然日在用**，改成这个口径它们一个都不用动
2. 「用户选中了哪一格」本质是**日历日**概念，不是时刻——月网格、`dayKey`、
   `visibleDays` 都是自然日坐标系
3. `HomeCalendarState.swift:72` 早就在入口处做这个归一化了，属于既有事实标准

### ⚠️ 但初始化 / 回今天不能裸换成 `startOfDay(for: Date())`

那三处（`:197` / `:1698` / `:1758`）必须**保住「语义今天」**：
`startHour = 3` 的晚睡用户在凌晨 1 点打开 App，该看到的是「昨天」的列表——
这正是 `DayClock` 存在的理由，不能丢。

写法是**先取语义日、再取它的自然日 0 点**：

```swift
// 语义今天（凌晨可能是昨天）的自然日 0 点
calendar.startOfDay(for: DayClock.startOfUserDay(for: Date(), calendar: calendar))
```

验算（`startHour = 3`，现在是 `3/15 01:00`）：
`startOfUserDay` → `3/14 03:00` → `startOfDay` → `3/14 00:00` ⇒ 选中 3/14 ✅

### 第二步：给 `DayClock` 补一个原语，三处共用

两个缺陷、外加 `completed-unscheduled-todo-placement.md` 待实施的完成归档逻辑，
需要的都是同一个换算：**「自然日 D」↦「用户日 D 的起点」**。建议加：

```swift
/// 把「自然日 day」映射到该自然日对应「用户日」的起点（day 的 00:00 + startHour）。
///
/// 与 `startOfUserDay(for:)` 的区别：那个接收**时刻**并问「它属于哪个用户日」；
/// 这个接收**已归一化的日**并问「这一天作为用户日从几点开始」。
/// 对一个 00:00 调 `startOfUserDay` 会掉到前一个用户日——那是 bug，不是本函数。
///
/// `startHour = 0` 时等价于 `calendar.startOfDay(for: day)`——零回归。
static func userDayStart(onNaturalDay day: Date, calendar: Calendar = .current) -> Date
```

三个调用点随之收敛（`startHour = 3` 与 `startHour = 0` 两种情形均已验算）：

| 调用点 | 改成 |
|---|---|
| `moveTodoToTomorrow`（`:1076`） | `nextDay(baseDate: DayClock.userDayStart(onNaturalDay: selectedDate, calendar: calendar), …)` → `3/15 03:00` → `tomorrow = 3/16 03:00` ✅，**shifter 与其单测都不用动** |
| `selectedDayStats` 兜底（`:731-734`） | `DayClock.startOfUserDay(for: due, calendar: calendar) == DayClock.userDayStart(onNaturalDay: selectedDate, calendar: calendar)` |
| `HomeCalendarState` 完成归档（另一篇文档） | 同上，把 `due` 换成 `completedAt` |

### 反面写法（这两个缺陷的共同形状，别再写出来）

```swift
// ❌ 对已归一化的「日」二次折算 —— startHour>0 时掉到前一个用户日
DayClock.startOfUserDay(for: selectedDate, calendar: calendar)
DayClock.isSameUserDay(someMoment, selectedDate, calendar: calendar)
```

正确的姿势永远是：**只折算「时刻」那一侧**，「日」那一侧用 `userDayStart(onNaturalDay:)`
抬到同一坐标系，或者干脆比自然日。

---

## 验证清单

前置：设置里把「一天起始时刻」设为 **3:00**。

- calendar tab 点 3/15 格 → 长按任务「移到明天」→ 确认落到 **3/16**（不是原地不动）
- 同上，但任务带钟点（如 14:30）→ 确认落到 **3/16 14:30**，钟点保留
- Today tab 做同样操作 → 确认行为与改动前一致（本就正常，防回归）
- 跨月切换的瞬间盯页头进度环 → 确认 `n/m` 不再闪一下前一天的数字
- 凌晨 1 点（或把系统时间调到凌晨 1 点）冷启动 → 确认选中日是**昨天**、
  且「移到明天」落到**今天**（语义日链路端到端正确）
- 把起始时刻改回 **0:00** → 上述全部行为与改动前逐一一致（零回归闸门）
- 新增单测放进 `VoiceTodoTests/Protocols/DayStartHourBoundaryTests.swift`：
  `userDayStart(onNaturalDay:)` 在 `startHour = 0 / 3 / 23` 三档 + DST 边界

---

## 与 `completed-unscheduled-todo-placement.md` 的关系

那篇文档的「设计决策 B」踩的是**同一个坑**（它的初版示意代码差点写成
`isSameUserDay(completedAt, selectedDate)`），并给出了同一个结论：
只折算 `completedAt` 一侧。

两者的关系：

- **本文档** = 现存缺陷（`selectedDate` 口径不一致，2 处已在线上）
- **那篇文档** = 新功能的正确姿势（无日期任务完成归档，尚未实施）

如果 `DayClock.userDayStart(onNaturalDay:)` 先落地，那篇文档的修复落点可以直接
复用它，示意代码里的 `calendar.isDate(completedDay, inSameDayAs: selectedDate)`
可简化为一次等值比较。两篇独立可分别实施，无强依赖。
