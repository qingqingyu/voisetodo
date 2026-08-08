# 方案：确认页成功反馈改为「落进列表」

> 状态：**已实施**（`75645aa feat(confirm-sheet): 删成功页改为「列表 stagger + toast」反馈`）。
> 「现象 / 根因 / 改动方案」保留为设计决策记录；**实施后评审发现 7 项待修复，见文末新增章节**。
> 核心结论：删掉 ConfirmSheet 的满屏绿勾成功页，改为「sheet 立刻收起 → 新增待办在首页列表依次弹入 → 顶部计数器缩放 → success 触觉 → 底部 toast 兜底」。
> 主改动文件：`UI/ConfirmSheet/ConfirmSheetView.swift`、`UI/Home/HomeView.swift`、`UI/Home/HomeSelectedDayListView.swift`、`App/AppCoordinator.swift`
> 新增文件：`UI/Shared/NumberPopModifier.swift`
> 相关文件（连带小改）：`UI/Shared/CardEntranceModifier.swift`、`UI/Shared/ToastView.swift`、`Resources/Localizable.xcstrings`、`VoiceTodoUITests/ScenarioTests.swift`
> 行号基线：**「现象 / 根因 / 改动方案」三节为 `a28fb83`（实施前）；「实施后评审」一节为 `6d5b989`（实施后）。**

---

## 现象

语音解析出待办、点头部 `Add N` 之后，ConfirmSheet 不是直接关闭，而是切换到一个成功页：居中一个绿色实心圆勾 +「Added to todos」，停留 1.5s 后自动 dismiss。

三个问题：

**1. 信息量为零。** 整个成功页只传达「成功了」这 1 bit。用户看不见到底加进去了什么——而语音解析恰恰是有错误率的场景：把「买牛奶」听成「买牛肉」，用户必须等 sheet 关掉、回到列表才可能发现。**最需要复核的时刻，恰恰把内容藏起来了。**

**2. 脏状态。** 成功态下头部的 `Cancel` / `Add N` 仍然渲染，与「已完成」的语义自相矛盾。

**3. 视觉不搭。** 系统风格的绿色实心圆勾，与 App 的珊瑚橙主色 + 衬线体标题气质不一致。

### 勘误：两条常见误判

评审过程中有两条批评经核实**已不成立**，记录在此避免后续重复讨论：

- **「头部中间的 `Save to app c…` 被截断」** —— 该元素已在 `4e611c9`（*refactor(confirm-sheet): 删除头部中间的日历目标提示文字*）整体移除。当前 `sheetHeader` 只有 Cancel 和 Add N。遗留的 `confirm.calendar_target.app_only` / `confirm.calendar_target.app_and_system` 两个 key 在 `Resources/Localizable.xcstrings` 里已标 `stale`，属孤儿。

- **「白底占了大半屏」** —— sheet 高度由 `clampedSheetHeight` 计算，下限硬编码 280pt（`UI/ConfirmSheet/ConfirmSheetView.swift:397-405`）：

  ```swift
  private var clampedSheetHeight: CGFloat {
      let screenHeight = Self.currentScreenHeight()
      let footer: CGFloat = hintVisible ? OperationHintFooter.estimatedHeight : 0
      let frame: CGFloat = 102 + footer
      let raw = contentHeight + frame
      let lowerBound: CGFloat = 280
      let upperBound = screenHeight * 0.85
      return min(max(raw, lowerBound), upperBound)
  }
  ```

  成功态下 `mainContent` 被移除，`contentHeight` 归零，sheet 自动收缩到 280pt——已经是内容高度了。**所以「把 sheet 缩到 280」不是修复项，它是现状。** 真正的问题是 280pt 里只有一个 80pt 的圆圈，密度过低，见根因 2。

---

## 根因

### 1. 头部常驻：`body` 只切换内容区

`UI/ConfirmSheet/ConfirmSheetView.swift:88-97`：

```swift
var body: some View {
    VStack(spacing: 0) {
        sheetHeader          // ← 成功态也在渲染

        if showSuccess {
            successOverlay
        } else {
            mainContent
        }
    }
```

`Add N` 因为 `canConfirm` 判据含 `!didFinish`（`:382-384`）而变灰禁用，但 `Cancel` 没有 `.disabled`，看起来仍可点击。

