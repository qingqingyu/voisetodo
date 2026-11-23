# 任务书:月历「已完成让位」+ 长按「移到稍后」

> 2026-11-23 起草。本文档是**交给执行者的任务书**,不是结果。
> 基线:`main` @ `2d3def8`(2026-11-21)。从这个提交拉分支开发。
> 完成后把结果写进 `docs/month-grid-completed-and-move-to-later-results.md`(格式见 §5),交回审查。
> 两个任务互不依赖,**分两个提交**(任务一一个、任务二一个),方便分别审查和回滚。

---

## 0. 背景(执行前必读)

### 0.1 用户反馈

1. 月历里已完成的任务占地方,今天的待办反而看不到。截图里 16 号那周 5 条划掉的任务
   把行高撑起来,23 号(今天,7 件未完成)那格只露出 1 条,而且看不到"还有几件"的提示。
2. 长按待办想直接扔回「稍后」,现在长按菜单只有「移到明天」和改时段。

### 0.2 已核实的原因(任务一)

| # | 原因 | 位置 |
|---|---|---|
| 1 | 行高分配按**当天全部事项数**算,已完成也计入需求。已完成多的周会在注水分配(尤其 Pass 3a「隐藏最多的周优先」)里抢走高度 | `UI/Home/HomeMonthHeaderView.swift:46-51`(`eventsPerDay` 用 `.count`) |
| 2 | 「+N」用 `Text + Text` 拼在最后一条标题尾部,整条 `.lineLimit(2)` + `.truncationMode(.tail)`。标题一长,「+N」被省略号吞掉 | `UI/Home/HomeMonthGridButton.swift:223-241` |
| 3 | `maxVisibleEvents == 0` 时连「+N」都不显示 | `UI/Home/HomeMonthGridButton.swift:264` |

补充:今天那格还会注入「稍后」+「待定日期」两组无日期任务(`UI/Home/HomeCalendarState.swift:305-330`),
所以今天格的需求天然偏大。格内排序已经是「未完成在前」(`HomeMonthGridButton.swift:273`),这条不用改。

### 0.3 「稍后」分组的口径(任务二必读)

`UI/Home/HomeCalendarState.swift`:

- 「稍后」(`unscheduledTodos`):`dueDate == nil && recurrenceRule == nil && extractionOutcome == .parsed && abandonedAt == nil && !isCompleted`,**且无时间信号**。
- 「待定日期」(`pendingDateTodos`):同上,但**有时间信号**。
- 时间信号 = `timeBucket != nil` 或 `dueHint` 去空白后非空(`hasTimeSignal`,第 161 行)。

所以「移到稍后」必须**同时清掉 dueDate、timeBucket、dueHint**,只清日期会落进「待定日期」而不是「稍后」。
这和现有的 `unassignTodoFromDay`(`HomeView.swift:3113`,拖回抽屉,**保留** timeBucket)语义不同,不要直接复用那个函数。

---

## 1. 任务一:月历里已完成的任务让位(方案 A)

### 1.1 目标行为

- 每周行高**先按未完成数**分配,剩余空间再用来显示已完成的任务。
- 空间不够时,先缩已完成的;只要还有空间,未完成的都应显示出来。
- 「+N」(N = 未显示的**未完成**数,口径不变)单独显示,**任何情况下不被截断**,`maxVisibleEvents == 0` 时也要显示。
- 所有周都只有未完成任务(没有已完成)时,分配结果必须和改动前**完全一致**(回归保护)。

### 1.2 改分配器 `HomeLayoutMetrics.allocateRowHeights`(`HomeMonthHeaderView.swift:288`)

**输入**:把 `eventsPerDay: [[Int]]` 改成每天两个数,例如:

```swift
struct DayDemand { let open: Int; let total: Int }   // open = 未完成数, total = 全部
static func allocateRowHeights(demandPerDay: [[DayDemand]], budgetHeight: CGFloat)
    -> (rowHeights: [CGFloat], barsShown: [Int])
```

(命名可以自定,但两个数都要传。)调用方 `allocation`(第 45 行)用 `occ.isCompleted` 分别计数。

