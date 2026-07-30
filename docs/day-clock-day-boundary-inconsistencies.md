# 自然日 / 用户日 口径混用（DayClock）—— 三处线上缺陷

> 状态：**已实施**。`8e5758f`（新原语 `userDayStart(onNaturalDay:)` + 三处调用点修复 + 7 条新测），
> 当前在 `wendang` 分支，**待合并 `main`**。
> 本文保留为**设计决策 + 实施记录**。
> 相关文件：`UI/Home/HomeView.swift`、`UI/Home/HomeCalendarState.swift`、
> `Protocols/Domain/DayClock.swift`
> 行号基准：缺陷引用 = `4b1eaa6`（= 当前 `origin/main`）；实施后引用 = `8e5758f`。
> 触发条件：**仅当用户把「一天起始时刻」设为非 0 值时出现**（设置项见 `4d49c44`）。
>
> ⚠️ **代码已修复，行为正确性待真机人工回归**：见文末「验证清单」（缺陷 1/2/3 + 零回归闸门）。
> 单测已覆盖：`DayStartHourBoundaryTests` 13/13（含 5 条新原语用例）、
> `HomeCalendarStateGroupingTests` 15/15（含缺陷 3 回归 + hour=0 零回归）。
> `TodoDueDateShifter` 与其单测**未动**（baseDate 契约是时刻，问题在调用点）。

---

## 一句话

项目里「某个时刻属于哪一天」有两套坐标系——**自然日**（`calendar.startOfDay`）
和**用户日**（`DayClock`，可配置起始时刻）。三处代码把两者混用了：

| # | 缺陷 | 形状 | 严重度 |
|---|---|---|---|
| 1 | 长按「移到明天」原地不动 | 对已是「日」的值**二次折算** | **严重**（持久数据错误） |
| 2 | 顶部进度环瞬态错开一天 | 对已是「日」的值**二次折算** | 轻微（瞬态显示） |
| 3 | 无日期任务完成归档与回顾页分裂 | 该折算的一侧**漏折算** | 中等（跨页面数据不一致） |

`startHour = 0`（默认）时三处全部不表现——这就是它们一直没被发现的原因。

---

## 根因 A：`HomeView.selectedDate` 的归一化口径分两派

`selectedDate` 表达的是「用户选中了哪一个日历日」，但 5 个赋值点写入的值口径不同：

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
`calendar.startOfDay` 快路径，见 `DayClock.swift:49-52`）。

### 消费者敏感度

**不敏感**（只取 y/m/d，或自己会再归一化一次，两种口径同结果）：

| 位置 | 为什么不敏感 |
|---|---|
| `:724` `TodoOccurrenceData.dayKey(for:)` | 内部 `startOfDay` + 只取 y/m/d（`Models.swift:99-102`） |
| `:957` → `HomeCalendarState.make` | `HomeCalendarState.swift:72` 会再 `calendar.startOfDay` 一次 |
| `:969` `visibleDays.firstIndex { isDate(_:inSameDayAs:) }` | 自然日比对 |
| `:1809` `setTodoHour` | 只取 `[.year, .month, .day]` |
| `:1855` `assignTodoToBucket` | `calendar.startOfDay(for: selectedDate)` |
| `HomeMonthHeaderView.swift:461,468` | 消费的是已归一化的 `state.selectedDate` |

**敏感 = 缺陷 1 与缺陷 2。** 两处形状相同：对一个已经是「日」的值再折算一次。

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
（凌晨 1 点属于用户日 7/23，它的明天是 7/24）。**这条断言是对的。**

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

跨月切换恰好同时满足两个条件——`changeMonth` 写的是自然日 0 点，且缓存刚失效——
所以这是最容易看到的场景。

---

## 缺陷 3：无日期任务完成归档与回顾页分裂（中等，已上线）

### 来源

`abfaa588`（`docs/completed-unscheduled-todo-placement.md` 的实施）。
那篇文档的设计决策明确写了「与回顾页同源」，但实施时**只对齐了「用哪个字段」
（`completedAt`），没对齐「怎么把字段折算成某一天」**。

### 现象

`startHour > 0` 时，凌晨完成的无日期任务，**首页和回顾页归到不同的日子**。

### 数字复现

首页，`UI/Home/HomeCalendarState.swift:174-181`：

```swift
guard todo.isCompleted, let completedAt = todo.completedAt else { return false }
return calendar.isDate(completedAt, inSameDayAs: selectedDate)   // ← 自然日
```

回顾页，`Protocols/Domain/ReviewAggregator.swift:81,110`：

```swift
let day = DayClock.startOfUserDay(for: event.completedAt, calendar: calendar)  // ← 用户日
```

设 `startHour = 3`，任务在 `3/16 01:00` 被勾完成：

| 页面 | 折算 | 归到 |
|---|---|---|
| 首页「已完成」分区 | `isDate(3/16 01:00, inSameDayAs:)` → 自然日 | **3/16** |
| 回顾页 | `startOfUserDay(3/16 01:00)` = `3/15 03:00` | **3/15** |

