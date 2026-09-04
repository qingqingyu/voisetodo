# 详情页下滑关闭：从「阈值判定」改成「跟手手势」

> 状态：**待实施**。本文档同时是 HTML 原型的绘制规格 + Swift 实施规格。
>
> **基线**：行号对齐 `3f7f051`（*feat(alerting): 层 B/C 实施*）。
> 实施时**先按符号名（属性名 / 函数名 / 注释原文）定位，行号仅作参考**。
>
> 主改动文件：`UI/Detail/TodoDetailView.swift`、`UI/Home/HomeView.swift`（呈现方式）
>
> 相关文件（只读参考）：`UI/Shared/SimultaneousDragGesture.swift`、
> `UI/Home/UnscheduledDrawer.swift`（grabber 实现）、`UI/Shared/DesignSystem.swift`、
> `UI/Shared/Haptics.swift`

---

## 缘起

外部建议：「详情页的下滑关闭，要不要做一个提示 / 暗示的动效？」

**结论：不做 coach mark，但要做跟手。** 这条建议方向对，但诊断错了病因 ——
当前缺的不是「用户不知道有这个手势」，而是「手势本身在过程中没有任何反馈」。

用户拖到 79pt 松手 → 页面从头到尾纹丝不动，然后也没关闭。这不是不知道，
是**试过了但没有得到回应**，比不知道更糟。给一个零反馈的手势加引导动画，
只会让用户去做一件做了也看不见结果的事。

## 结论摘要

| 问题 | 现状 | 处理 |
|---|---|---|
| 跟手反馈 | **完全没有**，页面 0 位移 | **必做**：offset + scale + 圆角 + haptic |
| 速度判定 | **没有**，只比位移 > 80pt | **必做**：位移 **或** 速度任一达标 |
| grabber | **没有**（fullScreenCover 非 sheet） | **必做**，但必须与跟手配套 |
| 滚动接管 | 要抬手再拖第二次 | **改**：同一次手势无缝接管 |
| iOS 26 手势失效风险 | 用的是已知有 bug 的原生 API | **先验证**，见「风险 0」 |
| 键盘两段式 | 已实现 ✓ | 保留，微调触发时机 |
| 误触成本 | 已有实时保存 ✓ | 不加确认弹窗 |
| coach mark 引导 | 无 | **不做**，理由见下 |

---

## 现状 review

### 1. 手势完全没有跟手

`UI/Detail/TodoDetailView.swift:388-401`：

```swift
.simultaneousGesture(
    DragGesture(minimumDistance: DismissDragConfig.minimumDistance)   // 40pt
        .onChanged { _ in
            // 只做状态快照,没有任何视觉输出
            if dragStartedAtTop == nil { dragStartedAtTop = isScrollViewAtTop }
        }
        .onEnded { value in
            let startedAtTop = dragStartedAtTop ?? false
            dragStartedAtTop = nil
            handleDismissDrag(value, startedAtTop: startedAtTop)
        }
)
```

`onChanged` 里只记了一个 `Bool` 快照。判定全在 `onEnded`（`handleDismissDrag`，`:485-501`）：
位移 > 80pt 就 `dismiss()`，否则**什么都不发生**。

整个手势周期内，页面位移恒为 0。

### 2. 其实没有速度判定

`:490-492`：

```swift
let translation = value.translation
guard translation.height > DismissDragConfig.verticalTranslationLowerBound,   // 80pt
      abs(translation.height) > abs(translation.width) else { return }
```

只比位移。所以「快速下滑才收起」这个描述跟代码对不上：

- 慢慢拖 80pt → **会**关闭
- 快速轻扫 60pt → **不会**关闭

两头都不符合直觉。`DragTranslation` / `DragGesture.Value` 都带 `velocity`，现在没用。

### 3. 没有 grabber，而且这个页面不是 sheet

详情页走 `fullScreenCover`（`UI/Home/HomeView.swift:818-823`）：

```swift
.fullScreenCover(item: $selectedTodo) { todo in
    NavigationStack {
        TodoDetailView(store: store, todo: todo)
            .environmentObject(coordinator)
    }
}
```

全屏推上来，不是卡片形态 → 既没有系统 grabber，也没有 `presentationDragIndicator`。
页面顶部是 48pt 空白 padding（`TodoDetailView.swift:370`）后直接接标题卡。

左上角 `chevron.down`（`:423-431`）只告诉用户「这里能关」，没告诉用户「整个页面能拖」。

