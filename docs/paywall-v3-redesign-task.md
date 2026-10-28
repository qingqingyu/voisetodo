# 任务书：付费页改版 v3——按新设计稿换排版和文案

> 2026-10-28 起草，代码对照基线 `main` @ `9ff7e31`（付费页文案 v2 已上线）。本文档是**交给执行者的任务书**。
> 设计稿：`docs/design/paywall-v3/zh.png`、`docs/design/paywall-v3/en.png`（产品给的 HTML 设计稿渲染图，画布 390×844pt）。
> 文案已由产品拍板，**执行者不得自行改写文案**；放不下、翻译有疑问，停下来在结果里报告。
> 完成后把结果写进 `docs/paywall-v3-redesign-results.md`（格式见 §10），交回审查。

---

## 0. 范围

这次替换**未订阅时**付费页的整页排版和文案，v2 的对比条、纯文字价值卡、试用卡都会被替换掉。

| 改 | 不改 |
|---|---|
| `UI/Paywall/PaywallView.swift`：页头、未订阅分支的全部区块、底部链接行 | 购买、恢复、权益判断逻辑（`EntitlementManager`） |
| `Resources/Localizable.xcstrings`：新增、修改、删除 key（§4） | StoreKit 配置、价格、商品 ID |
| `UI/Shared/DesignSystem.swift`：新增 2 个颜色（§3） | 付费页弹出时机（`AppCoordinator`）、sheet 形态 |
| `VoiceTodoUITests/ScenarioTests.swift`：S18、S20 适配新页头和新布局（§8） | 成功反馈流程（按钮变绿约 1 秒后收起 + 主界面 toast） |
| | 已订阅分支的内容和逻辑（只换页头和底部链接行，§5.7） |
| | `ValuePropCard`、引导页 |

---

## 1. 页面结构

```
┌─────────────────────────────────────┐
│ 页头（固定）：标题（左）     [ ✕ ]   │
├─────────────────────────────────────┤
│ 中间（可滚动）                        │
│   额度条（按状态显示，§5.2）           │
│   大标题                              │
│   权益卡                              │
├─────────────────────────────────────┤
│ 底部购买区（固定在底部）               │
│   年度方案卡（默认选中）               │
│   月度方案卡                           │
│   购买按钮                             │
│   [购买/恢复的错误提示]                │
│   续费说明                             │
│   恢复购买 · 隐私政策 · 使用条款        │
│   🍃 独立开发者小字                    │
└─────────────────────────────────────┘
```

**为什么底部购买区要固定**：把设计稿去掉固定高度后实测，内容自然高度中文 792pt、英文 768pt（390 宽）。
iPhone SE 上付费页的可用高度只有约 600～650pt，6.1 寸机型在 sheet 里也只有约 750pt。
所以这一版**不再要求整页一屏放下**，改成：**购买区（方案卡、按钮、续费说明、链接）在任何机型上都不用滚动就能看到**，
中间的额度条、大标题、权益卡在小屏上可以滚动。这是产品接受的取舍。

实现提示：

- 去掉现在的 `NavigationStack` 导航栏，页头自己画（标题 + 圆形关闭按钮），放在滚动区外面。
- 中间用 `ScrollView`，底部购买区用 `.safeAreaInset(edge: .bottom)` 挂在 ScrollView 上，背景用页面底色，避免滚动内容透出来。
- 设计稿底部留白 28pt 是画在 844 画布里的；真机有 Home 指示条安全区，购买区底部 padding 改为 12pt + 系统安全区。
- 仍然是 sheet，`AppCoordinator.presentPaywall` 和收起后的 toast 流程不动。

---

## 2. 视觉规格

字体：**全部用系统默认字体**（`.system(size:weight:)`，不带 `.rounded`），这是设计稿的选择。
字号保持固定（与现在的付费页一致，不跟随动态字体），但**任何文字都不能出现「…」截断**（项目规则）。

颜色列的名字是 `WarmTheme` 里的颜色（§3），**不要在视图里直接写十六进制值**，否则深色模式会坏。

