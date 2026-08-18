# Onboarding 付费墙合并：让「开始免费试用」真的启动试用

> 状态：待实现
> 分支：`claude/onboarding-paywall-ux-9kvq3i`
> 本文档是可直接执行的实施说明，行号基于本文档写作时的代码状态（`b09f850`）。
> 实施前请先核对行号是否漂移；文件路径和逻辑描述以实际代码为准。
>
> ⚠️ **2026-08-18 起本文部分作废**：onboarding 内嵌付费墙步（`proPaywallStep`）已被
> `docs/onboarding-first-voice-trial.md` §3.5 **移出 onboarding**——paywall 改为首次 wow
> 之后弹 app 级 sheet。本文 §3 的「内嵌第三屏」结论不再适用；其关于
> `pendingPaywallAfterOnboarding` 旧方案为何被删的历史记录（§1/§2）仍然有效，勿重蹈覆辙。

---

## 1. 背景与问题

当前 onboarding 的第 3 屏（`proIntroductionStep`）和第 4 屏（`PaywallView` sheet）是割裂的，走一遍流程会明显感到「被卖了两次，但第一次是假的」。

### 1.1 按钮名不副实（核心问题）

`App/OnboardingView.swift:824-838` 的「开始 3 天免费试用」按钮**完全没有碰 StoreKit**：

```swift
Button {
    onTryPro()                    // 只是设一个 flag
    hasCompletedOnboarding = true // 关掉 onboarding
} label: {
    Text(String(localized: "onboarding.pro.cta.trial"))  // "开始 3 天免费试用"
    ...
}
```

`onTryPro()` 在 `App/VoiceTodoApp.swift:261` 被实现为 `{ pendingPaywallAfterOnboarding = true }`，
随后 `App/VoiceTodoApp.swift:266-277` 在 600ms 延迟后弹出真正的 `PaywallView` sheet。

用户看到「开始 3 天免费试用」，预期的是 iPhone 上的标准试用流程——按下去弹出 Apple 系统购买弹窗，
确认后即刻开始三天免费、到期自动续订。实际上它只是翻了一页。**这是本次要修的主要问题。**

### 1.2 600ms 延迟是个 hack

SwiftUI 同时只允许一个 modal，所以必须等 onboarding sheet 的 dismiss 动画结束才能 present paywall：

```swift
// App/VoiceTodoApp.swift:266-277
.onChange(of: hasCompletedOnboarding) { _, completed in
    guard completed else { return }
    showOnboarding = false
    guard pendingPaywallAfterOnboarding else { return }
    pendingPaywallAfterOnboarding = false
    // onboarding sheet spring dismiss ≈ 350ms,留 600ms 余量保证完全消失再 present paywall
    Task { @MainActor in
        try? await Task.sleep(nanoseconds: 600_000_000)
        guard hasCompletedOnboarding else { return }
        coordinator.showPaywall = true
    }
}
```

这个延迟连带出一个持久化 flag `pendingPaywallAfterOnboarding`（`App/VoiceTodoApp.swift:28`），
还要在 UI 测试的 `resetUserData` 分支里手动清除（`App/VoiceTodoApp.swift:55`）。
两屏合并后这套机制整体消失。

### 1.3 `completionStep` 对免费用户是死代码

`visibleSteps`（`App/OnboardingView.swift:55-66`）产出的顺序是
`welcome → voicePermissions → [actionButton] → proIntro → completion`，
但 proIntro 的**两个按钮都**直接设 `hasCompletedOnboarding = true`（第 826、842 行）。

结果：免费用户永远看不到那个撒花庆祝页（`completionStep`，第 876 行起）。
只有已订阅用户（proIntro 被 `isPro` 过滤掉）才走得到。这是一段对绝大多数新用户不可达的 UI。

### 1.4 试用资格没校验（App Store 审核风险）

`UI/Paywall/PaywallView.swift:409` 对每个商品卡都硬写「含 3 天免费试用」：