项目内已有一个可复用的标准 grabber：`UI/Home/UnscheduledDrawer.swift:167-182`
（38×5pt Capsule，`WarmTheme.sketch.opacity(0.4)`）。

### 4. 滚动接管不平滑，而且是刻意的

`dragStartedAtTop`（`:100`，注释在 `:93-99`）锁定起手瞬间的滚动位置，
起手时不在顶部的**整段手势**都不会关闭。注释写得很明白，想要的是
「第一次滑到顶 → 抬手 → 第二次再滑才关」的二次确认心智模型。

但这跟系统 sheet 不一致：系统里列表滚到顶后继续下拉，**同一次手势**就无缝接管了，
不需要抬手。当前实现是这个交互里最不跟手的一环。

配套设施（都为这个二次确认服务，改完后可一并删除）：
`DetailScrollOffsetKey`（`:24-30`）、`DetailScrollCoordinateSpace`（`:33-35`）、
`isScrollViewAtTop`（`:83`）、`.onPreferenceChange`（`:402-404`）、
`ScrollView` 顶部锚点 `GeometryReader`（`:136-145`）、`.coordinateSpace`（`:373`）。

### 5. 已经做对的两件事，不要动

- **键盘两段式**（`:496-500`）：键盘弹起时下滑只收键盘不关页。符合直觉，保留。
- **实时保存**（`checkForChanges` `:941-956` → `scheduleAutosave` 800ms 防抖 `:965-972`，
  `onDisappear` 兜底 `:444-450`）。所以「编辑页误触成本高」在本 app 不成立，
  **不要**加 `isModalInPresentation` + 确认弹窗，那是在给一个已经解决的问题加摩擦。

---

## 风险 0（实施前必须先验证）

`UI/Shared/SimultaneousDragGesture.swift:23-26` 记录：

> iOS 26 起，SwiftUI 的 `.simultaneousGesture(DragGesture(...))` 在 HStack/ScrollView/List
> 等容器内**不再可靠触发**（Apple 回归 bug FB18199844）。

首页折叠手势已因此迁移到 UIKit 包装版（`UI/Home/HomeView.swift:1804`），
**但详情页 `:388` 还在用原生 `DragGesture`，并且它就挂在 `ScrollView` 上。**

**动手前先在 iOS 26 真机 / 模拟器上验证当前下滑关闭是否还生效。**
如果已经失效，那这次改动的性质就不是「优化体验」而是「修 P1 缺陷」，优先级要往上提。

---

## 方案决策

| 决策点 | 选择 | 落选项及原因 |
|---|---|---|
| 呈现方式 | **方案 A：换 `.sheet` + `.large` detent**（推荐） | 方案 B 手写跟手：工作量大、要自己维护物理曲线，且绕不开 iOS 26 手势 bug 之外的其他坑 |
| 引导形式 | **静态 grabber，不做 coach mark** | coach mark 见「为什么不做引导」 |
| 误触保护 | **不加**，靠现有实时保存 | 确认弹窗体验重，且与 autosave 语义打架 |
| 二次确认（抬手再拖） | **删除**，改无缝接管 | 与系统 sheet 不一致，是当前最大的「不跟手」来源 |

### 为什么不做引导动画

1. 下滑关闭是 iOS 通用手势，用户有肌肉记忆。为它弹引导是为已知的事付出打断成本。
2. 手势失败代价接近于零 —— 左上角 `chevron.down` 永远兜底。
3. 项目里已经有一个 coach mark（`UI/Home/ExpandMonthHintView.swift`，教「下拉展开月网格」）。
   那个值得做，因为**下拉展开月历是自创手势，没有系统先例**；下滑关闭不是。
   两者的区别就是判断该不该做引导的标准。
4. 真正的「暗示」是 grabber（静态、零打断、系统标准语汇）+ 跟手（过程中的实时反馈）。
   引导讲一次就忘，跟手每次都在。

### ⚠️ grabber 不能单独做

grabber 的语义是「这是一张可以拖的卡片」。如果加了 grabber、用户拖了、页面却不动，
这个暗示当场落空，**比现在更糟**。grabber 必须与跟手同批上线。

---

## 方案 A（推荐）：换成 `.sheet` + `.large` detent

改 `UI/Home/HomeView.swift:818-823`：

```swift
.sheet(item: $selectedTodo) { todo in
    NavigationStack {
        TodoDetailView(store: store, todo: todo)
            .environmentObject(coordinator)
    }
    .presentationDetents([.large])
    .presentationDragIndicator(.visible)
}
```

