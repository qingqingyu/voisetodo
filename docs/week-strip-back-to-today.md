# 周条（折叠态日历）左右滑翻周后「回到今天」

> 状态：**待实施**。本文档是实施方案，不含已落地的代码。
> 相关文件：`UI/Home/HomeView.swift`、`UI/Home/HomeCalendarState.swift`、
> `Resources/Localizable.xcstrings`、`VoiceTodoTests/UI/HomeCalendarPeriodVisibilityTests.swift`（新建）
>
> **基线**：本文所有行号对齐 `0d475f3`（*test(ui): 修 S12 容错边界 + 新增 S16 日历权限拒绝路径*）。
> 若实施时 main 又前进了，**先按符号名（函数名 / 属性名 / 注释原文）定位，行号仅作参考**。
>
> **范围**：`UI/Home/HomeMonthHeaderView.swift`（`WeekStripCard` 所在）**本次完全不用改**——
> 翻周手势那一块不要动。

---

## 需求

Calendar tab 的日历区可以从整月网格折叠成一条**周条**（`WeekStripCard`，
`HomeMonthHeaderView.swift:465-639`）。周条上左右滑可以翻周
（`SimultaneousDragGesture` → `onShiftWeek` → `HomeView.shiftWeek`）。

用户反馈：翻走之后**没有任何入口能回到今天**。

## 根因：不是缺按钮，是已有按钮的可见性判断粒度写错了

「回到今天」的按钮**其实已经存在**——就是日历大标题（月份名）后面那个
`chevron.left` 小箭头，整块「标题 + 箭头」是一个 Button，点击调 `jumpToToday()`：

- `HomeView.swift:770-786` — `backToTodayTitleButton`
- `HomeView.swift:642-649` — 标题区二选一：`isViewingCurrentPeriod` 为 true 渲染纯
  `monthTitleText`，false 渲染上面那个按钮
- `HomeView.swift:2143-2152` — `jumpToToday()`

问题出在谓词本身（`HomeView.swift:739-747`）：

```swift
/// 当前浏览的月（周视图为周）是否就是今天所在的月/周。
/// 设计稿规则：只按月/周判断，不看选中的具体某天——停在本月就不渲染「回到今天」胶囊。
private var isViewingCurrentPeriod: Bool {
    calendar.isDate(
        visibleMonthAnchor,
        equalTo: Date(),
        toGranularity: .month
    )
}
```

注释写的是「月（周视图为周）」，**实现只做了 `.month`**。注释与实现分叉，
这就是 bug 的书面证据。

而 `shiftWeek`（`HomeView.swift:2130-2141`）在同月内翻周时**故意不动**
`visibleMonthAnchor`：

```swift
private func shiftWeek(by value: Int) {
    guard let newDate = calendar.date(byAdding: .day, value: value * 7, to: selectedDate) else { return }
    let newMonthAnchor = HomeCalendarState.startOfMonth(for: newDate, calendar: calendar)
    withAnimation(WarmAnimation.springStandard) {
        selectedDate = newDate
        if !calendar.isDate(newMonthAnchor, equalTo: visibleMonthAnchor, toGranularity: .month) {
            visibleMonthAnchor = newMonthAnchor
        }
    }
}
```

这是**有意为之**（注释在 `:2128`：同月内切周不动 anchor，月网格 42 格不重 layout，视觉更稳）。

两者相乘的结果：**在周条里翻到本月的其它周，`isViewingCurrentPeriod` 恒为 `true`，
箭头永不出现**。只有翻出当前月才会出现——所以用户体感是「周视图里没有回到今天的按钮」。

> ⚠️ **不要通过改 `shiftWeek` 让 anchor 每次翻周都跟着动来「顺便」修好谓词。**
> 那会牺牲月网格的布局稳定性，是拿一个有意的设计换另一个。修谓词，别修 `shiftWeek`。

## 交互取舍（已与用户确认，不要另作发挥）

- **复用已有的标题 chevron**，不在周条里另加独立的「回到今天」按钮或圆钮。
- **不加任何自动跳回今天的机制**——不做 scenePhase 回前台自动跳，不做切 tab 重置。
  只保留用户主动点击。

