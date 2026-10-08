# 付费墙购买后体验——逐条改造说明(v2,2026-10-08)

> 交给实现方的任务书。每条写明 **现状 → 怎么改 → 要达到的效果(验收)**。
> v2 依据产品原型调整:成功反馈从「整页遮罩」改为「CTA 原地变绿 + 额度 3→100」,
> 新增首页额度胶囊、Pro 状态页、按钮下价格说明、年付默认置顶。
> 标「✅ 保留」的是 main(`abd30cc`)已有、本次不动的行为;「🔧」是本次要改的。改完由 Claude review。

## 0. 通用约束(所有条目都适用)

- **不要改动** `App/EntitlementManager.swift` 里权益判定的核心逻辑:`performEntitlementRefresh`
  的过滤与 `Transaction.latest(for:)` 兜底、`purchase()` 的 verified 成功直接设权益与非成功对账、
  DEBUG + Xcode 环境放行未验签交易。需要新信号就**加** `@Published` 属性/方法,不改已有分支语义。
- **成功反馈只认事件计数**(`purchaseSuccessCount` / `restoreSuccessCount`),**不许改回依赖
  `isPro` 跳变**——这是用户截图「付了钱页面不动」的根因(权益没刷出来时 isPro 不翻)。
- **文案「统一」指跟随系统语言统一,不是写死中文**。App 已有 en / ja / zh-Hans 三语;新增文案进
  `Resources/Localizable.xcstrings` 三语齐全,代码用 `String(localized:)` 或 `Protocols/ErrorMessages.swift`
  常量,不许硬编码中文。原型里的中文即 zh-Hans 的取值。
- 价格、周期一律取 StoreKit 的 `Product`(`displayPrice`、`priceFormatStyle`、`subscription`),
  **不许手写 ¥39.99、7 天**——各国店面币种和价格不同,试用时长以 `introductoryOffer.period` 为准。
- 日志用 `VoiceTodoLog.<category>`,事件名 `模块.动作 key=value`;注释中文、写「为什么」。
- 付费墙入口只能走 `AppCoordinator.presentPaywall(source:)`。
- 每条改完同步 `docs/payment-flow-review-2026-10.md` 第 4 节状态表;购买流程改动同步
  `VoiceTodoUITests/ScenarioTests.swift` 的 S20(UI 测试强制 zh,断言可用中文)。
- 原型是交互参考,**视觉以现有 WarmTheme 设计语言为准**(颜色 `WarmTheme.*`、间距 `WarmSpacing.*`、
  圆角 `WarmRadius.*`),不要引入新色值。

---

## 1. 购买成功:CTA 原地变绿 → 额度 3→100 → 约 1 秒后收起 → toast 🔧

**现状**:`UI/Paywall/PaywallView.swift` 用整页 `successOverlay`(对勾 +「已升级为 Pro」)盖住付费墙,
1.5 秒后 `dismiss()`,收起后无 toast。

**怎么改**:
1. **删除** `PaywallView` 的 `successOverlay` 及其 `.overlay` 挂载;保留 `successEvent` 状态、
   `.sensoryFeedback(.success, …)`、VoiceOver 播报、`.task(id:)` 定时收起的骨架。
2. `successEvent` 需要传给 `PaywallContent`(参数或 `@Binding`),`purchaseCTA` 在
   `successEvent != nil` 时渲染成功态:
   - 底色 `WarmTheme.success`,内容 `checkmark` 图标 + 文案(购买:`paywall.purchase_success`
     「已升级为 Pro」;恢复:`paywall.restore_success`「已恢复 Pro」);
   - 不可点(`.disabled(true)`,但**不要**降透明度——成功态要醒目);
   - 状态切换用 `.easeOut(0.25)` 过渡,`accessibilityIdentifier` 保持 `PaywallPurchaseButton`,
     成功态额外加 `accessibilityValue("success")` 供 UI 测试判断。
   - 商品卡同时 disabled(沿用 `isPurchasing` 的弱化样式即可),防止成功态期间再选方案。
