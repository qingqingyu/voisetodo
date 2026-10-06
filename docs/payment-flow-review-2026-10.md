# 付费链路全量走查(2026-10)

范围:`App/EntitlementManager.swift`、`UI/Paywall/PaywallView.swift`、`App/VoiceTodoApp.swift`
(启动/回前台刷新)、`App/AppCoordinator.swift`(付费墙触发)、`UI/Home/HomeSettingsSheet.swift`、
`App/Intents/AddTodoIntent.swift`(Siri 取 JWS)、`AIProxy/src/subscription.js` + `worker.js`(代理验签)。

## 1. 结论

- **不存在重复扣费路径。** 月付/年付在同一订阅组,App Store 本身不允许同组并存两份订阅
  (重复点同一商品只会弹「你已订阅」,月→年是 Apple 按比例折算的升级)。
  客户端还缺一层防连点,已补(见 2.1)。
- **有两处会让「已付费但不生效 / 显示不对」的问题,已修**(2.2、2.3)。
- 代理端配置(`APP_BUNDLE_ID` / `PRO_PRODUCT_IDS` / `PAID_DAILY_LIMIT`)与 iOS 端逐字一致,
  `wrangler-config.test.js` 已守住;315 个代理测试全绿。

## 2. 本次已修

### 2.1 购买 / 恢复无重入守卫
CTA 的 `.disabled` 要等下一帧渲染才生效,连点两下会排进两个 `purchase` Task。
`purchase()` / `restorePurchases()` 在第一个 `await` 前同步判 `isPurchasing || isRestoring`;
付费墙 CTA 在恢复购买进行中也禁用。

### 2.2 `refreshEntitlements` 并发写回竞态(可能「买了却显示没买」)
系统购买弹窗收起时 scenePhase 回到 `.active`,`VoiceTodoApp` 触发一次 `refreshEntitlements`,
与 `purchase()` 自身的刷新并发。两次遍历 `currentEntitlements` 在 MainActor 上交错,
若快照较早的那次后写回,会把刚到手的 `isPro` 覆盖回 false、`jwsString` 置 nil
(代理随之按免费档计费),直到下次回前台。
改为串行链:每次刷新排在上一次之后,后发起的一定后快照、后写回,
且调用方 `await` 返回时看到的是落定状态(`restorePurchases` 紧接着读 `isPro` 依赖这点)。

### 2.3 前台停留期间订阅到期,`isPro` 停在 stale-true
到期(已取消续订)不会经 `Transaction.updates` 推送,原来只能等回前台才刷新;
期间付费墙显示「已订阅」、首页不会触发付费墙,但代理已按免费档拒绝。
沙盒月付 5 分钟一续,测试时非常容易撞到。现在每次刷新后在 `expirationDate + 2s` 排一次重读;
到期时刻已过(计费宽限期)不排,避免自我重排成忙循环。

### 2.4 权益过滤与 JWS 选择
`currentEntitlements` 遍历增加 `revocationDate == nil` 与 `!isUpgraded` 过滤(防御),
多条时取到期最晚的一条,不依赖遍历顺序 —— 发给代理的 JWS 与「有效期至」同源。

### 2.5 代理拒绝已撤销交易
`verifySubscriptionJWS` 增加 `revocationDate` 校验(+ 单测)。见 3.1 的局限。

### 2.6 恢复购买时取消 Apple 账户验证被报为「恢复失败」
`AppStore.sync()` 抛 `StoreKitError.userCancelled` 时静默,不再显示错误。

### 2.7 已订阅用户在设置页仍看到「升级 VoiceTodo Pro」
入口文案/图标随 `isPro` 切到「你已订阅 Pro」(复用 `paywall.subscribed.title`,补齐了缺失的 ja 译文)。
付费墙导航标题未改:S20 UI 测试(ScenarioTests.swift)以 `navigationBars["升级 VoiceTodo Pro"]`
消失作为「购买后收起」的信号,随 isPro 改标题会让断言假通过(paywall 未关也判为已关)。
注意 S20 只能在 Xcode GUI 里跑:CLI xcodebuild 不给被测进程注入 scheme 的
Products.storekit 配置(商品恒为空、购买按钮不渲染),测试在 CLI 下被 XCTSkip。

## 3. 已知局限(未改,需决策)

### 3.1 退款后旧 JWS 仍可用到原到期日
撤销前签发的 JWS 不含 `revocationDate`,代理纯离线验签拦不住;年付最长可白用近一年。
彻底解决需接 App Store Server Notifications V2(`REFUND` / `REVOKE`)把
`originalTransactionId`(哈希)写入 KV 黑名单。是否值得做取决于退款滥用的实际量。

### 3.2 计费宽限期(Billing Grace Period)两端不一致
若在 ASC 打开宽限期,宽限期内客户端 `currentEntitlements` 仍给出交易(`isPro == true`),
但交易 JWS 的 `expiresDate` 已过,代理按免费档处理 → 用户看到「已订阅」却只有 3 次/天。
**建议保持 ASC 宽限期关闭**;要开就需要代理改为读 renewalInfo / Server API。

### 3.3 代理不区分 Sandbox / Production
`payload.environment` 未校验,生产代理也接受沙盒 JWS。TestFlight 依赖这一点(TF 购买走沙盒),
沙盒订阅续期加速、很快过期,滥用面小。上架稳定后可按需在生产拒绝 `Sandbox`。

### 3.4 体验项
- 已订阅态没有「管理订阅」入口(切换月/年、取消只能去系统设置),可加 `.manageSubscriptionsSheet`。
- 「有效期至 X」在自动续期开启时其实是下次续费日,可读 `renewalInfo.willAutoRenew` 区分文案。
- `pending`(家长审批)用的是警示色错误行,文案本身是中性的,可改中性色。
- 沙盒续期在到期时刻才发生:2.3 的到期重读可能先于续期交易到达,出现一次短暂 false→true。
  正式环境 Apple 提前约 24h 续期,不受影响。

## 4. 订阅前后显示状态核对

| 状态 | 付费墙 | 设置入口 | 自动弹付费墙 | 配额耗尽 |
|---|---|---|---|---|
| 未订阅 | 对比胶囊/用量 → 价值卡 → 商品 → CTA(试用资格决定文案)→ 法务 + 恢复 | 升级 VoiceTodo Pro | 首次 wow / 第 5 次录音 / 耗尽,14 天冷却 | 弹付费墙 |
| 商品加载失败 | 空态/错误卡 + 重试,CTA 不渲染,法务链接与恢复仍可点 | 同上 | 同上 | 同上 |
| 购买中 | CTA spinner + 禁用,商品卡禁用,恢复禁用 | — | — | — |
| 购买成功 | `purchaseSuccessCount` 驱动收起 + 成功 toast | — | — | — |
| 已订阅 | 实时用量 → 已订阅卡(有效期至)→ 法务 + 恢复,无购买按钮 | 你已订阅 Pro | 不弹 | toast「Pro 额度已用完」,不弹 |
| 订阅过期(前台) | 到期 +2s 自动退回未订阅 UI | 下次打开设置即恢复「升级」 | 恢复 | 弹付费墙 |