## 设计约束

### 1. 不能加宽标题行

`HomeView.swift:629-638` 记录了历史：原来的「回到今天」**文字胶囊**在英文下约 100pt，
叠上长月份名（"September"）+ 齿轮后一整行会超宽，月份名被挤到几乎 0 宽、
向左滑月份时直接「消失」。chevron 只占约 16pt 才被选中。

**所以复用 chevron，不要引入新的文案胶囊。**

### 2. 不能简单地把月条件和周条件 `&&` 起来

`HomeView.swift:740` 的设计意图：「只按月/周判断，**不看选中的具体某天**」。

如果写成 `同月 && 同周`，那么在**展开的月网格**里点选本月的另一天（比如今天 11 号、
点了 25 号）就会冒出箭头，破坏原有设计。

**必须按折叠态切换粒度**：折叠成周条 → 比周；展开成月网格 → 比月。

### 3. 不许用 `calendar.isDate(_:equalTo:toGranularity: .weekOfYear)`

周条的「一周是哪 7 天」是**硬编码周一起始**的
（`HomeCalendarState.swift:318-323`，`daysFromMonday = (weekday + 5) % 7`），
**完全不读 `calendar.firstWeekday`**：

```swift
private static func startOfWeek(for date: Date, calendar: Calendar) -> Date {
    let startOfDay = calendar.startOfDay(for: date)
    let weekday = calendar.component(.weekday, from: startOfDay)
    let daysFromMonday = (weekday + 5) % 7
    return calendar.date(byAdding: .day, value: -daysFromMonday, to: startOfDay) ?? startOfDay
}
```

而 zh_CN / en_US 的 `calendar.firstWeekday` 默认是 `1`（周日）。用 `.weekOfYear` 判同周，
它对**周日**的归属会与周条实际显示的 7 天不一致 → 出现「周条上今天就在眼前，
箭头却还挂着」。跨年周（12 月底与 1 月初）也会踩同一个坑。

**必须复用 `startOfWeek` 比较周起点。** 这一条是本方案里最容易被「优化」掉的一步，
下面的单测用例 4 和 5 专门用来锁死它。

### 4. 「今天」必须用**语义今天**，与 `jumpToToday` 同源

`jumpToToday`（`HomeView.swift:2145`）和 `startEntranceAnimation`（`:2091`）用的都不是裸
`Date()`，而是：

```swift
calendar.startOfDay(for: DayClock.startOfUserDay(for: Date(), calendar: calendar))
```

即「语义今天」——`VoiceTodoDayStartHour > 0` 时凌晨归前一用户日
（`Protocols/Domain/DayClock.swift:83-106`）。`selectedDate` 的 `@State` 初值
（`HomeView.swift:230`）也是这个口径。

**谓词若用裸 `Date()`**：在「周一凌晨 2 点 + `startHour = 3`」下，语义今天是**上周日**、
属于上一条周条；点箭头跳过去之后，谓词拿 `Date()`（自然日周一）比，仍判「不在本周」——
**箭头永远挂着且点不掉**。

### 5. 不要重置 `collapseProgress`

`HomeView.swift:247` 明确：折叠是「视图密度偏好」，与「看哪天/哪月」正交，
`切月 / jumpToToday 不重置`。现有 `jumpToToday` 本来就没碰它——**保持原样**。
点回今天不该把用户从周条弹回月网格。

---

## 实施

### ① `UI/Home/HomeCalendarState.swift`：`startOfWeek` 去掉 `private`

`startOfWeek(for:calendar:)`（`:318-323`）目前是 `private static`，改为 internal `static`。

它上方 `weekDays` 的注释（`:305-307`）已自称「单一来源：保证『本周是哪 7 天』的算法
不分散在多处」——现在多一个消费方，正好坐实这个定位。**不要新增第二套周边界算法。**

### ② `UI/Home/HomeCalendarState.swift`：新增 static 纯函数

`isViewingCurrentPeriod` 现在是 SwiftUI View 的 `private var`，没法写单元测试。
把判断逻辑挪成 `HomeCalendarState` 上的静态纯函数，与该文件里
`monthDays` / `weekDays` / `startOfWeek` 这批日期工具同处一室：