```swift
Text(String(localized: "paywall.card.trial_included"))
    .foregroundColor(WarmTheme.success)
```

从不查 `isEligibleForIntroOffer`。老用户退订后重新订阅会看到一个不会兑现的承诺——
这是 App Store 审核会挑的点，也是真实的用户欺骗。同样的问题存在于
`paywall.subtitle`、`onboarding.pro.bullet.trial.title` 等硬编码「3 天」的文案。

### 1.5 好消息：购买逻辑不用新写

`App/EntitlementManager.swift:121-147` 的 `purchase(_:)` 已经是完整的 StoreKit 2 实现：

```swift
func purchase(_ product: Product) async {
    isPurchasing = true
    lastError = nil
    defer { isPurchasing = false }
    do {
        let outcome = try await product.purchase()
        switch outcome {
        case .success(let verification): ... await transaction.finish(); await refreshEntitlements()
        case .userCancelled: ...
        case .pending: lastError = String(localized: "paywall.pending")
        @unknown default: break
        }
    } catch { lastError = ErrorMessages.paywallPurchaseFailed }
}
```

`userCancelled` / `pending` / 错误分支、`transaction.finish()`、权益刷新都齐了。
**本次只是把它接到 onboarding 里，不改购买本身。**

---

## 2. 目标流程

```
welcome → voicePermissions → [actionButton] → proPaywall → completion → HomeView
                                                  │
                                                  ├─ 点「开始 N 天免费试用」→ Apple 系统购买弹窗
                                                  │     ├─ 成功 → 自动前进到 completion
                                                  │     ├─ 取消 → 停留在本页，无报错，可再点
                                                  │     └─ 失败 → 页内错误提示 + 重试
                                                  └─ 点「以后再说」→ 前进到 completion
```

关键变化：

1. 第 3 屏就是真付费墙（真实价格 + 真实购买），第 4 屏 sheet 从 onboarding 路径上消失。
2. 订阅成功和「以后再说」都收敛到 `completionStep`，庆祝页对所有用户可达。
3. 只有在庆祝页点「开始使用」才 `hasCompletedOnboarding = true`。

不变的部分：

- 已订阅用户（`isPro == true`）仍然跳过 proPaywall 这一步。
- `AppCoordinator.showPaywall`（配额耗尽提示、设置页手动入口）继续使用 sheet 形态的 `PaywallView`。

---

## 3. 实施步骤

### 3.1 `App/EntitlementManager.swift` — 暴露试用资格

新增两个 `@Published` 属性，让两处付费墙界面共享同一份判断，StoreKit 逻辑不外泄到 View：

```swift
/// 当前 Apple ID 是否还能享受该订阅组的介绍性优惠（免费试用）。
/// 老用户退订后重订将为 false —— 此时必须隐藏试用文案（App Store 审核要求）。
@Published private(set) var isEligibleForIntroOffer = false

/// 介绍性优惠时长（如 3 天）。nil 表示商品未配置试用或当前无资格。
@Published private(set) var introOfferPeriod: Product.SubscriptionPeriod?
```

在 `loadProducts()`（第 65-86 行）成功拿到商品之后计算。要点：

- **资格是订阅组级别的**，不是单个商品级别。用
  `Product.SubscriptionInfo.isEligibleForIntroOffer(for: groupID)`，
  `groupID` 取自 `products.first?.subscription?.subscriptionGroupID`——
  月付和年付在同一订阅组（见 `EntitlementManager.swift:13` 的注释）。
- `introOfferPeriod` 取 `products.first?.subscription?.introductoryOffer?.period`。
- **失败保守处理**：groupID 为 nil、offer 为 nil 或查询抛错 → 一律当作无资格
  （`isEligibleForIntroOffer = false`、`introOfferPeriod = nil`），宁可少承诺不可多承诺。
