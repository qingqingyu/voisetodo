# 订阅两层口径：付费墙估算修正 + 静默降级检测

真机订阅后付费墙同时显示「You're already subscribed to Pro」和「Today: 0/3 used (estimated)」——3 是免费档上限。排查结论与两处修法。

**背景：** 订阅有两层，两层各自独立判定，今天没有任何地方能发现它们不一致。

- **层 1 客户端**：StoreKit 2 `Transaction.currentEntitlements` → `App/EntitlementManager.swift` → 付费墙显示「已订阅」
- **层 2 服务端**：客户端把 `jwsRepresentation` 放进 `X-Subscription-JWS` 头 → AIProxy `resolveSubscriptionTier` 验签 → 决定给 3 条还是 100 条

---

## 先说结论：截图是「正常的」，但有两件事要分清

### 1. `0/3` 现在只是本地默认值，不代表服务端给了 3 条

`QuotaUsage` 的初值就是免费档（`Protocols/Quota.swift:40-41`）：

```swift
@Published private(set) var limit: Int = QuotaConfig.freeDailyLimit      // = 3
@Published private(set) var remaining: Int = QuotaConfig.freeDailyLimit
@Published private(set) var plan: Plan = .free
@Published private(set) var isAuthoritative: Bool = false
```

只有代理返回 `X-Quota-*` 头时才会被覆盖（`Quota.swift:60-79`），那时 `isAuthoritative` 才变 `true`。

而「(estimated)」这个后缀，正是 `isAuthoritative == false` 的标记（`UI/Paywall/PaywallView.swift:284`）：

```swift
if !quotaUsage.isAuthoritative {
    Text(String(localized: "quota.non_authoritative"))   // "(estimated)"
}
```

订阅完还没发起过任何提取请求 → 没收到过任何 `X-Quota-*` 头 → 显示的就是写死的免费档初值。**这个数字此刻不携带任何服务端信息。**

问题在于：**刚付完钱看到免费档的数字，用户会以为没生效。** 这是本文档要修的第 1 件事。

### 2. 但这个 build 本来就验证不了服务端 Pro 链路

`project.yml:236` 的 run scheme 挂了本地 StoreKit 配置：

```yaml
schemes:
  VoiceTodo:
    run:
      config: Debug
      storeKitConfiguration: VoiceTodo/Products.storekit   # ← Command+R 走这个
```

所以 Command+R 部署到真机后的购买是 **Xcode 本地 StoreKit 模拟**，不是真 Sandbox。本地模拟交易的 JWS 由 **Xcode 的本地测试证书**签发。

而服务端 `resolveSubscriptionTier`（`AIProxy/worker.js:1594`）是零信任验签，锚定 Apple 真实根证书：

```js
const result = await verifySubscriptionJWS(jws, {
  expectedBundleId: env.APP_BUNDLE_ID || "com.voicetodo.app",
  productIDs: proProductIDs,
  rootFingerprint: env.SUBSCRIPTION_ROOT_SHA256 || APPLE_ROOT_CA_G3_SHA256   // ← 锚 Apple Root CA G3
});
```

本地测试证书的指纹对不上 Apple Root CA G3 → 验签抛错 → 走 fail-safe 分支（`worker.js:1650`）：

```js
} catch (error) {
  // fail-safe 到免费档（不 fail-open，不 500）
  logWarn("proxy.subscription.verify_failed", { ...requestContext, reason: "verify_failed", ... });
  return { tier: "free", limit: freeLimit, productId: null };
}
```

**所以在这个 build 上录一条待办后，大概率会拿到权威的 `X-Quota-Limit: 3`** —— 客户端说 Pro，服务端算免费档。

> ⚠️ **这是开发环境的固有限制，不是 bug，不要去「修」它。** 本地 StoreKit 模拟本来就产生不了 Apple 签名的收据。
>
> ⚠️ **更不要动 `SUBSCRIPTION_ROOT_SHA256` 去让它「通过」。** 把生产 worker 的根证书指向本地 StoreKit 测试根，等于接受任何人本地伪造的收据，付费墙直接失守。这个 env 覆盖只应用于独立的测试 worker。

### 3. 真正的问题：这个矛盾今天没人能发现