3. 顶部额度胶囊同步升档:`comparisonCard` 在 `successEvent != nil` 时一律走 `liveUsageCard`,
   上限取 `NetworkConfig.proDailyLimit`(即「今日已用 2/100」)。数字变化加
   `.contentTransition(.numericText())`。**不要**为此改 `QuotaUsage`——成功态是本次会话的
   展示覆盖,代理权威头到来后由 `displayedLimit` 正常接管。
4. 收起时机:成功态出现后 **1.0 秒** `dismiss()`(原 1.5 秒)。
5. 收起后弹 toast「已升级为 Pro」/「已恢复 Pro」(style `.success`):
   在 `App/VoiceTodoApp.swift` 的 paywall `.sheet` 改用 `onDismiss:`,由 `AppCoordinator`
   判断「本次 sheet 期间成功计数是否增加」(在 `presentPaywall` 时记下两个计数的快照,
   onDismiss 比较),增加了就 `showToast`。这样 toast 挂在主视图上、sheet 已收起,不会被盖住;
   也不必让 PaywallView 依赖 coordinator。第 3 条(2b)的「继续原操作」复用同一个 onDismiss 判定。
6. 用户在成功态 1 秒内手动点 ×:正常关闭,toast 照弹(onDismiss 判定不依赖谁触发的关闭)。

**验收**:
- 系统购买弹窗确认、弹窗消失后 ≤ 0.5 秒内 CTA 变绿「✓ 已升级为 Pro」,伴随一次成功震动;
  顶部胶囊同时变为「今日已用 x/100」。
- 约 1 秒后付费墙自动收起,主界面弹「已升级为 Pro」toast;首页额度胶囊(第 3 条)已是 Pro 档。
- 系统弹「你已订阅」后 App 对账为 Pro:同样走上述成功态(不是停在购买页)。
- 权益重读未反映交易(日志 `entitlement.purchase_entitlement_missing`)时成功态照常出现。
- VoiceOver:成功时朗读「已升级为 Pro」;成功态按钮朗读为不可用的「已升级为 Pro」。
- S20 Step 6 改为:断言 `PaywallPurchaseButton` 的 value 变为 `success` → 付费墙 10 秒内消失 →
  主界面出现「已升级为 Pro」toast。

## 2. 其它结果的反馈 🔧(取消/失败已有,pending 与 restore 调整)

| 结果 | 页面反应 | 现状 |
|---|---|---|
| 用户取消 | 恢复原样,无提示、无震动,CTA 立即可点 | ✅ 保留 |
| 失败 | 行内警示色「购买失败，请稍后重试」,CTA 可再点 | ✅ 保留 |
| 验签失败 | 行内「购买凭证校验失败，请稍后重试或恢复购买」 | ✅ 保留 |
| 等待批准 | 见 2a 🔧 | 现为警示色「购买待处理，请稍后」 |
| 恢复成功 | 与第 1 条同款成功态(按钮「✓ 已恢复 Pro」)→ 收起 → toast | 🔧 现为遮罩 |
| 无可恢复 | 行内「未找到可恢复的订阅」,不收起 | ✅ 保留 |
| 恢复失败 | 行内「恢复失败」 | ✅ 保留 |

### 2a. 等待批准(家长「询问购买」)
1. `ErrorMessages` 加 `paywallPending`,`EntitlementManager` 的 `.pending` 改用它。
2. 文案说明原因和下一步:zh-Hans「已提交，等待家长批准后自动生效」/
   en「Sent for approval. Pro turns on automatically once approved.」/
   ja「承認をリクエストしました。承認されると自動で有効になります」。
