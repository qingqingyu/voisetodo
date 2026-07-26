# 长 dueHint 溢出 —— 跑马灯方案

> 状态：**方案已定，待实现**。本文是实现依据，按此改即可；改完再走 review。

## 背景

解析完成后 AI 返回的 `dueHint` 是**用户原话的逐字保留**，不是归一化标签。Cloudflare Worker 的 system prompt 两个 locale 都明写了这一点：`AIProxy/src/adapters/base.js:125`「due_hint 始终保留用户原文」、`:245`"due_hint always preserves the original text"。因此它长度无界——few-shot 里就有 30–43 字符的例子，如 `"by the end of this month"`、`"every day at 3pm for the next month"`、`"每个月15号下午3点"`。

`title` 在 `Protocols/Models.swift:265` 被 `TextUtils.truncateTitle(maxLength: 200)` 截断，但 `sanitizeDueHint`（同文件 236–244 行）只做 trim 和伪 null 过滤，**全链路没有任何长度上限**。

### 真正的根因

`UI/Home/ChipView.swift:103` —— chip 的 `Text` 挂了 `.fixedSize(horizontal: true, vertical: false)`，且**没有** `lineLimit` / `truncationMode` / `maxWidth`。chip 因此以完整 intrinsic 宽度参与布局且不可压缩。

两个溢出现场：

- **现场 A —— `UI/Home/PendingDateTodoRow.swift`**（待定日期卡片）。行结构是 `HStack`: checkbox(44) + `VStack(标题, ChipView(.loose))` + `Spacer` + 「选日期」按钮。那个按钮在 `:111` 也挂了 `.fixedSize(horizontal: true)`（注释 107–110 解释：不挂会被压成竖排的 `Pic k / dat e`）。于是一行里有**两个不可压缩的兄弟**，唯一能让步的是标题——它已经被迫加了 `.lineLimit(2) + .truncationMode(.tail)`（注释 70–75 明确说这是「文本截断/换行零容忍」原则的"有按钮挤压"例外条款）。长 hint 直接吃掉标题的可读空间。
- **现场 B —— `UI/Home/WarmTodoCard.swift:296-304`**（卡片第二行那段灰字）：`clock` 图标 + `Text(composedTimeText)` 10pt `textSecondary`，同样没有 `lineLimit`。长文本在这里换行、把卡片撑高——正好抵消掉 `:253-255` 注释记录的那次 P1 优化（"元数据合并成一行，卡片高度降三分之一"）。

这个问题一直没在开发中暴露，是因为 `UI/MockStore.swift:311-317` 和所有 SwiftUI preview 用的都是短中文 hint（`"今天"`、`"周三前"`）。

### 为什么选跑马灯

候选方案与取舍：

- **(a) 截断 chip** 违反项目已成文的「文本截断/换行零容忍」原则（该原则在 `ConfirmSheetView.swift:203`、`PendingDateTodoRow.swift:74`、`WarmTodoCard.swift:288`、`UnparsedTodoCard.swift:9` 四处被引用）。
- **(b) chip 换行**（可用现成的 `UI/Shared/FlowLayout.swift`）会让卡片高度不齐，且 chip 单独占一行时视觉重量失衡。
- **(c) 牺牲卡片高度** 可行但会回退掉 `WarmTodoCard:253-255` 那次"高度降三分之一"的优化。
- **跑马灯**是唯一同时满足"不丢字"和"卡片等高"的方案。代价是引入动画——因此下面的设计把它约束成"只在真的放不下时才动，且随时可停"。
- **不采纳"改 AI prompt 限制 due_hint 长度"**：`due_hint` 保留原文是写进 prompt 的契约，`Protocols/Domain/TodoTimeDisplayComposer.swift` 的兜底语义、`AIProxy/worker.test.js:1061-1120` 的透传断言都依赖它；更关键的是 LLM 输出长度无法强制，前端兜底照样得写。

### 目标行为

