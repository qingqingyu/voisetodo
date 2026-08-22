# Onboarding 第三屏「无法加载订阅方案」修复方案

> 状态:待实现
> 相关文件:`VoiceTodo/Products.storekit`、`UI/Paywall/PaywallView.swift`、`App/EntitlementManager.swift`
> 相关既有文档:`docs/onboarding-paywall-merge.md`

---

## 1. 现象

走 onboarding 到第三屏(Pro 付费墙)时,商品卡片区域始终是错误占位:

```
[wifi.exclamationmark]
Couldn't load subscription plans
Check your connection or try again in a moment
        [ ↻ Retry ]
```

订阅按钮(purchaseCTA)完全不出现,只剩下方的 Restore Purchases / Maybe later。

## 2. 定位

### 2.1 这个文案精确对应 `.empty` 分支

`UI/Paywall/PaywallView.swift:310-343` 的 `productList` 按 `entitlement.productLoadState` 分流:

```swift
case .empty:
    stateMessage(
        icon: "wifi.exclamationmark",                                   // ← 截图里的图标
        title: String(localized: "paywall.products_empty.title"),       // Couldn't load subscription plans
        subtitle: String(localized: "paywall.products_empty.subtitle"), // Check your connection…
        retryAction: { Task { await entitlement.refresh() } }
    )
```

注意 `.error` 分支用的是 `exclamationmark.triangle` 图标 + `lastError` 文案。截图是 `.empty`,
**不是** `.error` —— 也就是说 `Product.products(for:)` 没有抛错,而是成功返回了**空数组**
(`App/EntitlementManager.swift:87-90`,同时打 `entitlement.products_empty` 警告)。

> **后续变更**:上面引用的是本文档撰写时的旧代码。`.empty` 分支现已按
> `NetworkMonitor.shared.isConnected` 分流 —— 无网显示 `paywall.products_empty.offline`
> (保留 `wifi.exclamationmark`),有网但商品空显示中性文案
> `paywall.products_empty.store_unavailable`(`cart.badge.exclamationmark`)。
> 旧 key `paywall.products_empty.subtitle` 已删除。

订阅按钮消失是连带结果 —— `purchaseCTA` 只在 `.success` 下渲染(`PaywallView.swift:82`)。

### 2.2 排除掉的几个方向

| 怀疑点 | 结论 |
|---|---|
| `EntitlementManager` 实例不是同一个 | **不是问题。**`VoiceTodoApp.swift:156` 建单例,`:252-255` 显式注入 onboarding sheet,`PaywallContent` 通过 `@EnvironmentObject` 拿到的是同一个 |
| scheme 里 StoreKit 配置路径写错 | **不是问题。**`VoiceTodo.xcscheme` 的 `identifier = "../../VoiceTodo/Products.storekit"` 是对的 —— 该路径相对工程根目录解析,已对照真实工程验证 |
| product ID 前缀没对齐 bundle ID | **前提就是错的。**见 2.4 |
| 网络问题 | 本地 StoreKit Configuration 不走网络 |

### 2.3 根因:`VoiceTodo/Products.storekit` 不是 Xcode 的 schema

该文件从 `1edf205`(首次纳入)起就是手写的,键名与 Xcode 生成的 `.storekit` 完全对不上。

对照基准(两份都是 Xcode 自己写出来的真实文件):