- 商品加载失败（`.empty` / `.error`）时也要把两个属性重置掉，避免上一次的状态残留。

沿用文件里现有的日志风格补一行，便于线上排查：

```swift
VoiceTodoLog.app.info("entitlement.intro_offer eligible=\(self.isEligibleForIntroOffer) hasPeriod=\(self.introOfferPeriod != nil)")
```

**加载期间的状态（C 点，重要）**

`Product.SubscriptionInfo.isEligibleForIntroOffer(for:)` 是 async API，在 `loadProducts()` 返回之后还要单独查一次。从「商品加载完成」到「资格查询完成」之间有一个短暂窗口：

- 如果 CTA 此刻按 `isEligibleForIntroOffer = false` 渲染「订阅 Pro」，资格查完翻成 true 后会抖成「开始 N 天免费试用」；
- 反过来也成立。

老用户退订后重订场景尤其刺眼——先变相承诺试用、再变脸，正是 1.4 节想修的那类欺骗。

加一个第三态：

```swift
/// intro offer 资格查询的加载态。true 期间 CTA 显示 spinner、不渲染文案，
/// 避免资格查询完成前后文案抖动造成「先承诺再变脸」。
/// 商品加载失败（.empty/.error）时此值无意义——CTA 那时不渲染。
@Published private(set) var isCheckingIntroOffer = true
```

`loadProducts()` 成功后把 `isCheckingIntroOffer` 置 true，再 await 资格查询，查完置 false；`loadProducts()` 失败分支里也置 false（CTA 不渲染，没必要让 spinner 一直转）。`PaywallContent` 的 CTA 在 `isCheckingIntroOffer == true` 时显示 spinner、不渲染文案；只有 false 后才决定显示「订阅 Pro」还是「开始 N 天免费试用」。

### 3.2 `UI/Paywall/PaywallView.swift` — 抽出可复用内容 + 改为「选择 + 单一 CTA」

把文件拆成三块：

**① `PaywallContent`（新增，internal）**

现有的 `header`（第 58-73 行）/ `comparisonCard`（第 84-95 行）/ `valuePropsList`（第 218-237 行）/
`productList`（第 241-273 行）/ `legalText`（第 334-342 行）/ `restoreButton`（第 346-367 行）
全部搬进来，再加一个新的主 CTA 按钮。

接一个 presentation context 参数来微调两处的呈现差异：

```swift
enum PaywallPresentationContext {
    case sheet       // AppCoordinator.showPaywall / 设置页入口
    case onboarding  // onboarding 第三屏内嵌
}
```

只用它控制 padding、是否渲染 header 的 `sparkles` 图标这类外观差异——
**内容和购买逻辑两处完全共用**，不要分叉出两套。

**② `PaywallView`（保留，对外签名不变）**

```swift
struct PaywallView: View {
    var body: some View {
        NavigationStack {
            ScrollView { PaywallContent(context: .sheet) }
                .background(WarmTheme.background.ignoresSafeArea())
                .navigationTitle(...)
                .toolbar { /* 关闭按钮，第 36-48 行原样保留 */ }
        }
        .task { await entitlement.refresh() }
        .onChange(of: entitlement.isPro) { _, becamePro in if becamePro { dismiss() } }
    }
}
```

调用方（`App/VoiceTodoApp.swift:227-231` 的 `coordinator.showPaywall` sheet）**完全不用改**。

**③ `ProductCard`（第 372-442 行）— 从「点击即购买」改为「点击即选中」**

当前每张卡片本身是个 Button，点下去直接 `entitlement.purchase(product)`（第 267 行）。
改成选择语义：

- 新增 `let isSelected: Bool`，选中时加 `WarmTheme.primary` 描边（复用现有
  `RoundedRectangle(cornerRadius: WarmRadius.card)` 的 `.stroke`）。
