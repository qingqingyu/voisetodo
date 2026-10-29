# 结果:付费页中间文案替换(paywall-copy-v2)

> 执行分支 `claude/paywall-copy-v2-impl`,基线 `main` @ `9ad5c00`。
> 任务书:`docs/paywall-copy-v2-task.md`(66aa629)。执行日期 2026-10-26。

## 1. 改动摘要

| 文件 | 改动 |
|---|---|
| `UI/Paywall/PaywallView.swift` | 对比条(改动 A)、核心卡 + 试用卡(改动 B,含拍板偏移)、底部小字(改动 C) |
| `Resources/Localizable.xcstrings` | +4 key / −2 key(见 §2),经字节级复现器编辑,无 Xcode 重排噪音 |

- **对比条标签做法**:任务书 §2 第 2 条两种做法中选了 **prefix key 方案**
  (`paywall.comparison.voice_prefix %@` 包住「免费版 N 次/每天」整列,标点随语言走,代码不拼标点)。
- **降级方案**:未使用。HTML 近似预览估算三语 0.7× 缩放均贴线(zh ≈71%、ja ≈73%、en ≈77%),
  是否「明显难读」待 SE 模拟器三语截图人眼判定;若截断/难读,回退方式 = 去 `comparisonText`
  的 prefix 调用 + 删 voice_prefix key + 图标保留 `mic.circle`。
- **未改**:`liveUsageCard`(⚡ 保留)、已订阅状态卡、价格/StoreKit 配置、引导页、
  `ValuePropCard` 组件本体(onboarding 继续用原形态)。

## 2. key 增删

新增(均 en/ja/zh-Hans 三语 `translated`):

| key | en | zh-Hans | ja |
|---|---|---|---|
| `paywall.comparison.voice_prefix %@` | Voice captures: %@ | 语音录入：%@ | 音声入力：%@ |
| `paywall.value.capture.title` | Say what's on your mind. It's on your list. | 想到什么，说出来，就进了清单。 | 思いついたら、話すだけ。もうリストに。 |
| `paywall.value.capture.desc` | Capture tasks in seconds — no typing, no forms. VoiceTodo understands you and files each task under the right date. | 几秒钟记下任务，不用打字，不用填表。VoiceTodo 听得懂，会把每件事排到对的日期。 | 数秒でタスクを記録。キー入力もフォームも不要。VoiceTodo が内容を理解して、正しい日付に振り分けます。 |
| `paywall.footer.indie` | 🌱 Made with care by one indie developer. Thank you for your support. | 🌱 VoiceTodo 由一位独立开发者用心打磨，感谢你的支持。 | 🌱 VoiceTodo は個人開発者がひとりで丁寧に作っています。応援ありがとうございます。 |

删除:`onboarding.pro.bullet.support.title`、`onboarding.pro.bullet.support.desc`
(`grep -rn "onboarding.pro.bullet.support" --include=*.swift .` 无结果,已复核)。

## 3. S18 一屏验证

**未跑——需要 Xcode GUI + SE(第 3 代)+ scheme 挂 StoreKit 配置**,命令行
`xcodebuild test` 不注入 StoreKit(商品恒为空,测不到「试用卡 + 新卡 + 双商品卡 + CTA + 法务 + 小字」最坏情况)。

- 改前基线 `PaywallContentFits` 数值:无(本次未采集)。
- HTML 近似预览(`/tmp/paywall-copy-v2-preview.html`,375×667、视口 603pt)结论:
  三语新版均在一屏内,但 ja/en 余量极小(数十 pt 级),**以 GUI 实测为准**。
- 待办(GUI):S18 跑通 + 贴 `PaywallContentFits` 值;SE 三语未订阅截图(检查对比条缩放与
  无「…」)+ 已订阅截图(检查小字)。不通过则先只调间距,仍不过停下报告。

## 4. 回归

- `xcodebuild build`(iPhone Simulator 目标):**BUILD SUCCEEDED**。
- `arch -arm64 swift test`:349 tests,仅 `TodoDueDateShifterTests.testDSTSpringForward_fallsBackToMidnight`
  1 失败 —— CLAUDE.md 写明的已知基线红灯(CN 时区),非本次回归。
- 购买 / 恢复购买手动点验(StoreKit 本地配置):**待 GUI**(同 §3 限制)。

## 5. 偏离任务书的地方

1. **B 卡无 emoji、纯文字居中**(任务书 §1.1/§3 原定 🎙️ emoji 圆 + ValuePropCard):
   产品 2026-10-26 在 HTML 预览过程中拍板 —— 两卡文字块高度不一,emoji 圆垂直居中后彼此错位;
   去掉后与整页中轴对称节奏一致。改用 PaywallView 内新增的 `PaywallCopyCard`(容器视觉参数
   沿用 ValuePropCard compact 规格)。🌱 致谢职能按原计划移至底部小字(§1.2 文案不变)。
2. **试用卡(🎁)形态同步改**(任务书 §0 区块 3 原定「不改」):同一轮拍板,试用卡也去 emoji 圆、
   改 PaywallCopyCard 居中形态;文案 key(`onboarding.pro.bullet.trial.*`)与渲染条件(C 点防抖)不变。
3. 对比条标签:任务书允许的两种做法中选了 prefix key 方案(§1 已写明),非偏离。
