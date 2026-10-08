# 付费墙购买后体验——逐条改造说明(2026-10-08)

> 交给实现方的任务书。每条写明 **现状 → 怎么改 → 要达到的效果(验收)**。
> 标「✅ 已实现」的条目代码已在 main(`abd30cc`),实现方只需**按验收项核对、不要重写**;
> 标「🔧 待实现」的才是本次要改的。改完由 Claude review。

## 0. 通用约束(所有条目都适用)

- **不要改动** `App/EntitlementManager.swift` 里权益判定的核心逻辑(`performEntitlementRefresh`
  的过滤与 `latest(for:)` 兜底、`purchase()` 的对账、DEBUG + Xcode 环境放行)。需要新信号就**加**
  `@Published` 属性/方法,不要改已有分支的语义。
- 新增用户可见文案一律进 `Resources/Localizable.xcstrings`,**en / ja / zh-Hans 三语齐全**,
  代码里用 `String(localized:)` 或在 `Protocols/ErrorMessages.swift` 加常量,不许硬编码。
- 日志用 `VoiceTodoLog.<category>`,事件名 `模块.动作 key=value` 风格(参照现有 `entitlement.*`、
  `coordinator.*`)。
- 注释用中文,写「为什么」,与周边代码密度一致。
- 付费墙入口只能走 `AppCoordinator.presentPaywall(source:)`,不许直接写 `showPaywall = true`。
- 每条改完同步 `docs/payment-flow-review-2026-10.md` 第 4 节状态表;涉及购买流程的改动同步
  `VoiceTodoUITests/ScenarioTests.swift` 的 S20。
- 新逻辑能单测的放 `VoiceTodoTests/`(`EntitlementManager.setEntitlementForTesting` 是 DEBUG 测试注入口)。

---

## 1. 购买成功立刻有明确反馈 ✅ 已实现

**现状**:`UI/Paywall/PaywallView.swift` 的 `successOverlay`——`purchaseSuccessCount` 变化即整页盖上
对勾 +「已升级为 Pro」+ 有效期,`.sensoryFeedback(.success)` 触感,VoiceOver 播报。
不依赖 `isPro` 是否已翻正(旧实现依赖它,权益没刷出来时页面毫无变化——用户截图的问题)。

**验收**:
- 系统购买弹窗点确认、弹窗消失后 **≤ 0.5 秒** 内付费墙出现成功遮罩,下层购买按钮不可再点。
- 真机能感到一次成功震动;VoiceOver 开启时朗读「已升级为 Pro」。
- 系统弹「你已订阅」后 App 对账为 Pro,同样出现成功遮罩(不是停在购买页)。

## 2. 约 1 秒后自动关闭付费墙 ✅ 已实现(关闭部分) / 🔧 待实现(继续原操作)

### 2a. 自动关闭 ✅
**现状**:`PaywallView` 的 `.task(id: successEvent)` 1.5 秒后 `dismiss()`。
**验收**:遮罩出现约 1.5 秒后付费墙自动收起,回到打开前的页面;期间用户手动点 × 也正常关闭、不崩。

### 2b. 因额度用完弹出的付费墙,买完继续原操作 🔧

**现状**:额度耗尽时 `AppCoordinator.handleOfflineFallbackSaved` 已把本次输入**存成 pending 条目**
(toast「已离线保存」),再 `presentPaywall(source: .quotaExhausted)`。pending 只会在下次
scenePhase 回到 `.active` 时由 `handleAppForeground()` → `PendingRecoveryFlow` 处理。
购买发生在 App 内,付费墙收起后不会触发回前台,用户刚才说的那句话要等下次切 App 才被解析。

**怎么改**:
1. `AppCoordinator` 记住最近一次付费墙来源(`presentPaywall` 里已有 `source`,存一个
   `private(set) var lastPaywallSource: PaywallSource?`)。
2. 加 `func handlePaywallDismissedAfterPurchase()`:若来源是 `.quotaExhausted` 且
   `entitlement.isPro == true`,调 `await handleAppForeground()` 处理 pending;打日志
   `coordinator.paywall.resume_pending source=quota_exhausted`。
3. 触发点:`PaywallView` 成功遮罩的自动 `dismiss()` 之后(PaywallView 当前没有 coordinator,
   需在 `VoiceTodoApp` 的 paywall sheet 上重新注入 `.environmentObject(coordinator)`,
   或改用 `.sheet(isPresented:onDismiss:)` 在 onDismiss 里判断「本次是否成功购买」再调用)。
   推荐 `onDismiss` 方案:不让 PaywallView 依赖 coordinator。需要一个「本次 sheet 期间购买成功过」
   的标志——可在 `presentPaywall` 时记下当时的 `entitlement.purchaseSuccessCount`,
   onDismiss 时比较是否增加。