- `action` 改为只设 `selectedProductID`，不再触发购买。
- 卡内那行「含 3 天免费试用」（第 409-413 行）改为**仅在 `entitlement.isEligibleForIntroOffer` 为 true 时渲染**。

**购买中的视觉态（A 点，重要）**

`entitlement.isPurchasing == true` 时，所有 ProductCard 都要 `disabled` + `opacity(0.5)`，**不只是主 CTA 显 spinner**。否则用户在 StoreKit 系统弹窗出现前的几百毫秒里还能切换商品，让 `selectedProductID` 在飞行中漂移，下次再点 CTA 时购买的就是漂移后的商品。

当前 `ProductCard` 把 `isPurchasing` 仅用于把价格替换成内嵌 spinner（第 417-419 行）。改为选择语义后，**这个内嵌 spinner 一并移除**——spinner 只在主 CTA 上，卡片一律 disable + 弱化。价格保持显示（弱化后），让用户知道在买什么。

**`PaywallContent` 的新状态与主 CTA**

```swift
@State private var selectedProductID: String?
```

默认选中年付（`EntitlementManager.yearlyProductID`），找不到则取排序后的第一个。
`products` 已在 `EntitlementManager.loadProducts()` 里按价格升序排好（第 73 行），
所以「第一个」是月付——注意默认值要显式指定年付，不要依赖数组顺序。

主 CTA 按钮放在商品卡下方、legal 文案上方：

| 场景 | 按钮文案 |
|---|---|
| `isEligibleForIntroOffer == true` 且有 `introOfferPeriod` | `paywall.cta.start_trial %@`，`%@` 填本地化时长 |
| 其他 | `paywall.cta.subscribe` |

时长用 StoreKit 自带的本地化，**不要手写「3 天」**：

```swift
period.formatted(product.subscriptionPeriodFormatStyle)  // "3 days" / "3 天"
```

按钮动作：

```swift
Button {
    guard let product = selectedProduct else { return }
    Task { await entitlement.purchase(product) }
} label: { ... }
.disabled(entitlement.isPurchasing)
.accessibilityIdentifier("PaywallPurchaseButton")
```

`entitlement.isPurchasing` 为 true 时显示 spinner 并 disable（复用现有状态，第 25 行）。
`productLoadState != .success` 时不渲染 CTA——沿用现有的 empty / error 卡片 + 重试按钮
（`stateMessage`，第 275-321 行），那部分逻辑不用动。

**legal 文案分流（第 334-342 行）**

- 有试用资格 → 现有的 `paywall.legal.autorenew`（"试用期结束后自动续费…"）
- 无试用资格 → 新 key `paywall.legal.autorenew_no_trial`（去掉"试用期结束后"的措辞）

**`paywall.subtitle` 的硬编码**

现有值是「更高的每日额度，3 天免费试用」。无试用资格时这句同样在撒谎。
最简处理：无资格时改用只讲额度的文案（可新增 `paywall.subtitle_no_trial`，
或复用 `onboarding.pro.bullet.quota.desc` 的措辞），实施时按视觉效果定。

### 3.3 `App/OnboardingView.swift` — 第三屏变真付费墙

**枚举更名**（第 8-14 行）：`.proIntro` → `.proPaywall`，语义对齐。顺带更新
第 60 行的 `visibleSteps` 过滤、第 106-107 行的 switch、第 138 行的 `shouldHideBottomBar`。

**参数改动**（第 24-32 行）：

```swift
// 删除：
var isPro: Bool = false
var onTryPro: () -> Void = {}

// 新增：
@ObservedObject var entitlement: EntitlementManager
@EnvironmentObject private var quotaUsage: QuotaUsage   // PaywallContent 的 Free vs Pro 对比卡需要
```

**步骤列表稳定性（重要）**

`visibleSteps`（第 55-66 行）当前按 `isPro` 实时过滤。用户在本页订阅成功后 `isPro` 翻转 → 
`.proPaywall` 从列表里消失 → `currentStepIndex` 错位。
现有代码只有第 1099 行的 clamp 兜底，那是防御不是修复。