- 文字放得下 → 和现在**完全一致**，不测量、不动画、不起 timer。（`下午`/`今晚`/`这个周末` 都属于这一档。）
- 放不下 → 容器宽度固定，文字横向滚动：**开头停 ~1.5s → 慢速滚到尾 → 停 ~1s → 回到开头**，循环；溢出侧加渐隐遮罩。
- 卡片滚出屏幕时暂停。
- `accessibilityReduceMotion` 开启时完全不动，退化为静态截断 + 渐隐。
- VoiceOver 无论滚到哪都朗读完整字符串。

**范围**：现场 A 和现场 B。不动 ConfirmSheet、Widget、TodoDetailView，不动 AI prompt。

## 实现

### 1. 新文件 `UI/Shared/MarqueeText.swift`

一个可复用的单行跑马灯。`UI/Shared` 在 `project.yml:57` 是整目录 glob，新文件自动进 target，**不需要改 project.yml**（重跑 `xcodegen generate` 即可）。

**布局机制（不需要 `GeometryReader`，也不会形成布局回环）**：视图由两层叠成——

- **布局锚层**：一份 `Text(text).lineLimit(1)`，**不挂** `fixedSize`，`.opacity(0)`。不挂 fixedSize 的 `Text` 的 ideal width = 完整 intrinsic、min width 极小，所以它在父容器里的实际宽度天然就是 `min(文字宽, 父给的宽)`——这正是我们要的"有空间就贴合内容，没空间就让步"。它只撑布局，永不显示。
- **显示层**：`.overlay(alignment: .leading)` 里放一份**挂了** `fixedSize(horizontal: true)` 的同样 `Text`，永远是完整文字，按相位做 `.offset(x:)`，外层 `.clipped()` 裁掉超出部分。

两个宽度都用已有的 `.onGeometryChange(for: CGFloat.self)` 读（用法参照 `UI/Home/HomeView.swift:1351`）：锚层的实际宽度 = 可用宽，显示层的宽度 = intrinsic 宽。**`offset` 只是 transform，不改变任何一层的尺寸**，所以测量不会反过来触发重新布局。`travel = max(0, intrinsic − 可用)`；`travel == 0` 时走静态分支。

**动画驱动：无状态 `TimelineView(.periodic(from: .now, by: 1.0/30.0))`。** 理由（都写进 doc comment）：

- 不用 `@State + .onAppear + .repeatForever`——`List` 的 cell 随滚动被回收重建，`@State` 重置会让滚动位置跳变，与 `ConfirmGroupedList.swift:163-166` 记录的 `StreamingFooter` 闪烁问题同源；也避开 `BottomInputPanelView.swift:145-146` 记录的 `.repeatForever` 停不下来的 SwiftUI 缺陷。
- 用 `.periodic(by: 1/30)` 而非 `.animation`：同 `ConfirmGroupedList.swift:168-169` 与 `WaveformView.swift:27` 的 30Hz 选择。22pt/s 的速度下每帧位移 0.73pt，30fps 足够顺滑，又不像 `.animation` 每帧重绘那样在低端机掉帧。
- 相位从 `context.date.timeIntervalSinceReferenceDate` 算，与 schedule 的锚点无关，所以 cell 重建后相位连续。

**错峰：确定性相位偏移。** 多张卡片整齐划一地同时滚动像商场广告屏，很机械。但"按各自入场时刻起算"要存一个 `@State` 时间戳，而 `List` 里 cell 回收重建会把它重置——卡片滚出再滚回，跑马灯就从头再来一遍，正是上面要避开的问题。

两全的做法是**从内容本身哈希出一个稳定的相位偏移**：

```swift
/// 每个实例的固定相位偏移,让同屏多张卡片错峰滚动。
/// 用文本内容哈希而不是"入场时刻":后者要存 @State,List cell 回收重建时会重置,
/// 跑马灯会从头再来;哈希是纯函数,重建后偏移不变、相位连续。
/// 用 stableHash 而非 Swift 的 `hashValue` —— 后者带每进程随机 seed,
/// 同一条 todo 每次冷启动的错峰位置都不同。
private var phaseShift: Double {
    Double(MarqueePhase.stableHash(text) % 1000) / 1000 * cycleDuration
}
```