4. `handleAppForeground` 自带 `isRecording / showConfirmSheet` 等守卫,直接复用,不要绕过。

**验收**:
- 免费档用满 3 次 → 第 4 次录音 → toast「已离线保存」+ 付费墙 → 购买成功 → 遮罩 → 自动收起 →
  **不切后台**,几秒内刚才那句话被解析,走正常确认流程(ConfirmSheet 或直接入列,与正常录音一致)。
- 手动从设置打开付费墙购买(`.manual` 来源):收起后**不**触发 pending 处理。
- 购买取消 / 失败后关闭付费墙:**不**触发。
- 注意 Xcode 本地 StoreKit 下代理验签不过、仍按免费档计(见 `docs/payment-test-plan.md`「大坑」),
  这条的端到端验收**必须用沙盒账号**,否则 pending 处理会再次撞额度耗尽。

## 3. 全局状态同步——首页可见 Pro 🔧 待实现

**现状**:`entitlement.isPro` 是全局共享的 `@Published`,设置页入口已随之切到「你已订阅 Pro」
(`UI/Home/HomeSettingsSheet.swift`)。但**首页没有任何额度或 Pro 标识**,买完回到首页看不出变化。
额度数字只在付费墙顶部胶囊里(`quota.today_used`,数值来自 `QuotaUsage.displayedLimit`,
订阅后、代理响应前已过渡显示 Pro 档上限)。

**怎么改**(克制,只加一个小标识,不做额度面板):
1. `UI/Home/HomeView.swift` 头部标题行,设置齿轮 `settingsButton` 左侧,`entitlement.isPro` 为 true 时
   显示小胶囊「PRO」(`WarmTheme.primary` 描边或浅底,字号 11 semibold rounded,高 ≤ 20pt)。
   用 `@EnvironmentObject EntitlementManager` 或 `coordinator.isProSubscriber`,与现有写法一致。
2. 胶囊可点 → `coordinator.presentPaywall(source: .manual)`(付费墙已订阅态会显示有效期)。
3. 加 `accessibilityIdentifier("HomeProBadge")`,a11y label 用新文案 `home.pro_badge`
   (en "Pro member" / zh-Hans "Pro 会员" / ja "Pro メンバー")。
4. 不要在首页加「x/100」额度数字:Pro 档 100 条/天几乎用不满,常驻数字是噪音。

**验收**:
- 未订阅:首页无 PRO 胶囊,头部布局与现在像素级一致(跑 `ScreenshotUITests` 对比)。
- 购买成功、付费墙自动收起后,回到首页**立即**出现 PRO 胶囊(无需重启/切后台)。
- 订阅到期(沙盒月付 5 分钟)后,前台停留中胶囊在到期 +2 秒内消失(依赖已有的到期重读)。
- SE 尺寸 + 最大动态字号下标题行不截断、不换行错位。
- S20 Step 6 之后加断言:`HomeProBadge` 存在。

## 4. 用户取消 → 静默留在页面 ✅ 已实现
**现状**:`purchase()` 的 `.userCancelled` 不设 `lastError`。
**验收**:系统购买弹窗点「取消」→ 付费墙保持原样,无错误行、无震动、CTA 立即可再点。

## 5. Pending(家长「询问购买」)→ 中性提示「等待批准」 🔧 待实现(小改)

**现状**:`purchase()` 的 `.pending` 设 `lastError = String(localized: "paywall.pending")`
(zh「购买待处理，请稍后」/ en「Purchase pending」),由 `PaywallContent.inlineErrorText`
以 **警示色** `WarmTheme.warning` 渲染——看起来像出错。批准后 `Transaction.updates` 会刷新权益。

**怎么改**:
1. `ErrorMessages` 加常量 `paywallPending`,`EntitlementManager` 改用它赋值(值不变)。
2. 文案改为更明确的「等待批准」:zh-Hans「已提交,等待批准后自动生效」、
   en「Waiting for approval. Pro activates once approved.」、ja「承認待ちです。承認されると自動で有効になります」。
3. `inlineErrorText` 里 `lastError == ErrorMessages.paywallPending` 时用 `WarmTheme.textSecondary`
   并前置 `clock` 图标;其它错误保持警示色。
4. 批准后若付费墙仍开着:应走成功反馈。现在 `Transaction.updates` 只刷新 `isPro`、不增
   `purchaseSuccessCount`,所以**不会**出遮罩。在 `EntitlementManager` 记一个
   `private var hasPendingPurchase`(`.pending` 时置 true),`listenForTransactionUpdates`
   里刷新后若 `hasPendingPurchase && isPro` → `purchaseSuccessCount += 1` 并清标志。

