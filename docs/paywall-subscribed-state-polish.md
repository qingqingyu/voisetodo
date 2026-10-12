# 付费墙「已订阅」状态页打磨（已取消续费场景）

> 2026-10-12。来源：真机截图（Pro 年付已取消自动续费）+ 一份外部 review。
> 本文先逐条判定 review 对不对，再给出实施规格。实施方按 §2 改，完成后按 §3 自检，交回 review。

**涉及文件**
- `UI/Paywall/PaywallView.swift`（`PaywallView` 标题；`PaywallContent` 已订阅分支 `if entitlement.isPro && successEvent == nil`）
- `Resources/Localizable.xcstrings`（en / ja / zh-Hans 三套都要加）
- 新增单测（见 §2.3）

**不要动**
- `App/EntitlementManager.swift` 的权益判定逻辑（`performEntitlementRefresh` 等）。本次只读它已有的
  `willAutoRenew` / `subscriptionExpirationDate` / `activeProductID`。
- 未订阅分支（购买 UI）的任何东西，包括其 `legalBlock` / `legalText`——那里是 3.1.2 合规必需。
- 成功窗口（`successEvent != nil`）的行为。

---

## 1. Review 逐条判定

| # | Review 意见 | 判定 | 结论 |
|---|---|---|---|
| 1 | 底部「¥298/year, auto-renews」与卡片「不再续费」矛盾 | **对，而且比描述的更严重** | 已订阅分支删掉 `legalText` |
| 2 | 已是 Pro 还写「Upgrade to VoiceTodo Pro」 | **对** | 已订阅分支标题改「VoiceTodo Pro」 |
| 3 | 到期日缺紧迫感 | **部分对** | 仅「已关续费 + 7 天内到期」改相对说法 + 警示色；不做红色、不做全时段倒计时 |
| 4 | 主按钮改「Resume Pro / 重新订阅」 | **方向对，文案不对** | 仅「已关续费」时改为「重新开启自动续费」，动作不变 |
| 5 | 没说到期后会怎样；用空白区列 Pro 功能挽留 | **前半对，后半不要做** | 加一行「到期后回到免费版：每天 3 次」；不列功能、不填空白 |

### 1.1 第 1 条：比 review 说的更严重

`legalText` 的价格取的是 `currentSelectedProduct`——**付费墙上「当前选中的购买方案」，默认年付**，
不是用户实际订阅的那个商品。已订阅分支没有商品列表，这个选中值就是默认年付。所以：

- 月付用户（无论是否续费）会在底部看到「¥298.00/year, auto-renews」——价格和周期都是错的；
- 已关续费的用户看到「auto-renews」，与卡片直接矛盾（截图即此情况）。

这段是**购买前**的自动续费披露（3.1.2），已订阅分支没有购买按钮，不需要它；卡片的日期行已经准确说明了
续费状态（下次续费 X / 有效期至 X 不再续费）。**直接不渲染**，不要改写成「已取消自动续订」——卡片里已有，重复。

隐私政策 / 使用条款链接和「恢复购买」**保留**（恢复是被拒订阅提示的出口，链接留着无害）。

### 1.2 第 3 条：为什么只做一半

截图里「到期日 = 今天」是**沙盒加速续费**造成的（沙盒年付 1 小时一续），真实用户取消年付后，
多数时候离到期还有几个月。对几个月后的日期标橙色是噪音，对开着续费的用户显示倒计时更是在制造焦虑。
所以只在「已关续费 且 7 天内到期」时改相对说法 + 警示色；红色在本 App 语义是错误，不用。

### 1.3 第 4 条：为什么不用「Resume Pro / 重新订阅」

- 此时 Pro **仍然有效**，「Resume Pro」暗示 Pro 已经停了，与卡片「你已是 Pro」矛盾；
- 按钮实际打开的是 Apple 的订阅管理页（`manageSubscriptionsSheet`），用户在那里做的是**重新开启自动续费**，
  不是重新购买。按钮文案必须如实描述点下去会发生什么。