改为在 `init` 里把 `entitlement.isPro` 快照下来：

```swift
/// onboarding 开始时的订阅状态快照。用户在 proPaywall 页订阅成功会翻转 entitlement.isPro，
/// 若 visibleSteps 跟着实时变化会导致步骤索引错位，故整个 onboarding 期间固定这份快照。
private let showsProStep: Bool
```

`visibleSteps` 里 `.proPaywall` 的分支改判 `showsProStep`。第 1099 行的 clamp 保留作防御。

**`proIntroductionStep`（第 789-856 行）整体替换**

```swift
/// Pro 付费墙：onboarding 内嵌的真实订阅页。
/// 与 sheet 版 PaywallView 共用 PaywallContent —— 价格、试用资格判断、购买调用完全同源。
/// 「以后再说」始终可见，商品加载失败也一样：onboarding 绝不能被网络或 StoreKit 问题卡死。
private var proPaywallStep: some View {
    VStack(spacing: 16) {
        PaywallContent(context: .onboarding)
            .environmentObject(entitlement)
            .environmentObject(quotaUsage)

        Button {
            nextStep()
        } label: {
            Text(String(localized: "onboarding.pro.cta.later"))
                .font(WarmFont.body(15))
                .foregroundColor(sketchColor)
                .padding(.vertical, 8)
        }
        .accessibilityIdentifier("ProIntroLaterButton")
    }
}
```

注意：

- 「以后再说」的 accessibility identifier 沿用现有的 `ProIntroLaterButton`（第 849 行），
  避免无谓地打断可能存在的外部引用。
- 原来的 `ProIntroTrialButton`（第 839 行）消失，被 `PaywallContent` 里的
  `PaywallPurchaseButton` 取代。当前代码库里没有任何测试引用 `ProIntroTrialButton`，可以安全移除。
- `proBadgeIllustration`（第 858-872 行）若不再使用则一并删除，别留死代码。
- 本页现在内容较高，注意它渲染在 `body` 的 `ScrollView` 里（第 96-114 行），
  内嵌 `PaywallContent` 时**不要再套一层 ScrollView**，会造成嵌套滚动。
  `PaywallContent` 本身应只提供 `VStack` 内容，由调用方决定滚动容器。

**视觉层级（B 点，重要）**

`PaywallContent` 内部本身就有 `legalText` 和 `restoreButton`，「以后再说」是 onboarding 独有的外层按钮。两层叠在一起容易乱。预期顺序（自上而下）：

```
┌──────────────────────────────────┐
│  header（sparkles + 副标题）      │
│  comparisonCard（Free vs Pro 对比）│
│  valuePropsList（3 张价值卡）     │
│  productList（月付/年付选择）     │
│  [CTA] 开始 N 天免费试用          │  ← PaywallContent 内
│  legalText                       │  ← PaywallContent 内
│  restoreButton                   │  ← PaywallContent 内
└──────────────────────────────────┘
   「以后再说」（onboarding 独有）   ← proPaywallStep 外层
```

要点：

- 「以后再说」是兜底逃生舱，视觉上弱（小号灰色文字按钮）、位置在最末。**别让它夹在 legal 和 restore 之间**，也别紧跟 CTA——后者会让用户误以为是次等价的购买选项。
- `context: .onboarding` 时 PaywallContent 内部 padding 适当收紧：原 sheet 有 NavigationStack + toolbar 占位，onboarding 内嵌没有，header 上方留白可以减小，让外层「以后再说」与 PaywallContent 在视觉上仍是同一组。
- 商品加载失败（`.empty`/`.error`）落到 `stateMessage` 时，「以后再说」仍要可点——它在 PaywallContent 外层，不受 stateMessage 影响。

**购买成功后自动前进**

在 `body` 上加：