同一条任务，两个页面说的不是同一天。对晚睡用户（`DayClock` 的目标人群）来说，
凌晨 1 点做完的事算「昨天的成果」才符合心智——回顾页对，首页错。

### 形状与缺陷 1/2 相反

缺陷 1/2 是**多折算了一次**（对已是「日」的值再折算），
缺陷 3 是**漏折算了一次**（`completedAt` 是时刻，该折没折）。
但根因同族：两套坐标系没有单一入口，靠每个调用点各自记得该用哪套。

---

## 为什么现有单测没抓到

- `TodoDueDateShifterTests` 只在 `:163` 一条用例里 `setStartHour(3)`，
  且它验的是**工具本身**的时刻语义（正确的那部分）。其余用例全在 `startHour = 0` 上跑。
- `DayStartHourBoundaryTests.swift` 的覆盖面写在文件头注释里（`:9-12`）：
  `TodoDueDateResolver` / `ReviewAggregator` / `WidgetTodoFilter`——**不含 HomeView，
  也不含 `HomeCalendarState`**。
- `HomeCalendarStateGroupingTests` 的 13 个用例全部在 `startHour = 0` 下跑，
  缺陷 3 对它们不可见。
- 缺陷 1/2 都在 **HomeView 的调用点**，而 `HomeView` 是个 SwiftUI View，
  当前没有针对 `selectedDate` 归一化的测试挂点。

⇒ 修复时新用例应放进 `DayStartHourBoundaryTests`（它已有 `setStartHour` +
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

三个缺陷需要的都是同一个换算：**「自然日 D」↦「用户日 D 的起点」**。建议加：

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

| 缺陷 | 调用点 | 改成 |
|---|---|---|
| 1 | `moveTodoToTomorrow`（`HomeView.swift:1076`） | `nextDay(baseDate: DayClock.userDayStart(onNaturalDay: selectedDate, calendar: calendar), …)` → `3/15 03:00` → `tomorrow = 3/16 03:00` ✅，**shifter 与其单测都不用动** |
| 2 | `selectedDayStats` 兜底（`:731-734`） | `DayClock.startOfUserDay(for: due, calendar: calendar) == DayClock.userDayStart(onNaturalDay: selectedDate, calendar: calendar)` |
| 3 | `HomeCalendarState.swift:174-181` 的 filter | 同上，把 `due` 换成 `completedAt`——一行改动，且自动与 `ReviewAggregator` 对齐 |

### 反面写法（别再写出来）

```swift
// ❌ 对已归一化的「日」二次折算 —— startHour>0 时掉到前一个用户日（缺陷 1/2）
DayClock.startOfUserDay(for: selectedDate, calendar: calendar)
DayClock.isSameUserDay(someMoment, selectedDate, calendar: calendar)

// ❌ 把「时刻」直接当自然日比 —— 漏掉用户日折算（缺陷 3）
calendar.isDate(completedAt, inSameDayAs: selectedDate)
```

正确的姿势永远是：**「时刻」那一侧用 `startOfUserDay` 折算，「日」那一侧用
`userDayStart(onNaturalDay:)` 抬到同一坐标系**，然后比较。

---

## 验证清单

前置：设置里把「一天起始时刻」设为 **3:00**。

- 缺陷 1：calendar tab 点 3/15 格 → 长按任务「移到明天」→ 确认落到 **3/16**
- 缺陷 1：同上但任务带钟点（如 14:30）→ 确认落到 **3/16 14:30**，钟点保留
- 缺陷 1：Today tab 做同样操作 → 确认行为与改动前一致（本就正常，防回归）
- 缺陷 2：跨月切换的瞬间盯页头进度环 → 确认 `n/m` 不再闪一下前一天的数字
- 缺陷 3：凌晨 1 点勾掉一条无日期任务 → 确认首页「已完成」分区把它归到**昨天**，
  **且与回顾页显示的日期一致**（这条是缺陷 3 的核心闸门）
- 端到端：凌晨 1 点冷启动 → 确认选中日是**昨天**、且「移到明天」落到**今天**
- **把起始时刻改回 0:00 → 上述全部行为与改动前逐一一致（零回归闸门）**
- 新增单测放进 `VoiceTodoTests/Protocols/DayStartHourBoundaryTests.swift`：
  `userDayStart(onNaturalDay:)` 在 `startHour = 0 / 3 / 23` 三档 + DST 边界；
  缺陷 3 另在 `HomeCalendarStateGroupingTests` 补一条 `startHour = 3` 的凌晨用例

---

## 与 `completed-unscheduled-todo-placement.md` 的关系

那篇文档记录的 bug **已经实施完毕**（`abfaa588` + `8b3e3f09`），
本文的**缺陷 3 就是它留下的那一项**——设计决策写了「与回顾页同源」，
实施时只对齐了字段、没对齐折算方式。

两篇的分工：

- **那篇** = 「无日期任务完成后归档到哪一天」的设计决策 + 实施记录（已完成）
- **本篇** = 「怎么把时刻折算成某一天」的口径缺陷（三处，已实施 `8e5758f`）

三个缺陷已一并修：共用同一新原语 `userDayStart(onNaturalDay:)`，避免分散修
导致引入后仍有调用点停在旧写法上。