### 1.4 第 5 条：为什么不列「失去的 Pro 功能」

Pro **只提升每日解析额度**（3 → 100），没有其它独占功能（见提审审核备注）。编一串「失去的功能」
既不真实，也有 2.3 元数据/误导风险。只说一句额度变化即可。

下方空白也**不要填**：付费墙有一屏预算约束（`contentFits` / UI 测试 S18 哨兵），已订阅页内容少是正常的。

---

## 2. 实施规格

### 2.1 状态矩阵（已订阅分支内）

`willAutoRenew` 有三态：`true` / `false` / `nil`（异步读取中或读不到）。**`nil` 一律按现状处理**，不推断。

| 元素 | `true`（续费中） | `false`（已关续费） | `nil`（未知） |
|---|---|---|---|
| 导航标题 | VoiceTodo Pro | VoiceTodo Pro | VoiceTodo Pro |
| 日期行 | 不变 | 见 §2.2-C | 不变 |
| 到期后说明行 | 不显示 | **显示** | 不显示 |
| 主按钮文案 | 管理订阅 | **重新开启自动续费** | 管理订阅 |
| 主按钮动作 | `manageSubscriptionsSheet` | 同左（不变） | 同左 |
| 底部 `legalText` | **不显示** | **不显示** | **不显示** |
| 隐私/条款链接、恢复购买 | 保留 | 保留 | 保留 |
| 被拒订阅警示行 | 不变 | 不变 | 不变 |

### 2.2 逐项改法

**A. 去掉已订阅分支的 `legalText`**

`legalBlock` 被两个分支共用。给它加参数（如 `legalBlock(showsPriceDisclosure: Bool)`），
已订阅分支传 `false`、未订阅分支传 `true`；或已订阅分支直接写 `VStack { legalLinks; restoreButton }`。
**未订阅分支行为必须一字不变。**

**B. 标题**

`PaywallView.body` 的 `.navigationTitle`：`entitlement.isPro && successEvent == nil` 时用新 key
`paywall.title.subscribed`，否则沿用 `paywall.title`。条件必须与 `PaywallContent` 的分支条件一致——
成功窗口内页面还停在购买 UI，标题也要留在「升级」。

| key | en | ja | zh-Hans |
|---|---|---|---|
| `paywall.title.subscribed` | VoiceTodo Pro | VoiceTodo Pro | VoiceTodo Pro |

**C. 日期行（仅 `willAutoRenew == false`）**

按**日历天**算剩余天数（`Calendar.current`，比较 `startOfDay(now)` 与 `startOfDay(expiration)`，不要用秒数除 86400）：

- `days <= 0` → `paywall.subscribed.expires_today_no_renew`
- `days == 1` → `paywall.subscribed.expires_tomorrow_no_renew`
- `2...7` → `paywall.subscribed.expires_in_days_no_renew %lld`
- `> 7` → 现有 `paywall.subscribed.expires_no_renew %@`（不变）

前三种文字颜色用 `WarmTheme.warningText`（可读的警示色；不要用 `WarmTheme.warning`，那是填充色，白底上对比度不够），其余维持 `textSecondary`。

| key | en | ja | zh-Hans |
|---|---|---|---|
| `paywall.subscribed.expires_today_no_renew` | Expires today. Won’t auto-renew. | 本日で期限切れ。自動更新されません | 今天到期，到期后不再续费 |
| `paywall.subscribed.expires_tomorrow_no_renew` | Expires tomorrow. Won’t auto-renew. | 明日で期限切れ。自動更新されません | 明天到期，到期后不再续费 |
| `paywall.subscribed.expires_in_days_no_renew %lld` | Expires in %lld days. Won’t auto-renew. | あと%lld日で期限切れ。自動更新されません | %lld 天后到期，到期后不再续费 |

（`%lld` 只会取 2…7，英文 days 恒为复数，不需要 plural variations。）