- **v4(主基准,含 `introductoryOffer` / `winbackOffers` / `adHocOffers` 实例)**:
  [flutter/packages · in_app_purchase_storekit example Configuration.storekit](https://github.com/flutter/packages/blob/main/packages/in_app_purchase/in_app_purchase_storekit/example/ios/Runner/Configuration.storekit)
- v2(结构更简,交叉印证):
  [RevenueCat/storekit2-demo-app · Step10Configuration.storekit](https://github.com/RevenueCat/storekit2-demo-app/blob/main/StepByStepExamples/Step10/Step10Configuration.storekit)

| 位置 | 仓库现状(错) | Xcode 真实 schema |
|---|---|---|
| 顶层 | `"type": "subscriptions"`、`"name": "Products"` | 无这两个键 |
| 顶层 | 缺失 | `"products": []`、`"nonRenewingSubscriptions": []`、`"settings": {…}`(v4 还有 `"appPolicies"`) |
| 顶层 | `"version": 3`(标量) | `"version": {"major": 4, "minor": 0}`(对象) |
| 商品 ID | `"id"` | **`"productID"`**(单这一条就足以让加载返回空) |
| 续订周期 | `"subscriptionPeriod"` | `"recurringSubscriptionPeriod"`(仅商品层;`introductoryOffer` 内的 `"subscriptionPeriod"` 键名不变) |
| 家庭共享 | `"familySharable"` | `"familyShareable"` |
| 商品 | 缺失 | `"internalID"`、`"groupNumber"`、`"type": "RecurringSubscription"` |
| 商品 | 多余非 schema 键 | `"levels"`、`"internal"`、`"recurringPrice"`、`"offerCode"`、`"name"` |
| 试用 | `introductoryOffer.referenceName` | 无此键(只有 `adHocOffers` / `winbackOffers` 的条目才有 `referenceName` 和 `offerID`) |

现状文件里**写对了**的部分(不要在重写时改掉):`"winbackOffers": []` 是 v4 schema 的合法键;
`introductoryOffer.paymentMode` 的取值应为 `"free"`(v5 schema,见 §3.1 修正说明;
`"freeTrial"` 会让 runtime 解码失败)。

Xcode 解析不了这个文件 → 本地商店里一个商品都没有 → `Product.products(for:)` 返回 `[]` → `.empty`。

### 2.4 前一次修复(`29603ec`)方向错了

`29603ec` 把 product ID 从 `com.voicetodo.pro.*` 改成 `com.qingqingyu.voicetodo.pro.*`,
理由是「App Store Connect 强制要求前缀与 bundle ID 一致,新版 Xcode 本地 StoreKit Configuration 也会校验」。

**这两句都不成立。**IAP product ID 只需要全局唯一,不要求以 bundle ID 为前缀;本地
StoreKit Configuration 更不做这种校验。所以那次改动没有解决问题。

改后的 ID 本身无害(前缀对齐是个不错的命名约定),**保留即可**,但
`App/EntitlementManager.swift:14-15` 的注释必须改掉 —— 留着会把下一次排查继续带偏。

### 2.5 两个放大问题的次生 bug

**(a) `PaywallContent` 自己不触发加载。**
只有 sheet 版 `PaywallView` 挂了 `.task { await entitlement.refresh() }`(`PaywallView.swift:52`)。
onboarding 第三屏是直接内嵌 `PaywallContent`(`App/OnboardingView.swift:811`),外层
`proPaywallStep` 没有任何 `.task` / `.onAppear`。第三屏只能吃
`VoiceTodoApp.handleAppLaunch()` 那一次冷启动 refresh(`VoiceTodoApp.swift:301`)的结果,
而且 `handleAppLaunch` 不在回前台时重跑(`handleScenePhaseChange` 没调它)。一旦那次失败,
除了用户手点 Retry 没有任何自愈路径。

**(b) 初始态就是错误态。**
`productLoadState` 默认值是 `.empty`(`EntitlementManager.swift:24`),所以第三屏首帧直接画错误卡,
而不是 spinner。

---

## 3. 改动清单

### 3.1 重写 `VoiceTodo/Products.storekit`(核心修复)

整体替换为下面的内容。product ID、价格数值(12 / 98)、3 天免费试用、中英双语文案全部保持不变,
只改 schema 结构(键名/嵌套关系);identifier/group ID 格式按 Xcode 约定从伪 UUID 收敛为 8 位 hex,
`displayPrice` 字符串表示从整数 `"12"`/`"98"` 改为 `"12.00"`/`"98.00"`(Xcode 写法)。

```json
{
  "identifier" : "F4A2C9D8",
  "nonRenewingSubscriptions" : [

  ],
  "products" : [

  ],
  "settings" : {
    "_failTransactionsEnabled" : false,
    "_locale" : "zh_CN",
    "_storefront" : "CHN"
  },
  "subscriptionGroups" : [
    {
      "id" : "B1C2D3E4",
      "localizations" : [
        {
          "description" : "VoiceTodo Pro：更高的每日语音整理额度",
          "displayName" : "VoiceTodo Pro",
          "locale" : "zh_CN"
        },
        {
          "description" : "VoiceTodo Pro: higher daily voice quota",
          "displayName" : "VoiceTodo Pro",
          "locale" : "en_US"
        }
      ],
      "name" : "Pro",
      "subscriptions" : [
        {
          "adHocOffers" : [

          ],
          "codeOffers" : [

          ],
          "displayPrice" : "98.00",
          "familyShareable" : false,
          "groupNumber" : 1,
          "internalID" : "A1000002",
          "introductoryOffer" : {
            "displayPrice" : "0.00",
            "internalID" : "A1000012",
            "paymentMode" : "free",
            "subscriptionPeriod" : "P3D"
          },
          "localizations" : [
            {
              "description" : "每年自动续费，比月付省约 32%",
              "displayName" : "Pro 年付",
              "locale" : "zh_CN"
            },
            {
              "description" : "Billed annually. Save ~32% vs monthly.",
              "displayName" : "Pro Yearly",
              "locale" : "en_US"
            }
          ],
          "productID" : "com.qingqingyu.voicetodo.pro.yearly",
          "recurringSubscriptionPeriod" : "P1Y",
          "referenceName" : "Pro Yearly",
          "subscriptionGroupID" : "B1C2D3E4",
          "type" : "RecurringSubscription",
          "winbackOffers" : [

          ]
        },
        {
          "adHocOffers" : [

          ],
          "codeOffers" : [

          ],
          "displayPrice" : "12.00",
          "familyShareable" : false,
          "groupNumber" : 2,
          "internalID" : "A1000001",
          "introductoryOffer" : {
            "displayPrice" : "0.00",
            "internalID" : "A1000011",
            "paymentMode" : "free",
            "subscriptionPeriod" : "P3D"
          },
          "localizations" : [
            {
              "description" : "每月自动续费，可随时取消",
              "displayName" : "Pro 月付",
              "locale" : "zh_CN"
            },
            {
              "description" : "Billed monthly. Cancel anytime.",
              "displayName" : "Pro Monthly",
              "locale" : "en_US"
            }
          ],
          "productID" : "com.qingqingyu.voicetodo.pro.monthly",
          "recurringSubscriptionPeriod" : "P1M",
          "referenceName" : "Pro Monthly",
          "subscriptionGroupID" : "B1C2D3E4",
          "type" : "RecurringSubscription",
          "winbackOffers" : [

          ]
        }
      ]
    }
  ],
  "version" : {
    "major" : 4,
    "minor" : 0
  }
}
```

要点:

- `internalID` 和组 `id` 用 8 位十六进制(Xcode 的约定),**不要**用 UUID。顶层 `identifier` 同样按 8 位 hex 写(当前文件的伪 UUID 格式 `F4A2C9D8-1B5E-...` 非标准)。
- `groupNumber` 是组内档位排序,年付给 1(更高档),月付给 2。
- `version` 写 `{major: 4, minor: 0}`,与 v4 基准样本一致。Xcode 打开后如需要会自行调整。
- 试用写 **`"paymentMode": "free"`**(v5 schema)。**2026-08-22 实测修正,推翻本节旧结论**:
  v5 JSON 里 `payAsYouGo` / `payUpFront` 保持 API rawValue 拼写,**唯独 freeTrial 例外,写 `"free"`**。
  132a03f 曾依本文档把 `"free"` 改成 `"freeTrial"`,结果 iOS 26.5 模拟器 runtime 的
  ASOctaneSupport 解码整个配置文件失败(`Error decoding configuration file ... 格式不正确`),
  本地商店无商品、`Product.products(for:)` 返回空数组 —— 即 paywall 的「Couldn't load
  subscription plans」。已用多份真实 Xcode 26 生成的 v5 文件(Kurozora 等)交叉验证并实测修复。
- `introductoryOffer` 里带 `displayPrice`(免费试用写 `"0.00"`)和 `internalID`,但**没有**
  `referenceName` —— `referenceName` / `offerID` 只属于 `adHocOffers` 和 `winbackOffers` 的条目。
- `winbackOffers` 是 v4 schema 的合法键,每个商品都要有(没有 win-back offer 就给空数组)。
- `settings` 里的 `_locale` / `_storefront` 决定本地调试时价格显示的货币。设成 `zh_CN` / `CHN`,
  `displayPrice` 的 12 / 98 才会渲染成 ¥12 / ¥98;不设则跟随 Xcode 默认(通常是 USA/美元)。

### 3.2 `UI/Paywall/PaywallView.swift`:让 `PaywallContent` 自己负责加载

把 `.task { await entitlement.refresh() }` 从 `PaywallView` 下移到 `PaywallContent`,
两个入口(sheet / onboarding 内嵌)共用同一套加载触发。

`PaywallView.body`(约 `:29-56`)——**删掉** `.task` 那一行:

```swift
        }
-       .task { await entitlement.refresh() }
        .onChange(of: entitlement.isPro) { _, becamePro in
            if becamePro { dismiss() }        // 购买成功后关 sheet,保留不动
        }
```

`PaywallContent.body`(约 `:75-103`)——在最外层 `VStack` 的修饰符链上**加上**:

```swift
        .task { await entitlement.refresh() }
        .onChange(of: entitlement.products) { _, newProducts in
            // …既有逻辑不动
        }
```

`EntitlementManager.loadProducts()` 已有重入守卫(`:79` 的 `isLoadingProducts`),
和 `handleAppLaunch()` 的启动 refresh 并发触发是安全的。

### 3.3 `App/EntitlementManager.swift:24`:初始态改 `.loading`

```diff
-    @Published private(set) var productLoadState: ProductLoadState = .empty
+    /// 初始为 .loading —— 首帧应显示 spinner 而不是「加载失败」卡片。
+    /// 真正的空/错误态由 loadProducts() 落定。
+    @Published private(set) var productLoadState: ProductLoadState = .loading
```

配合 3.2,第三屏首帧走 `loadingPlaceholder`(`PaywallView.swift:393-399`)。

### 3.4 `App/EntitlementManager.swift:13-18`:改掉错误注释

```diff
     /// App Store Connect 中的自动续费订阅产品 ID（月付 / 年付，同一订阅组）。
-    /// 前缀必须与 App bundle ID 一致（com.qingqingyu.voicetodo）—— App Store Connect 强制要求,
-    /// 新版 Xcode 本地 StoreKit Configuration 也会校验,不匹配会让商品加载返回空。
+    /// 这两个 ID 必须与 VoiceTodo/Products.storekit（本地调试）以及 App Store Connect 上注册的
+    /// 订阅（上架后）**逐字一致**,否则 Product.products(for:) 返回空数组。
+    /// 注:IAP product ID 只要求全局唯一,并不要求以 bundle ID 为前缀 —— 这里对齐前缀纯属命名约定。
     static let monthlyProductID = "com.qingqingyu.voicetodo.pro.monthly"
     static let yearlyProductID = "com.qingqingyu.voicetodo.pro.yearly"
```

### 3.5 `.error` 分支的文案(小)

`PaywallView.swift:326` 当前复用 `ErrorMessages.paywallPurchaseFailed`
(`Protocols/ErrorMessages.swift:78`,「购买失败,请稍后重试」),但这里是**加载**失败,
并没有发生任何购买,文案会误导用户。

在 `Resources/Localizable.xcstrings` 新增 `paywall.products_load_failed`:

- zh-Hans:`加载订阅方案失败，请稍后重试`
- en:`Something went wrong. Please try again later.`

(注意:`.error` 分支的 title 仍复用 `paywall.products_empty.title`「Couldn't load subscription plans」,
所以副标题不要再用 "Couldn't load plans" 开头 —— 否则两行语义重复。这里选 "Something went wrong"
做区分。)

同时在 `Protocols/ErrorMessages.swift`(与现有 `paywallPurchaseFailed` 同一文件,`:78`)新增集中常量:

```swift
static let paywallProductsLoadFailed = String(localized: "paywall.products_load_failed")
```

`.error` 分支改为 `subtitle: entitlement.lastError ?? ErrorMessages.paywallProductsLoadFailed`,
同时把 `EntitlementManager.loadProducts()` catch 块里的 `lastError = ErrorMessages.paywallPurchaseFailed`
(`:97`)一并换成 `ErrorMessages.paywallProductsLoadFailed`。

### 3.6 清理 `VoiceTodo.xcodeproj/project.pbxproj` 的失效引用(可选)

`29603ec` 引入的根 group 文件引用指向仓库外两级,在 Xcode 里显示为红色失效项:

```
420: F56D32993028681D0067A08B /* Products.storekit */ = {isa = PBXFileReference; lastKnownFileType = text; name = Products.storekit; path = ../../VoiceTodo/Products.storekit; sourceTree = "<group>"; };
687:     F56D32993028681D0067A08B /* Products.storekit */,
```

删掉这两行即可。**不要动** `:293`(target 内正确的 `path = Products.storekit`)和 `:985`
(resource build phase 条目)。跑 `xcodegen generate` 也能顺带清掉。

---

## 4. 验证

1. **先验 schema(最关键)。** Xcode 打开 `VoiceTodo/Products.storekit`,必须进入 StoreKit
   可视化编辑器,显示订阅组 `Pro` + 2 个商品,每个商品的 Introductory Offer 显示 3 天免费试用。
   若报错或只当纯文本打开 → schema 仍不对:先退回最小可用形态(`"introductoryOffer": null`、
   组 `localizations` 置为空数组)确认能打开,再用 Xcode 编辑器 UI 把试用和本地化文案加回去并保存,
   **以 Xcode 自己写出的 JSON 为准**覆盖本文档 §3.1。
2. Edit Scheme → Run → Options → **StoreKit Configuration** 应显示 `Products.storekit`(不是 None)。
3. 模拟器**先删除 App**(重置 `hasCompletedOnboarding`),重新 Run,走完前两屏到第三屏:
   预期先看到 spinner,随后出现两张商品卡(按价格升序:¥12/月 + ¥98/年,年付默认选中)、
   "3 天免费试用" 文案和订阅 CTA。
4. Console:`entitlement.products_empty` 警告应消失。若改为出现 `entitlement.products_failed`,
   那是另一类问题(抛错),按 `.error` 分支单独排查。
5. **回归 sheet 入口**:主界面设置页「升级 Pro」(`UI/Home/HomeView.swift:432` → `coordinator.showPaywall`)
   弹出的 `PaywallView` 仍能正常加载 —— 验证 3.2 的 `.task` 下移没有造成回归。
6. `VoiceTodoUITests/ScenarioTests.swift:451-456` 的断言只校验「以后再说」可点,修复后仍应通过。
   但那里的注释说「UI 测试环境无 StoreKit mock → 付费墙落到 .empty 状态」已经过时
   (test action 在 `project.yml:219` 同样配了 `storeKitConfiguration`),顺手更新注释。
   建议改为:「test action 虽配了 `storeKitConfiguration`,但 UI 测试仍按降级路径验收 ——
   商品加载失败时 onboarding 不能被卡死」(保留「以后再说」可点的硬性断言不变)。
7. 跑一遍单测 + UI 测试(scheme `VoiceTodo`,Debug)。

---

## 5. 范围之外(上架前待办)

Archive / Release 不绑定 StoreKit Configuration(`project.yml:227-228` 的 archive 用 Release 且未配),
TestFlight / App Store 构建取的是 App Store Connect 上的真实商品数据。

本次修复只解决**本地 / 模拟器 Run** 的商品加载。上架前仍需:

- 在 App Store Connect 用同样两个 product ID(`com.qingqingyu.voicetodo.pro.monthly` /
  `.yearly`)注册自动续费订阅,放在同一订阅组,配 3 天免费试用;
- 商品状态进入「准备提交 / 已批准」,否则 TestFlight 上会看到一模一样的 `.empty` 画面。

另外注意:`Products.storekit` 目前被打进 app bundle 作为资源
(`project.pbxproj:985`,`Products.storekit in Resources`)。运行时无害,但会把测试配置随 Release 一起发出去,
可以另行评估是否从 resource build phase 移除。

---

## 6. 实施前需确认的开放问题

以下 5 点在本方案起草时识别但未完全解决,实施前需逐一确认。

> **已逐条查证,结论见 §7。** 摘要:6.1 / 6.5 已解决(拿到 Xcode 真实产出的 v4 样本,
> §3.1 已据此修正,其中 `paymentMode` 原来写错了);6.4 成立,保留;
> **6.2 和 6.3 的前提不成立**,按 §7 的结论执行,不要按 §6 的处方改。

### 6.1 §3.1 替换 JSON 不是金标准

§3.1 给出的完整 JSON 是按 RevenueCat 示例对齐手写的,**不是 Xcode 自己写出来的**。其中
`"paymentMode": "free"`(StoreKit JSON 枚举)是全套改动里唯一无法靠静态检查确认的字段 ——
必须以 Xcode 打开后重新保存的 JSON 为准。

**实施约束**:不要直接 copy-paste §3.1 落盘。先用 §3.1 让 Xcode 进入可视化编辑器(若进得去),
保存一次,以 Xcode 输出的 JSON 覆盖 §3.1;若 Xcode 拒绝打开,退回最小可用形态
(`"introductoryOffer": null`、组 `localizations` 置空),再用 Xcode UI 把试用和本地化加回去。

### 6.2 §3.2 `.task` 下移的「自愈」是部分的

`PaywallContent` 加 `.task { await entitlement.refresh() }` 后,会和 `VoiceTodoApp.handleAppLaunch()`
的启动 refresh 并发触发。`isLoadingProducts` 重入守卫(`EntitlementManager.swift:79`)只保证
不发并发 StoreKit 请求 —— **被守卫挡掉的调用会立即返回,不会等结果**。

这意味着:如果 `handleAppLaunch()` 的启动 refresh 已经落 `.empty`,onboarding 第三屏打开瞬间
`PaywallContent.task` 触发的 refresh 会被守卫挡掉、立即返回,UI 看到的还是缓存里的 `.empty`。

**实施约束**:`.task` 下移只是形式上的「两个入口都触发加载」,不构成真正的自愈路径。要让第三屏
真正自愈,需要 `.task` 看到 `productLoadState` 是 `.empty` 或 `.error` 时**强制再拉一次**(绕过
守卫,或给守卫加 force 参数)。

### 6.3 §3.6 删 pbxproj 失效引用会被 xcodegen 写回

§3.6 标「可选」是相对于「修复本地商品加载」而言 —— 不删不影响功能。但**仅删 `project.pbxproj`
不够**:`project.yml:71` 已经有 `path: VoiceTodo/Products.storekit`(相对工程根目录的正确路径),
失效项是历史遗留;但只要 `project.yml` 里仍有 StoreKit 相关路径声明,跑 `xcodegen generate`
就可能把 group 条目写回来(注意:`project.yml` 的路径是 `VoiceTodo/Products.storekit`,**不是**
失效项里的 `../../VoiceTodo/Products.storekit`,两者指向同一个文件但相对基准不同)。

**实施约束**:删 `pbxproj` 引用前先看 `project.yml` 是否也有相关条目。要彻底清掉,得改 `project.yml`
(或确认 yml 已经不引用、失效项纯粹是历史遗留)。

### 6.4 §3.5 文案分离时 `EntitlementManager.swift:97` 容易漏改

§3.5 同时要求改两处:

1. `PaywallView.swift:326`(UI error 分支 subtitle)
2. `EntitlementManager.swift:97`(catch 块里的 `lastError` 赋值)

第 2 处在 §3.5 的描述里只用一句话带过,很容易被实施者漏掉。

**实施约束**:执行 §3.5 时,务必把这两处作为**同一个原子改动**提交,任何一处漏改都会让 `.error`
分支的文案回到旧的「购买失败」误导文案。

### 6.5 §3.1 `introductoryOffer.internalID` 字段 + `winbackOffers` 的不确定性

§3.1 给商品的 `introductoryOffer` 指定了 `"internalID": "A1000012"`(年付试用)/ `"A1000011"`
(月付试用)。商品本身也有 `internalID`(`A1000002` / `A1000001`)。`internalID` 是 Xcode 本地生成的
标识。

此外,§3.1 的 JSON 省略了 `winbackOffers`(当前文件有 `"winbackOffers": []`)。当前无法静态确认
Xcode 较新版本是否已把 `winbackOffers` 纳入 schema —— 若已纳入,§3.1 的省略会让 Xcode 补回空数组;
若未纳入,则当作多余键丢弃。

未确认:手填的 internalID 会不会在 Xcode 首次打开时被接受、Xcode 重新保存时会不会被覆盖、
覆盖后会不会和商品本身的 internalID 冲突;`winbackOffers` 是否属于当前 Xcode schema。

**实施约束**:跟 §6.1 同源。Xcode 写出来的 JSON 为准;若发现 Xcode 重新分配 internalID,
以 Xcode 的为准,§3.1 的值仅用于让 Xcode 首次能解析通过。

### 6.6 小结

5 个开放问题归为 3 类:

| 类别 | 涉及 | 共同主题 |
|---|---|---|
| schema 真伪 | §6.1、§6.5 | Xcode 写出来的 JSON 才是金标准,§3.1 的手写值只能当骨架,必须以 Xcode 重新保存的结果覆盖 |
| 修复覆盖面 | §6.2、§6.4 | 「下移 `.task`」「分离文案」看似一行改动,实际需要配套实现才能真正达成目标 |
| 工具链配套 | §6.3 | 手改 `pbxproj` 不持久,源头在 `project.yml` |

实施前的最小 checklist:

1. **别 copy-paste §3.1 落盘**:先让 Xcode 打开、保存,以其输出覆盖 §3.1(覆盖 §6.1、§6.5)
2. **§3.2 `.task` 下移后补 force-refresh 路径**:看到 `.empty`/`.error` 时绕过守卫重拉(覆盖 §6.2)
3. **§3.5 两处改原子提交**:`PaywallView.swift:326` + `EntitlementManager.swift:97`(覆盖 §6.4)
4. **§3.6 删 pbxproj 前先看 `project.yml`**:源头不在 pbxproj(覆盖 §6.3)

---

## 7. 对 §6 开放问题的查证结论

### 7.1 → §6.1「§3.1 不是金标准」:**成立,已解决**

质疑正确,而且抓到了一个真错误。已找到 Xcode 自己写出的 **version 4** 配置文件
([flutter/packages · Configuration.storekit](https://github.com/flutter/packages/blob/main/packages/in_app_purchase/in_app_purchase_storekit/example/ios/Runner/Configuration.storekit)),
里面同时含 `introductoryOffer`、`adHocOffers`、`winbackOffers` 的真实实例:

```json
"introductoryOffer" : {
  "displayPrice" : "0.99",
  "internalID" : "62DAF06C",
  "paymentMode" : "payUpFront",
  "subscriptionPeriod" : "P1M"
}
```

同一文件里 `adHocOffers` / `winbackOffers` 的 `paymentMode` 取值是 `"payAsYouGo"` —— 据此推断 JSON 直接用
StoreKit API 枚举 rawValue、免费试用应为 `"freeTrial"`。**这个推断是错的(2026-08-22 实测推翻,见 §3.1
修正说明):v5 里免费试用写 `"free"`,`"freeTrial"` 会让 runtime 解码器拒绝整个文件。**
`displayPrice` / `winbackOffers` / `version` 4 / `settings` 的结论仍然成立。

「以 Xcode 重新保存的结果为准」这条实施约束仍然保留:手写 JSON 再准也只是骨架。

### 7.2 → §6.2「`.task` 下移的自愈是部分的」:**前提不成立,不要按此处方改**

§6.2 说「如果启动 refresh 已经落 `.empty`,第三屏 `.task` 触发的 refresh 会被守卫挡掉、立即返回」。
这个描述与代码不符。看 `EntitlementManager.loadProducts()`:

```swift
guard !isLoadingProducts else { return }
isLoadingProducts = true
productLoadState = .loading
defer { isLoadingProducts = false }        // ← 函数返回时释放
do { let storeProducts = try await Product.products(for: Self.productIDs) ... }
```

`isLoadingProducts` 由 `defer` 在 `loadProducts()` 返回时释放。「启动 refresh **已经落** `.empty`」
意味着它已经返回、守卫已经释放 —— 此时第三屏 `.task` 的 refresh **能正常穿过守卫并发起真实请求**。
守卫只挡**并发**调用,不挡后续调用。

唯一真被挡掉的情况是:启动 refresh **仍在飞行中**时第三屏正好出现。但那次在飞的请求本来就会
publish 结果到同一个 `@Published productLoadState`,UI 照样会更新,不存在「卡在旧的 `.empty`」。

时序上也够宽裕:`switch currentStep` 外包了 `Group`(`OnboardingView.swift:110-122`),
`proPaywallStep` 只在用户走到第三屏时才创建,`.task` 那一刻触发;而用户要先过 welcome 页和权限页
(含系统弹窗),距冷启动通常已数秒。

**结论**:不要加 force 参数绕过守卫。那样只会在第三屏出现的瞬间打出一个重复的并发 StoreKit 请求,
正好是守卫存在的理由。§3.2 按原样实施即可。

(顺带一个 §6.2 没提但真实存在的小缺口:用户在第三屏把 App 切后台再回来,不会重新拉取 ——
`handleScenePhaseChange` 不调 `handleAppLaunch`,`.task` 也不会因 scenePhase 重跑。
影响很小,有 Retry 兜底,本次不处理。)

### 7.3 → §6.3「删 pbxproj 会被 xcodegen 写回」:**方向反了**

§6.3 认为源头在 `project.yml`、跑 `xcodegen generate` 会把失效项写回来。实际相反。

`project.pbxproj` 里 `Products.storekit` 有**两条**引用:

| 行 | 内容 | 出处 |
|---|---|---|
| `:293` + `:801` | `path = Products.storekit`,挂在 `C98DBDBB /* VoiceTodo */` group(该 group `path = VoiceTodo`) | **XcodeGen 从 `project.yml:71` 生成的,正确** |
| `:420` + `:687` | `name = Products.storekit; path = ../../VoiceTodo/Products.storekit`,挂在**根 group** `9B6C7BF5`(无 path,基准即工程根目录)→ 解析到仓库外两级 | **Xcode 自己加的重复项**,`29603ec` 的 commit message 也明说是「Xcode 操作副作用」 |

XcodeGen 不会为同一个 source path 生成两条引用,所以 `xcodegen generate` 是**清掉**失效项,不是写回。
`project.yml` 里的 `VoiceTodo/Products.storekit`(target sources)和
`storeKitConfiguration: VoiceTodo/Products.storekit`(scheme)都是对的,**不需要改 `project.yml`**。

失效项的真正来源:Xcode 打开工程、解析 scheme 里的 `StoreKitConfigurationFileReference` 时,会照那个
字符串在导航器里建一条引用。scheme 的 `identifier = "../../VoiceTodo/Products.storekit"` 本身是对的
(Xcode 的约定是固定 `../../` 前缀 + 相对工程根目录的路径,已对照真实工程验证);但 Xcode 把同一字符串
当 group 相对路径建 `PBXFileReference`,基准不同就成了坏路径。

**结论**:§3.6 仍然是纯清理、可选。删了之后 Xcode 下次打开工程可能再加回来 —— 这是打地鼠,不影响功能,
也可以干脆不删。**不要为它去改 `project.yml`。**

### 7.4 → §6.4「§3.5 两处容易漏改」:**成立,保留**

`EntitlementManager.swift:97` 和 `PaywallView.swift:326` 必须同改,原子提交。

补一点 §6.4 没提的:`.error` 分支写的是
`subtitle: entitlement.lastError ?? ErrorMessages.paywallProductsLoadFailed`,
但 `lastError` 在 catch 里**一定**被赋值,所以 `??` 右边其实是死代码。这不是 bug,
但它意味着**真正生效的是 `EntitlementManager.swift:97` 那一处**——正好是最容易被漏掉的那处。
实施时以它为准。

### 7.5 → §6.5「`introductoryOffer.internalID` + `winbackOffers` 不确定」:**已解决**

v4 基准样本给出了确定答案:

- `introductoryOffer.internalID` 是 schema 的正式键(样本值 `"62DAF06C"`,8 位 hex),手填合法。
- `winbackOffers` **属于**当前 schema(iOS 18 / Xcode 16 引入 win-back offer),样本里每个订阅都有,
  无 offer 时为空数组。所以它不该被列进「多余非 schema 键」——§2.3 表格已更正,§3.1 已补回。
- 反过来,`introductoryOffer` 里**没有** `referenceName`(现状文件写了「3 天免费试用」),
  `referenceName` / `offerID` 只属于 `adHocOffers` / `winbackOffers` 条目。

至于「Xcode 会不会重新分配 internalID」:样本无法证伪,但这不影响正确性 —— internalID 是 Xcode 本地
标识,重排不影响 `productID` 匹配。手填值只用于让 Xcode 首次能解析通过,之后以 Xcode 的输出为准。

### 7.6 修订后的实施 checklist

1. **§3.1 已按 v4 样本修正**(`paymentMode: "free"`(v5 实测修正,原误写 `"freeTrial"`)、
   补 `displayPrice`/`winbackOffers`、`version` 4、`settings` 补 locale/storefront)。仍然:
   落盘后先用 Xcode 打开并保存一次,以 Xcode 输出覆盖 §3.1。
2. **§3.2 按原样实施,不要加 force-refresh**(§7.2)。
3. **§3.5 两处原子改**,重点是 `EntitlementManager.swift:97`(§7.4)。
4. **§3.6 保持可选,不要改 `project.yml`**(§7.3)。