**算法**:两层需求,未完成层先吃满,再给全部层。

- `openDemand[i]` = 该周各天 `open` 的最大值,`totalDemand[i]` = 该周各天 `total` 的最大值,都受 `gridMaxBarsPerCellHardLimit` 截断。
- `estimatedCap` / `initialDemand`:改用 `openDemand` 计算。
- **Pass 1、Pass 2**:逻辑不变,demand 用 `initialDemand`(来自 `openDemand`)。Pass 2 的 tie-break `hidden` 也只算未完成的隐藏数。
- **Pass 3a**:拆成两段,复用同一个循环体:
  1. 第一段 demand = `openDemand`(未完成层先吃满);
  2. 第二段 demand = `totalDemand`(剩余 slack 再给已完成)。
  两段的选周规则都和原来一样(隐藏最多优先,并列取 shown 少的,再并列取 index 小的)。
- **Pass 3b**:`weeksWithHidden` 按 `totalDemand` 判断(行为和原来一致)。
- **Pass 4**:`min(actualCap, totalDemand[i])`,`precondition` 不变式保留。

**为什么这样能保证回归**:没有已完成时 `openDemand == totalDemand`,第二段 3a 立即退出,其余各 pass 与原来逐行等价。

`HomeMonthGridButton.swift` 第 22-26 行、`HomeMonthHeaderView.swift` 第 268-287 行的注释要同步更新,写清「两层需求」。

### 1.3 改格子 `HomeMonthGridButton`

1. **「+N」挪出事件条**:从 `eventBarRow` 里删掉 `overflowText` 拼接(第 223-229 行),`eventBarRow` 不再需要 `isLast` / `overflow` 参数。
2. **「+N」放到日数字那一行的右侧**:`dayNumberView` 外层改成 `ZStack` 或 `.overlay(alignment: .trailing)`,
   日数字仍居中,「+N」靠右,`WarmFont.mono(8)`、`WarmTheme.textSecondary`、`.lineLimit(1)`、`.fixedSize()`。
   **不能增加这一行的高度**(分配器把它算在 `gridCellChrome = 20` 里)。今天/选中的橙色胶囊不受影响。
3. **`maxVisibleEvents == 0` 时**:事件条为空,但「+N」照常显示(N = 全部未完成数)。删掉第 260-264 行注释里"无处渲染"的说法。
4. **VoiceOver**:`gridAccessibilityLabel` 里补读溢出数的逻辑保留,注释(第 311-313 行)改成「+N 在日数字行」。
5. `slicedEvents()` 抽成**可测试的 static 纯函数**(输入 occurrences + maxVisibleEvents,输出 visible + overflow),view 里调用它。排序规则不动。

### 1.4 不要做

- 不改已完成的视觉(灰底、灰字、删除线)。
- 不改格内排序规则、不改「今天格注入稍后/待定日期」的逻辑。
- 不改 `gridBarHeight`、`gridCellChrome` 等常量。
- 不改周视图(`WeekStripCard`)。

### 1.5 测试(新文件 `VoiceTodoTests/UI/HomeMonthAllocatorTests.swift`)

分配器是 static 纯函数,直接测。**改代码前先跑一遍旧函数,把下面第 1 组的输出记下来写成期望值。**

| # | 场景 | 断言 |
|---|---|---|
| 1 | 回归:3 组只含未完成的输入(4 周月、5 周月、6 周月,各有忙周和空周),total == open | 行高、条数与改动前完全一致 |
| 2 | 复现截图:5 周月,第 3 周某天 5 条全已完成,第 4 周某天 7 条未完成,预算按 iPhone 15 量级(可取 ~480pt) | 第 4 周条数 ≥ 改动前;第 4 周条数 ≥ 第 3 周;第 4 周条数 == min(7, 预算能装下的上限) |
| 3 | 只有已完成的周 + 空余预算充足 | 已完成的照样能显示出来(第二段 3a 生效) |
| 4 | 预算极小(装不下 1 条) | 不崩溃,`barsShown` 全 0 |
| 5 | 任意输入(可用几组随机数) | `need(barsShown[i]) <= rowHeights[i]`;`barsShown[i] <= totalDemand[i]`;行高总和 + 行间距 ≈ 预算 |

