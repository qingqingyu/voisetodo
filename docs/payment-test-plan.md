# VoiceTodo 付费（订阅）测试方案

> 2026-08-30 建立。提测前端前付费链路的完整测试方案，供 QA 直接执行。
> 口径基线：free = 3/天（2026-08-30 客户端与代理已同步切 3），Pro = 100/天。

## 0. 付费体系与口径速查（QA 必读）

```
购买: PaywallView → EntitlementManager.purchase() → StoreKit 2
       ↓ verified 交易 → finish + refreshEntitlements → isPro=true + jwsString
鉴权: jwsString → NetworkClient 请求头 X-Subscription-JWS → AIProxy
       ↓ verifySubscriptionJWS(签名/root锚/bundleID/productID/过期)
       ↓ 任一失败 → fail-safe 按免费档
额度: 代理按 X-Device-ID 计数，响应 X-Quota-Plan/Limit/Used/Remaining 头
       → QuotaUsage（UI 权威数据源；无头时回退客户端本地估算）
```

| 项 | 值 | 出处 |
|---|---|---|
| 月付 | `com.qingqingyu.voicetodo.pro.monthly` $4.99 | Products.storekit |
| 年付 | `com.qingqingyu.voicetodo.pro.yearly` $39.99（省~33%） | Products.storekit |
| 免费试用 | 7 天，月/年都配，同订阅组 "Pro" | Products.storekit |
| 免费额度 | 3/天（客户端后备与代理 DAILY_REQUEST_LIMIT 均为 3） | Constants.swift / wrangler.toml |
| Pro 额度 | 100/天（有限，UI 禁止宣称"无限"） | Constants.swift:proDailyLimit |
| 产品 ID | 三处必须逐字一致：EntitlementManager / Products.storekit / ASC | ProductsStorekitGuardTests 守卫 |

## 1. 测试环境三层——以及最容易踩的大坑

| 层 | 搭法 | 能测 | 不能测 |
|---|---|---|---|
| L1 本地 StoreKit | scheme 已挂 Products.storekit，debug 真机跑 | 购买全流程、失败/AskToBuy/加速续订（配置开关） | **验签链路** |
| L2 沙盒 | 真机 + 沙盒账号 | 端到端含代理验签、续订/取消/试用资格 | 退款 |
| L3 TestFlight | TF 构建 | 最终验收 | 可控性差，仅抽查 |

**大坑**：本地 Xcode StoreKit Configuration 的交易是 Xcode 测试签发链签的 JWS，
AIProxy 的 root 指纹锚定**验不过 → fail-safe 免费档**。所以 L1 买成功后打代理，
额度仍是免费档——这不是 bug 是机制。"购买 → 立即升 Pro 额度"的端到端只能在
L2 沙盒验。DEBUG `setEntitlementForTesting` 注入的 isPro 也只影响客户端 UI。

### 沙盒环境搭建

1. ASC → 用户和访问 → 沙盒 → 测试员（+）：邮箱用**从未注册过 Apple ID** 的邮箱
2. 真机（iOS 26）：设置 → App Store → 沙盒账户 → 登录
3. 清购买历史（测"新用户试用资格"必用）：同一页面 → 清除购买历史
4. 取消订阅：沙盒购买弹窗 → 订阅管理页
5. 沙盒续订加速（Apple 官方时间表）：月付 ≈ 5 分钟一续 ×12 次后转 1 小时；年付 ≈ 1 小时级

### L1 可玩开关（Products.storekit 底部 Editor 设置）

`_failTransactionsEnabled`（购买失败）、`_askToBuyEnabled`（Ask to Buy）、
`_timeRate`（加速时间流）、`_storeKitErrors`（指定错误注入）。

## 2. 已有自动化守卫（提测前跑一遍，勿人肉重测）

```bash
# iOS 侧（Rosetta 环境必须 arch -arm64 前缀）
arch -arm64 xcodebuild test -project VoiceTodo.xcodeproj -scheme VoiceTodo \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /tmp/vt-derive \
  -only-testing:VoiceTodoTests/ProductsStorekitGuardTests \
  -only-testing:VoiceTodoTests/Protocols/QuotaUsageTests \
  -only-testing:VoiceTodoTests/AppCoordinatorTests

# 代理侧
cd AIProxy && npm test
```

已覆盖：productID 三处一致、paymentMode 拼写、bundle/productID 交叉校验、
JWS 签名/过期/锚定/伪造拒绝、429→paywall 路径、quotaExhaustedPro 文案。

## 3. 测试用例

### A 组：Paywall 曝光入口（4 入口 + 埋点 source）

| # | 前置 | 步骤 | 预期 | 层 |
|---|---|---|---|---|
| A1 | 新装+完成 onboarding | 引导下创建第一条待办 | paywall 弹出，`paywall_source=first_wow` | L1 |
| A2 | 新装 | 累计 5 次录音成功 | 第 5 次成功后弹，`source=recording_count` | L1 |
| A3 | 免费额度用尽 | 再录一条 | 弹，`source=quota_exhausted`；免费用户文案含"免费额度" | L2 |
| A4 | 任意状态 | 设置页点「升级 Pro」 | 弹，`source=manual` | L1 |
| A5 | 断网 | 打开 paywall | 首帧 spinner（.loading 语义），失败显示错误卡+重试，不闪现"加载失败"再变加载中 | L1 |