```swift
/// 标题区是否停在「当前时段」——true 渲染纯月份标题，false 渲染「回到今天」箭头按钮。
///
/// 粒度随日历形态切换：
/// - 折叠成周条（`isWeekStrip == true`）：比较 `selectedDate` 所在周 与 `today` 所在周。
///   周条里 `selectedDate` 才是「正在浏览的周」的唯一来源（`shiftWeek` 移的是它），
///   而 `visibleMonthAnchor` 同月内翻周时不动，用它判断会永远认为「还在当前时段」。
/// - 展开成月网格（`isWeekStrip == false`）：比较 `visibleMonthAnchor` 与 `today` 的月。
///   刻意不看 `selectedDate`——月网格里点选本月某一天不算「离开了当前时段」。
///
/// 同周判断必须走 `startOfWeek`（周一起始，硬编码）而不是
/// `toGranularity: .weekOfYear`：后者读 `calendar.firstWeekday`，
/// 在周日起始的 locale（zh_CN / en_US 默认）下与周条实际显示的 7 天不一致。
///
/// `today` 必须传「语义今天」（`DayClock.startOfUserDay` 折算后的自然日 0 点），
/// 与 `HomeView.jumpToToday` 同源；否则 `startHour > 0` 的凌晨场景下
/// 点了按钮谓词也不翻转，箭头永远挂着。
static func isViewingCurrentPeriod(
    selectedDate: Date,
    visibleMonthAnchor: Date,
    isWeekStrip: Bool,
    today: Date,
    calendar: Calendar
) -> Bool {
    if isWeekStrip {
        return startOfWeek(for: selectedDate, calendar: calendar)
            == startOfWeek(for: today, calendar: calendar)
    }
    return calendar.isDate(visibleMonthAnchor, equalTo: today, toGranularity: .month)
}
```

### ③ `UI/Home/HomeView.swift`：接上

**新增 `semanticToday` 计算属性**，把 `startEntranceAnimation`（`:2091`）和
`jumpToToday`（`:2145`）里重复了两遍的表达式收成一处，新谓词共用——避免三处口径分叉：

```swift
/// 「语义今天」的自然日 0 点：`startHour > 0` 时凌晨归前一用户日。
/// `selectedDate` 初值（见 @State 声明）/ `startEntranceAnimation` /
/// `jumpToToday` / `isViewingCurrentPeriod` 共用同一口径。
private var semanticToday: Date {
    calendar.startOfDay(for: DayClock.startOfUserDay(for: Date(), calendar: calendar))
}
```

然后把 `:2091` 和 `:2145` 那两行改成用 `semanticToday`。

**新增 `isWeekStripActive`**：

```swift
/// 日历区当前是否呈现为周条（而非整月网格）。
/// 0.5 阈值是本文件既有约定：命中层切换（月网格 / 周条 `allowsHitTesting`）
/// 与首次下拉引导的触发条件都用它。
private var isWeekStripActive: Bool {
    selectedBottomTab == .calendar && collapseProgress > 0.5
}
```

> 0.5 这个阈值不是随手选的：`HomeView.swift:1218` 和 `:1267` 用它切换月网格 / 周条
> 两层的命中，`:262` 的下拉引导开关也用它。**沿用，不要另选阈值。**

**`isViewingCurrentPeriod`（`:741`）改为转发**，并修正那句名不副实的注释：

```swift
/// 当前浏览的时段是否就是今天所在的时段。
/// 折叠成周条时按「周」判断，展开成月网格时按「月」判断——
/// 两种形态下都不看选中的具体某天。判断逻辑见
/// `HomeCalendarState.isViewingCurrentPeriod`（纯函数，可单测）。
private var isViewingCurrentPeriod: Bool {
    HomeCalendarState.isViewingCurrentPeriod(
        selectedDate: selectedDate,
        visibleMonthAnchor: visibleMonthAnchor,
        isWeekStrip: isWeekStripActive,
        today: semanticToday,
        calendar: calendar
    )
}
```

