# 结果:付费页改版 v3 任务书执行回执

> 分支 `paywall-v3-redesign`,基于 `main` @ `2a0ecdc` 起步(任务书对照基线 `9ff7e31`,
> 期间 main 新增的入口卡 × 收口提交 `b805283`/`2a0ecdc` 与付费页无交集)。
> 执行环境:macOS,Xcode 26,`xcodegen` 生成工程后模拟器编译/测试。

## 1. 改动摘要

| 文件 | 改动 |
|---|---|
| `UI/Shared/DesignSystem.swift` | `WarmTheme` 新增 `ctaFill`(D4613C)与 `primaryTint`(light FCE9E2 / dark 493835) |
| `UI/Paywall/PaywallView.swift` | 整页重排:去 `NavigationStack` 改自绘页头(标题+圆形 ×);未订阅分支改「中间滚动(额度条/大标题/权益卡)+ 底部购买区固定(`safeAreaInset`:方案卡/CTA/错误提示/续费说明/链接行/小字)」;`ProductCard` → `PlanCard`(单选圈+角标+右对齐价格);「省 X%」Decimal 实时计算向下取整;额度条五态状态机;已订阅分支内容不变,换页头与底部链接行;`PaywallContentFits` 改测中间滚动区、值格式不变 |
| `Resources/Localizable.xcstrings` | 新增 16 key(三语)/ 修改 4 key 的指定语言 / 删除 14 key(删前全仓库 grep 零引用,见 §2) |
| `VoiceTodoUITests/ScenarioTests.swift` | S18:paywall 判定加 `PaywallHeaderTitle`、Step 6 改新口径(按钮 `isHittable` + 续费说明 frame 在窗口内;`ContentFits` 只记录);S20:两处 `navigationBars` → `PaywallHeaderTitle` |

购买/恢复/权益判断逻辑(`EntitlementManager`)、StoreKit 配置、商品 ID、弹出时机、
成功反馈流程、已订阅状态卡与管理订阅按钮均未动。

## 2. key 变更清单

**新增 16**(zh/en/ja 全部按任务书 §4.1 原文):`paywall.quota.exhausted`、
`paywall.quota.used`、`paywall.hero.title`、`paywall.benefits.heading %@`、
`paywall.benefits.count %lld`、`paywall.benefits.free_note %lld`、`paywall.benefits.voice`、
`paywall.benefits.dates`、`paywall.plan.yearly`、`paywall.plan.monthly`、
`paywall.plan.monthly_note`、`paywall.plan.save %@`、`paywall.period.year_short`、
`paywall.period.month_short`、`paywall.cta.subscribe_yearly`、`paywall.cta.subscribe_monthly`。

**修改 9 语言项**:`paywall.legal.price_autorenew`(zh/ja,英文保持原值)、
`paywall.legal.trial_then_price`(zh/ja,英文保持原值)、`paywall.footer.indie`(zh/en/ja)、
`paywall.legal.privacy_link`(en=Privacy)、`paywall.legal.terms_link`(en=Terms)。

**删除 14**:`paywall.value.capture.title`、`paywall.value.capture.desc`、
`paywall.comparison.voice_prefix %@`、`paywall.comparison.free`、`paywall.comparison.pro`、
`paywall.comparison.limit_per_day %lld`、`paywall.comparison.per_day`、`paywall.yearly`、
`paywall.yearly_save`、`paywall.legal.cancel_path`、`paywall.card.trial_included %@`、
`paywall.cta.subscribe`、`onboarding.pro.bullet.trial.title %@`、`onboarding.pro.bullet.trial.desc`。
删除前逐 key 全仓库(含测试)`grep` 均为 0 引用(onboarding 引导页不引用试用卡 key,
仅旧付费页 `valuePropsList` 在用,已随改版移除)。

编辑方式:Python 序列化器逐字节复现 Xcode 格式(改动前 round-trip 校验通过),
新 key 插入位置经 Swift `localizedStandardCompare` 定位(与 451e6d5 收敛序一致),
写回后 `json.loads` 校验合法。

## 3. 新增颜色最终值

| 颜色 | light | dark | 说明 |
|---|---|---|---|
| `ctaFill` | `#D4613C`(不分档) | 同左 | 购买按钮/选中描边/单选圈;白字对比度 ≈3.8:1 |
| `primaryTint` | `#FCE9E2` | `#493835` | 权益图标块、「省 X%」角标底;dark 按 primary 16% 叠深色卡推得,待 §4.g 深色截图确认 |