好在 `cancelAction()` 开头有 guard（`:485-490`）：

```swift
private func cancelAction() {
    guard !didFinish else { return }
    didFinish = true
    onCancel()
    dismiss()
}
```

成功后 `didFinish` 已是 `true`，所以点它是**空操作**，不会误触发 `cancelTodos()`，无数据风险。但从体验上讲，一个看起来能点、点了没任何反应的按钮，比一个明确禁用的按钮更糟。

### 2. 成功页密度过低

`UI/ConfirmSheet/ConfirmSheetView.swift:425-452`，两个 `Spacer()` 夹一个 `WarmSize.hero`（80pt）的圆：

```swift
private var successOverlay: some View {
    VStack(spacing: WarmSpacing.md) {
        Spacer()
        ZStack {
            Circle()
                .fill(WarmTheme.success)
                .frame(width: WarmSize.hero, height: WarmSize.hero)
            Image(systemName: "checkmark")
                .font(.system(size: 40, weight: .bold))
                .foregroundColor(.white)
        }
        ...
        Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
```

280pt 的区域里，有效内容只有 80pt 圆 + 一行文字。「显得空」的来源是密度，不是尺寸——**靠缩小 sheet 解决不了，只能靠填内容或干脆不要这一屏。**

### 3. 关键坑：入场动画会在 sheet 背后播完

**这是本方案唯一的技术难点，不解决则「删绿勾 + 提前 dismiss」的结果是反馈归零。**

`confirmAction()` 是**同步**调用 `onConfirm` 的（`UI/ConfirmSheet/ConfirmSheetView.swift:467-483`）：

```swift
private func confirmAction() {
    guard !didFinish else { return }
    guard !todos.isEmpty else { return }

    didFinish = true
    let success = onConfirm(todos)      // ← 同步，直通 store
    ...
}
```

`onConfirm` → `AppCoordinator.confirmTodos(_:)` → `store.addBatch(todos, localeIdentifier:)`（`App/AppCoordinator.swift:561`）。`TodoStore.todos` 是 `@Published`，于是：

```
点 Add
  → 数据立刻进 store
  → HomeView 立刻重渲染，新行插入 List
  → 行的 .onAppear 立刻触发 stagger 入场动画
  → 但此时 sheet 还盖着（成功态停留 1.5s）
  → 等 sheet 收起，动画早已播完
```

行的入场动画是 `.onAppear` 驱动的（`UI/Home/HomeSelectedDayListView.swift:404-409`，`occurrenceRow` 在 `:443-448` 有一份等价副本）：

```swift
.opacity(cardAppeared.contains(todo.id) ? 1 : 0)
.onAppear {
    withAnimation(WarmAnimation.springCard.delay(Double(index) * 0.06)) {
        _ = cardAppeared.insert(todo.id)
    }
}
```

sheet 弹出时，下层的 List **并没有从视图树移除**，`onAppear` 照常触发。所以如果只是删掉成功页、把 `dismiss()` 提前，用户看到的将是**一堆已经静止在那儿的行**——比现在的绿勾还差。

---

## 改动方案

核心思路：不改入库时机（避免动 `onConfirm -> Bool` 的失败语义），改成**「先抑制、后揭晓」**——新增行先被标记为待揭晓，`onAppear` 不自行加入 `cardAppeared`（保持 opacity 0），等 sheet 的 `onDismiss` 回调触发后由 HomeView 统一放动画。

### 1. `App/AppCoordinator.swift` —— 待揭晓 ID 队列

- 新增 `@Published private(set) var pendingRevealTodoIDs: [UUID] = []`。用**有序数组**而非 Set：序号即 stagger 的 rank。
- `confirmTodos(_:)`（`:541-624`）成功路径 `return true` 之前赋值：`pendingRevealTodoIDs = todos.map(\.id)`。
- 新增 `func consumePendingReveal() -> [UUID]`：返回并清空，保证只揭晓一次（防止 sheet 反复 present/dismiss 时重放）。

### 2. `UI/ConfirmSheet/ConfirmSheetView.swift` —— 删掉成功页

