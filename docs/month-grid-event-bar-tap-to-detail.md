# 月历格子事件条 → 点击打开待办详情

> 状态：**未实施**。评估结论：不麻烦，核心约 30 行、半天可完成。
> 相关文件：`UI/Home/HomeMonthGridButton.swift`、`UI/Home/HomeMonthHeaderView.swift`、
> `UI/Home/HomeView.swift`、`Resources/Localizable.xcstrings`
>
> **基线**：本文所有行号对齐 `818536a`（*Merge branch 'xiahuayue' — 折叠态下 List
> 到顶下滑也能展开月网格*）。该合并改动了 `HomeView.swift`、`HomeMonthHeaderView.swift`、
> `SimultaneousDragGesture.swift`，行号已相应校准过一遍。
> 若实施时 main 又前进了，**先按符号名（函数名 / 属性名 / 注释原文）定位，行号仅作参考**。
> `HomeMonthGridButton.swift`、`WarmTodoCard.swift`、`HomeSelectedDayListView.swift`
> 自本方案写成以来未被改动。

---

## 需求

Calendar tab 展开态的月历里，每个日期格子会渲染当天的待办概览条（`eventBar`），
但它们目前是**纯展示**的：整格是一个 `Button`，点击只触发 `onSelect(date)` 选中当天，
事件条本身没有任何交互。希望点击某一条能直接跳到该待办的详情页。

## 为什么值得做

展开态（`collapseProgress == 0`）下月网格占满 95% 高度，**下方任务列表根本不渲染**
（`HomeView.swift:1059-1072`）。所以用户在展开态看到某条任务时，
必须「上滑折叠 → 在列表里找到它 → 点开」才能查看/编辑，绕了一大圈。

反过来说，展开态下「选中当天」的**收益本来就低**——列表不渲染，
点了只有日期数字胶囊变实心。这个观察在后面的命中区取舍里很关键。

---

## 评估：为什么便宜

三件事都已就位，只需要接一个回调 + 包一层嵌套 `Button`。

### 1. 数据现成

`eventBar` 已持有 `occurrence: TodoOccurrenceData`（`HomeMonthGridButton.swift:128`），
其 `.todo` 就是完整的 `TodoItemData`（`Protocols/Models.swift:83-103`），
正是 `TodoDetailView` 需要的类型。不需要按 id 回查，不需要改数据层。

### 2. 展示通道现成

```swift
// HomeView.swift:253
@State private var selectedTodo: TodoItemData?

// HomeView.swift:415-420
.fullScreenCover(item: $selectedTodo) { todo in
    NavigationStack {
        TodoDetailView(store: store, todo: todo)
            .environmentObject(coordinator)
    }
}
```

新回调只要做 `selectedTodo = $0`，与 `HomeView.swift:1080` 传给
`HomeSelectedDayListView` 的 `onOpenTodo` 完全同构。

### 3. 嵌套 Button 模式在本仓库已有生产先例

`HomeSelectedDayListView.swift:388-404` 用 `Button(action:) { WarmTodoCard(...) }` 包裹，
而 `WarmTodoCard` 内部还有自己的 checkbox `Button`（`WarmTodoCard.swift:229-236`）。
`WarmTodoCard.swift:326-333` 的注释明确记录了两条结论：

- SwiftUI 把 tap 派发给**最内层** Button，不会误触发外层 row tap；
- **必须用 `Button` 而不是 `.onTapGesture`**——iOS 26 FB18199844：顶层 `onTapGesture`
  会吞掉 List swipeActions 的删除按钮 tap。

所以本改动是在复用一个已验证过的模式，不是新开路。

---

## 实施方案

### 1. `UI/Home/HomeMonthGridButton.swift`

**1a. 新增参数**（属性列表末尾，紧跟第 27 行 `maxVisibleEvents`）：