### ④ VoiceOver 标签分形态

现有 `a11y.today_month` 的实际文案是「回到今天所在月份」/「Back to this month」——
**周条形态下这句是错的**。

新增本地化条目 `a11y.today_week`：

| locale | 文案 |
|---|---|
| zh-Hans | 回到今天所在的周 |
| en | Back to this week |

`backToTodayTitleButton` 的 `.accessibilityLabel`（`HomeView.swift:785`）按
`isWeekStripActive` 二选一。

> `Resources/Localizable.xcstrings:3362` 的 `home.back_to_today`
> （`extractionState: stale`，"Back to today" / "回到今天"）是文字胶囊时代的遗留。
> **本次不复活也不删除**——它是文字胶囊语义，和 chevron 不是一回事。

### ⑤ 折叠手势中途的观感

`collapseProgress` 跨过 0.5 时，标题会在「纯 `Text`」和「`Button(Text + chevron)`」
之间切换。

评估：两个分支的 `frame(minHeight: WarmSize.touch, alignment: .center)` 已经对齐
（`:644` vs `:780`），**高度不跳**；宽度上只多出 chevron 的约 16pt，
且 `monthTitleText` 有 `minimumScaleFactor(0.65)` 兜底。

建议给 chevron 挂 `.transition(.opacity)`，切换走 `WarmAnimation.springFast`。

**这一条必须在真机 / 模拟器上跟手拖一遍确认**（见验证清单第 6 条）。
若观感仍有跳动，**退路**是：始终渲染 Button 分支，用 `.opacity` 控制 chevron 显隐
并同步 `.allowsHitTesting`——布局宽度恒定，彻底无跳变。

### ⑥ 可选加分项：折叠态下的 VoiceOver 动作按形态切换

**可以独立成一个提交，主路径不依赖它。**

`HomeView.swift:1425-1434` 的 `.accessibilityActions` 在日历 tab 下**恒定**提供
「上一月 / 下一月」，即使已经折叠成周条——而周条上的可见手势是**翻周**。
也就是说 VoiceOver 用户在周条形态下既翻不了周、也回不了今天。

```swift
.accessibilityActions {
    if selectedBottomTab == .calendar {
        if isWeekStripActive {
            Button(String(localized: "a11y.previous_week")) { shiftWeek(by: -1) }
            Button(String(localized: "a11y.next_week")) { shiftWeek(by: 1) }
            if !isViewingCurrentPeriod {
                Button(String(localized: "a11y.today_week")) { jumpToToday() }
            }
        } else {
            Button(String(localized: "a11y.previous_month")) { shiftPeriod(by: -1) }
            Button(String(localized: "a11y.next_month")) { shiftPeriod(by: 1) }
        }
    }
}
```

再补两条本地化，命名对齐既有的 `a11y.previous_month` / `a11y.next_month`：

| key | zh-Hans | en |
|---|---|---|
| `a11y.previous_week` | 上一周 | Previous Week |
| `a11y.next_week` | 下一周 | Next Week |

改动全在 `HomeView` 内，**`WeekStripCard` 不用动**。

---

## 划到范围外（本次不动）

**周条跨月时标题月份的归属。** 周条可能横跨两个月（如周一 7/28 – 周日 8/3），
而 `visibleMonthAnchor` 只跟着 `selectedDate` 的月走，标题显示的月份可能不是周条上
多数格子的月份。这是既有行为，与本次修复正交；改它会牵动
`.task(id: CalendarRefreshKey)`（`HomeView.swift:1459`）的月度数据加载，风险不成比例。
**留待单独评估。**

**一个预期内的行为变化（不是 bug）**：折叠态改成周粒度后，
「浏览的是本周、但 `visibleMonthAnchor` 已被推到下个月」这种情况不再显示箭头。
这是对的——今天就在周条上摆着。

---

## 要改的文件