系统白送：跟手、grabber、平滑滚动接管、位移+速度松手判定、回弹曲线、
以及跟系统提醒事项 / 备忘录完全一致的手感。

同时可以从 `TodoDetailView.swift` **删掉**（约 60 行 + 5 个 `@State`）：

- `DismissDragConfig`（`:12-17`）
- `DetailScrollOffsetKey`（`:24-30`）
- `DetailScrollCoordinateSpace`（`:33-35`）
- `isScrollViewAtTop`（`:83`）、`dragStartedAtTop`（`:100`）
- ScrollView 顶部锚点 `GeometryReader`（`:136-145`）、`.coordinateSpace`（`:373`）
- `.simultaneousGesture(...)`（`:388-401`）、`.onPreferenceChange(...)`（`:402-404`）
- `handleDismissDrag`（`:485-501`）

**键盘两段式的替代**：加 `.scrollDismissesKeyboard(.interactively)` 到 `ScrollView` 上。
这是系统惯例（下滑先把键盘推下去），比手写的两段式更贴系统，也不需要
`isKeyboardVisible`（`:91`）+ 两个 `onReceive`（`:408-413`）。
**但要实测**：确认「键盘弹起时下滑第一下不会直接关页」。若系统行为不满足，
保留 `isKeyboardVisible` + `.interactiveDismissDisabled(isKeyboardVisible)`，
键盘弹起时禁用系统下滑关闭，靠 `.scrollDismissesKeyboard` 收键盘。

### 代价（需要产品确认）

视觉形态变化：`.large` sheet 顶部会露出下层首页约 10pt、页面带圆角、
下层有轻微缩放后退效果。这是 iOS 标准 modal 观感，但**跟现在的全屏不同**。

顶部 48pt padding（`:370`）的原注释是为了「防标题被导航栏视觉截断 + 给 compact toast 让位」，
换 sheet 后 grabber 会占掉约 20pt，需要重新量一次，大概率收到 `WarmSpacing.xl`(24pt)。

---

## 方案 B（备选）：保持 fullScreenCover，手写跟手

如果全屏形态不能动，就得手写完整的跟手。以下参数同时是 **HTML 原型的绘制规格**。

### B.1 状态

```swift
/// 跟手位移(pt)。0 = 静止;正值 = 页面下移。上滑 clamp 到 0。
@State private var dismissDragOffset: CGFloat = 0
/// 本次手势是否只用于收键盘(起手时键盘弹起)。为 true 时不驱动 offset。
@State private var dragIsKeyboardOnly = false
/// 是否已在本次手势中越过阈值(用于 haptic 只触发一次)。
@State private var didCrossDismissThreshold = false
```

### B.2 常量

```swift
private enum DismissDragConfig {
    /// 手势识别最小位移。要跟手就必须小,原 40pt 太大(前 40pt 页面不动 = 依然卡顿感)。
    static let minimumDistance: CGFloat = 10
    /// 松手关闭的位移阈值。
    static let dismissTranslation: CGFloat = 120
    /// 松手关闭的速度阈值(pt/s)。位移不足但甩得快也关。
    static let dismissVelocity: CGFloat = 800
    /// 视觉插值行程:offset 到这个值时 scale/圆角达到终点。
    static let visualTravel: CGFloat = 260
    /// 页面最小缩放。
    static let minScale: CGFloat = 0.94
    /// 页面最大圆角(= WarmRadius.sheet)。
    static let maxCornerRadius: CGFloat = 20
}
```

### B.3 物理曲线（HTML 原型按这个实现）

```
progress = min(1, max(0, offset) / 260)

offset    = max(0, dy)                       // 1:1 跟手,不加阻尼。上滑直接 clamp 0
scale     = 1 - progress * 0.06              // 1.00 → 0.94
radius    = progress * 20                    // 0 → 20pt
grabber 宽 = 38 + progress * 10              // 38 → 48pt(越拖越"被抓住")
grabber 色 = sketch 40% → 70% 不透明度        // #8993A4,alpha 0.4 → 0.7
露出区底色 = #F4F5F7 (WarmTheme.background)
```

**为什么 1:1 不加阻尼**：这是一个「要离开」的手势，阻尼会制造「关不掉」的挫败感。
阻尼适用于「不该越界」的场景（如上滑），所以上滑 clamp 到 0 即可。

