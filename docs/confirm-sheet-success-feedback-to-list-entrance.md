# 方案：确认页成功反馈改为「落进列表」

> 状态：**待实施**。本文档为设计决策 + 实施方案，尚未落地。
> 核心结论：删掉 ConfirmSheet 的满屏绿勾成功页，改为「sheet 立刻收起 → 新增待办在首页列表依次弹入 → 顶部计数器缩放 → success 触觉 → 底部 toast 兜底」。
> 主改动文件：`UI/ConfirmSheet/ConfirmSheetView.swift`、`UI/Home/HomeView.swift`、`UI/Home/HomeSelectedDayListView.swift`、`App/AppCoordinator.swift`
> 新增文件：`UI/Shared/NumberPopModifier.swift`
> 相关文件（连带小改）：`UI/Shared/CardEntranceModifier.swift`、`UI/Shared/ToastView.swift`、`Resources/Localizable.xcstrings`、`VoiceTodoUITests/ScenarioTests.swift`
> 行号基线：`a28fb83`

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

**(c) 计数器数字 pop**：`pillLabel(total:completed:)`（`:900-911`）中的 `Text(verbatim: "\(completed)/\(total)")` 加缩放。

新建 `UI/Shared/NumberPopModifier.swift`，照抄 `UI/ConfirmSheet/ConfirmSheetAnimations.swift:48-105` 中 `PopCount` 的双阶段写法（`@State popping` + `Task.sleep` 复位 + generation 比对防并发竞写）。用法 `.numberPop(trigger: total)`。

- **只在 `oldTotal > 0` 时 pop**：total 从 0 变正数时，pill 整体正在做 opacity 入场（`:638` 的 `.transition(.opacity)` + `:643` 的 `.animation(motionAnim(...), value: statsHidden)`），再叠一个 pop 会打架。
- 不动 `PopCount` 本体——它还带 haptic 和胶囊底色，职责不同，且其 doc 明确写了「只在 ConfirmSheet 视图树用，不污染 `UI/Shared` 的通用 modifier 库」。两者可留 follow-up 统一。

**(d) 底部 toast（HomeView 局部状态）**：

```swift
@State private var addedToastVisible = false
@State private var addedToastMessage = ""
@State private var addedToastToken = 0
```

挂 `.toast(message: addedToastMessage, style: .success, isPresented: $addedToastVisible, position: .bottom, presentationToken: addedToastToken)`。

- **不要走 `AppCoordinator.showToast`**：根部那个 toast 是默认 `.top` 位置（`App/VoiceTodoApp.swift:232-238`），会正好盖住我们要做 pop 动画的 `Today x/y` 计数器。
- HomeView 局部 bottom toast 是本项目已有的先例——`ConfirmSheetView.swift:102-108` 的流式点击反馈就是这么做的。
- `presentationToken` 递增用于连续添加时重置计时（`UIConfig.toastDuration = 2.0`，`Protocols/Constants.swift:101`）。
- 需检查底部避让：`.bottom` 走 safe area，而首页底部有输入面板 / tab bar，参考 `UI/Home/HomeMonthHeaderView.swift` 的 `HomeLayoutMetrics.bottomBarHeight` 补 padding。
- 建议给 `ToastView`（`UI/Shared/ToastView.swift:137`）加 `.accessibilityIdentifier("Toast")`，便于 UI 测试断言。

### 5. 文案分流

`presentAddedToast(for:)` 用 `DayClock.isSameUserDay` 统计有多少条**不在**当前 `selectedDate`（含 `dueDate == nil` 的「稍后」「待定日期」条目），据此选串：

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