| 文件 | 改动 |
|---|---|
| `UI/Home/HomeCalendarState.swift` | `startOfWeek`(`:318`) 去 `private`；新增 `static isViewingCurrentPeriod(...)` |
| `UI/Home/HomeView.swift` | 新增 `semanticToday` / `isWeekStripActive`；`isViewingCurrentPeriod`(`:741`) 转发；`backToTodayTitleButton`(`:785`) a11y 标签分形态；`startEntranceAnimation`(`:2091`) 与 `jumpToToday`(`:2145`) 改用 `semanticToday`；加分项额外改 `.accessibilityActions`(`:1425`) |
| `Resources/Localizable.xcstrings` | 新增 `a11y.today_week`（加分项再加 `a11y.previous_week` / `a11y.next_week`） |
| `VoiceTodoTests/UI/HomeCalendarPeriodVisibilityTests.swift` | 新建 |

---

## 验证

### 单元测试

新建 `VoiceTodoTests/UI/HomeCalendarPeriodVisibilityTests.swift`，沿用
`HomeCalendarStateGroupingTests.swift` 的写法：XCTest + `Calendar(identifier: .gregorian)`，
**`setUp` / `tearDown` 里 `DayClock.appGroupDefaults.removeObject(forKey: DayClock.startHourKey)`
清共享状态**（该文件 `:16` / `:24` 已有此模式，**务必照抄**——`startHour` 存在
App Group `UserDefaults` 里，是跨测试类共享的，不清会污染同 target 的其它测试）。

用固定日期做断言，覆盖：

| # | 场景 | 期望 | 锁的是什么 |
|---|---|---|---|
| 1 | `isWeekStrip: true`，`selectedDate` 与 `today` 同月但差一周 | `false` | **当前 bug 的回归用例** |
| 2 | `isWeekStrip: true`，同周不同天 | `true` | 周条里点选本周其它天不该冒出箭头 |
| 3 | `isWeekStrip: false`，`visibleMonthAnchor` 本月、`selectedDate` 本月另一周 | `true` | 展开态不回归（约束 2） |
| 4 | `var cal = Calendar(identifier: .gregorian); cal.firstWeekday = 1`；`today` 取某个**周日**，`selectedDate` 取同一条周条上的**周一** | `true` | **约束 3**：实现若改用 `.weekOfYear` 此例会红 |
| 5 | 跨年周：12 月底与 1 月初同属一条周一起始的周 | `true` | 同上，`.weekOfYear` 的另一个坑 |
| 6 | `DayClock.setStartHour(3)`，周一 01:30 走 `startOfUserDay` → 语义今天是周日、属上一条周条。断言 `selectedDate = 语义今天` → `true`；`selectedDate = 自然日周一` → `false` | 如左 | **约束 4** |

命令：

```
xcodebuild test -scheme VoiceTodo \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:VoiceTodoTests/HomeCalendarPeriodVisibilityTests
```

项目由 XcodeGen 从 `project.yml` 生成，新文件按目录自动纳入 target；
`.xcodeproj` 未跟随时先跑 `./prepare_xcode_project.sh` 或 `xcodegen generate`。

### 手动验证（不可省——单测覆盖不到手势和观感）

1. 进日历 tab，下拉折叠成周条。
2. 左右滑到**本月内**的另一周 → 月份标题后应出现 `chevron.left`。
   **修复前这一步必然不出现，是最关键的一条。**
3. 点箭头 → 弹簧动画跳回今天所在周，今天格高亮，箭头消失，
   且**仍保持周条形态**（`collapseProgress` 不被重置）。
4. 滑到别的月 → 标题月份跟着变，箭头照常出现并可用（原有行为不回归）。
5. 上拉展开成月网格 → 点本月任意一天，箭头**不**出现；滑到别的月，箭头出现
   （原有行为不回归）。
6. 折叠手势跟手拖到 0.5 附近来回蹭 → 标题不应有明显闪跳（对应实施 ⑤）。
7. VoiceOver 打开：周条形态下聚焦标题按钮应念「回到今天所在的周」，
   月网格形态下念「回到今天所在月份」。做了加分项则再确认 rotor 里的动作在周条形态下
   是「上一周 / 下一周 / 回到今天所在的周」。
8. 英文 locale + 长月份名（September）下重跑 2–4，确认月份名没被挤窄（对应约束 1）。