`slicedEvents` 抽出的函数也补测试:

| # | 场景 | 断言 |
|---|---|---|
| 6 | 7 未完成 + 2 已完成,maxVisible = 4 | visible 是 4 条未完成,overflow = 3 |
| 7 | 2 未完成 + 5 已完成,maxVisible = 4 | visible = 2 未完成 + 2 已完成,overflow = nil 或 0 |
| 8 | 3 未完成,maxVisible = 0 | visible 为空,overflow = 3 |

### 1.6 真机/模拟器验收

在模拟器造截图那种数据(某周 5 条已完成、今天 7 件未完成,标题故意取长),截图对比改前改后,附在结果文档里:
- 今天那格未完成的条数明显变多;
- 「+N」完整显示在日数字右侧,没有被截断;
- 6 周的月份、今天被选中/未选中两种状态各截一张。

---

## 2. 任务二:长按菜单加「移到稍后」

### 2.1 目标行为

- 长按菜单里,在「移到明天」**下面**加一项「移到稍后」。
- 点了以后:清掉 `dueDate`、`hasDueTime`、`timeBucket`、`dueHint`,任务进「稍后」分组;弹 toast「"xxx" 已移回稍后」。
- 以下情况**不显示**这一项:
  1. 已经在「稍后」里(`dueDate == nil` 且无时间信号);
  2. 重复任务(`recurrenceRule != nil`)——本期不做,以后另定语义;
  3. 已完成的任务;
  4. `extractionOutcome != .parsed` 的任务(清日期后会进「没能识别」而不是「稍后」)。
- 「待定日期」里的任务(有 timeBucket/dueHint、没日期)**应该显示**这一项:点了会把时段/提示清掉,进「稍后」。
  但这一组现在用的是 `PendingDateTodoRow`,没有长按菜单——**本期不给它加菜单**,只在结果文档里注明。

### 2.2 改动点

1. **判定函数**:在 `HomeCalendarState` 里加 static 函数,和 `hasTimeSignal` / `isLaterActiveTodo` 放一起,作为唯一口径:

   ```swift
   static func canMoveToLater(_ todo: TodoItemData) -> Bool
   // !isCompleted && abandonedAt == nil && recurrenceRule == nil
   // && extractionOutcome == .parsed
   // && !(dueDate == nil && !hasTimeSignal(todo))
   ```

2. **`UI/Home/WarmTodoCard.swift`**:
   - 加 `var onMoveToLater: (() -> Void)? = nil`(放在 `onMoveToTomorrow` 下面,注释风格对齐)。
   - `.contextMenu` 里,在「移到明天」按钮后面加:`if let onMoveToLater, HomeCalendarState.canMoveToLater(todo)`
     → `Button { HapticFeedback.light(); onMoveToLater() } label: { Label(String(localized: "card.menu.move_to_later"), systemImage: "tray") }`。
   - 更新第 422 行附近的注释。

3. **`UI/Home/HomeSelectedDayListView.swift`**:
   - 加 `let onMoveToLater: (UUID) -> Void`(放在 `onMoveToTomorrow` 下面)。
   - 第 510 行(`unscheduledTodoCardBase`)和第 557 行(`occurrenceRow`)都传 `onMoveToLater: { onMoveToLater(<id>) }`。
     「稍后」组自身的行会被 `canMoveToLater` 过滤掉,不需要在调用点再判断。