3. `inlineErrorText` 对该值用 `WarmTheme.textSecondary` + 前置 `clock` 图标(中性,不像出错)。
4. 批准后若付费墙仍开着要走成功态:`EntitlementManager` 加 `private var hasPendingPurchase`,
   `.pending` 时置 true;`listenForTransactionUpdates` 刷新后若 `hasPendingPurchase && isPro`
   → `purchaseSuccessCount += 1` 并清标志(只加一次,防重复成功态)。

**验收**(`Products.storekit` 的 `_askToBuyEnabled` 临时改 true,**不要提交**):
点购买 → 灰色带时钟的「已提交，等待家长批准后自动生效」,无成功态、无震动 →
Xcode Transaction Manager 批准 → 付费墙仍开着则出现成功态并收起;已关闭则首页胶囊变 Pro。
拒绝 → 保持购买态,不得出现成功态。

### 2b. 恢复购买
第 1 条改完后恢复成功自然复用成功态,只需确认按钮文案为「✓ 已恢复 Pro」、toast 为「已恢复 Pro」。

## 3. 首页额度胶囊 + 额度用完后买完继续原操作 🔧

### 3a. 首页额度胶囊(新增)
**现状**:首页没有任何额度/Pro 显示(额度只在付费墙顶部),买完回首页看不出变化。

**怎么改**:
1. `UI/Home/HomeView.swift` 头部标题行、`settingsButton` 左侧加额度胶囊:
   - 免费:「今日 2/3」(复用 `quota.today_used` 或新增短文案 `home.quota_pill`);
   - Pro:「Pro · 2/100」,`WarmTheme.primary` 浅底;
   - 数值来自 `QuotaUsage.used` 与 `displayedLimit(storeKitIsPro: entitlement.isPro)`,
     与付费墙同口径;`quotaUsage.loadState == .error` 或尚无数据时显示「Pro」/ 隐藏数字,不显示错误。
2. 点胶囊 → `coordinator.presentPaywall(source: .manual)`(Pro 时进入第 4 条状态页)。
3. `accessibilityIdentifier("HomeQuotaPill")`,a11y label 读完整句(「今日已用 2 次,共 3 次」/
   「Pro 会员,今日已用 2 次,共 100 次」)。
4. 不要挤压标题:SE + 最大动态字号下胶囊可只显示「Pro」或数字,标题行不得截断。

**验收**:
- 免费档首页显示「今日 x/3」,每次录音成功后数字更新。
- 购买成功、付费墙收起后**立即**变为「Pro · x/100」(无需重启/切后台)。
- 沙盒月付到期后,前台停留中胶囊在到期 +2 秒内回落为免费档。
- 未订阅时头部其余元素位置不变(跑 `ScreenshotUITests` 对比)。

### 3b. 额度用完弹出的付费墙,买完继续原操作
**现状**:额度耗尽时 `AppCoordinator.handleOfflineFallbackSaved` 已把输入存为 pending,再
`presentPaywall(source: .quotaExhausted)`;pending 只在回前台 `handleAppForeground()` 时处理,
App 内购买后收起付费墙不会触发。

**怎么改**:第 1 条第 5 步的 onDismiss 判定里,若「本次成功计数增加」且 `presentPaywall` 记下的
来源是 `.quotaExhausted` 且 `entitlement.isPro`,`Task { await handleAppForeground() }`,
日志 `coordinator.paywall.resume_pending source=quota_exhausted`。复用其守卫,不要绕过。

**验收**(**必须沙盒账号**:Xcode 本地 StoreKit 的 JWS 代理验签不过,仍按免费档计,
见 `docs/payment-test-plan.md`「大坑」):免费用满 → 第 4 次录音 →「已离线保存」+ 付费墙 →
购买 → 成功态 → 收起 → **不切后台**几秒内刚才那句被解析,走正常确认流程。
`.manual` 来源购买、或取消/失败后关闭:均不触发。

## 4. 已是 Pro:「你已是 Pro」状态页 🔧(在现有已订阅态上补全)