- 删除 `successOverlay`（`:425-452`）、`@State private var showSuccess`（`:66`）、以及 1.5s 延时 dismiss 的 `.task(id: showSuccess)`（`:140-155`）。
- `body` 的 `VStack` 简化为 `sheetHeader` + `mainContent`。
- `confirmAction()` 成功路径改为：保留 `Telemetry.record(.todoSaved(...))`，加 `HapticFeedback.success()`，然后 `dismiss()`。

  > `HapticFeedback.success()` 已定义于 `UI/Shared/Haptics.swift:15`，但**全项目零调用**——直接用即可，无需新增。

- **`didFinish` 必须保留**：`.onDisappear` 的 `guard !didFinish`（`:135-139`）是防止成功后 `dismiss()` 触发 `onCancel()` 的关键，删了会导致刚添加的批次立刻被 `cancelTodos()` 清掉状态。
- 顺带清理 `Resources/Localizable.xcstrings` 中三个标 `stale` 的孤儿 key：`confirm.calendar_target.app_only`、`confirm.calendar_target.app_and_system`、`confirm.add %lld`（后者的现役 key 是 `confirm.add_count %lld`）。
- **`ErrorMessages.addedSuccess`（`Protocols/ErrorMessages.swift:58`）不要删** —— `UI/Shared/ToastView.swift:223` 和 `UI/UIDemoView.swift:25` 的 preview 仍在引用。

### 3. `UI/Home/HomeSelectedDayListView.swift` —— 抑制待揭晓行的自动入场

- 新增参数 `let pendingRevealIDs: Set<UUID>`。
- 两处内联入场动画（`todoRow` `:404-409`、`occurrenceRow` `:443-448`）的 `.onAppear` 加前置 guard：

```swift
.onAppear {
    // 待揭晓的新增条目交给 HomeView 在 sheet dismiss 后统一放动画,
    // 否则动画会在 ConfirmSheet 背后播完(见「根因 3」)。
    guard !pendingRevealIDs.contains(todo.id) else { return }
    withAnimation(WarmAnimation.springCard.delay(Double(index) * 0.06)) {
        _ = cardAppeared.insert(todo.id)
    }
}
```

行本身已是 `.opacity(cardAppeared.contains(id) ? 1 : 0)`，不进 `cardAppeared` 就自然保持不可见，无需额外状态。

- `UI/Home/UnscheduledDrawer.swift` 走的是共享 modifier `cardEntrance(id:index:cardAppeared:)`（`UI/Shared/CardEntranceModifier.swift:39`）：给该 modifier 加一个 `suppressed: Bool` 参数并在 `onAppear` 里同样 guard，让落到「稍后」分组的新增条目也走统一揭晓。

> 注意：`PendingDateTodoRow` / `UnparsedTodoCard` 本来就没有入场动画，落到「待定日期」「没能识别」两个分组的条目靠第 5 步的 toast 兜底，本次不为它们新增动画。

### 4. `UI/Home/HomeView.swift` —— 统一揭晓 + 计数器 pop

**(a) 给 sheet 挂 `onDismiss`**（`:427-429` 目前没有这个参数）：

```swift
.sheet(isPresented: $coordinator.showConfirmSheet, onDismiss: revealConfirmedTodos) {
    confirmSheetBody
}
```

**(b) 揭晓函数**：

```swift
private func revealConfirmedTodos() {
    let ids = coordinator.consumePendingReveal()
    guard !ids.isEmpty else { return }

    for (rank, id) in ids.enumerated() {
        // 步长与既有内联 stagger 一致(0.06);封顶 8 防止长批次拖尾过久。
        let delay = Double(min(rank, 8)) * 0.06
        withAnimation(motionAnim(WarmAnimation.springCard.delay(delay))) {
            _ = cardAppeared.insert(id)
        }
    }
    presentAddedToast(for: ids)
}
```

- `motionAnim(_:)`（`:1981-1983`）在 Reduce Motion 下返回 `nil` → 直接显示不做动画。
- `cardAppeared` 是 `@State`（`:303`），`.onChange(of: store.todos.count)` 的 `intersection` 清理（`:465-468`）只做交集，不会误删新 ID。

**(c) 计数器数字 pop**：`progressBarRow(total:completed:)`（`:913`）中的 `Text(verbatim: "\(completed) / \(total)")` 加缩放。