**为什么用 scale + 圆角而不是「露出下层首页」**：`fullScreenCover` 下层视图是否仍在渲染
不受文档保证，依赖它会有黑屏 / 白屏风险。scale + 圆角是自包含的，把页面读成
「一张正在脱离屏幕的卡片」，不依赖任何下层内容。

### B.4 阈值 haptic —— 这才是「暗示」的正解

`offset` 首次跨过 `dismissTranslation`(120) 时，触发一次 `HapticFeedback.light()`
（`UI/Shared/Haptics.swift:30`），并置 `didCrossDismissThreshold = true`；
回落到阈值以下时复位（可再次触发）。

这条比任何引导动画都有用：它在用户**正在做这件事的那一刻**告诉他
「松手就关了」，而不是在他还没想做的时候打断他。

### B.5 手势实现

换用项目已有的 `SimultaneousDragGesture`（`UI/Shared/SimultaneousDragGesture.swift`），
绕开 iOS 26 的 `DragGesture` bug，并用 `allowSimultaneousWithScrollViewPan`
拿到无缝滚动接管（首页折叠手势 `HomeView.swift:1804` 是现成范例）：

```swift
.gesture(
    SimultaneousDragGesture(
        minimumDistance: DismissDragConfig.minimumDistance,
        direction: .vertical,
        onChanged: { drag in
            // 起手时键盘弹起 → 本次手势只收键盘,不驱动 offset
            if dismissDragOffset == 0 && !dragIsKeyboardOnly && isKeyboardVisible {
                dragIsKeyboardOnly = true
                dismissKeyboard()
                return
            }
            guard !dragIsKeyboardOnly else { return }
            dismissDragOffset = max(0, drag.translation.height)
            updateThresholdHaptic()
        },
        onEnded: { drag in
            defer { dragIsKeyboardOnly = false; didCrossDismissThreshold = false }
            guard !dragIsKeyboardOnly else { return }
            let shouldDismiss = drag.translation.height > DismissDragConfig.dismissTranslation
                || drag.velocity.dy > DismissDragConfig.dismissVelocity
            if shouldDismiss {
                dismiss()
            } else {
                withAnimation(WarmAnimation.springSmooth) { dismissDragOffset = 0 }
            }
        },
        onCancelled: {
            dragIsKeyboardOnly = false
            didCrossDismissThreshold = false
            withAnimation(WarmAnimation.springSmooth) { dismissDragOffset = 0 }
        },
        allowSimultaneousWithScrollViewPan: { scrollView, pan in
            // 列表已在顶部 + 手指向下 → 外层接管,同一次手势无缝转交,不需要抬手
            scrollView.contentOffset.y <= 0 && pan.velocity(in: scrollView).y > 0
        }
    )
)
```

**注意 `onCancelled` 必须实现** —— 否则手势被系统中断（来电、系统边缘手势）时
`dismissDragOffset` 会卡在中途，页面永久歪着。这个契约在
`SimultaneousDragGesture.swift:73-77` 有明确说明。

### B.6 视觉挂载

```swift
ZStack { ... }                                    // 现有根 ZStack(:128)
    .scaleEffect(dismissScale, anchor: .top)
    .clipShape(RoundedRectangle(cornerRadius: dismissCornerRadius))
    .offset(y: dismissDragOffset)
    .background(WarmTheme.background.ignoresSafeArea())   // 露出区底色
```

### B.7 grabber

复用 `UnscheduledDrawer.swift:167-182` 的实现，放在导航栏下方、ScrollView 之上，
水平居中。上下 `WarmSpacing.xs`(8pt) padding。

**与 UnscheduledDrawer 的差异**：那个 grabber 可点击（切换展开）；这里
**不要**加 `onTapGesture`，它只是一个视觉指示器。a11y 用
`.accessibilityHidden(true)`（关闭动作由左上角按钮承担，已有
`accessibilityLabel("panel.close")`，`:429`）。

顶部 padding（`:370` 的 `WarmSpacing.xxxl`=48pt）需要减去 grabber 占用的约 21pt，
改为 `WarmSpacing.xl`(24pt)，重新验证 compact toast（`:468-476`）不遮标题卡。

### B.8 风险：dismiss 时的位移跳变

调 `dismiss()` 时 `dismissDragOffset` 可能是 150pt，而 `fullScreenCover` 的系统出场动画
是从「原位」开始下滑的 —— 可能出现「先跳回原位再滑出」的跳变。

实测确认。若有跳变，改成先动画推出屏幕再 dismiss：