剩余天数的计算抽成**纯函数**并注入 `now` / `calendar`，便于单测，例如：

```swift
/// 到期日距今的日历天数(今天 = 0,已过 = 负数)。
static func calendarDaysUntil(_ date: Date, now: Date, calendar: Calendar) -> Int
```

**D. 到期后说明行（仅 `willAutoRenew == false`）**

放在 `subscribedStatusCard` 内、日期行下方；12pt、`textMuted`、居中，`lineLimit(2)` + `minimumScaleFactor(0.85)`。
数字取 `NetworkConfig.freeDailyLimit`，**不要写死 3**。

| key | en | ja | zh-Hans |
|---|---|---|---|
| `paywall.subscribed.after_expiry_free %lld` | After that, you’ll be on Free: %lld per day. | 期限後は無料版(1日%lld回)に戻ります | 到期后回到免费版：每天 %lld 次 |

卡片是 `.accessibilityElement(children: .combine)`，新行会自动并入朗读，无需额外处理。

**E. 主按钮文案（仅 `willAutoRenew == false`）**

`manageSubscriptionButton` 的 label 换 key，动作、`accessibilityIdentifier("PaywallManageSubscriptionButton")`、
关闭后 `refreshEntitlements()` 全部不变。

| key | en | ja | zh-Hans |
|---|---|---|---|
| `paywall.manage_subscription.turn_on_renew` | Turn On Auto-Renew | 自動更新をオンにする | 重新开启自动续费 |

用户在系统页重新开启后，关闭时已有的 `refreshEntitlements()` → `refreshWillAutoRenew` 会把状态翻回 `true`，
按钮、日期行、说明行随之恢复，无需额外处理。

### 2.3 测试

- **单测**（`VoiceTodoTests/`，沿用现有形态）：`calendarDaysUntil` 覆盖
  今天稍后 = 0、明天凌晨 00:01 = 1（即使不足 24 小时）、7 天 = 7、8 天 = 8、已过 = 负数、跨月、跨夏令时（用 `America/New_York` 时区的 calendar）。
- **现有用例**：`npm test` 不涉及；Swift 单测全量跑一遍，`ScenarioTests` `test_S20_trialPurchase_onboardingMustNotReappear` 末尾的已订阅卡断言（`PaywallSubscribedCard`、无 `PaywallPurchaseButton`）必须仍通过；S18 一屏哨兵不得变红。
- 新增 xcstrings key 三语齐全，无 `needs_review` / 空值。

---

## 3. 验收（实施方自检后交回 review）

真机或沙盒，分别截图：

1. **续费中（年付）**：标题「VoiceTodo Pro」；日期行「下次续费 X」；**底部无「¥…/year, auto-renews」**；主按钮「管理订阅」；无到期后说明行。
2. **续费中（月付）**：同上，且底部同样无年付价格（这是 §1.1 的隐藏 bug，重点看）。
3. **已关续费，>7 天到期**：日期行「有效期至 X，到期后不再续费」（原色）；说明行「到期后回到免费版：每天 3 次」；主按钮「重新开启自动续费」。
   - 沙盒加速续费下很难造出 >7 天，可用 Xcode StoreKit 本地配置 + Transaction Manager 调整，或以单测覆盖代替。
4. **已关续费，今天到期**（沙盒即可复现，就是本次截图场景）：日期行「今天到期，到期后不再续费」（警示色）；其余同 3。
5. **重新开启**：在 4 的状态点主按钮 → 系统页重新开启续费 → 关闭后页面回到 1 的样子。
6. **未订阅**：购买 UI 与改动前完全一致（含底部价格披露），标题仍「升级 VoiceTodo Pro」。
7. **购买成功窗口**：点购买成功后约 1 秒内标题仍是「升级 VoiceTodo Pro」，CTA 变绿后收起——不得闪成已订阅页。
8. 三语（zh-Hans / en / ja）各看一遍 4，SE 尺寸 + 最大动态字号下无截断省略号。