| 区块 | 规格 |
|---|---|
| 页面 | 底色 `background`；左右边距 24pt |
| 页头 | 标题 20pt bold，字距 -0.2，`textPrimary`，左对齐；关闭按钮 44×44 圆形，底色 `cardBackground`，阴影 `shadowLight`（半径 3，y 1），图标 `xmark` 16pt bold，`ink` |
| 额度条 | 页头下方 20pt；胶囊形，底色 `cardBackground`，内边距 上下 8 / 左右 14，元素间距 8；图标 `bolt` 16pt，`primaryText`；文字 14pt `ink`；数字（如 3/3）14pt bold `textPrimary` |
| 大标题 | 上方 28pt；30pt heavy，行距约 +4pt（`.lineSpacing(4)`），字距 -0.3（英文 -0.5），`textPrimary`；按文案里的换行显示两行 |
| 权益卡 | 上方 24pt；底色 `cardBackground`，圆角 18，内边距 上 18 / 左右 18 / 下 20；卡内「标题组」与「列表」间距 16 |
| ├ 卡标题 | 16pt bold，`textPrimary`；其中次数（如「100 次」）用 `primaryText` 上色 |
| ├ 卡副标题 | 标题下 4pt；13pt `textSecondary` |
| └ 权益行 | 两行，行间距 12；左侧图标块 32×32，圆角 10，底色 `primaryTint`，图标 18pt `primaryText`（第 1 行 `mic`，第 2 行 `calendar`）；图标块与文字间距 12；文字 15pt regular `textPrimary` |
| 方案卡 | 两张卡间距 12；底色 `cardBackground`，圆角 16，内边距 上下 16 / 左右 18，元素间距 14；**两种状态都画 2pt 描边**：选中 = `ctaFill`，未选中 = `cardBackground`（看不见，但切换时尺寸不跳）；选中加阴影 `ctaFill` 14% 不透明度，半径 14，y 4 |
| ├ 单选圈 | 22pt；选中 = `ctaFill` 实心圆 + 中间 8pt 白点；未选中 = 2pt `textMuted` 圆环；不参与朗读 |
| ├ 方案名 | 17pt bold `textPrimary`；年度后面跟「省 X%」角标：12pt bold `primaryText`，底色 `primaryTint`，内边距 上下 3 / 左右 8，胶囊形，与方案名间距 8 |
| ├ 方案副标题 | 方案名下 3pt；13pt `textSecondary`（年度 =「约 ¥24.83/月」，月度 =「按月付费」） |
| └ 价格 | 右对齐；价格 22pt heavy `textPrimary` + 周期「/年」14pt `textSecondary` |
| 购买按钮 | 方案卡下 16pt；高 56，胶囊形，底色 `ctaFill`，文字 19pt bold 白色；阴影 `ctaFill` 28% 不透明度，半径 18，y 6 |
| 续费说明 | 按钮下 12pt；13pt `textSecondary`，居中，最多 3 行，不可截断 |
| 链接行 | 说明下 12pt；一行居中：恢复购买（13pt semibold `ink`）· 隐私政策 · 使用条款（13pt regular `ink`）；分隔点 `textMuted`，间距 10；**每个可点项的点击区域高度至少 36pt**（`WarmSize.secondaryHit`），视觉上仍是小字 |
| 小字 | 链接行下 10pt；`leaf` 图标 14pt `success` + 文字 12pt `textSecondary`，间距 6，居中 |

---

## 3. 颜色

在 `WarmTheme` 里新增 2 个颜色：

```swift
/// 付费页购买按钮、选中方案描边与单选圈。比 primary 深:白字对比度约 3.8:1(primary 只有约 2.3:1)。
static let ctaFill = Color(hex: "D4613C")
/// 付费页浅橙底:权益图标块、「省 X%」角标底色。
static let primaryTint = Color(light: "FCE9E2", dark: "493835")
```

设计稿颜色与 `WarmTheme` 的对应关系（深色模式靠这张表）：

| 设计稿 | 用途 | WarmTheme |
|---|---|---|
| `#F4F4F6` | 页面底色 | `background` |
| `#FFFFFF` | 卡片、方案卡、额度条、关闭按钮底色 | `cardBackground` |
| `#1C1C1E` | 主要文字 | `textPrimary` |
| `#3A3A3C` | 链接、恢复购买、额度条文字、关闭图标 | `ink` |
| `#6B7280` | 次要文字（副标题、说明、小字） | `textSecondary` |
| `#C7C7CC` | 未选中单选圈、分隔点 | `textMuted` |
| `#D4613C` | 按钮、选中描边、单选圈 | `ctaFill`（新） |
| `#C2502F` / `#B24524` | 强调文字（次数、角标字、图标） | `primaryText` |
| `#FCE9E2` | 浅橙底 | `primaryTint`（新） |
| `#5A8F5E` | 叶子图标 | `success` |