```swift
.onChange(of: entitlement.isPro) { _, becamePro in
    guard becamePro, currentStep == .proPaywall else { return }
    nextStep()   // 前进到 completionStep
}
```

**`nextStep()`（第 1092-1102 行）不改。**
因为 `.completion` 现在真的排在 `.proPaywall` 后面，`nextStep()` 会自然前进到庆祝页；
只有在庆祝页点「开始使用」（`currentStepIndex == totalSteps - 1`）才设
`hasCompletedOnboarding = true`。这正是第 1.3 节那个死代码问题的修复。

**`completionStep`（第 876 行起）**

保留现有撒花插图 + 使用提示卡片。已订阅用户（`entitlement.isPro`）额外显示一行
`onboarding.done.pro_thanks`（新 key）；未订阅则完全维持现状。

### 3.4 `App/VoiceTodoApp.swift` — 拆掉 600ms hack

**删除 `pendingPaywallAfterOnboarding`**（第 24-28 行的声明和注释，第 55 行 `resetUserData` 分支里的清除）。

留一次性迁移，清掉老版本可能残留的值（升级用户不会有功能副作用，但键会一直留在 plist 里）：

```swift
// 迁移：v? 起 onboarding 内嵌付费墙，不再需要跨 modal 的 pending 标志。
UserDefaults.standard.removeObject(forKey: "pendingPaywallAfterOnboarding")
```

**onboarding sheet（第 254-264 行）**改为：

```swift
.sheet(isPresented: $showOnboarding) {
    OnboardingView(
        permissionManager: permissionManager,
        hasCompletedOnboarding: $hasCompletedOnboarding,
        entitlement: entitlementManager
    )
    .environmentObject(entitlementManager)
    .environmentObject(quotaUsage)
    .interactiveDismissDisabled()
}
```

显式注入两个 environment object——sheet 对环境的继承不可靠，
这也是现有代码在第 229-230 行给 `PaywallView` 显式注入的原因，保持一致。

**`.onChange(of: hasCompletedOnboarding)`（第 266-277 行）**整块简化为：

```swift
.onChange(of: hasCompletedOnboarding) { _, completed in
    guard completed else { return }
    showOnboarding = false
}
```

**第 227-231 行的 `coordinator.showPaywall` sheet 保持不变**——配额耗尽和设置页入口仍需要它。

### 3.5 `Resources/Localizable.xcstrings` — 新增 key

项目 `knownRegions` 只有 `Base` / `zh-Hans` / `en`（`project.yml:8-11`），
按现有 515 个 key 的主流写法**只补 `en` + `zh-Hans` 两种语言**
（文件里散落的 17 个 `ja` 条目不是发布语言，不跟）。

新增：

| key | en | zh-Hans |
|---|---|---|
| `paywall.cta.start_trial %@` | Start %@ free trial | 开始 %@ 免费试用 |
| `paywall.cta.subscribe` | Subscribe to Pro | 订阅 Pro |
| `paywall.legal.autorenew_no_trial` | Auto-renews until canceled. Cancel anytime in Settings → Apple ID → Subscriptions. | 订阅后自动续费，可随时在「系统设置 → Apple ID → 订阅」取消。 |
| `onboarding.done.pro_thanks` | Pro unlocked — thanks for the support! | 已解锁 Pro，感谢支持！ |

（若 3.2 节末尾决定拆分 subtitle，再加 `paywall.subtitle_no_trial`。）

可删除的旧 key：

- `onboarding.pro.cta.trial`（假 CTA，被 `paywall.cta.start_trial` 取代）
- `onboarding.pro.title` / `onboarding.pro.subtitle`（第三屏现在直接用 `paywall.title` / `paywall.subtitle`）

**保留** `onboarding.pro.bullet.*`——`PaywallContent` 的 `valuePropsList` 仍在用
（`UI/Paywall/PaywallView.swift:218-237`）。但注意 `onboarding.pro.bullet.trial.title`
硬写了「3 天免费试用」：改为从 `introOfferPeriod` 生成时长，或在无试用资格时整张卡不渲染。

