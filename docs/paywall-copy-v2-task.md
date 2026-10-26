# 任务书：付费页中间文案替换（核心卡片 + 底部小字 + 额度条标签）

> 2026-10-26 起草，代码对照基线 `main` @ `9ad5c00`。本文档是**交给执行者的任务书**。
> 文案已由产品拍板，**执行者不得自行改写文案**；遇到放不下、翻译有疑问等情况，停下来在结果里报告。
> 完成后把结果写进 `docs/paywall-copy-v2-results.md`（格式见 §7），交回审查。

---

## 0. 范围一览

付费页（`UI/Paywall/PaywallView.swift`，未订阅分支）从上到下：

| # | 区块 | 本次动作 |
|---|---|---|
| 1 | 导航标题「升级 VoiceTodo Pro」 | **不改**（现有文案已一致） |
| 2 | 顶部额度对比条 | 加「语音录入」标签 + 图标换麦克风（§2） |
| 3 | 试用卡（🎁，有试用资格时才显示） | **不改** |
| 4 | 「🌱 支持独立开发」卡 | **替换**为新的核心卡片（§3） |
| 5 | 价格区域（商品卡、「省 33%」角标） | **不改**（§5 说明为什么不改成 34%） |
| 6 | 购买按钮「订阅 Pro」/「开始 7 天免费试用」 | **不改** |
| 7 | 续费说明 + 隐私·条款链接 | **不改**（App Store 审核要求） |
| 8 | 底部小字 | **新增**，放在「恢复购买」上方（§4） |

只改 `UI/Paywall/PaywallView.swift` 和 `Resources/Localizable.xcstrings`。
**不改**：价格、StoreKit 配置、引导页、已订阅状态卡的逻辑、任何业务代码。

---

## 1. 定稿文案（三语）

### 1.1 核心卡片

| 位置 | English | 简体中文 | 日本語 |
|---|---|---|---|
| 标题 | Say what's on your mind. It's on your list. | 想到什么，说出来，就进了清单。 | 思いついたら、話すだけ。もうリストに。 |
| 说明 | Capture tasks in seconds — no typing, no forms. VoiceTodo understands you and files each task under the right date. | 几秒钟记下任务，不用打字，不用填表。VoiceTodo 听得懂，会把每件事排到对的日期。 | 数秒でタスクを記録。キー入力もフォームも不要。VoiceTodo が内容を理解して、正しい日付に振り分けます。 |

- 说明是**一个字符串**，两句之间英文用一个空格、中日文不加空格，**不要插入换行符**（让它自然折行，省高度）。
- 英文里的破折号是 em dash `—`（U+2014），前后各一个空格。
- **不写每日次数**（产品决定，不补「Up to 100 a day」）。
- emoji 用 `🎙️`（原卡片的 `🌱` 挪给底部小字）。

### 1.2 底部小字

| English | 简体中文 | 日本語 |
|---|---|---|
| 🌱 Made with care by one indie developer. Thank you for your support. | 🌱 VoiceTodo 由一位独立开发者用心打磨，感谢你的支持。 | 🌱 VoiceTodo は個人開発者がひとりで丁寧に作っています。応援ありがとうございます。 |

### 1.3 额度对比条标签

| English | 简体中文 | 日本語 |
|---|---|---|
| Voice captures | 语音录入 | 音声入力 |

---

## 2. 改动 A：顶部额度对比条

现状（`freeVsProComparisonPill`，约 `PaywallView.swift:283`）：
`[⚡] 免费版 3 次 / 每天 › Pro 版 100 次 / 每天`，一行 14pt，`minimumScaleFactor(0.7)`。
注意：这条**只在免费用户当天用量为 0 时显示**；用过之后显示的是实时用量卡（`liveUsageCard`），本次不改实时用量卡。

改成：`[🎙] 语音录入：免费版 3 次 / 每天 › Pro 版 100 次 / 每天`

1. 图标 `bolt.circle` → `mic.circle`（**只改对比条这一处**；`liveUsageCard` 里的 `bolt.circle` 不动）。
2. 在第一列文本前加标签，新 key `paywall.comparison.voice_label`（文案见 §1.3）。
   标签与后面文字之间的标点按语言放进本地化值里还是代码里拼接，执行者自定，但必须三语都自然：
   中文用全角冒号「：」，英文用 `: `，日文用全角「：」。推荐做法：再加一个带占位符的 key
   `paywall.comparison.voice_prefix %@`（en `Voice captures: %@`、zh `语音录入：%@`、ja `音声入力：%@`），
   包住原来的「免费版 3 次 / 每天」，这样标点随语言走、代码里不拼标点。两种做法任选其一，在结果里写明。
3. 保持一行、保持 `minimumScaleFactor(0.7)`。**项目规则：零容忍「…」截断。**

**降级方案（只有验收 §6.2 发现截断时才用）**：去掉文字标签，只保留麦克风图标，把新增的 key 删掉。
用了降级方案要在结果里写明是哪种语言、哪个机型触发的，并附截图。

---

## 3. 改动 B：核心卡片替换「支持独立开发」卡

位置：`valuePropsList`（约 `PaywallView.swift:701`）。

1. 把 `🌱` + `onboarding.pro.bullet.support.title/desc` 那张 `ValuePropCard` 换成：
   `emoji: "🎙️"`、`title` = 新 key `paywall.value.capture.title`、`description` = 新 key `paywall.value.capture.desc`，
   仍然 `compact: true`。文案见 §1.1。