「客户端认为 Pro、服务端认为免费档」在生产环境**已经真实发生过一次**。`AIProxy/wrangler.toml` 的注释记着：

> 两个值必须与 iOS 端逐字一致……任一不匹配 → `verifySubscriptionJWS` 抛 `bundle_mismatch` / `product_mismatch` → fail-safe 免费档，付费用户被静默降级（2026-08-20 真机复现：订阅用户第 3 次录音弹免费限制墙的根因）。

付费用户拿不到付费额度，收入和口碑双输，**而且会一直沉默**——服务端 `logWarn` 了但没人看日志，客户端完全无感。这是本文档要修的第 2 件事。

---

## 改动 1：付费墙本地估算按订阅态取上限

### 修法

`Protocols/Quota.swift` 加入口：

```swift
/// 无权威头时，按本地订阅态选估算上限。权威值到达后不再受影响。
func applyLocalEntitlement(isPro: Bool) {
    guard !isAuthoritative else { return }
    plan = isPro ? .pro : .free
    limit = isPro ? QuotaConfig.proDailyLimit : QuotaConfig.freeDailyLimit
    remaining = max(0, limit - used)
}
```

`guard !isAuthoritative` 是**硬约束**：服务端权威值一旦到达，本地估算绝不能再覆盖它。否则会把「服务端只给了 3 条」这个真相盖掉，正好是改动 2 要检测的东西。

`QuotaConfig` 目前只暴露 `freeDailyLimit`（`Quota.swift:4-7`），补一个：

```swift
enum QuotaConfig {
    static let freeDailyLimit: Int = NetworkConfig.freeDailyLimit
    /// Pro 档本地估算上限。权威值仍以代理 X-Quota-Limit 为准。
    static let proDailyLimit: Int = NetworkConfig.proDailyLimit   // 已有，Constants.swift:77
}
```

### 挂接点

`App/AppCoordinator.swift` 已同时持有两者，现成可用：

```swift
private let entitlement: EntitlementManager   // :32
private weak var quotaUsage: QuotaUsage?      // :43（注意是 weak）
```

`entitlement.isPro` 也已经在用了（`:253` 的付费墙判定）。订阅态变化时调一次 `quotaUsage?.applyLocalEntitlement(isPro: entitlement.isPro)`，覆盖三个时机：

- 启动时 `currentEntitlements` 首次解析完成
- 购买成功后
- `Restore Purchases` 成功后

### 「(estimated)」标记必须保留

改完之后 Pro 用户首次调用前会看到 `0/100 (estimated)`。**不要因为「现在数字对了」就把这个标记去掉**——它仍然是本地估算，没跟服务端确认过。这个标记正是让用户/开发者能区分「客户端以为」和「服务端认可」的唯一线索。

---

## 改动 2：静默降级检测

### 客户端：新增遥测事件

`Protocols/Telemetry.swift` 加：

```swift
/// B 类：付费用户被静默降级（客户端 Pro + 服务端 free）
case subscriptionTierMismatch(localPlan: String, serverPlan: String, hasJWS: Bool)
```

事件名 `subscription_tier_mismatch`，参数 `localPlan` / `serverPlan` / `hasJWS`。

**触发点**：`Quota.applyQuotaHeaders`（`Quota.swift:60`）——收到权威头时，若服务端 `plan == .free` 而本地 entitlement 是 Pro，记一条。

需要让 `QuotaUsage` 能知道本地 entitlement 状态；改动 1 的 `applyLocalEntitlement` 已经把它带进来了（存一个 `localEntitlementIsPro` 私有属性即可），两处改动天然配套。

**PII 红线**（与 `TELEMETRY.md` 一致）：只报 plan 字符串与布尔值，**绝不带** JWS 内容、productId 之外的订阅信息、任何用户标识。`hasJWS` 只报布尔，用来区分「压根没发凭证」和「发了但验不过」——这两种的排查方向完全不同。

`TELEMETRY.md` 的事件表补一行。

### 服务端：把失败原因带进日志

`worker.js:1650` 的 `verify_failed` 分支现在只有笼统的 `errorFields(error)`。把 `verifySubscriptionJWS` 的具体失败原因（`bundle_mismatch` / `product_mismatch` / 链校验失败 / 已过期）显式作为独立字段带上，让 `wrangler tail` 一眼能定位是哪种。