`stableHash` 用 FNV-1a 之类的固定算法自己写（几行），**不能用 `String.hashValue`**——它带每进程随机 seed，冷启动后错峰位置会变。这样既错峰又无状态。

**相位数学抽成纯 struct `MarqueePhase`（同文件），这样能单测**——View 本身没法断言 offset：

```swift
struct MarqueePhase {
    var travel: CGFloat          // 需要滚动的距离 = intrinsic − 可用宽
    var speed: Double = 22       // pt/s
    var startPause: Double = 1.5
    var endPause: Double = 1.0
    var fade: Double = 0.35      // 回到开头时的淡出/淡入时长

    var scrollDuration: Double { travel <= 0 ? 0 : Double(travel) / speed }
    var cycleDuration: Double { startPause + scrollDuration + endPause }

    func offset(at t: Double) -> CGFloat   // 0 → −travel，尾段保持 −travel
    func opacity(at t: Double) -> Double   // 周期首 fade 秒淡入、末 fade 秒淡出
    func edgeOpacities(at t: Double) -> (leading: Double, trailing: Double)

    static func stableHash(_ s: String) -> UInt64   // FNV-1a，跨进程稳定
}
```

调用方传入的时间是 `context.date.timeIntervalSinceReferenceDate + phaseShift`，错峰只影响传进来的 `t`，`MarqueePhase` 本身仍是纯函数。

回到开头不做"快速滑回"（会很显眼），而是**在周期末 0.35s 淡出、周期首 0.35s 淡入**，位移在不可见时瞬间归零。这要求 `startPause`/`endPause ≥ fade`，当前取值满足。

**三个静态短路条件**，任一命中就完全不建 `TimelineView`、不起帧、渲染成一个普通 `Text`：

- `travel <= 0`（文字放得下）——绝大多数 hint 走这条，**零成本**；
- `@Environment(\.accessibilityReduceMotion)` 为真；
- 卡片滚出视野——`.onScrollVisibilityChange(threshold: 0.05) { isVisible = $0 }`。

**threshold 为什么取 0.05 而不是 0.5**：offset 是绝对时间的纯函数，所以"暂停"只是停止重绘、并不冻结相位——恢复渲染的那一刻会直接跳到当前时刻应有的位置，暂停越久跳得越远。取 0.5 的话，这个跳变发生在卡片半可见时、正对着用户眼睛；取 0.05 则推到卡片几乎完全出屏的位置，肉眼基本抓不到。省帧收益差别不大——`List` 本身早就把远处的 cell 拆掉了，这个 threshold 只兜住"贴着边缘还活着"的那一两张。

**边缘渐隐：动态强度，不是 on/off。** 遮罩是 `.mask` 一个 4 段 stop 的 `LinearGradient`，渐隐宽度 10pt，两端的 stop opacity 按"该侧还剩多少没露出来"连续插值，而不是布尔开关：

```swift
let fadeWidth: CGFloat = 10
let scrolled  = -currentOffset            // 左边已经滚进去多少
let remaining = travel - scrolled         // 右边还剩多少没露
let leadingOpacity  = 1 - min(1, scrolled  / fadeWidth)   // 1 = 不虚,0 = 全虚
let trailingOpacity = 1 - min(1, remaining / fadeWidth)
```

代价只是把两个常量换成两个 `min` 表达式，所以直接做精细版：文字刚起步时左侧渐隐由实转虚、快滚到尾时右侧由虚转实，跟 Apple Music 的观感一致，没有"渐隐突然出现/消失"的闪跳。`travel == 0` 时两端 opacity 都是 1，遮罩退化成纯不透明矩形，短文字两端不会发虚。

**无障碍**：`.accessibilityElement(children: .ignore)` + `.accessibilityLabel(text)`，VoiceOver 读完整字符串，与滚动位置无关。