2. 试用卡（🎁）的逻辑、位置都不动，仍在新卡片**上方**。
3. 删除不再使用的 key：`onboarding.pro.bullet.support.title`、`onboarding.pro.bullet.support.desc`。
   起草时已核对：这两个 key 只在 `PaywallView.swift` 用到，引导页和测试都不引用。删之前再 `grep` 一遍确认。
4. 同步改 `valuePropsList` 和 `PaywallContent` 顶部的文档注释（现在写的是「support 卡总是显示」「复用 OnboardingView 同源 `onboarding.pro.bullet.*` 文案」），改成符合新结构的描述。

---

## 4. 改动 C：底部小字

1. 新 key `paywall.footer.indie`，文案见 §1.2。
2. 放在 `legalBlock(showsPriceDisclosure:)` 里，**`legalLinks` 之后、`restoreButton` 之前**。
   `legalBlock` 在已订阅和未订阅两个分支都会调用，所以两个分支都会显示——这是有意的：已订阅用户看到「感谢你的支持」更贴切。
3. 样式和续费说明（`legalText`）一致：`.system(size: 11, weight: .regular, design: .rounded)`、
   `WarmTheme.textMuted`、居中、`lineLimit(2)`、`minimumScaleFactor(0.85)`、左右 `WarmSpacing.lg` 内边距。
   **不做成卡片**，不加背景。
4. 不需要 accessibility identifier；VoiceOver 正常朗读即可（emoji 会被读出来，可接受）。

---

## 5. 明确不改的地方及理由

- **「省 33%」角标保持 33%，不要改成 34%。** 角标是所有地区共用的固定字符串（`paywall.yearly_save`）。
  人民币价 ¥298 vs ¥38×12 省 34.6%，但美区 $39.99 vs $4.99×12 只省 **33.2%**。写 34% 在美区就是不实宣传；33% 是所有地区都成立的下限。
- **标题、购买按钮**：现有文案与产品要求已完全一致。
- **续费说明**：审核 3.1.2 要求，任何字都不动。
- **不把复盘写成 Pro 功能、不把日期识别写成 Pro 专属**：复盘和日期识别免费版都有，写成 Pro 好处有 2.3 误导风险。新卡片的说明是在描述「每次录入都能做到的事」，不是 Pro 独占，这是有意的。

---

## 6. 验收

### 6.1 本地化文件

- `Resources/Localizable.xcstrings` 改完必须仍是合法 JSON：`python3 -m json.tool Resources/Localizable.xcstrings > /dev/null`。
- 新增的每个 key 都有 `en`、`zh-Hans`、`ja` 三语，`state` 为 `translated`。
- 优先用 Xcode 的 String Catalog 编辑器改；手改 JSON 时保持 Xcode 的格式（`" : "` 分隔、2 空格缩进、key 按字母序），避免下次 Xcode 打开时产生大面积无关 diff。
- 两个旧 key 已删除，`grep -rn "onboarding.pro.bullet.support" --include=*.swift .` 无结果。

### 6.2 一屏高度（最重要）

新卡片的说明比旧卡片多一到两行，又多了底部小字，页面大约高出 35～45pt。付费页有一屏化 UI 测试（S18，
`VoiceTodoUITests/ScenarioTests.swift` 约 `:657`），要求小屏不滚动就能看到全部内容。

1. **必须在 Xcode GUI 里跑**，模拟器 **iPhone SE（第 3 代）**，scheme 挂上 `VoiceTodo/Products.storekit`。
   命令行 `xcodebuild test` 不注入 StoreKit 配置，商品恒为空，测不到「试用卡 + 新卡片 + 两张商品卡 + CTA + 法务 + 小字全渲染」的最坏情况。
2. S18 通过，在结果里贴 `PaywallContentFits` 的值（形如 `1|content=…|viewport=…|state=success`），并和改前同一机型的值对比。
3. 在 SE 上手动截图三语（en / zh-Hans / ja）的未订阅付费页（有试用资格的状态），确认：
   - 没有任何「…」截断（对比条、卡片标题、说明、小字）；
   - 对比条的字没有缩到明显难读；
   - 购买按钮不滚动可见。
4. 再截一张已订阅状态的付费页（任一语言），确认底部小字显示正常。

**如果 S18 不通过：不要自行删减或改写文案。** 先尝试只调间距（例如小字与链接之间的间距），仍不通过就停下，
在结果里报告 content / viewport 差值和截图，交回产品决定。

### 6.3 回归

- 单元测试全部通过（`VoiceTodoTests`）。
- 购买、恢复购买流程手动点一遍（StoreKit 本地配置即可），确认 CTA 变绿、自动收起等原有行为不受影响。

---

## 7. 结果格式（`docs/paywall-copy-v2-results.md`）

1. 改动摘要：改了哪些文件；对比条标签用了哪种做法（§2 第 2 条的两种之一）；是否用了降级方案。
2. 新增 / 删除的 key 列表。
3. S18 结果和 `PaywallContentFits` 改前改后数值。
4. §6.2 第 3、4 条的截图（放在 `docs/screenshots/paywall-copy-v2/`，或直接贴在结果文档里）。
5. 偏离任务书的地方及理由（没有就写「无」）。

---

## 8. 执行约束

- 从最新 `main` 拉新分支（名字自定），**不要直接在 main 上改**；提交、推送分支后交回审查，**不合 main**。
- 不改文案；不改价格和 StoreKit 配置；不改 `liveUsageCard`、已订阅状态卡、引导页。
- 提交信息里不要出现模型名称。