新建 `UI/Shared/NumberPopModifier.swift`，照抄 `UI/ConfirmSheet/ConfirmSheetAnimations.swift:48-105` 中 `PopCount` 的双阶段写法（`@State popping` + `Task.sleep` 复位 + generation 比对防并发竞写）。用法 `.numberPop(trigger: total)`。

- **只在 `oldTotal > 0` 时 pop**：total 从 0 变正数时，进度条行整体正在做 opacity 入场（`:648` 的 `.transition(.opacity)` + `:655` 的 `.animation(motionAnim(...), value: statsHidden)`），再叠一个 pop 会打架。
- 不动 `PopCount` 本体——它还带 haptic 和胶囊底色，职责不同，且其 doc 明确写了「只在 ConfirmSheet 视图树用，不污染 `UI/Shared` 的通用 modifier 库」。两者可留 follow-up 统一。

**(d) 底部 toast（HomeView 局部状态）**：

```swift
@State private var addedToastVisible = false
@State private var addedToastMessage = ""
@State private var addedToastToken = 0
```

挂 `.toast(message: addedToastMessage, style: .success, isPresented: $addedToastVisible, position: .bottom, presentationToken: addedToastToken)`。

- **不要走 `AppCoordinator.showToast`**：根部那个 toast 是默认 `.top` 位置（`App/VoiceTodoApp.swift:232-238`），会正好盖住我们要做 pop 动画的 `X / Y` 计数器。
- HomeView 局部 bottom toast 是本项目已有的先例——`ConfirmSheetView.swift:102-108` 的流式点击反馈就是这么做的。
- `presentationToken` 递增用于连续添加时重置计时（`UIConfig.toastDuration = 2.0`，`Protocols/Constants.swift:101`）。
- 需检查底部避让：`.bottom` 走 safe area，而首页底部有输入面板 / tab bar，参考 `UI/Home/HomeMonthHeaderView.swift` 的 `HomeLayoutMetrics.bottomBarHeight` 补 padding。
- 建议给 `ToastView`（`UI/Shared/ToastView.swift:137`）加 `.accessibilityIdentifier("Toast")`，便于 UI 测试断言。

### 5. 文案分流

`presentAddedToast(for:)` 用 `DayClock.isSameUserDay` 统计有多少条**不在**当前 `selectedDate`（含 `dueDate == nil` 的「稍后」「待定日期」条目），据此选串：

> ⚠️ **本段有误，已在实施后评审中订正。** 把 `dueDate == nil` 归为「别处」是错的：「稍后」「待定日期」「没能识别」三个分区都渲染在 Today tab 的同一个 `HomeSelectedDayListView` 里，是**可见**的。照此实现会让整批无日期的待办弹出「已添加 0 条 · N 条在其他日期」。详见「实施后评审」P1-3。

| 情况 | key | zh-Hans | en |
|---|---|---|---|
| 全部落在当前可见日 | `home.added_toast %lld` | 已添加 %lld 条 | Added %lld |
| 有条目落在别处 | `home.added_toast.elsewhere %lld %lld` | 已添加 %lld 条 · %lld 条在其他日期 | Added %lld · %lld on other dates |

---

## 为什么 toast 是必需项，不是可选装饰

「看见东西落进列表」是好的成功反馈，但它有三种**静默失败**的场景。没有 toast 兜底，这三种情况下用户点完 Add 得到的反馈是「什么都没发生」：

**1. 跨天条目。** 首页列表只显示 `selectedDate` 那一天，`selectedDayStats()`（`UI/Home/HomeView.swift:811-845`）也只统计那一天。说一句「明天买牛奶」，点 Add——**列表不动，`Today 0/1` 也不变**。而 ConfirmSheet 自己就按「今天 / 明天 / 周三」分组显示，说明多日批次是设计内的常态，不是边缘情况。同理还有落到「稍后」「待定日期」「没能识别」分组的条目。

**2. Reduce Motion。** `revealConfirmedTodos` 走 `motionAnim`，开了「减弱动态效果」时返回 `nil`，行直接显示、无动画。把全部反馈押在动画上，等于对这部分用户静默失败。

**3. 用户停在 Calendar tab。** `selectedBottomTab` 不是 `.today` 时，列表压根不可见。