```swift
/// 点击单条事件条 → 打开该 todo 详情。nil = 事件条不可点，整格点击仍走 onSelect。
/// 与 WarmTodoCard.contextMenu 同策略（WarmTodoCard.swift:334-336）：
/// 调用方不注入 callback 时不挂 Button，避免空 action 的 Button 吞掉整格 tap。
var onOpenTodo: ((TodoItemData) -> Void)? = nil
```

必须放在**最后**——Swift memberwise init 的实参顺序须与声明顺序一致，
放末尾则 `HomeMonthHeaderView.swift:126-132` 的调用只需追加一行。

**1b. body 的 `ForEach`（45-47 行）改调包装方法**，并在 `eventBar` 上方（128 行前）新增：

```swift
/// 事件条的交互包装。onOpenTodo == nil 时返回裸 eventBar——
/// 空 action 的 Button 会吞掉 tap，让整格 onSelect 在事件条区域失效。
@ViewBuilder
private func eventBarRow(_ occurrence: TodoOccurrenceData, idx: Int, isLast: Bool, overflow: Int?) -> some View {
    if let onOpenTodo {
        Button {
            HapticFeedback.light()   // 24pt 小目标，触觉确认命中（UI/Shared/Haptics.swift:30）
            onOpenTodo(occurrence.todo)
        } label: {
            eventBar(occurrence, isLast: isLast, overflow: overflow)
        }
        .buttonStyle(.plain)
        // 已完成条 bg = Color.clear，不加 contentShape 时命中区会退化到文字包围盒。
        // inset(by: 2) 把条间死区从 2pt 拓到 6pt，减少误触相邻条（见「命中区尺寸」一节）。
        .contentShape(Rectangle().inset(by: 2))
        .accessibilityIdentifier("MonthGridBar_\(TodoOccurrenceData.dayKey(for: dayState.date))_\(idx)")
    } else {
        eventBar(occurrence, isLast: isLast, overflow: overflow)
    }
}
```

`eventBar` 本体（128-173 行）**完全不动**。

关于两个外层修饰符：
- 第 55 行 `.buttonStyle(.plain)` 通过 environment 传到内层，内层重申只为可读性。
- 第 56 行 `.contentShape(Rectangle())` 定义**外层自身**的命中形状（让 padding / `Spacer`
  区域可点），在命中顺序上位于 label 内容**之后**，所以内层 Button 先被命中。
  这正是 WarmTodoCard 的先例结构。

**1c. 不联动选中日期**：只调 `onOpenTodo`，不调 `onSelect`。
`HomeView.selectDay`（`HomeView.swift:1323-1332`）在 `withAnimation` 里改
`selectedDate` / `visibleMonthAnchor` / 折叠 unscheduled drawer，
与同时 present 的 `fullScreenCover` 叠加会产生无谓动画和 dismiss 时的跳动。
这也与 `HomeSelectedDayListView.occurrenceRow` 的行为一致（打开时不重选日期）。

### 2. 回调透传（3 行）

| 文件 | 改动 |
|---|---|
| `HomeMonthHeaderView.swift` | 第 16 行 `onShiftPeriod` 后加 `var onOpenTodo: ((TodoItemData) -> Void)? = nil`；`dayCell`（122-133 行）的 `HomeMonthGridButton(...)` 追加 `onOpenTodo: onOpenTodo` |
| `HomeView.swift:950-958` | `HomeMonthHeaderView(...)` 追加 `onOpenTodo: { selectedTodo = $0 }`（放在 `availableHeight` 前，顺序须与声明一致） |

**`WeekStripCard` 不需要改**：它的 `dayCell`（`HomeMonthHeaderView.swift:536-593`）
渲染的是**按分类去重**的 `Circle()` 圆点，一个圆点可能代表 3 条任务，没有 1:1 的 todo 目标。
且折叠态正是 `HomeSelectedDayListView` 可见可点的状态，那里已有 `onOpenTodo`。