`primaryTint` 的深色值 `#493835` 是按「primary 16% 叠在深色卡片上」算的；深色模式截图看着不对可以微调，在结果里写明最终值。

---

## 4. 文案（三语）

数字、价格**一律不写死**：次数取常量和额度数据，价格取 StoreKit（§5）。下表 `%@` / `%lld` 是占位符。

### 4.1 新增

| key | 简体中文 | English | 日本語 |
|---|---|---|---|
| `paywall.quota.exhausted` | 今日免费次数已用完 | Free captures used today | 今日の無料回数を使い切りました |
| `paywall.quota.used` | 今日免费次数已用 | Free captures used today | 今日の無料利用 |
| `paywall.hero.title` | 想到就说，\n说完就进清单。 | Say it.\nIt's on your list. | 思いついたら、話すだけ。\nもうリストに。 |
| `paywall.benefits.heading %@` | 升级 Pro，每天 %@都能这样用 | With Pro, do this %@ a day | Pro なら1日%@、こうして使えます |
| `paywall.benefits.count %lld` | %lld 次 | %lld times | %lld回 |
| `paywall.benefits.free_note %lld` | 免费版每天 %lld 次 | Free plan: %lld a day | 無料版は1日%lld回 |
| `paywall.benefits.voice` | 张口就记，不用打字，不用填表 | Just speak. No typing, no forms. | 話すだけで記録。入力もフォームも不要 |
| `paywall.benefits.dates` | “月中”“下周五”也能排到对的日期 | Puts “next Friday” on the right day | 「月半ば」「来週の金曜」も正しい日付に |
| `paywall.plan.yearly` | 年度 | Yearly | 年額プラン |
| `paywall.plan.monthly` | 月度 | Monthly | 月額プラン |
| `paywall.plan.monthly_note` | 按月付费 | Billed monthly | 毎月のお支払い |
| `paywall.plan.save %@` | 省 %@ | Save %@ | %@お得 |
| `paywall.period.year_short` | 年 | yr | 年 |
| `paywall.period.month_short` | 月 | mo | 月 |
| `paywall.cta.subscribe_yearly` | 订阅年度 Pro | Subscribe to Pro Yearly | Pro 年額プランを購読 |
| `paywall.cta.subscribe_monthly` | 订阅月度 Pro | Subscribe to Pro Monthly | Pro 月額プランを購読 |

说明：

- `\n` 是大标题里的换行，按设计稿断成两行。
- `paywall.benefits.heading` 整句本地化，`%@` 填 `paywall.benefits.count` 的结果；给「100 次」上色时用 `AttributedString` 找到这一段改颜色，**不要在代码里拼语序**（日文语序不同）。
- `paywall.plan.save %@` 的 `%@` 填本地化好的百分比（§5.1）。

### 4.2 修改（只改下表列出的语言，其余语言保持原值）

| key | 语言 | 新值 |
|---|---|---|
| `paywall.legal.price_autorenew` | zh-Hans | %1$@/%2$@，自动续费，可随时在系统设置中取消 |
| | ja | %1$@/%2$@、自動更新されます。「設定」からいつでもキャンセルできます。 |
| `paywall.legal.trial_then_price` | zh-Hans | 免费试用 %1$@，之后按 %2$@/%3$@ 自动续费，可随时在系统设置中取消 |
| | ja | %1$@の無料体験後、%2$@/%3$@で自動更新されます。「設定」からいつでもキャンセルできます。 |
| `paywall.footer.indie` | zh-Hans | 由一位独立开发者用心打磨，感谢支持 |
| | en | Made with care by one indie developer. Thank you. |
| | ja | 個人開発者が心を込めて作っています。応援ありがとうございます。 |
| `paywall.legal.privacy_link` | en | Privacy |
| `paywall.legal.terms_link` | en | Terms |

- `paywall.footer.indie` 去掉了开头的 🌱，叶子改用代码画的 `leaf` 图标。
- 英文链接按设计稿缩短，保证「Restore Purchases · Privacy · Terms」在 SE 上一行放得下。链接地址不变。
- 续费说明合成一行（设计稿如此），原来单独一行的「在 设置 → Apple ID → 订阅 中取消」不再显示。