### 3.6 `VoiceTodoUITests/ScenarioTests.swift` — 修 S12

`test_S12_firstLaunch_onboarding`（第 423-459 行）**当前已经是过期的**：
它断言存在独立的「需要你的麦克风」（第 434 行）和「还需要语音识别」（第 437 行）两页，
但这两页早已合并为 `voicePermissionsStep`（`OnboardingView.swift:376`）；
它也完全没有覆盖 proIntro 页。借这次一并重写为真实序列：

```
welcome → voicePermissions → actionButton → proPaywall → completion → 主界面
```

proPaywall 那一步的断言重点：`ProIntroLaterButton` 存在并可点击。
UI 测试环境没有 StoreKit mock，`Product.products(for:)` 会返回空 →
付费墙落到 `.empty` 状态显示「暂时无法加载订阅方案」——
**这正是要验证的降级路径：商品加载失败时 onboarding 不能卡死。**

---

## 4. 验证

1. **构建**
   ```
   xcodebuild -project VoiceTodo.xcodeproj -scheme VoiceTodo \
     -destination 'platform=iOS Simulator,name=iPhone 17' build
   ```
   若 `project.yml` 有变动，先跑 `./prepare_xcode_project.sh`。

2. **单元测试**
   ```
   xcodebuild test -scheme VoiceTodo -destination '...' -only-testing:VoiceTodoTests
   ```
   本次不动核心逻辑，重点确认 `EntitlementManager` 新增的两个属性没破坏
   `enableTransactionListener: false` 的测试路径（`EntitlementManager.swift:45-51`）。

3. **StoreKit 本地测试（关键，必须做）**

   Xcode 里配一个 StoreKit Configuration File，给 `com.voicetodo.pro.monthly` /
   `com.voicetodo.pro.yearly` 建**同一个订阅组**并配 3 天 introductory offer，然后逐项验：

   - [ ] 全新安装 → 走到第三屏 → 显示真实价格，年付默认选中，CTA 写「开始 3 天免费试用」
   - [ ] 点 CTA → **Apple 系统购买弹窗弹出**（这是本次改动的核心验收点）
   - [ ] 完成购买 → 自动前进到庆祝页，显示 Pro 感谢文案 → 点「开始使用」进主界面
   - [ ] 购买弹窗点取消 → 停留在第三屏，无报错，可以再点
   - [ ] 切换选中月付 → CTA 价格/时长跟着变，购买的是月付商品
   - [ ] 点「以后再说」→ 直接到庆祝页（不显示 Pro 感谢文案）
   - [ ] Transaction Manager 清掉购买记录、把试用资格标记为已用尽 →
         CTA 变「订阅 Pro」，卡内试用绿字消失，legal 文案换成 `autorenew_no_trial` 版本

4. **降级路径**

   模拟器开飞行模式 → 第三屏应显示「暂时无法加载订阅方案」+ 重试按钮，
   **且「以后再说」仍然可点**，能走完整个 onboarding 进主界面。

5. **回归：sheet 形态的 PaywallView**

   `--skip-onboarding` 启动 → 主界面把配额用尽触发 `coordinator.showPaywall` →
   确认选择 + CTA + 关闭按钮 + 恢复购买都正常，购买成功后 sheet 自动 dismiss
   （`PaywallView.swift:51-53` 的 `onChange` 逻辑）。

6. **UI 测试**
   ```
   xcodebuild test -scheme VoiceTodo -destination '...' \
     -only-testing:VoiceTodoUITests/ScenarioTests/test_S12_firstLaunch_onboarding
   ```

---

## 5. 实施注意事项

- **不要新写购买逻辑。** `EntitlementManager.purchase(_:)` 已经覆盖了
  成功 / 取消 / pending / 异常四条分支，直接调用即可。