### 3. 无障碍（必做，否则是回归）

`HomeMonthGridButton.swift:57` 的 `.accessibilityElement(children: .ignore)` 会把整格压成
单个元素，**嵌套 Button 会被完全移出 AX 树**——VoiceOver / Switch Control / Voice Control /
全键盘访问用户将无路可达。在 `.accessibilityHint`（59 行）后、
`.accessibilityAddTraits`（60 行）前插入：

```swift
// 事件条是嵌套 Button，被 accessibilityElement(children: .ignore) 从 AX 树里吞掉，
// VoiceOver / Switch Control 无法直达。用 custom action 补一条等价路径：
// 每条可见事件一个「打开 <标题>」动作（与视觉可见条一一对应；
// overflow 的 N 条视觉上也点不到，a11y 保持同口径，不额外暴露）。
.accessibilityActions {
    if let onOpenTodo {
        ForEach(visible, id: \.id) { occurrence in
            Button(String(format: String(localized: "a11y.day.open_todo"), occurrence.todo.title)) {
                onOpenTodo(occurrence.todo)
            }
        }
    }
}
```

`visible` 已是 body 内的局部 `let`（第 38 行）。`accessibilityActions(_:)` 是 iOS 16+，
项目 target iOS 17+；仓库已在 `HomeMonthHeaderView.swift:529` 用过单动作形式。

**为什么选 custom actions，而不是让每条 bar 成为独立 AX 元素**

| | custom actions | 每条 bar 独立元素 |
|---|---|---|
| 整屏 AX 元素数 | 42（不变） | 42 + 最多约 120 |
| 横扫月历的 swipe 成本 | 不变 | 差 3-4 倍 |
| 「打开任务」的可发现性 | 仅 rotor（VoiceOver 播报「有可用操作」） | 直接，体验更好 |
| 保留合成的当日摘要（`gridAccessibilityLabel`，231-244 行） | 是 | 需重做 |
| 改动量 | ~8 行 | 重构 body + 标签策略 |

第 57 行的 `.ignore` 是有意的设计决策（月历是**扫视**界面，42 个元素已经不少）。
让「加个点击」把这个决策作为副作用推翻，不划算。
现有的溢出播报（第 241 行）已经告诉用户还有多少条。
若日后证明 rotor 可发现性不够，再升级成独立元素方案。

**新增本地化 key**（`Resources/Localizable.xcstrings`，en + zh-Hans 都要，
`"state": "translated"`，按字母序插在 `a11y.day.no_todo` 与 `a11y.day.out_of_month` 之间）：

| key | en | zh-Hans |
|---|---|---|
| `a11y.day.open_todo` | `Open %@` | `打开%@` |

用法同第 241 行与 `WarmTodoCard.swift:27`：`String(format: String(localized:), title)`。
`a11y.day.hint`（"Tap to select this day"）保持不变——整格点击仍是选中当天，
VoiceOver 会自动追加「有可用操作」。

---

## 命中区尺寸：唯一需要留意的真问题

**几何**：`gridBarHeight = 24pt`（`HomeMonthHeaderView.swift:252`），条间距 2pt。
393pt 宽的 iPhone 上列宽 `(393 − 2×4 − 6×2) / 7 ≈ 53pt`。
所以每条约 **53 × 24pt，纵向明显低于 Apple HIG 的 44pt 最小命中区**。

两种误触，严重程度差很多：

**① 误触相邻条（轻微）**
条间只有 2pt。手指接触面约 40pt，系统取单点命中，瞄准第 2 条时略偏上就打开了第 1 条。
后果是多打开一次详情，一次 dismiss 即可恢复。