4. **`UI/Home/HomeView.swift`**:
   - 第 1919 行附近构造 `HomeSelectedDayListView` 时传 `onMoveToLater: { id in moveTodoToLater(id) }`。
   - 新增 `private func moveTodoToLater(_ todoId: UUID)`,放在 `moveTodoToTomorrow` 后面,结构照抄它:
     - `store.findTodo(by:)` 找不到 → `VoiceTodoLog.ui.warning("home.move_to_later.todo_not_found ...")` 返回。
     - **防御**:`guard HomeCalendarState.canMoveToLater(todo)`,不满足就 warning 日志后返回(UI 已过滤,这里兜底)。
     - `coordinator.updateTodoDetail(todoId, update: TodoDetailUpdate(title: todo.title, detail: todo.detail, category: nil, priority: nil, dueDate: nil, hasDueTime: false, timeBucket: nil, dueHint: "", recurrenceRule: todo.recurrenceRule))`。
       `reminderOffsetMinutes`、`eventEndDate` 用默认值即可(无日期时会被归一化清掉)。
     - 成功:`occurrenceRevision += 1`,toast 复用 `home.unassigned_from_day`(三语文案已是「已移回稍后」)。
     - 失败:error 日志 `home.move_to_later.failed`,toast `ErrorMessages.storageError`。
     - doc 注释写清:和 `unassignTodoFromDay` 的区别是**清 timeBucket 和 dueHint**,原因见 §0.3。

5. **`Resources/Localizable.xcstrings`**:新增 `card.menu.move_to_later`:
   - en:`Move to Later`
   - ja:`「後で」に移動`
   - zh-Hans:`移到稍后`
   (和分组标题 `home.undated.section` 的 Later / 後で / 稍后 对齐。)用 Xcode 或保持现有 JSON 格式手改,不要整文件重排。

6. `UI/Home/UnscheduledDrawer.swift` 目前没有被任何地方实例化,**不用改**;如果编译要求补参数再补,传空实现即可。

### 2.3 不要做

- 不改「移到明天」的行为。
- 不给 `PendingDateTodoRow` 加长按菜单。
- 不支持重复任务。

### 2.4 测试

在 `VoiceTodoTests/UI/HomeCalendarStateGroupingTests.swift` 里加 `canMoveToLater` 的用例:

| # | 输入 | 期望 |
|---|---|---|
| 1 | 有日期、未完成、不重复、parsed | true |
| 2 | 无日期、有 timeBucket(待定日期) | true |
| 3 | 无日期、只有 dueHint「下周」 | true |
| 4 | 无日期、无时间信号(已在稍后) | false |
| 5 | 无日期、dueHint 只有空白 | false |
| 6 | 有 recurrenceRule | false |
| 7 | 已完成 | false |
| 8 | extractionOutcome = .rawFallback | false |

再加一个分组用例:把用例 1 的任务按 `moveTodoToLater` 的字段改法构造出来(dueDate nil、timeBucket nil、dueHint ""),
喂给 `HomeCalendarState`,断言它出现在 `unscheduledTodos`、不在 `pendingDateTodos`。

### 2.5 模拟器验收

截图附在结果文档:
- 今天列表里一条有日期的任务长按,菜单里「移到稍后」在「移到明天」下面;点了以后任务出现在「稍后」组,toast 正常。
- 「稍后」组里的任务长按,菜单里没有「移到稍后」。
- 重复任务长按,菜单里没有「移到稍后」。
- 切到日文,文案是「後で」に移動。

---

## 3. 通用要求

- 按项目现有风格写中文注释,注明改动原因和日期(2026-11)。
- 跑完整测试:`xcodebuild test`(scheme 和 destination 参照 `TESTING.md`),全部通过才交。失败的测试不要跳过、不要删。
- 不要碰与本任务无关的文件;不要改 `project.yml` 以外的工程配置(新测试文件如需登记,按 `project.yml` / XcodeGen 的现有方式)。

## 4. 已知的旁支问题(不要修,只记录)

- `moveTodoToTomorrow`(`HomeView.swift:3034`)构造 `TodoDetailUpdate` 时没传 `eventEndDate`,默认 nil,
  可能把跨天事件的结束日清掉。不在本任务范围,如果验证属实,在结果文档里写一句即可。

## 5. 结果文档格式(`docs/month-grid-completed-and-move-to-later-results.md`)

1. 两个提交的 hash 和一句话说明。
2. 每个改动文件 + 改了什么(一两句)。
3. 测试:新增用例列表、`xcodebuild test` 的最终结果(通过数/失败数)。
4. 任务一 §1.5 第 1 组:改动前记录的期望值是怎么得到的。
5. 截图(任务一改前/改后,任务二各场景)。
6. 和任务书不一致的地方、自己做的判断、没做完的部分,逐条写明。