toast 同时还是 Undo 的正确落点（见下）——它出现时列表已经可见，用户能对照着内容决定要不要撤销；而成功页上什么都看不见，1.5s 后就消失了。

---

## 不在本次范围

**1. Undo。** 基础设施是齐的——`AppCoordinator.showToast(message:style:actionTitle:action:)`（`:1035-1041`）已支持带按钮的 toast（`showVoicePermissionRequiredToast()` 是现成先例），`ToastModifier` 在有 action 时自动把停留时间加倍（`ToastView.swift:124`），`TodoStore.delete(_:)`（`Store/TodoStore.swift:195`）也在。

但真正的 Undo 必须回滚 `confirmTodos` 的**全部**副作用，不只是删数据：

- 系统日历写入（`App/AppCoordinator.swift:604-614`，`calendarSyncService.enqueueWrite`）——不撤会留下孤儿日历事件
- 词汇学习（`:574-582`）与纠错追踪（`:587-602`）
- `pendingItemIds` 批次替换（`:549-558`）——离线补录路径的回退更复杂
- `WidgetCenter.reloadAllTimelines()`

这是独立一块工作，应另开一次改动，不要当作本方案的附赠品。

**2. 绿勾换品牌色描边勾。** 若保留 toast 图标，`ToastStyle.success` 的 `iconColor` 是 `WarmTheme.success = #7BC47F`（`UI/Shared/DesignSystem.swift:38`），可换成 `WarmTheme.primary = #FF8A6B`（珊瑚橙）以贴合 App 气质。项目已有 `WarmCheckmarkShape`（`UI/Home/WarmTodoCard.swift:418-429`）配 `.trim` 可做描边笔画动画。**纯视觉改动，建议单独一次提交**，别和行为改动混在一起。

**3. `PendingDateTodoRow` / `UnparsedTodoCard` 补入场动画。**

**4. 统一 `PopCount` 与 `NumberPopModifier`**，以及把 `HomeSelectedDayListView` 的两份内联入场动画迁移到共享的 `CardEntranceModifier`（该迁移在 `CardEntranceModifier.swift:10-11` 已被标为待办）。

---

## 验证

> 本仓库的 iOS target 无法在 Linux 环境编译，以下需在 macOS + Xcode 下执行。

### 自动化

1. `xcodebuild build -scheme VoiceTodo -destination 'platform=iOS Simulator,name=iPhone 16'` —— 编译通过
2. **`VoiceTodoUITests/ScenarioTests.swift:99` 必须同步修改**：

   ```swift
   let successAnimation = appHelper.app.otherElements["SuccessAnimation"]
   XCTAssertTrue(successAnimation.waitForExistence(timeout: 2.0))
   ```

   该元素随 `successOverlay` 一并删除，此断言必然失败。改为断言 sheet 消失后首页出现 3 条（`:106-109` 已有 `homeTodoList.cells.count == 3`），并可补断言 toast 存在。
3. `xcodebuild test -scheme VoiceTodo -destination '...' -only-testing:VoiceTodoUITests/ScenarioTests`
4. 检查 `VoiceTodoTests/` 下是否有依赖 `showSuccess` 时序或 1.5s 延时的断言

### 手动走查（模拟器 + 真机各一遍）

- **当天批次**：说「今天买牛奶、交电费、取快递」→ 点 Add → sheet 立刻收起 → 三行依次弹入 → `Today 0/1` 变 `0/4` 并缩放 → success 触觉 → 底部 toast「已添加 3 条」。
  **重点确认动画不是在 sheet 背后播完的**——这是根因 3 的回归点。
- **跨天批次**：说「明天买牛奶」→ 列表和计数器都不动 → toast 显示「已添加 1 条 · 1 条在其他日期」
- **混合批次**：今天 2 条 + 明天 2 条 → 当天两条弹入，toast 正确报分布
- **Reduce Motion**（设置 → 辅助功能 → 动态效果 → 减弱动态效果）→ 行直接显示不动画，toast 正常出现
- **落到「稍后」/「待定日期」/「没能识别」分组**的条目 → toast 走 elsewhere 文案
- **停在 Calendar tab 时添加** → toast 仍可见
- **连续两次快速添加** → toast 计时被 `presentationToken` 正确重置，不提前消失
- **确认失败路径**（`confirmTodos` 抛错返回 `false`）→ sheet 不关、不揭晓、不出 toast
- **成功后立刻上滑关 sheet** → 不重复揭晓、不触发 `onCancel()`
- **中英双语**各看一遍 toast 文案不截断（`ToastView` 的 `Text` 是 `.lineLimit(2)`）