### 4.3 删除

下列 key 改版后不再使用。**每个删之前在整个仓库（含测试）grep 一遍**，确认无引用再删：

`paywall.value.capture.title`、`paywall.value.capture.desc`、`paywall.comparison.voice_prefix %@`、
`paywall.comparison.free`、`paywall.comparison.pro`、`paywall.comparison.limit_per_day %lld`、`paywall.comparison.per_day`、
`paywall.yearly`、`paywall.yearly_save`、`paywall.legal.cancel_path`、`paywall.card.trial_included %@`、
`paywall.cta.subscribe`、`onboarding.pro.bullet.trial.title %@`、`onboarding.pro.bullet.trial.desc`。

### 4.4 继续沿用（不改）

`paywall.title`、`paywall.title.subscribed`、`paywall.close`、`paywall.cta.start_trial %@`、`paywall.yearly_per_month %@`、
`paywall.period.year`、`paywall.period.month`、`paywall.restore`、`paywall.products_empty.*`、
`quota.today_used`、`quota.error`、`quota.non_authoritative`，以及已订阅分支用到的全部 key。

---

## 5. 动态数据与状态（设计稿只画了一种状态，下面这些必须实现）

### 5.1 价格、折合月价、「省 X%」

- 价格一律用 StoreKit 的 `product.displayPrice`；周期单位用新的短单位（`paywall.period.year_short` / `month_short`）。
- 年度副标题「约 ¥24.83/月」：沿用现有 `ProductCard.monthlyEquivalentPrice` 的算法（`priceFormatStyle.format(price / 12)`）+ `paywall.yearly_per_month %@`。
- 「省 X%」**按当前店面实时算，向下取整**，不要写死：
  - 省的比例 = 1 −（年付价 ÷（月付价 × 12）），用 `Decimal` 算，乘 100 后**向下取整**成整数；
  - 再用 `.percent` 格式化成本地化的百分比文字（如「34%」），填进 `paywall.plan.save %@`；
  - 找不到月付商品，或算出来 ≤ 0，就不显示角标。
  - 为什么向下取整：人民币价 ¥298 vs ¥38×12 是 34.6%，四舍五入成 35% 就夸大了；美区 $39.99 vs $4.99×12 是 33.2%。
    向下取整后人民币显示「省 34%」，美区显示「省 33%」，都不会夸大。**设计稿上的「省 35%」不照抄。**
- 方案名用 `paywall.plan.yearly` / `paywall.plan.monthly`（按商品 ID 区分，同 `paywallPeriodUnit` 的判断），不再显示 StoreKit 的 `displayName` 和 `description`。
- 年度在上、默认选中（沿用 `defaultProductID` 和 `displayOrderedProducts`）。

### 5.2 额度条

按下表决定显示什么。次数取 `quotaUsage`（与现在的 `comparisonCard` 同一数据源）。

| 状态 | 显示 |
|---|---|
| 额度读取失败（`quotaUsage.loadState == .error`） | 沿用现有 `quotaErrorPill` 的内容，套新的胶囊样式 |
| 成功窗口内，或已是 Pro（`successEvent != nil` / `quotaUsage.isPro` / `entitlement.isPro`） | 沿用现有 `quota.today_used`（「今日已用 3/100」）和数字滚动动画 |
| 免费，已用 ≥ 上限 | `paywall.quota.exhausted` + 加粗「3/3」 |
| 免费，0 < 已用 < 上限 | `paywall.quota.used` + 加粗「1/3」 |
| 免费，已用 = 0 | **不显示**额度条（权益卡里已经写了「免费版每天 3 次」） |

- 数字部分用 `Text(verbatim: "\(used)/\(limit)")`；不是权威数据时（`!quotaUsage.isAuthoritative`），后面照旧跟「（估算）」小字。
- 整条合并成一个朗读元素。

### 5.3 权益卡里的次数

- 「每天 100 次」取 `NetworkConfig.proDailyLimit`。
- 「免费版每天 3 次」取 `NetworkConfig.freeDailyLimit`（不用 `quotaUsage.limit`：成功窗口内它会变成 Pro 上限，副标题会变成「免费版每天 100 次」）。