**现状**:`PaywallContent` 的 `entitlement.isPro` 分支 = 实时用量胶囊 + `PaywallSubscribedCard`
(「你已订阅 Pro」+「有效期至 X」)+ 法务 + 恢复,无购买按钮。缺方案名、试用/收费日期区分、管理订阅。

**怎么改**:
1. `EntitlementManager` 加只读 `@Published` 字段(在 `performEntitlementRefresh` 选定交易时一并赋值,
   不改选择逻辑):`activeProductID: String?`、`isInIntroOffer: Bool`(`transaction.offerType == .introductory`)、
   `willAutoRenew: Bool?`(取对应 `Product.subscription?.status` 里该交易的 `renewalInfo.willAutoRenew`;
   取不到为 nil)。
2. 状态卡内容(自上而下):
   - 标题「你已是 Pro」(更新 `paywall.subscribed.title` 的 zh-Hans 取值即可,en/ja 同步);
   - 方案:「Pro 年付 · ¥39.99/年」(`Product.displayName` + `displayPrice` + 周期);
   - 日期一行,三种情况:
     - 试用中且会续费:「免费试用至 10月15日，之后按 ¥39.99/年 收费」;
     - 已付费且会续费:「下次续费 2027年10月8日」;
     - 已关闭自动续费:「有效期至 X，到期后不再续费」;
     - `willAutoRenew == nil`:退回现有「有效期至 X」。
   - 今日用量:「今日已用 2/100」(就是顶部实时用量胶囊,保留即可)。
3. 底部主按钮「管理订阅」:`.manageSubscriptionsSheet(isPresented:)`(iOS 15+),
   `accessibilityIdentifier("PaywallManageSubscriptionButton")`;下面保留法务链接与「恢复购买」。
4. 管理订阅页关闭后调 `entitlement.refreshEntitlements()`(用户可能刚取消续费或切换方案)。

**验收**:
- 订阅后点首页胶囊或设置入口:看到「你已是 Pro」、方案与价格、正确的日期文案、今日用量,
  **没有**商品列表和购买按钮。
- 试用期账号显示「免费试用至 …，之后按 … 收费」;在管理订阅里取消续费、关闭后,
  日期行变为「到期后不再续费」。
- 「管理订阅」能打开系统订阅管理页(真机/沙盒;模拟器 Xcode StoreKit 下打开测试管理页)。

## 5. 价格说明放在按钮下方 🔧

**现状**:CTA 下方 `legalText` 是通用句子(「试用结束后自动续费。可随时在 设置 → Apple ID → 订阅 中取消」),
不含所选方案的价格。

**怎么改**:
1. `legalText` 改为按**当前选中商品**拼:
   - 有试用资格:`paywall.legal.trial_then_price`「试用 %1$@ 后按 %2$@/%3$@ 自动续费，可随时取消」
     (时长取 `introOfferPeriod.formattedLocalizedPeriod()`,价格 `displayPrice`,周期「年/月」);
   - 无资格:`paywall.legal.price_autorenew`「%1$@/%2$@，自动续费，可随时取消」;
   - 第二行保留取消路径「在 设置 → Apple ID → 订阅 中取消」。
2. 切换选中方案时文案即时更新;仍只在 `productLoadState == .success && !isCheckingIntroOffer` 时渲染
   (沿用 C 点防抖)。
3. 合规:不可截断,`lineLimit(3)` + `minimumScaleFactor(0.85)` 预算保留;字号可从 11 提到 12,
   但需保证 S18「一屏装下」UI 测试仍通过。

**验收**:选年付显示「试用 7 天后按 ¥39.99/年 自动续费，可随时取消」;切月付立即变为
「… ¥4.99/月 …」;无试用资格账号显示「¥39.99/年，自动续费，可随时取消」;
SE 尺寸 CTA 与价格说明无需滚动可见。

## 6. 年付默认选中、置顶,显示折合月价 🔧