顺带修一个已有缺陷：`ChipView.swift:118` 现在只有 `.accessibilityElement(children: .ignore)` 而**没有 label**，等于把 chip 文字对 VoiceOver 完全隐藏了；`WarmTodoCard.swift:291` 外层的 `.combine` 也因此收不到钟点。补一行 `.accessibilityLabel(text)`。

### 2. `UI/Home/ChipView.swift`

加一个溢出策略开关，**放在属性列表最末**，这样两个现有调用点的 memberwise init 实参顺序都不用动：

```swift
/// 文本溢出时怎么办。
enum Overflow {
    /// 按 intrinsic 宽度占位、永不压缩(默认,保持旧行为)。
    /// 用于长度可预期的短文本 —— 如 `.solid` 的钟点 "18:00"。
    case intrinsic
    /// 宽度可被父压缩;压到放不下时文字跑马灯滚动。
    /// 用于 AI 原文这类长度无界的文本。
    case marquee
}
var overflow: Overflow = .intrinsic
```

`label`（99–119 行）里把 `Text` 换成按 `overflow` 分支：`.intrinsic` 保留现在的 `.fixedSize(horizontal: true, vertical: false)` 原样；`.marquee` 换成 `MarqueeText(text: text, font: labelFont)`。padding / 背景 / 圆角 / dot 全部不动——因为 `MarqueeText` 的布局锚会贴合内容，背景 `RoundedRectangle` 照样 hug 短文字。

### 3. 现场 A —— `UI/Home/PendingDateTodoRow.swift:79-83`

只加一个参数：

```swift
ChipView(
    text: looseChipText,
    style: .loose,
    accent: WarmTheme.textMuted,
    overflow: .marquee
)
```

**这里不需要额外算宽度预算**——去掉 `fixedSize` 本身就是完整的解法。原来一行里有两个不可压缩兄弟（chip 和「选日期」按钮），现在只剩按钮一个；`HStack` 先满足 `fixedSize` 的按钮和 44pt checkbox，剩下的给 `VStack`，chip 在 `VStack` 里取 `min(intrinsic, 剩余)`。`:111` 那个按钮的 `.fixedSize` 必须**保持不动**（注释 107–110 记录了去掉会变成竖排 `Pic k / dat e`）。

标题的 `.lineLimit(2)`（76–77 行）保留，但压力大幅下降：chip 不再抢宽度了。

### 4. 现场 B —— `UI/Home/WarmTodoCard.swift:296-304`

这里不是 `ChipView`，直接复用同一个 primitive：

```swift
if let timeText = composedTimeText {
    HStack(spacing: WarmSpacing.xxs) {
        Image(systemName: "clock")
            .font(.system(size: 10))
        MarqueeText(text: timeText, font: WarmFont.caption(10))
    }
    .foregroundColor(WarmTheme.textSecondary)
}
```

注意 `composedTimeText` 不只是裸 hint——`TodoTimeDisplayComposer.compose` 还可能拼出「每天 · 至8月5日 · 15:00」这种长串，同样受益。卡片高度回到恒定的两行，`:253-255` 那次"高度降三分之一"的优化不再被长文本抵消。

### 5. Dynamic Type / AX5 —— 为什么不会重犯「陷阱 B」

`DesignSystem.swift:259-264` 的陷阱 B 警告：`HStack` 里没挂 `fixedSize` 的 `Text` 会被优先压缩（compression-resistance 250），即使还有余量也被压成 `…` 伪截断。这次**故意**让 chip 变成不挂 `fixedSize`——正是陷阱 B 描述的配置。

之所以安全：被压缩的那层是 `.opacity(0)` 的布局锚，**永远不显示**，所以 `…` 不可能出现在屏幕上；真正显示的是 overlay 里挂了 `fixedSize` 的完整文字。压缩过度的后果只是"跑马灯提前启动"，是优雅降级而非视觉缺陷。