- **不要为 onboarding 复制一套付费墙 UI。** 两处必须共用 `PaywallContent`，
  否则试用资格判断、价格展示、legal 文案会随时间漂移出两套行为——
  第 1.4 节的 bug 正是这类重复的产物。
- **「以后再说」是逃生舱，任何状态下都必须可点。** 商品加载失败、网络断开、
  StoreKit 不可用时，用户仍要能走完 onboarding。
- **试用文案一律以 `isEligibleForIntroOffer` 为准。** 全局搜一遍「3 天」/「3-day」/「3 days」，
  确认没有漏网的硬编码。

---

## 6. 实施补充：A/B/C 三处易踩坑点

3.1 / 3.2 / 3.3 已分别埋了细节，这里集中列一遍，实施时按此清单逐项 check，避免遗漏。

### A. ProductCard 购买中的视觉态（对应 3.2）

卡片从「点击即购买」改为「点击即选中」后，**购买期间（`entitlement.isPurchasing == true`）所有 ProductCard 一律 `disabled` + `opacity(0.5)`**，不只是主 CTA 显 spinner。

- **原因**：StoreKit 系统弹窗出现前的几百毫秒里用户仍能切商品，会让 `selectedProductID` 在飞行中漂移——下次点 CTA 购买的可能是漂移后的商品。
- **顺带清理**：`ProductCard` 现有内嵌 spinner（`PaywallView.swift:417-419`，把价格替换成 ProgressView）随语义变更一并移除。spinner 只在主 CTA 上，卡片保持显示价格（弱化后），让用户知道在买什么。
- **验收**：点了 CTA 之后到系统弹窗出现之前，所有商品卡都不再响应点击。

### B. 「以后再说」与 PaywallContent 内 legal / restore 的视觉层级（对应 3.3）

PaywallContent 内部已有 `legalText` + `restoreButton`，「以后再说」是 onboarding 独有的外层按钮。两层叠在一起容易乱。

- **固定顺序**：`商品卡 → CTA → legal → restore → 以后再说`。
- **不要做**：把「以后再说」夹在 legal 和 restore 之间；把「以后再说」紧跟 CTA（会让用户误以为是次等价的购买选项）。
- **样式**：「以后再说」是小号灰色文字按钮（沿用现有 `ProIntroLaterButton` 样式），视觉权重最弱，位置在最末。
- **`context: .onboarding` 时收紧 padding**：原 sheet 有 NavigationStack + toolbar 占位，onboarding 内嵌没有，header 上方留白可减小，让「以后再说」与 PaywallContent 在视觉上仍是同一组。
- **降级**：商品加载失败（`.empty`/`.error`）时 PaywallContent 落到 stateMessage，外层「以后再说」仍要可点——这是「onboarding 不能被网络/StoreKit 卡死」的最后一道保险。

### C. isEligibleForIntroOffer 的加载态（对应 3.1）

`Product.SubscriptionInfo.isEligibleForIntroOffer(for:)` 是 async。商品加载完成到资格查询完成之间有短暂窗口：

- 按 false 显示「订阅 Pro」、查完变 true 抖成「开始 N 天免费试用」；
- 反过来也成立。

老用户退订后重订场景尤其刺眼——先变相承诺试用、再变脸，正是 1.4 节想修的那类欺骗。

- **加第三态** `@Published private(set) var isCheckingIntroOffer = true`。
- **时机**：`loadProducts()` 成功前置 true，await 资格查询完成后置 false；失败分支也置 false（CTA 不渲染，spinner 不需要转）。
- **CTA 渲染**：`isCheckingIntroOffer == true` → spinner 不显文案；`false` + eligible → 「开始 N 天免费试用」；`false` + ineligible → 「订阅 Pro」。
- **验收**：模拟器断网/StoreKit 不可用时，第三态最终会落到 false（因为商品都没加载成功），不会卡在永久 spinner。