这几种的处置完全不同：

| 失败原因 | 说明 | 怎么处置 |
|---------|------|---------|
| `bundle_mismatch` | `APP_BUNDLE_ID` 与 iOS `PRODUCT_BUNDLE_IDENTIFIER` 不一致 | 改 `wrangler.toml` 重新部署 |
| `product_mismatch` | `PRO_PRODUCT_IDS` 与 `EntitlementManager` 的产品 ID 不一致 | 同上 |
| 链校验失败 | 非 Apple 签发（本地 StoreKit 模拟就属于这类） | 开发环境正常；生产环境出现要查 |
| 已过期 | 订阅真的过期了 | 正常业务路径，不是故障 |

> `AIProxy/wrangler-config.test.js` 已经会拿 iOS 源码交叉校验 bundle / 产品 ID，前两种理论上进不了生产。日志字段是最后一道兜底。

### ⚠️ 先不要接 Telegram 告警

**看到 `ALERTING.md` 那套告警基建，不要顺手把这个也接上去。**

开发期本地 StoreKit build 会**持续**触发 `verify_failed`——每次真机调试都会刷。直接接告警必然被噪音淹没，然后 bot 被静音，等于把整套告警一起废掉。这正是 `ALERTING.md` 反复强调要避免的失效方式（「告警疲劳 = bot 被静音 = 白做」）。

正确顺序：

1. 先落遥测（本改动）
2. 等 D1 遥测开通（`docs/telemetry-d1-enablement.md`）后，看真实分布、确定基线
3. 再决定阈值——合理的形态是「窗口内 N 个**不同** device 同时 mismatch 才推」，单设备持续 mismatch 大概率就是开发机

---

## 改动文件

| 文件 | 改什么 |
|------|--------|
| `Protocols/Quota.swift` | `applyLocalEntitlement(isPro:)`；`QuotaConfig` 补 `proDailyLimit`；`applyQuotaHeaders` 里加 mismatch 判定 |
| `App/AppCoordinator.swift` | 订阅态变化时调用 `applyLocalEntitlement` |
| `Protocols/Telemetry.swift` | 新事件 `subscription_tier_mismatch` |
| `AIProxy/worker.js` | `verify_failed` 日志补失败原因字段 |
| `TELEMETRY.md` | 事件表补一行 |

## 测试

`VoiceTodoTests/`，沿用现有 Quota 测试形态：

- `applyLocalEntitlement(isPro: true)` → `limit == proDailyLimit`、`plan == .pro`、**`isAuthoritative` 仍为 false**
- **权威头到达后再调 `applyLocalEntitlement` → 不覆盖权威值**（关键回归防线：这条守不住，改动 1 就会把改动 2 要检测的真相盖掉）
- 权威头 `X-Quota-Plan: free` + 本地 Pro → 记一条 `subscription_tier_mismatch`
- 权威头 `X-Quota-Plan: pro` + 本地 Pro → **不记**（正常路径不能刷事件）
- 本地 free + 服务端 free → 不记
- mismatch 事件的 params 里不含 JWS 内容、不含任何用户标识

`AIProxy/`：`npm test` 全量不回归。

## 验证服务端 Pro 链路（必须换 build 方式）

**Command+R 的本地 StoreKit 配置验不了这条链路**，二选一：

1. Xcode → Product → Scheme → Edit Scheme → **Run → Options → StoreKit Configuration 设为 None**，设备登录 Sandbox Apple ID 后购买。真 Sandbox 交易由 Apple 真实证书链签发，能过验签
2. 或走 TestFlight build

然后录一条待办，**两处对齐才算通**：

- 付费墙显示 **`1/100`** 且**没有**「(estimated)」——说明收到了权威头且是 Pro 档
- `npx wrangler tail` 看到 `proxy.subscription.verified tier=pro`，而不是 `proxy.subscription.verify_failed`

只看付费墙不够：`1/100` 也可能来自改动 1 的本地估算（那种情况会带「(estimated)」）。**「没有 estimated 标记」这一点才是服务端认可的证据。**

反过来，如果看到 `1/3` 且**没有**「(estimated)」，说明服务端确实把你当免费档——这时去 `wrangler tail` 查 `verify_failed` 的原因字段。