## 4. §9.2 截图矩阵 —— 待 GUI 执行

S18/S20 GUI 跑法与 7 组截图(a–g)依赖 **Xcode GUI 挂 `VoiceTodo/Products.storekit`**:
命令行 `xcodebuild test` 不注入 StoreKit 配置(既有结论),商品恒 empty,购买区与
试用状态无法呈现;无试用资格状态还需在 StoreKit 测试里先完成一次试用再过期。
以下留给真机/GUI 阶段逐项确认(清单即任务书 §9.2 原表):

| # | 状态 | 机型/语言 | 结果 |
|---|---|---|---|
| a | 额度用完+有试用 | iPhone 16 / SE 3 × zh、en、ja | ☐ |
| b | 额度用完+无试用 | iPhone 16 × zh | ☐ |
| c | 今日已用 1/3 | iPhone 16 × zh | ☐ |
| d | 今日未使用(无额度条) | iPhone 16 × zh | ☐ |
| e | 商品加载失败(断网) | iPhone SE 3 × zh | ☐ |
| f | 已订阅 | iPhone 16 × zh | ☐ |
| g | 深色,同 a | iPhone 16 × zh、en | ☐(primaryTint dark 值在此确认) |

iPhone 16 间距未缩放(首版按设计稿原值:大标题上方 28/权益卡上方 24/方案卡上下 16),
若 GUI 实测放不下再按 §9.2 降间距,最终取值届时回填此处。

## 5. S18 / S20 运行结果

| 项 | 环境 | 结果 |
|---|---|---|
| App+Widget 编译 | iPhone 17 Pro 模拟器,CLI | **BUILD SUCCEEDED**,无新增警告 |
| 单元测试 | `arch -arm64 swift test` | **361 例,唯一失败为已知 CN 时区 DST 基线红灯**(非回归,CLAUDE.md 记载) |
| S18(empty 态) | iPhone 17 Pro,CLI | `:590`「录音面板应该出现」失败——Step 3 的 FAB **坐标点击**未命中,发生在 paywall 之前;与本改动无关的既有红灯(ScenarioTests `tapRecordFABWithFallback` 注释:「S18 系在本机 iPhone 17 上因单一坐标点击命不中而既有红灯(HEAD 同样失败)」) |
| S18(empty 态) | iPhone SE 3,CLI | **passed(34.7s)**——新页头 `PaywallHeaderTitle` 判定生效,自绘页头/额度条/empty 态购买区(错误卡+链接行+小字)在 SE 视口渲染正常,Step 6 新口径断言通过 |
| S18(success 态) | Xcode GUI + StoreKit + SE 3 | **待 GUI 执行**(新断言:按钮 isHittable + 续费说明 frame 在窗口内) |
| S20 | Xcode GUI + StoreKit | **待 GUI 执行**(已无 StoreKit 环境,购买流程无法 CLI 覆盖) |

## 6. 偏离任务书的地方

1. **任务书对照基线为 `main @ 9ff7e31`,实际起步于 `main @ 2a0ecdc`**(期间合入入口卡
   × 收口两提交,与付费页文件无交集)。变更文件集与任务书 §0 表完全一致。
2. `WarmTheme.primaryTint` 之外**未新增其他颜色**;已订阅分支「管理订阅」按钮初版误换
   `ctaFill`,已按 §5.7「已订阅分支不变」恢复原 `primary` 样式。
3. 空字符串死键 `""`(值 `{}`,Xcode stale 标记残留)在排序脚本中以
   `omittingEmptySubsequences: false` 保留,未顺手删除(不在任务书范围)。
4. 其余无偏离;文案逐字照任务书,未改写。

## 7. 双 review 循环(2026-10-28,Three Check + code-review-expert 交替)

第 3 轮双零收敛(1 轮 2+2 → 2 轮 0+1 → 3 轮 0+0),累计 5 发现 / 5 修复,无冲突:

1. 免费用量徽章补「(估算)」注记(§5.2 口径,初版遗漏)+ 主文本 `.layoutPriority(1)`
   (CLAUDE.md 文本布局规则)
2. 「(估算)」注记两态重复 → 抽 `estimateNote` 共用
3. 底部链接块两分支重复 → 抽 `footerLinksContent` 共用(布局等价)
4. 三文件四处注释引用已删/改名符号(`comparisonCard`→`quotaBadge`、
   `ProductCard`→`PlanCard`)同步更新

修复后复验:App 编译零错误,`swift test` 361 例仅已知 DST 红灯。文案零改动。