**现状**:`EntitlementManager.loadProducts` 按价格升序 → 月付在上;默认选中年付的逻辑只在
`onChange(of: entitlement.products)` 里——**再次打开付费墙时商品已加载、数组没变,onChange 不触发,
`selectedProductID` 为 nil,没有任何卡片高亮**(现有 bug,用户截图可见选中态与预期不符)。

**怎么改**:
1. 排序改在视图层:`productList` 渲染时年付在前(`yearlyProductID` 优先,其余按价格),
   **不改** `EntitlementManager.products` 的顺序(其它地方可能依赖)。
2. 初始选中修复:`onChange(of: entitlement.products, initial: true)`(iOS 17+),
   让首次出现时也走默认年付逻辑。
3. 年付卡价格下方加折合月价:「约 ¥3.33/月」——`product.price / 12` 用
   `product.priceFormatStyle` 格式化,文案 `paywall.yearly_per_month`(%@ 占位)。
   保留「Save 33%」角标(已有 `paywall.yearly_save`)。
4. 默认推年付是产品建议,不是硬要求:把「默认选中哪个」收敛成一个常量
   (如 `PaywallContent.defaultProductID = EntitlementManager.yearlyProductID`),以后改一行即可。

**验收**:每次打开付费墙(含第二次及以后)年付都在上方且默认高亮;年付卡显示「约 ¥3.33/月」;
CTA 与第 5 条价格说明对应年付;点月付后高亮、CTA、价格说明一起切换。

## 7. 中英混排(配置 + 上架清单,无业务代码) 🔧

**现状**:截图里商品名「Pro 月付」与描述是中文、其余英文——商品元数据来自 StoreKit,不是 App 文案:
Xcode 本地测试取 `VoiceTodo/Products.storekit` 的 `"_locale" : "zh_CN"`(不跟随设备语言);
上架后取 App Store Connect 各商品的本地化。

**怎么改**:
1. `Products.storekit` 的 `_locale` 保持 zh_CN;`docs/payment-test-plan.md` 补说明:测英文界面时在
   Xcode 打开 Products.storekit → Editor → Default Localization 临时切 English (US),不要提交。
2. `app-store-submit-checklist.md` 加检查项:两个订阅商品与订阅组在 ASC 填写 English (U.S.) 与
   简体中文的显示名称和描述(与 Products.storekit 两套文案一致),上架日本区再加日语。

**验收**:设备中文 + zh_CN 配置整页中文;设备英文 + 临时切 English 配置整页英文;清单有该项。

## 8. 已核实、无需改动

- 「购买后只 `finish()` 没更新状态 / 没监听 `Transaction.updates`」:不成立。`purchase()` 在
  `finish()` 后 `refreshEntitlements()`,启动即 `listenForTransactionUpdates()`。截图问题的真实原因
  是权益重读未反映交易,已以「verified 交易直接设权益 + `latest(for:)` 兜底」修复,
  日志 `entitlement.purchase_entitlement_missing` / `entitlement.refresh_fallback_latest`。
  真机复测若出现这两条日志,请附在 PR 里。

---

## 交付与 review

- 在单独分支上做,一条一个 commit(`feat(paywall): …` / `fix(paywall): …`),不直接推 main。
- 建议顺序:6(含选中 bug)→ 5 → 1 → 2 → 4 → 3a → 3b → 7。1 与 3b 共用 onDismiss 判定,先做 1。
- PR 描述按本文编号列出「改了什么 / 怎么验的」,真机验收附截图或录屏(尤其 1、2a、3、4)。
- Review 重点:是否碰了第 0 节禁止改动的权益逻辑;成功反馈是否仍只认事件计数;
  新文案三语是否齐全、价格是否全部来自 StoreKit;3b 是否会在非购买场景误触发 pending 处理;
  2a 批准路径是否会重复计成功;6 的初始选中在「第二次打开付费墙」时是否生效。