**验收**(Xcode 本地 StoreKit:`Products.storekit` 的 `_askToBuyEnabled` 临时改 true,别提交):
- 点购买 → 付费墙显示灰色带时钟图标的「已提交,等待批准后自动生效」,**无成功遮罩、无震动**。
- 在 Xcode Transaction Manager 里批准 → 付费墙(若仍开着)出现成功遮罩并自动收起;
  若已关闭,下次打开付费墙为已订阅态,首页出现 PRO 胶囊。
- 拒绝 → 付费墙保持购买态,提示行不变或清除均可,不得显示成功。

## 6. 失败 → 简短错误 + 可重试 ✅ 已实现
**现状**:抛错 → `paywall.purchase_failed`「购买失败，请稍后重试」警示色行内显示,CTA 恢复可点;
验签失败 → `paywall.purchase_unverified` 并提示恢复购买。
**验收**:`_failTransactionsEnabled = true`(临时)→ 点购买 → 出现「购买失败，请稍后重试」,
再点 CTA 能重新弹系统购买框。

## 7. Restore Purchases 给出结果 ✅ 已实现
**现状**:成功 → 同一成功遮罩「已恢复 Pro」并自动收起(`restoreSuccessCount`);
无可恢复 → 行内「未找到可恢复的订阅」;Apple ID 验证点取消 → 静默;其它错误 →「恢复失败」。
**验收**:已订阅账号在购买态点「恢复购买」→ 遮罩「已恢复 Pro」→ 收起;
未订阅账号点 → 行内「未找到可恢复的订阅」,不收起。

## 8. 已是 Pro 再打开付费墙 → 显示状态而非购买按钮 ✅ 已实现
**现状**:`PaywallContent` 的 `entitlement.isPro` 分支:实时用量 → `PaywallSubscribedCard`
(「你已订阅 Pro」+ 有效期)→ 法务 + 恢复,无购买按钮。
**验收**:订阅后从设置进付费墙,看到已订阅卡与「有效期至 X」,没有商品列表和 CTA。

## 9. 「只 finish 没更新状态 / 没监听 Transaction.updates」 ✅ 该判断不成立
代码在 `purchase()` 里 `finish()` 后会 `refreshEntitlements()`,App 启动即监听
`Transaction.updates`(`listenForTransactionUpdates`)。用户截图那次的真实原因是权益重读没反映出
这笔交易,已用「以成功交易直接设权益 + `Transaction.latest(for:)` 兜底」修复,并留了
`entitlement.purchase_entitlement_missing` / `entitlement.refresh_fallback_latest` 日志。
**无需改动**;实现方真机复测时若看到这两条日志,请把日志附在 PR 里。

## 10. 中英混排 🔧 待实现(配置 + 上架清单,无业务代码)

**现状**:截图里标题/卖点/按钮是英文(App 本地化跟随系统语言,正确),套餐名「Pro 月付」与描述
是中文——这两段来自 StoreKit 商品元数据,不是 App 文案:
- Xcode 本地测试:取自 `VoiceTodo/Products.storekit` 的 `"_locale" : "zh_CN"`(Xcode 只按这个
  Default Localization 出商品文案,不跟随设备语言)。
- 上架后:取自 App Store Connect 里每个订阅商品的本地化,按用户语言/店面下发。

**怎么改**:
1. 不改代码。`Products.storekit` 的 `_locale` **保持 zh_CN**(主力市场),在
   `docs/payment-test-plan.md` 补一句:测英文界面时在 Xcode 打开 Products.storekit →
   Editor → Default Localization 临时切 English (US),**不要提交**该改动。
2. `app-store-submit-checklist.md` 增加检查项:两个订阅商品 + 订阅组在 ASC 均填写
   **English (U.S.) 与 简体中文** 的显示名称和描述(与 Products.storekit 里两套文案一致),
   如上架日本区再加日语。
3. 顺带核对:`ProductCard` 的「/ month」「/ year」与「Save 33%」走的是 App 本地化,不受此影响。

**验收**:
- 设备英文 + Products.storekit 切 English 时,付费墙商品名为「Pro Monthly / Pro Yearly」,
  整页无中文。
- 设备中文 + 默认 zh_CN 时整页中文。
- 上架清单里有上述 ASC 本地化检查项。

---

## 交付与 review

- 一条一个 commit(`feat(paywall): …` / `fix(paywall): …`),在单独分支上做,不直接推 main。
- PR 描述按本文编号列出每条「改了什么 / 怎么验的」,真机验收附截图或录屏
  (尤其 2b、3、5)。
- Review 时重点看:是否碰了第 0 节禁止改动的权益逻辑;新文案三语是否齐全;
  2b 是否会在非购买场景误触发 pending 处理;5 的 pending→批准路径是否会重复计成功
  (遮罩出现两次)。