---

# 实施后评审：7 项待修复

> 针对 `75645aa` 的实施评审。行号基线 `e2738f2`。
> 注：`e2738f2` 把右上角 Today 胶囊重构成了标题行下方的细进度条（`pillLabel` → `progressBarRow`），本节行号与命名已对齐该次重构；7 项结论本身不受影响。
> 实现忠实于上文方案，**核心「先抑制、后揭晓」时序是对的**（见文末「已核查、判定为非问题」）。以下 7 项按优先级排列，其中 P0 两项建议发版前处理。

## P0-1 Toast 挡住录音 FAB 整整 2 秒

**落点**：`UI/Home/HomeView.swift:437`（toast 挂载处）、`UI/Shared/ToastView.swift:84-90`（修复处）

几何已核实：

| | 范围（距容器底部） |
|---|---|
| VoiceFAB | `WarmSize.fab = 72` + 自带 `.padding(.bottom, WarmSpacing.md = 16)` → **16–88pt**，圆心 52pt |
| 成功 toast | `.padding(position.edgeInsets, WarmSpacing.xxxl = 48)`（`ToastView.swift:89`），本体约 64pt → **48–112pt** |

FAB 圆心落在 toast 的覆盖区内。且 toast 的 `.overlay` 挂在 `HomeView.swift:437`，晚于 FAB 的 `.overlay`（`:397`）→ 渲染在上层；`ToastView` 有不透明 `RoundedRectangle` 背景，可命中。

结果：**刚添加完待办、最可能想立刻再录一条的时刻，麦克风按钮被自己弹出的成功提示挡住 2 秒。**

修复（`ToastView.swift:84-90`，加一行）：

```swift
    .padding(position.edgeInsets, WarmSpacing.xxxl)
    // 无操作按钮的 toast 纯展示,不该拦截点击 —— 底部 toast 与 HomeView 的
    // VoiceFAB(16–88pt)在 48–112pt 重叠,不放行会让麦克风在 toast 存活的
    // 2s 内点不动。有按钮的 toast 必须可命中,故按 action 分流。
    .allowsHitTesting(action != nil)
    .zIndex(1)
```

波及 4 个调用方：`App/VoiceTodoApp.swift:232`、`UI/Detail/TodoDetailView.swift:391`（都透传 `coordinator.toastAction`，非 nil 时照常可点）；`UI/ConfirmSheet/ConfirmSheetView.swift:96`、`UI/UIDemoView.swift:155`（无 action，变为点击穿透——纯提示，正是期望行为）。

## P0-2 stagger 可能整体塌成一次动画

**落点**：`UI/Home/HomeView.swift:865-876`

```swift
for (rank, id) in ids.enumerated() {
    let delay = Double(min(rank, 8)) * 0.06
    withAnimation(motionAnim(WarmAnimation.springCard.delay(delay))) {
        _ = cardAppeared.insert(id)
    }
}
```

N 次 `withAnimation` 在**同一个 runloop tick** 内连续修改同一个 `@State cardAppeared`。SwiftUI 会把同 tick 内对同一状态的多次改动合并成一次更新，各档 `.delay` 是否还分别生效并不确定。

**这与既有的内联 stagger 不是一回事**：`HomeSelectedDayListView:410-416` / `:452-458` 那两处是各行 `.onAppear` 在 List 懒加载时分别触发，天然分散在不同 tick；这里是一个紧凑同步循环。

危害在于失败是**静默**的：真塌了就是「所有行同时淡入」，仍然有反馈，冒烟测试发现不了，只有专门去看有没有瀑布才察觉。

修复：改成按 tick 串行推进，让每次 insert 各占一次事务，**结构上**保证级联，而不依赖事务合并语义。同时并入 P1-5 的可见性过滤：