### B 组：购买主流程

| # | 步骤 | 预期 | 层 |
|---|---|---|---|
| B1 | 新用户 → paywall | 有 7 天试用文案；资格查询完成前 CTA 只显示 spinner 不先渲染文案 | L1/L2 |
| B2 | 购买月付 → Face ID → 成功 | sheet 自动收起 + 全局成功 toast（purchaseSuccessCount 信号） | L1/L2 |
| B3 | B2 后立即录音一次 | `X-Quota-Plan=pro, Limit=100`；额度 UI 显示已用/100 | **仅 L2** |
| B4 | 购买年付 | 同 B2/B3；$39.99、省 33% 文案正确 | L2 |
| B5 | 连点 CTA | 不产生重复订单（isPurchasing 守卫） | L1 |
| B6 | 价格/币种 | 与 ASC 逐字一致；切商店区域后价格本地化 | L2 |

### C 组：购买异常路径（L1 开关驱动）

| # | 操作 | 预期 | 层 |
|---|---|---|---|
| C1 | 系统弹窗点取消 | 静默返回，无错误 toast | L1 |
| C2 | `_failTransactionsEnabled=true` | 显示购买失败错误，可重试 | L1 |
| C3 | `_askToBuyEnabled=true` | "等待批准"提示；批准后 Transaction.updates 自动到账 → isPro=true | L1 |
| C4 | unverified（难人为触发） | 显示验签失败错误、不显示成功、不 finish；日志 `entitlement.purchase_unverified` | 代码走查+日志 |
| C5 | 系统弹窗期间断网 | 恢复后要么到账要么明确失败，不许无反馈挂死 | L1 |

### D 组：恢复购买（审核必需入口）

| # | 前置 | 步骤 | 预期 | 层 |
|---|---|---|---|---|
| D1 | 已购后卸载重装 | 点恢复购买 | isPro=true，额度 UI 转 pro | L2 |
| D2 | 从未购买/已退款 | 点恢复购买 | "无可恢复购买"错误 | L1/L2 |
| D3 | 未登录 Apple ID | 点恢复购买 | 走 AppStore.sync() 报错路径显示失败，不崩 | L1 |

### E 组：订阅生命周期（L2 沙盒专属，靠续订加速）

| # | 场景 | 预期 |
|---|---|---|
| E1 | 试用期最后一天 | 仍 pro/100 |
| E2 | 试用到期自动扣款 | 无感续期，isPro 不闪断 |
| E3 | 取消续订 → 到期 | isPro=false，额度回落；下一次超额弹 paywall，文案含"免费额度" |
| E4 | 老用户退订后重订 | isEligibleForIntroOffer=false → **试用文案必须消失**，CTA 变直接付费（审核硬伤，重点盯） |
| E5 | 已订阅用户额度耗尽（可借代理 inspect 接口拉满计数） | 文案为 quotaExhaustedPro——不含"免费"字样、说明转写已保留 |
| E6 | 月付↔年付切换 | 同组升降级生效，不双扣、无权益空窗 |
| E7 | 退款（沙盒不可测） | 风险移交 TF/线上：reportaproblem 验证 Transaction.updates 收到 revocation → isPro 回落 |

### F 组：代理验签 fail-safe（单测已覆盖，QA 抽查两点）

| # | 步骤 | 预期 |
|---|---|---|
| F1 | 沙盒订阅成功后抓包 | 请求头带 `X-Subscription-JWS`，代理回 `X-Quota-Plan=pro` |
| F2 | 订阅过期（沙盒到期不续） | 下次请求代理按 free 放行，UI 权威头显示 free——fail-safe 静默降级，不弹错误 |

### G 组：合规与文案（审核清单）

1. 法务链接可点：隐私政策（GitHub Pages）+ Apple 标准 EULA
2. 任何档位不得出现"无限"字样
3. 试用文案与实际资格严格一致（关联 E4）
4. 价格三处一致（ASC / storekit / 清单）——guard 测试守着
5. paywall 过 Dynamic Type 最小档→AX5 + RTL

## 4. 建议执行顺序

- **提测前自查**：§2 守卫全跑 → A/B/D 在 L1 过一遍
- **QA 主力**：L2 沙盒层 B3/B4/D1/E1-E6（唯一能验"钱→权益→额度"全链路）
- **TF 抽查**：G 组 + E7 风险移交

## 附：free 2→3 切换记录

- 2026-08-22 拍板（PROMOTION_PLAN §2.1，随定价决策），文案/Terms/Review Notes 按 3 口径
- 2026-08-30 执行：wrangler.toml（DAILY_REQUEST_LIMIT=3）deploy 上线；客户端
  `Constants.swift freeDailyLimit` 2→3（本地离线估算后备同步口径）