### 5.4 免费试用（设计稿没画，两款商品都配了 7 天免费试用，大多数新用户会落在这个状态）

| | 有试用资格 | 没有试用资格 |
|---|---|---|
| 购买按钮 | 「开始 7 天免费试用」（沿用 `paywall.cta.start_trial %@`，时长取 StoreKit） | 「订阅年度 Pro」/「订阅月度 Pro」，随选中方案变 |
| 续费说明 | `paywall.legal.trial_then_price`：「免费试用 7 天，之后按 ¥298/年 自动续费……」 | `paywall.legal.price_autorenew`：「¥298/年，自动续费……」 |

- 资格查询中：按钮显示转圈、续费说明暂不显示（沿用现有防抖逻辑，即 C 点）。
- 原来单独的试用卡、方案卡里的「含 7 天免费试用」小字都**去掉**，试用信息只放在按钮和续费说明里。这样两种状态下方案卡高度一致，页面不跳。
- 续费说明里的价格跟随选中的方案变（沿用 `legalPriceLine`）。这是审核 3.1.2 要求的：试用多久、之后收多少钱，必须在购买按钮附近写清楚。

### 5.5 商品加载

- 加载中：购买区放一个占位，高度约等于两张方案卡（约 170pt），中间转圈，避免加载完页面跳动。
- 加载失败（`.empty` / `.error`）：沿用现有的 `stateMessage`（图标 + 说明 + 重试按钮，`PaywallRetryButton`），放在方案卡的位置；按钮和续费说明不显示；**链接行和小字照常显示**（审核 3.1.2：商品加载失败时隐私、条款链接也必须能点）。

### 5.6 购买中、成功、出错（沿用现有逻辑，只换样式）

- 购买中：两张方案卡禁用并半透明，按钮显示转圈。
- 成功窗口：按钮原地变绿（`WarmTheme.success`）+ 对勾 +「已升级为 Pro / 已恢复 Pro」，保持 `PaywallPurchaseButton` 标识和 `accessibilityValue("success")`；方案卡禁用；约 1 秒后收起。页头标题在成功窗口内保持「升级 VoiceTodo Pro」（沿用 `navigationTitleKey` 的判断）。
- 出错：沿用 `inlineErrorText`，放在购买按钮下面、续费说明上面。
- 恢复购买进行中：链接行里的「恢复购买」换成转圈 +「正在恢复…」，购买按钮禁用（沿用）。

### 5.7 已订阅分支

- 页头：同一个新页头，标题「VoiceTodo Pro」。
- 中间内容、状态卡、管理订阅按钮、各种提示：**全部不变**，放在滚动区里，不需要固定底部区。
- 底部：用新的链接行（恢复购买 · 隐私政策 · 使用条款）+ 小字，和未订阅分支保持一致；不显示续费说明（沿用现在的规则）。

### 5.8 深色模式

设计稿只画了浅色。按 §3 的颜色对应关系实现，深色模式下截图验收（§9）。

---

## 6. 无障碍

- 关闭按钮的朗读名称仍是 `paywall.close`（「关闭」）。UI 测试靠这个名字找按钮。
- 页头标题加 `.isHeader`，并加标识 `PaywallHeaderTitle`（§8 的测试要用）。
- 大标题加 `.isHeader`。
- 方案卡：整卡合并成一个朗读元素，选中时带 `.isSelected`；单选圈不朗读。朗读内容包含方案名、「省 X%」、副标题、价格和周期。
- 权益行的图标不朗读。

---

## 7. 保留的测试标识

`PaywallPurchaseButton`、`PaywallRetryButton`、`PaywallSubscribedCard`、`PaywallInlineError`、
`PaywallManageSubscriptionButton`、`PaywallSubscriptionRejectedHint` 都保留在对应的元素上。

`PaywallContentFits`（DEBUG 钩子）保留，但改为测量**中间滚动区**能不能一屏装下，值的格式不变
（`1|content=…|viewport=…|state=…`），放在中间滚动内容的末尾。

---

## 8. UI 测试适配（`VoiceTodoUITests/ScenarioTests.swift`）

改 UI 必须同步改这两处，**不允许跳过或删掉测试**：

1. **S20**（约 `:910`）：现在用 `navigationBars["升级 VoiceTodo Pro"]` 判断付费页弹出。导航栏去掉后找不到了，
   改成找 `PaywallHeaderTitle` 标识（按任意元素类型匹配，参考同文件 `PaywallSubscribedCard` 的写法）。