**② 密集格子里「选中当天」几乎点不到（严重）**
分配器把行高压到 `need(shown) = 20 + shown×24 + (shown−1)×2`
（`HomeMonthHeaderView.swift:319-321`），其中 `gridCellChrome = 20` 正是日期数字行的预算。
满额格子里 `Spacer(minLength: 0)`（`HomeMonthGridButton.swift:48`）塌成 ≈0，
可选中当天的区域只剩 **~14pt 的日期数字行 + 2pt 条间隙**。
也就是说：**任务最多的格子——恰恰是用户最想选中的格子——点「这一天」会几乎必然打开某条任务。**
目前是 100% 的格子面积选中当天，改后在密集周可能掉到约 25% 的格子高度。

### 建议：先按 M1 + M5 落地

- **M1 接受现状**。日期数字行仍是选中当天的目标，这与 Apple Calendar 的心智一致。
  更重要的是前面「为什么值得做」里的观察：**展开态下选中当天的收益本来就低**
  （列表不渲染），而直接点开任务的收益高得多。这个取舍是划算的。
- **M5 收窄命中区**。内层用 `.contentShape(Rectangle().inset(by: 2))`，
  把条间死区从 2pt 拓到 6pt，显著减少 ① 类误触。零成本，已写进上面的代码。

### 若真机验证后发现选中当天太难，按此优先级回退

- **M3 两段式激活**：仅当 `dayState.isSelected` 时事件条才可点
  （首点选中当天，再点条打开）。完整保住选中当天，纯交互改动、约 5 行，不碰布局。
  代价是可发现性和多一次点击。
- **M2 预留选中条带** / **M6 加高 `gridBarHeight`**：会动到
  `HomeLayoutMetrics.allocateRowHeights` 的 `gridCellChrome`、`need()`
  和 Pass 4 的 `precondition`（`HomeMonthHeaderView.swift:435`），
  并重新打开 `month-grid-known-issues.md` 记录的回归面。
  **这是另一个 1-2 天的独立改动，不建议与本需求捆绑。**

---

## 已知取舍（无需额外改动，但要清楚）

1. **`+N` 徽标在最后一条内**。`overflowText` 与标题拼在同一个 `Text`
   （`HomeMonthGridButton.swift:149-161`），所以点 "+3" 会打开最后那条任务。
   拆出来需要改成 HStack，而 124-127 行的注释说明这个拼接正是为了在 ~52pt 列宽下
   保住两行标题截断。建议**接受 + 加一行注释**。VoiceOver 侧无回归（241 行已朗读溢出数）。
2. **重复任务打开的是「系列」而非「当天那一次」**。`occurrence.todo` 是系列本体。
   与 `HomeSelectedDayListView.swift:389` 行为一致，不是本次新引入的问题。
3. **跨月补齐格（`isCurrentMonth == false`）的条也会变可点**。
   `dropDestination` 明确拒绝这些格（66-69 行），但打开详情是只读、无破坏性的，建议允许。
   若要与 drop 对称，把包装条件改成 `if let onOpenTodo, dayState.isCurrentMonth`。

---

## 验证

### 构建

`swift test` 只覆盖 `VoiceTodoTests/Protocols`（`Package.swift` 的 target 只含 `Protocols`），
**不会编译**这些 UI 文件。`.xcodeproj` 未入库，需先生成：

```bash
xcodegen generate      # 或 ./prepare_xcode_project.sh
xcodebuild -scheme VoiceTodo -destination 'platform=iOS Simulator,name=iPhone 16' build
```

无新增源文件，`project.yml` / `.xcode_main_app_files.txt` 无需改。

### 单元测试

本改动是纯视图组合，没有逻辑下沉到可测类型，仓库也无 ViewInspector 依赖。
**不要为此硬造测试。**

### 手动验收清单（真正的验证在这里）