```swift
/// stagger 步长 60ms,与既有内联入场一致;封顶 8 档防长批次拖尾。
private static let revealStaggerStepNanos: UInt64 = 60_000_000
private static let revealStaggerCap = 8

@State private var revealTask: Task<Void, Error>?

private func revealConfirmedTodos() {
    let ids = coordinator.consumePendingReveal()
    guard !ids.isEmpty else { return }
    presentAddedToast(for: ids)

    // 只揭晓当前 List 真的会渲染的行,其余留给它们自己的 .onAppear(见 P1-5)。
    let visible = ids.filter { landsInCurrentList($0) }
    guard !visible.isEmpty else { return }

    revealTask?.cancel()
    guard !reduceMotion else {
        cardAppeared.formUnion(visible)   // 动效减弱:一次插完,不动画
        return
    }
    revealTask = Task { @MainActor in
        for (rank, id) in visible.enumerated() {
            if rank > 0 && rank <= Self.revealStaggerCap {
                do { try await Task.sleep(nanoseconds: Self.revealStaggerStepNanos) }
                catch is CancellationError { return }
                catch { return }
            }
            withAnimation(WarmAnimation.springCard) {
                _ = cardAppeared.insert(id)
            }
        }
    }
}
```

`reduceMotion` 已有（`HomeView.swift:160`）。`Task` + `Task.sleep` + 显式 catch 是项目既有风格（`ConfirmSheetAnimations.PopCount`）。

## P1-3 全是无日期任务时 toast 说「已添加 0 条」

**落点**：`UI/Home/HomeView.swift:885`

```swift
guard let due = todo.dueDate else { return true }   // ← 无日期一律算「别处」
```

「稍后」分区走的就是 `todoRow`（`HomeSelectedDayListView.swift:74`），同样吃 `pendingRevealIDs` 抑制 + 揭晓，**渲染在 Today tab 的同一个 List 里**；「待定日期」「没能识别」也在同一个 List。把它们说成「在其他日期」不成立。一批全是无日期的待办 → `onSelectedDay = 0` → 文案变成「已添加 0 条 · 3 条在其他日期」。

> 这条的根源在上文「改动方案 §5 文案分流」——原方案明确写了把 `dueDate == nil` 归为别处。是**方案本身考虑错了**，实现是照做的。该处已加勘误标注。

修复两步：

1. `return true` → `return false`（无日期 = 可见，不算别处）。「别处」严格收窄为「有 `dueDate` 但落在别的日子」。
2. 仍可能出现 `onSelectedDay == 0`（整批都定在明天），需要第三条文案。新增 key `home.added_toast.all_elsewhere %lld` → zh「已添加 %lld 条 · 都在其他日期」/ en「Added %lld · all on other dates」，在 `onSelectedDay == 0 && elsewhere > 0` 时使用。

同时把这条判定抽成 `private func landsInCurrentList(_ id: UUID) -> Bool`，供 `presentAddedToast` 与 P0-2 的 reveal 过滤共用，避免两份规则各写一遍。

## P1-4 切换日期时计数器也会弹

**落点**：`UI/Shared/NumberPopModifier.swift:46`、`UI/Home/HomeView.swift:939`

`.numberPop(trigger: total)`（`HomeView.swift:939`）监听的是任意 `total` 变化，只 gate 了 `oldValue == 0`。左右滑切到别的日期时 `total` 就变了 → 数字弹一下。这个 pop 本意是「东西落进列表」的反馈，现在变成了日常导航噪音。

修复：改成 token 驱动，只有真的添加了当天条目才弹。

- `NumberPopModifier.swift:46` 删掉 `guard oldValue > 0 else { return }`（gate 上移到调用方），同步修改文件头注释里「gate `oldValue == 0`」那段说明
- `HomeView` 加 `@State private var pillPopToken = 0`
- `presentAddedToast` 内，当 `onSelectedDay > 0` **且**该日原本已有条目（`selectedDayStats().total > onSelectedDay`，避免与进度条行的 opacity 入场动画打架，见 `:646` 的 `if !statsHidden` 与 `:655` 的 `.animation(..., value: statsHidden)`）时 `pillPopToken += 1`
- `progressBarRow`（`:913-950`）改为 `.numberPop(trigger: pillPopToken)`

## P1-5 跨天条目从此永久失去入场动画

**落点**：`UI/Home/HomeView.swift:865-876`