```swift
withAnimation(.easeOut(duration: 0.22)) { dismissDragOffset = UIScreen.main.bounds.height }
DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { dismiss() }
```

代价是与系统转场时长叠加，需要调参。**这个坑是方案 A 完全没有的**，
也是推荐方案 A 的主要理由之一。

---

## HTML 原型规格（给画原型的 AI）

目的：先看手感对不对，再决定走 A 还是 B。**原型只验证方案 B 的视觉，
因为方案 A 的手感就是 iOS 系统 sheet，不需要原型。**

### 要做出来的东西

一个 iPhone 尺寸（**390 × 844**）的模拟屏，里面放详情页的静态复刻，
支持鼠标拖拽 / 触摸拖拽，实时演示 B.3 的物理曲线。

### 页面内容（静态复刻即可，不需要真实功能）

从上到下：

1. 导航栏：高 44px，左侧 `chevron.down` 图标（24px），居中标题「详情」
2. **grabber**：38×5px 圆角胶囊，居中，上下留白各 8px ← **本次新增，重点**
3. 内容区（垂直间距 20px，左右 padding 24px，可滚动）：
   - 标题卡：白底，圆角 20px，内 padding 20px，阴影 `0 5px 10px rgba(30,42,58,.14)`。
     内含 4×32px 彩色竖条 + 「标题」小字（13px `#5C6A7A`）+ 标题文本（20px `#1E2A3A`）
   - 备注卡 / 时间卡 / 重复卡 / 分类卡 / 优先级卡：白底，圆角 16px，内 padding 12px，
     阴影 `0 2px 4px rgba(30,42,58,.10)`。每张卡顶部一行 13px `#5C6A7A` 的小标题，
     下面塞占位内容（chip 行 / 文本行皆可）
   - 底部：红色「删除」文字链（14px `#E5484D`）+ 创建时间小字（12px `#8E97A4`）
4. 内容要**足够长可滚动**（至少 1.5 屏），用于验证「滚到顶后继续下拉才接管」

### 配色 token（来自 `UI/Shared/DesignSystem.swift`，浅色模式）

| 用途 | 值 |
|---|---|
| 页面背景 / 露出区 | `#F4F5F7` |
| 卡片背景 | `#FFFFFF` |
| 主文字 | `#1E2A3A` |
| 次要文字 | `#5C6A7A` |
| 弱化文字 | `#8E97A4` |
| grabber | `#8993A4`，alpha 0.4 → 0.7 |
| 主色（珊瑚橙） | `#FF8A6B` |
| 危险色 | `#E5484D` |
| 分类色（标题竖条，随便挑一个） | `#6B8FE8` |
| 轻阴影 | `rgba(30, 42, 58, 0.10)` |
| 中阴影 | `rgba(30, 42, 58, 0.14)` |
| 圆角 | 卡片 12 / 区块 16 / 弹窗 20 |

### 交互实现要点

1. **跟手**：`pointerdown` / `touchstart` 起手，`pointermove` 时
   `offset = max(0, currentY - startY)`，实时更新 transform。**必须用
   `transform: translateY()` + `scale()`，不要用 `top`**，否则掉帧。
   拖拽期间关掉 CSS transition（`transition: none`），松手时再打开。
2. **接管规则**：只有 `scrollContainer.scrollTop <= 0` **且**手指向下时才进入拖拽模式；
   否则是正常滚动。关键是**同一次手势内**从滚动切到拖拽，不要求抬手。
   这一条是原型要验证的核心，请重点确认手感连续。
3. **松手判定**：`offset > 120 || velocity > 800 px/s` → 播放关闭动画
   （`translateY(844px)`，220ms `ease-out`），然后 2 秒后自动复位便于反复试；
   否则弹回 0，用 spring 近似曲线
   `cubic-bezier(0.34, 1.36, 0.64, 1)`，350ms（对应 `WarmAnimation.springSmooth`
   response 0.35 / damping 0.7）。
   速度取最近两帧 `Δy / Δt`。
4. **阈值反馈**：`offset` 跨过 120 时，grabber 变色到 alpha 0.7 并
   `navigator.vibrate?.(10)`（桌面浏览器无效不影响），同时在屏幕外
   加一行调试文字「已越过阈值，松手关闭」。回落到 120 以下复位。
5. **调试面板**：屏幕右侧（模拟屏之外）实时显示 `offset / progress / scale /
   radius / velocity / 是否越过阈值`，方便调参。