为防 AX5 下锚层被压到几乎为零，给 `MarqueeText` 一个常量下限 `.frame(minWidth: 36, alignment: .leading)`（常量，不参与测量，不会形成回环）。

### 6. 测试与 fixture

现状是 `ChipView` / `WarmTodoCard` / `PendingDateTodoRow` **零测试覆盖**，且预览与 mock 只有短中文 hint（`UI/MockStore.swift:311-317` 最长的是「月底前」3 个字），这正是这个问题一直没暴露的原因。

- 新增 `VoiceTodoTests/UI/MarqueePhaseTests.swift`（`VoiceTodoTests` 在 `project.yml:181` 也是整目录 glob）：
  - `travel == 0` 时 offset 恒 0 / opacity 恒 1（零成本路径）；
  - 停顿段 offset 不变、滚动段单调不增、滚动结束时 offset == −travel；
  - `offset(t) == offset(t + cycleDuration)`（周期性）；
  - opacity 在位移归零的那一刻恰好为 0（回跳不可见）——这条是"淡出回头"设计成立的关键；
  - 边缘遮罩：起点 leading opacity == 1、滚过 fadeWidth 后 == 0；终点 trailing opacity == 1；
  - `stableHash` 对同一字符串跨调用恒定，且不同文本的相位偏移分散（不要断言具体哈希值，只断言确定性与分散度）。
- 往 `MockStore.preview` 补两条长 hint fixture，中英文各一：`"by the end of this month"`、`"每个月15号下午3点"`。
- `MarqueeText` 与 `PendingDateTodoRow` 各加 `#Preview`，覆盖短/长 × 默认字号/AX5 四种组合——AX5 用已有写法 `.environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge)`（参照 `UI/Home/HomeView.swift:2070`）。
- 给 `ChipView` 加一个可选 `accessibilityIdentifier` 参数，让 chip 首次变得可被 UI 测试定位（现在它没有任何 identifier）。

### 明确不动的东西

`UI/ConfirmSheet/TodoItemRow.swift`（sheet 更宽、可竖向滚动，压力最小）、`UI/Widget/TodoWidgetComponents.swift`、`UI/Detail/TodoDetailView.swift`、以及 `AIProxy/` 下的任何 prompt。

## 验收

以下均需在 macOS + Xcode 26 上跑（SwiftUI 无法在 Linux 构建）。

1. `xcodegen generate`（新文件在 glob 目录下，`project.yml` 无需改动），然后构建 `VoiceTodo` scheme。
2. 跑 `VoiceTodoTests`——新的 `MarqueePhaseTests` 全绿，且已有的 `DomainModuleTests` 里 `TodoTimeDisplayComposer` 那 11 个用例（267–350 行）不受影响。
3. Xcode Canvas 看 `MarqueeText` 与 `PendingDateTodoRow` 的新 preview：短文本必须和改动前**像素级一致且完全静止**；长文本容器宽度不变、文字循环滚动、两端渐隐。
4. 模拟器实跑：录一条「这个月底之前交税」和一条英文 "remind me to file taxes by the end of this month"，确认卡片进「待定日期」分组后 chip 滚动、标题不再被挤断、几张卡片并排时高度一致。**同屏至少三条长 hint**，确认它们错峰而不是整齐划一（哈希相位生效），且列表来回滚动后错峰关系不变（cell 回收不重置相位）。
5. 无障碍两项：设置 → 辅助功能 → 动态效果 → 减弱动态效果打开后，文字必须**完全静止**并退化为渐隐截断；VoiceOver 聚焦 chip 时朗读完整字符串（顺带验证前面补的 `accessibilityLabel` 修好了 chip 此前完全不发声的问题）。
6. AX5 字号（设置 → 显示与亮度 → 文字大小拉满 + 辅助功能更大字体）下，确认没有出现 `…` 伪截断，「选日期」按钮没有回退成竖排 `Pic k / dat e`。
7. 长列表滚动时用 Instruments 的 Animation Hitches 快速确认没有掉帧——重点看多张长 hint 卡片同屏的情况。
