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
对照基准:[RevenueCat/storekit2-demo-app / Step10Configuration.storekit](https://github.com/RevenueCat/storekit2-demo-app/blob/main/StepByStepExamples/Step10/Step10Configuration.storekit)(Xcode 自己写出来的文件)。

| 位置 | 仓库现状(错) | Xcode 真实 schema |
|---|---|---|
| 顶层 | `"type": "subscriptions"`、`"name": "Products"` | 无这两个键 |
| 顶层 | 缺失 | `"products": []`、`"nonRenewingSubscriptions": []`、`"settings": {}` |
| 顶层 | `"version": 3`(标量) | `"version": {"major": 2, "minor": 0}`(对象) |
| 商品 ID | `"id"` | `"productID"` |
| 续订周期 | `"subscriptionPeriod"` | `"recurringSubscriptionPeriod"`(仅商品层;`introductoryOffer` 内的 `"subscriptionPeriod"` 键名不变) |
| 家庭共享 | `"familySharable"` | `"familyShareable"` |
| 商品 | 缺失 | `"internalID"`、`"groupNumber"`、`"type": "RecurringSubscription"` |
| 商品 | 多余非 schema 键 | `"levels"`、`"internal"`、`"recurringPrice"`、`"offerCode"`、`"name"`、`"winbackOffers"`(见 §6.5 备注) |

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
          "type" : "RecurringSubscription"
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
          "type" : "RecurringSubscription"
        }
      ]
    }
  ],
  "version" : {
    "major" : 2,
    "minor" : 0
  }
}
```

要点:

- `internalID` 和组 `id` 用 8 位十六进制(Xcode 的约定),**不要**用 UUID。顶层 `identifier` 同样按 8 位 hex 写(当前文件的伪 UUID 格式 `F4A2C9D8-1B5E-...` 非标准)。
- `groupNumber` 是组内档位排序,年付给 1(更高档),月付给 2。
- `version` 写 `{major: 2, minor: 0}`;Xcode 打开后如需要会自行升级格式,不用手动猜最新版本号。
- 试用写 `"paymentMode": "free"` —— 这是 `.storekit` JSON 里的写法(StoreKit API 侧的枚举才叫
  `.freeTrial`,别混)。**这是全套改动里唯一无法靠静态检查确认的字段,必须走 §4 验证第 1 步。**

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