2. **S18**（约 `:626` 和 `:657` 起的 Step 6）：
   - 判断付费页弹出的地方同样补上 `PaywallHeaderTitle`（现有的「关闭」按钮判断保留）。
   - Step 6 原来断言「整页一屏放下」（`PaywallContentFits` 以 `1` 开头）。按 §1 的新要求改为断言：
     `PaywallPurchaseButton` 存在且可点（`isHittable`），并且续费说明（含「自动续费」）的整个 frame 在窗口内。
     `PaywallContentFits` 的值只截图记录，不再断言为 1。
   - 测试里的注释同步改成新的口径。

---

## 9. 验收

### 9.1 编译和测试

- App 和小组件两个 target 编译通过，没有新增警告。
- `VoiceTodoTests` 全部通过（已知的 CN 时区红灯除外，写明）。
- 在 **Xcode GUI**、scheme 挂 `VoiceTodo/Products.storekit` 的情况下跑通 S18（iPhone SE 第 3 代）和 S20。
  命令行 `xcodebuild test` 不注入 StoreKit 配置，商品恒为空，测不到购买区。

### 9.2 截图矩阵（放进 `docs/screenshots/paywall-v3/`）

| # | 状态 | 机型 | 语言 |
|---|---|---|---|
| a | 额度用完 + 有试用资格 | iPhone 16（6.1 寸）、iPhone SE 3 | zh、en、ja |
| b | 额度用完 + 无试用资格 | iPhone 16 | zh |
| c | 今日已用 1/3 | iPhone 16 | zh |
| d | 今日未使用（不显示额度条） | iPhone 16 | zh |
| e | 商品加载失败（断网） | iPhone SE 3 | zh |
| f | 已订阅 | iPhone 16 | zh |
| g | 深色模式，状态同 a | iPhone 16 | zh、en |

无试用资格的状态：在 Xcode 的 StoreKit 测试里先完成一次试用订阅，再到「Manage Transactions」里让它过期，即可得到。

逐项确认：

- **iPhone 16**：状态 a 三种语言都**不用滚动**就能看到全部内容。放不下时先缩小纵向间距（大标题上方 28→20、权益卡上方 24→16、方案卡上下内边距 16→14），**不要缩字号**；在结果里写明最终取值。这样仍放不下就停下来，报告差多少 pt，交回产品决定。
- **iPhone SE 3**：方案卡、购买按钮、续费说明、链接行、小字**不用滚动就可见**；中间区域可以滚动。
- 任何地方都没有「…」截断（额度条、大标题、权益行、方案卡、按钮、续费说明、链接行、小字）。
- 本地 StoreKit 配置是 $4.99/月、$39.99/年，应显示「省 33%」「约 $3.33/月」。人民币价（应显示「省 34%」「约 ¥24.83/月」）在 TestFlight 上确认，写进结果。
- 深色模式下文字、按钮、浅橙底都清晰可读。

### 9.3 回归（StoreKit 本地配置，手动点一遍）

- 切换年度/月度：选中描边、按钮文案、续费说明价格跟着变，卡片尺寸不跳。
- 购买：系统购买弹窗 → 按钮变绿 → 约 1 秒后收起 → 主界面 toast。
- 恢复购买：有订阅时成功提示，无订阅时「未找到可恢复的订阅」。
- 隐私政策、使用条款链接能打开，地址与现在一致。
- 关闭按钮、下拉都能关掉付费页。

---

## 10. 结果格式（`docs/paywall-v3-redesign-results.md`）

1. 改动摘要：改了哪些文件，每处一句话。
2. 新增、修改、删除的 key 列表，删除前的 grep 结果。
3. 新增颜色的最终值（含深色）。
4. §9.2 的截图和逐项结论；iPhone 16 上如有调整间距，写明最终取值。
5. S18、S20 的运行结果。
6. 偏离任务书的地方及理由（没有就写「无」）。

---

## 11. 执行约束

- 从最新 `main` 拉新分支（名字自定），**不要直接在 main 上改**；提交、推送分支后交回审查，**不合 main**。
- 不改文案；不改价格、StoreKit 配置、购买和恢复逻辑。
- 提交信息里不要出现模型名称。