1. 点事件条 → 打开对应 `TodoDetailView`；关闭后回到同一月份，`selectedDate` 未变。
2. 点日期数字 / 条下方空白 → 仍选中当天，不打开详情。**在满额格子上重测**（见命中区一节）。
3. 点已完成条（删除线 + `Color.clear` 背景）→ 能打开，验证内层 `contentShape` 生效。
4. **从事件条上起手竖向拖** → 网格正常折叠，松手不误开详情。
5. 从事件条上起手横向拖 → 正常翻月。
6. 从 Unscheduled 拖任务悬停到事件条上 → 格子高亮环出现，drop 落到正确日期。
7. 折叠到 `collapseProgress > 0.5` → 事件条不可点。
8. VoiceOver：聚焦有任务的格子 → 听到合成标签；上下滑 → 按视觉顺序枚举「打开 <标题>」；双击打开。
9. 切 zh-Hans 重跑 1-8，确认动作名无 `%@` 泄漏。

### 第 4-7 条的静态分析结论：都不会破，但仍需真机过一遍

- **竖向折叠手势**用的是 `SimultaneousDragGesture`（`UI/Shared/SimultaneousDragGesture.swift:56`），
  本质是 `UIPanGestureRecognizer`，挂在**祖先视图**上。UIKit 会把子视图上的触摸路由给
  祖先 recognizer，**与命中到哪个子视图无关**。而该区域**本来就已经被外层格子 Button 覆盖**，
  加一个内层 Button 不改变这条路由。横向翻月同理（`HomeMonthHeaderView.swift:106-114`）。

  注意该文件近期被重写过（见下方「基线」）：现在 `shouldBegin` 里有**方向门控**
  （非匹配方向的触摸直接让本 recognizer `.failed`，把机会让给子视图），
  且 `shouldRecognizeSimultaneouslyWith` 对 `UIScrollView` 的 pan **默认返回 false**，
  只有调用方通过 `allowSimultaneousWithScrollViewPan` 显式选择加入才共存。
  这些都不改变上面的结论——方向门控与「命中到哪个子视图」正交——
  但让手动验收第 4、5 条更有必要真机过一遍。
- **`dropDestination`**（`HomeMonthGridButton.swift:62-76`）挂在外层格子上，
  内层 Button 不注册任何 drop interaction，拖拽悬停仍命中格子。
- **`.allowsHitTesting(collapseProgress <= 0.5)`**（`HomeView.swift:1015`）作用于整个子树，
  嵌套 Button 自动跟随。`HomeView.swift:1007-1009` 记录的
  「任意 progress 下有且仅有一层可点击」不变量自动保持。

### UI 测试：建议跳过

因为第 57 行的 `.ignore`，事件条不在 AX 树里，XCUITest **无法**用
`app.buttons["MonthGridBar_..."]` 查询，只能按坐标点击
（`cell.coordinate(withNormalizedOffset:).tap()` + 断言 `TodoDetailCloseButton` 出现）。
这种测试天生脆弱，且 `CalendarHomeUITests.swift:17-25` 的注释已记录上一个月历格测试
被删除的原因。性价比低。
（`MonthGridBar_...` identifier 仍值得加——`po` / Accessibility Inspector 调试用得上。）

---

## 工作量

| 部分 | 量 | 风险 |
|---|---|---|
| 核心（新参数 + `eventBarRow` 包装 + 透传） | ~18 行 | 低——同仓库有直接先例 |
| 无障碍 + 本地化 | ~10 行 + 1 个 key | 低 |
| **验证嵌套 Button 在外层 `contentShape` 下的命中派发** | 0 行 | **中**——无法静态证明，需模拟器。若失败，退路是把 `.contentShape` 从 Button 移到 label 的 VStack 上，或去掉改依赖背景 |
| 交互回归手测（折叠 / 翻月 / drop / 命中门控） | 0 行 | 低-中——约 20 分钟 |
| 命中区缓解 M1 + M5 | ~1 行 | 低 |

**合计：半天。**

唯一可能显著膨胀的是命中区方案：若最终必须走 M2/M6，会牵进行高分配器，
变成 1-2 天且有真实回归面。因此建议**先按 M1+M5 出手，真机看效果再决定**。