6. **参数可调**：把 B.2 的 6 个常量做成滑杆
   （dismissTranslation / dismissVelocity / visualTravel / minScale /
   maxCornerRadius / 回弹时长），我们要用原型直接调出最终数值，
   再回填到 Swift 常量里。

### 明确不需要做的

- 真实的编辑功能、日期选择器、数据持久化
- 深色模式
- 左上角按钮的关闭逻辑（画出来即可，不用能点）
- 键盘两段式（HTML 里模拟不出软键盘，实测在真机做）

---

## 实施步骤

### 第 0 步（必做，先于一切）

iOS 26 真机 / 模拟器验证当前 `:388` 的下滑关闭是否还生效。记录结果。

### 走方案 A

1. `HomeView.swift:818-823` `fullScreenCover` → `sheet` + `.presentationDetents([.large])`
   + `.presentationDragIndicator(.visible)`
2. `TodoDetailView.swift` 删除「方案 A」一节列出的全部死代码
3. `ScrollView` 加 `.scrollDismissesKeyboard(.interactively)`
4. 实测键盘行为，不满足则保留 `isKeyboardVisible` +
   `.interactiveDismissDisabled(isKeyboardVisible)`
5. 重量顶部 padding（`:370`），验证 compact toast（`:468-476`）不遮标题卡
6. 跑 `VoiceTodoUITests/DetailKeyboardUITests.swift`，大概率要改

### 走方案 B

1. 按 B.1 / B.2 加状态与常量，删除 `dragStartedAtTop`、`isScrollViewAtTop`、
   `DetailScrollOffsetKey`、`DetailScrollCoordinateSpace`、`.onPreferenceChange`、
   ScrollView 顶部锚点
2. 按 B.5 换 `SimultaneousDragGesture`（**别忘 `onCancelled`**）
3. 按 B.6 挂视觉，参数用 HTML 原型调出来的最终值
4. 按 B.4 加阈值 haptic
5. 按 B.7 加 grabber + 重量顶部 padding
6. 按 B.8 实测 dismiss 跳变，必要时加推出动画
7. 跑 `VoiceTodoUITests/DetailKeyboardUITests.swift`

---

## 验收清单

**跟手**

- [ ] 手指按住页面任意空白处下拉，页面**立即**跟随，无 40pt 死区
- [ ] 慢速拖到 100pt 松手 → 平滑回弹，不闪烁不跳变
- [ ] 慢速拖到 150pt 松手 → 关闭
- [ ] 快速轻扫 60pt 松手 → 关闭（速度通道生效）
- [ ] 上滑 → 页面不动（clamp 生效），不出现负位移
- [ ] 越过 120pt 时有一次 haptic，回落再越过可再次触发，不连续震

**滚动接管**

- [ ] 内容滚到中段时下拉 → 正常滚动，页面不跟手
- [ ] 滚到顶后**不抬手**继续下拉 → 无缝接管，中间不掉帧、不需要第二次手势
- [ ] 接管过程中 List 不出现 bounce 抢位

**grabber**

- [ ] 顶部居中可见，不与导航栏、compact toast 重叠
- [ ] 拖拽时宽度 / 颜色随 progress 变化
- [ ] VoiceOver 不朗读 grabber

**键盘**

- [ ] 键盘弹起时下滑 → 只收键盘，页面不跟手、不关闭
- [ ] 键盘收起后再下滑 → 正常关闭
- [ ] 硬件键盘连接（软键盘不出现）时下滑 → 直接走关闭语义

**数据**

- [ ] 改标题后立刻下滑关闭 → 改动已落盘（`onDisappear` 兜底 `:444-450`）
- [ ] 关闭过程中不弹「放弃修改」类确认

**回归**

- [ ] 左上角 `chevron.down` 行为不变
- [ ] 删除按钮的二次确认 alert 正常
- [ ] 详情页内 toast（保存成功 / 校验失败）位置不被 grabber 挤动
- [ ] iOS 26 上手势稳定触发（呼应第 0 步）

---

## 不做的事

- **不做 coach mark / 引导动画。** 理由见「为什么不做引导动画」。
  如果上线后数据显示仍有用户找不到关闭方式，优先怀疑 grabber 的可见性，而不是加引导。
- **不加误触确认弹窗**（`isModalInPresentation` + alert）。实时保存已经解决了这个问题，
  加确认是给已解决的问题加摩擦。
- **不动持久化层**。本次改动纯 UI 层，`persistChanges` / `scheduleAutosave` /
  `checkForChanges` 一行不碰。