`revealConfirmedTodos` 把**所有** id 都插进了 `cardAppeared`，包括落在别的日期、当前根本没渲染的行。`.onChange(of: store.todos.count)`（`:479-482`）的清理只跟 store 做交集，这些 todo 确实存在，所以会一直留着。等用户以后翻到那天，行已经在 `cardAppeared` 里 → 直接 opacity 1 显示，没有入场动画。改动前它们会在那天正常播入场。

影响很小（toast 已兜住反馈），但属于轻微回退。修复已并入 P0-2 的 `landsInCurrentList` 过滤：不可见的条目不插 `cardAppeared`，留给它们自己的 `.onAppear` 走既有路径。

## P2-6 S01 用例现在是竞态的

**落点**：`VoiceTodoUITests/ScenarioTests.swift:103,106`

两个问题叠加：

- `XCTAssertEqual(cells.count, 3)` 是不等待的瞬时快照，而新行现在被刻意压在 opacity 0 直到 `onDismiss` + stagger 跑完——原来那个 1.5s 成功页恰好保证了断言时行早就在了
- 紧接着的 `Toast` 断言给了 2.0s 超时，而 toast 寿命本身就是 2.0s（`UIConfig.toastDuration`，`Protocols/Constants.swift:101`），前面那次 cells 遍历可能吃掉不少

修复：先断言有时限的 toast，再等行。

```swift
XCTAssertTrue(appHelper.confirmSheet.waitForNonExistence(timeout: 3.0))
// toast 只活 2s,先断言它,再做耗时的 cells 遍历
XCTAssertTrue(appHelper.app.otherElements["Toast"].waitForExistence(timeout: 2.0))
// 行是 stagger 揭晓的,先等第 3 行出现再断总数
XCTAssertTrue(appHelper.todoList.cells.element(boundBy: 2).waitForExistence(timeout: 3.0))
XCTAssertEqual(appHelper.todoList.cells.count, 3, "HomeView 应该有 3 条待办")
```

`:339` / `:366` 的 `cells.count` 走 `launchWithPresetTodos`，不经确认流程，不受影响。

## P3-7 `CardEntranceModifier.suppressed` 是给 follow-up 埋的坑

**落点**：`UI/Shared/CardEntranceModifier.swift:30`

只在 `.onAppear` 里 guard，没有 `.onChange(of: suppressed)`。当前无调用方传 `true`，所以现在无害；但其注释说明它是为 UnscheduledDrawer 的 follow-up 准备的——真那么用的时候，抑制解除后卡片会永久停在 opacity 0，因为没有任何东西会再把它插进 `cardAppeared`。

修复（4 行）：

```swift
.onChange(of: suppressed) { _, isSuppressed in
    guard !isSuppressed, !cardAppeared.contains(id) else { return }
    withAnimation(WarmAnimation.springCard.delay(Double(index) * 0.06)) {
        _ = cardAppeared.insert(id)
    }
}
```

## 已核查、判定为非问题

- **`NumberPopModifier.onDisappear` 不重置 `popping`**：进度条行是 `if !statsHidden` 条件渲染，移出视图树时 `@State` 销毁重建、重新初始化为 `false`，缩放卡不住。
- **抑制名单与新行的先后**：`store.addBatch`（`AppCoordinator.swift:568`）与 `pendingRevealTodoIDs = todos.map(\.id)`（`:627`）同在 `confirmTodos` 的同步段内、`return true` 之前，中间没有 await，SwiftUI 不可能在两者之间渲染。抑制名单一定先于新行就位。
- **失败 / 取消路径**不写队列；`consumePendingReveal()` 一次性消费防重放；`didFinish` 仍挡住 `onDisappear → onCancel`。

## 修复后的回归清单（Mac / 真机）

- 加 8 条今日任务，确认是**瀑布**而非齐刷刷（P0-2 的核心验证点）
- toast 存活期间点麦克风 FAB 可用（P0-1）
- 整批无日期 → 「已添加 N 条」；整批明天 → 「已添加 N 条 · 都在其他日期」（P1-3）
- 左右切日期，计数器不弹（P1-4）
- 翻到明天看新加的条目，仍有入场动画（P1-5）
- `ScenarioTests` S01 连跑 10 次不 flake（P2-6）
