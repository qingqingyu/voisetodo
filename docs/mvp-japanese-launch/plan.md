# VoiceTodo MVP 日语支持上线计划

> 文档创建于 2026-08-02。状态:**v1.1 执行**。
> 2026-08-15 拍板:首版 v1.0 只上 zh + en,本计划推迟到 v1.1(见 memory `project_mvp_language_scope.md`)。
> 单人开发,无母语 QA,v1.1 目标 3-7 天内完成 zh + en + ja 三语版本。

---

## 0. 决策摘要(给未来的自己看)

| 维度 | 决策 |
|---|---|
| 上线语言范围 | v1.0: zh + en;v1.1: + ja(2026-08-15 拍板;法德推迟,等数据) |
| 质量策略 | AI 驱动翻译 + AI 驱动 prompt 生成,**无母语 QA** |
| 复查机制 | 用两个不同 AI 模型交叉检查(Claude × GPT-4 之类) |
| 兜底机制 | 日文 UI 加 Beta 标签,降低用户预期 + 收集反馈 |
| 时间线 | 7 天内完成所有改动并提审 |
| 当前 app 状态 | **尚未上线**;Branch: `riyu` |

**已锁定的决策不再讨论**:是否做日语、是否找母语 QA、是否做法德 —— 这些已经在前置讨论中确定,后续 session 不要重新质疑(详见 memory `project_mvp_language_scope.md`)。

> ⚠️ **实施前必读**:动代码前先看 §8 决策清单。每条都有默认值,全部接受默认也能跑通,但 D1 / D2 / D4 建议显式确认。

---

## 1. 战略来龙去脉(为什么做这个,接受什么风险)

### 1.1 决策依据

- **观察**:Todoist 日本区差评活跃,日本用户在任务管理品类里写评论活跃
- **判断**:todo list 场景契合日本市场,不想错过
- **重要事实**:这些差评**全部是功能/bug 抱怨,没有一条是"想要日语版"**。所以"做日语"是基于直觉的赌注,不是数据驱动

### 1.2 接受的风险(都已认可)

1. **AI 翻译/prompt 质量不稳**:接受,用双 AI 复查 + Beta 标签兜底
2. **早期差评不可逆**:App Store 评论永久挂页面。Beta 标签是唯一防御
3. **AI 在日文上的特定失败模式**(「今度」「近日」「敬体混用」) → 在 prompt 里加显式消歧规则
4. **单人无法验证 AI 输出质量** → 接受"盲飞",Beta 标签用户反馈是唯一信号源

### 1.3 为什么不做法德

- 法德用户的差评也是功能抱怨(德国要"日历事件识别为待办",法国要"iPhone 日历同步"),不是语言抱怨
- VoiceTodo 已经能用英文版满足这些需求,加法语 UI 解决不了功能抱怨
- 单人 7 天做不了 5 种语言质量都过关
- 等 zh+en+ja 上线后看数据再决定

---

## 2. 当前 i18n 状态(代码层证据,2026-08-02)

| 层 | 现状 | 日本用户当前体验 |
|---|---|---|
| UI 字符串 | ✅ `Resources/Localizable.xcstrings` 530 keys × `en` + `zh-Hans` | 回退到英文 |
| 日期/日历格式 | ✅ SwiftUI Locale 感知 | 日历/日期自动日文化(免费) |
| 语音识别语言 | ⚠️ `SpeechRecognitionLanguage` 只有 `auto` / `zh-Hans` / `en-US` | `auto` 跟随系统 → ja-JP **能识别** |
| AI 提取 locale | ❌ **代理硬切二选一** | 见下 |

### 关键 bug 代码

**`AIProxy/worker.js:1566`**:

```javascript
function normalizeLocale(locale) {
  const raw = String(locale || "en");
  return raw.toLowerCase().startsWith("zh") ? "zh" : "en";  // ← ja-JP 被吞成 en
}
```

**`AIProxy/src/adapters/base.js:95`**:

```javascript
const basePrompt = locale === "zh" ? CHINESE_SYSTEM_PROMPT : ENGLISH_SYSTEM_PROMPT;
// 没有 JAPANESE_SYSTEM_PROMPT,没有日文 few-shot 示例
```

**有意思的对比**:`base.js:281` 的 prompt 规则 10 已经说"if the user speaks Japanese, write Japanese"。但整套 system prompt 和 15 个 few-shot 示例只有中英两套,日文 transcript 进来后被英文 prompt 框住处理,大概率输出英文标题或半通不通的日语。

### 已发现的"AI 在日文上的失败模式"清单

写进 prompt 显式处理(见 Layer 3 第 4 节):

1. **「今度」歧义**:可以是"下次" / "最近" / "刚才",取决于上下文
2. **敬体/常体混用**:同一 app 内「保存します」和「保存する」混着用,母语用户立刻识破
3. **日期格式**:令和 N 年 vs 20XX 年,场景不同
4. **助词微妙差异**:「水曜日に」vs「水曜日まで」,一字之差意思完全不同
5. **few-shot 示例本身的日文质量**:AI 评估 AI 写的日文,盲点一致,几乎一定说"很好"

---

## 3. Layer 1:UI 本地化(界面)

### 3.1 改动清单

| # | 文件 | 改什么 | 备注 |
|---|---|---|---|
| 1.1 | `Resources/Localizable.xcstrings` | 给全部 530 个 key 加 `ja` 翻译 | AI 批量翻 + 第二个 AI 复查 |
| 1.2 | `VoiceTodo/InfoPlist.xcstrings` | 给 4 个权限说明加 `ja`:Microphone / SpeechRecognition / CalendarsWriteOnly / (CFBundleDisplayName 保持 "VoiceTodo" 品牌名) | 系统权限弹窗文案,日本用户看到的第一面 |
| 1.3 | `VoiceTodoWidget/InfoPlist.xcstrings` | Widget 相关 key 加 `ja`(若有) | 同上 |
| 1.4 | `project.yml` | `knownRegions` 加 `- ja`(在 Base/zh-Hans/en 之后) | 让 XcodeGen 把 ja 纳入构建 |
| 1.5 | 新增 Beta 标签 UI(见 §6.1) | 防御机制 | |
| 1.6 | App Store Connect 后台 | 标题/副标题/关键词/描述/截图文案的 `ja` 版本 | 日本区能否被搜到的命脉 |

### 3.2 翻译风格规范(写进给 AI 的 prompt 里)

- **文体统一**:全部用「です/ます」敬体(消费者向 app 标配)。**禁止**出现「〜する」「〜である」常体或混用
- **标题/按钮风格**:用「体言止め」或动词辞书形(例:「保存」「キャンセル」「設定」) —— 与 Apple HIG 日文版风格一致
- **数字与单位**:日文用全角还是半角要统一(建议半角,符合 Apple 系统惯例)
- **不要直译**:例 "Today" → 「今日」(可),但 "Up Next" → 「次に」(不要直译成「次に上がる」)
- **两个 AI 复查时,必须明确指定"检查所有字符串的 です/ます 一致性"** —— 否则 AI 自己也看不出问题

### 3.3 风险点

- **AX5 字号下日文溢出**:日文密度比中文还高。所有按钮、标签都要按 memory 里那条「文本截断零容忍」规则测一遍(`lineLimit` + `minimumScaleFactor` + fixedSize + ViewThatFits)
- **提交前用中/英/日三语言长文本各测一遍**(项目 CLAUDE.md 的"文本布局规则"硬性要求)
- **Info.plist 权限说明**这 3 条尤其重要 —— 日本用户对权限弹窗极敏感,文案如果半通不通会显著降低授权率

---

## 4. Layer 2:语音录入

### 4.1 改动清单

| # | 文件 | 改什么 |
|---|---|---|
| 2.1 | `Voice/SpeechRecognitionLanguage.swift` | 加 `case jaJP = "ja-JP"`,`displayName` 走 `String(localized: "settings.speech_language.ja-JP")`,`fixedLocale` 返回 `Locale(identifier: "ja-JP")` |
| 2.2 | `Resources/Localizable.xcstrings` | 加新 key `settings.speech_language.ja-JP` 的 en/zh-Hans/ja 三语翻译(英文 "Japanese"、简中"日语"、日文「日本語」) |
| 2.3 | `VoiceTodoTests/Voice/VoiceInputTests.swift` | 加 `.jaJP` case 的单元测试 |

### 4.2 已经自动 work 的部分(不用改)

- **`auto` 模式**:`SpeechRecognitionLanguage.auto` 已走 `Locale.preferredLanguages.first`。日本用户系统是 ja-JP,装上就自动用日文识别,**day-1 就能用**
- **SFSpeechRecognizer 支持 ja-JP**:Apple 标准支持,不需要额外配置
- **`VoiceInputManager.resolveCurrentLocale()`**:已正确处理 locale 解析,加新 case 不破坏现有逻辑

### 4.3 风险点

- **真机测试必做**:CLAUDE.md 写过"simulator 上 SFSpeechRecognizer 经常失败"。日文语音必须在**真机**上测,不能在模拟器上验
- **`auto` 模式下的中英日识别精度**:用户系统是日文,但他想说中文时怎么办?有 `.zhHans` 显式选项兜底,但 UI 要让日本用户能看懂这个选项是干嘛的(就是 2.2 那条翻译)

---

## 5. Layer 3:AI 提取层(最大头,先做)

### 5.1 改动清单

| # | 文件 | 行 | 改什么 |
|---|---|---|---|
| 3.1 | `AIProxy/worker.js` | 1566 | `normalizeLocale` 加 ja 分支:`if (raw.startsWith("ja")) return "ja";` |
| 3.2 | `AIProxy/src/adapters/base.js` | 在 `CHINESE_SYSTEM_PROMPT` / `ENGLISH_SYSTEM_PROMPT` 旁边 | **新增 `JAPANESE_SYSTEM_PROMPT` 常量** —— 完整日文 system prompt + 15 个 few-shot 示例 |
| 3.3 | `AIProxy/src/adapters/base.js` | 90-94 | `todayLine` 加 ja 分支:`` `\n\n参照日:${today}(YYYY-MM-DD)。相対日付の計算基準として使用。` `` |
| 3.4 | `AIProxy/src/adapters/base.js` | 95 | `basePrompt` 选择三元改成:zh→中文 prompt、ja→日文 prompt、其他→英文 prompt |
| 3.5 | `AIProxy/src/adapters/base.js` | 106-111 | `vocabularyHintPrompt` 加 ja 分支:日文版的"用户近期常用词"提示 |
| 3.6 | `VoiceTodoTests/Extractor/ExtractorTests.swift` | — | 加 ja locale 的输入/输出测试 |
| 3.7 | `AIProxy` worker 测试 | — | 加 ja locale 测试 |

### 5.2 日文 system prompt 写作要点(给 AI 的指令规范)

让 AI 生成 `JAPANESE_SYSTEM_PROMPT` 时,**必须把这些规则传给它**:

1. **以现有 `CHINESE_SYSTEM_PROMPT` 为模板**,逐条对应翻译,**不要自创规则**
2. **15 个示例必须覆盖同样的场景**(无时间、带钟点、月度重复、周重复多天、有限周期、非"未来N"边界、相对日期、N天后、模糊时段、一次性截止日、interval 重复、多时间点、模糊日期换算、title_mention vs user_explicit 对比对)
3. **规则 10(枚举字段保持英文)** —— 这条不能改,所有 enum 值仍是 `high/normal`、`work/study/...`、`morning/afternoon/evening` 等
4. **歧义词显式规则**(加进 prompt 里):
   - 「今度」= 默认按「次回」处理,标 `due_date_basis="inferred"`
   - 「明日」「翌日」都是 tomorrow
   - 「明後日」= 后天,「明々後日」= 大后天
   - 「今週末」「来週末」= 即将到来的周六 / 下周六
   - 「月末」「月初」「月中」= 当月最后一天 / 1 号 / 15 号
5. **文体规则**(放规则 10 之后):title 用「体言止め」或辞书形动词(例:「会議資料の準備」「買い物をする」),**不用**「〜します」敬体

### 5.3 双 AI 复查的具体分工

- **AI A**(主生成):GPT-4 或 Claude,生成日文 prompt + 15 个示例
- **AI B**(复查):用与 A 不同的模型,**只检查以下三项**:
  1. 日文示例的自然度(不是 JSON 结构对不对)
  2. 文体一致性(全 prompt 是否统一 です/ます 或统一常体)
  3. 是否有意译漏译(对比英文/中文原版规则条数)
- **不要让 AI B 检查"逻辑正确性"** —— 它会跟 AI A 一致地认为"很好",盲点相同

### 5.4 风险点(高风险)

- **15 个示例任何一个有微妙错误 → 整个产品基线被污染**
- **`今度` 这种词 AI 处理不好** → 必须在 prompt 里加显式消歧规则
- **服务端缓存污染**:`makeCacheKey` 包含 locale,ja 的缓存独立,不会污染 zh/en。但要确认上线后第一次请求是干净的(没有遗留脏缓存)
- **`base.js:281` 规则 10 已经写"if user speaks Japanese, write Japanese"** —— 这条不变,但需要日文 prompt 里也有对应说明

---

## 6. Cross-layer 必做项

### 6.1 Beta 标签 UI

**位置**(建议两处都加):

**A. 设置页(Settings)**:在「语音识别语言」section 上方加 info banner

```
ℹ️ 日本語版はベータ版です
AI 処理のため、不自然な表現がある可能性があります。
ご意見・不具合報告は [フィードバック] までお願いします。
[フィードバックを送る] (按钮)
```

**B. 首次启动 onboarding**(可选,但强烈建议):检测 `Locale.preferredLanguages.first` 是 `ja-*` 时,首次启动弹一次说明

**显隐规则**:`if Locale.current.identifier.hasPrefix("ja")` 才显示。中英文用户看不到。

### 6.2 反馈渠道(必须先定)

Beta 标签上的「フィードバックを送る」按钮指向哪?

- **A.** `mailto:` 链接 —— 最简单,但需要准备收日文邮件
- **B.** Google Form / Tally / Typeform —— 结构化收集,免费,不暴露邮箱
- **C.** GitHub Issues(如果开源)
- **D.** iOS 系统反馈邮件 + 自动附 device info

**推荐 B(Google Form)**。结构化、免费、可以让用户选 category(翻译问题 / AI 输出问题 / 功能建议 / bug)。

### 6.3 App Store metadata(独立工作流)

日本区 App Store Connect 需要:

- App 名称(日文,建议保留 "VoiceTodo" 英文 + 日文副标题)
- 副标题(日文,描述核心价值,如「音声でメモする ToDo リスト」)
- 关键词(100 字符上限,研究日本用户搜什么 —— 候选:「 ToDo リマインダー」「音声 メモ」「タスク管理」「買い物リスト」等)
- 描述(4000 字符,要写日文)
- 截图文案(5 张截图,每张上面有日文标题)

**这块工作量与 Layer 1 翻译相当,但对获客的影响比 UI 翻译大 10 倍**。再烂的 UI 翻译都比搜不到强。

### 6.4 Beta 退出标准(必须提前定,否则永远 Beta)

写进 memory 里,什么信号触发"摘掉 Beta 标签":

- 日本区评分 ≥ 4.0 且评论 ≥ 30 条,且**翻译相关差评 < 20%** → 摘掉
- 或:有母语用户主动联系你帮忙审校 → 摘掉

没达到就保持 Beta。这不是耻辱,是诚实。

---

## 7. 7 天执行计划

| 天 | 工作 | 风险 |
|---|---|---|
| **Day 1** | Layer 3.1 + 3.2 + 3.3 + 3.4 + 3.5 —— AIProxy 改造 + 让 AI 写日文 prompt + 15 个示例。**最大风险先做** | 极高 |
| **Day 2** | Layer 3.6 + 3.7 测试 + 第二个 AI 复查 prompt + 用日文 transcript 跑一遍 | 中 |
| **Day 3** | Layer 1.1 + 1.2 + 1.3 + 1.4 —— UI 翻译批量做 + Info.plist + project.yml | 中 |
| **Day 4** | Layer 2.1 + 2.2 + 2.3 —— 语音 enum 加 ja + 翻译 + 测试 | 低 |
| **Day 5** | Cross-layer 6.1 + 6.2 —— Beta 标签 UI + 反馈渠道接入 | 低 |
| **Day 6** | Cross-layer 6.3 —— App Store metadata + 截图日文化 + **真机切日文系统端到端测试**(必做,模拟器不能测语音) | 高 |
| **Day 7** | 修补 + 提审 | 中 |

### 7.1 顺序背后的逻辑

- **Layer 3 优先**:这是最大风险、最大工作量、最不可逆的部分。先做,如果连 prompt 都写不出来,后面 Layer 1+2 都没意义
- **Layer 1 第二**:见效快,看到日文 UI 心里有底,且 ASO metadata 在 Day 6 才做(此时 UI 翻译已完成,可以基于真实 UI 写截图文案)
- **Layer 2 倒数第二**:工作量最小,改 enum + 加翻译 + 测试,几小时搞定
- **真机测试 Day 6**:必须在所有代码改动完成后做,模拟器不能测语音(CLAUDE.md 明确警告)

---

## 8. 决策清单(开始实施前必须回答)

> 本节列所有需要在动代码前确定的决策。每条都有:**问题 / 选项 / 推荐 / 不决策时的默认 / 阻塞什么**。
>
> **使用方式**:下次 session 实施时,先逐条决策(全部接受默认也行),然后按 §7 执行。决策结果建议直接在本节内追加到每条下方,留下痕迹。

### D1: 反馈渠道

**问题**:Beta 标签上的「フィードバックを送る」按钮指向哪里?

**选项**:
- **A. `mailto:` 链接** —— 最简单,几行代码。但需要准备收日文邮件(可用 Google Translate 翻译后处理)
- **B. Google Form / Tally / Typeform** —— 结构化收集,免费,不暴露邮箱,可让用户选 category(翻译问题 / AI 输出问题 / 功能建议 / bug)
- **C. GitHub Issues**(如果开源) —— 公开透明,但需要项目开源
- **D. iOS 系统反馈邮件 + 自动附 device info** —— 体验好,需要额外开发

**推荐**:**B(Google Form)**

**不决策时的默认**:A(`mailto:`),最简,不阻塞 Beta UI 开发

**阻塞**:Day 5 Beta UI 的按钮目标 URL

**决策**:[ ] A / [ ] B / [ ] C / [ ] D / [ ] 接受默认 A

---

### D2: Beta 首次启动 onboarding

**问题**:首次启动是否给日文系统用户弹一次性说明?

**选项**:
- **A. 只在 Settings 加 Beta banner** —— 工作量小(1-2 小时),但用户可能根本不进 Settings 就直接用,然后撞到烂翻译
- **B. Settings banner + 首次启动 modal** —— 多 2-3 小时工作量,但首次印象更稳;检测 `Locale.preferredLanguages.first` 是 `ja-*` 时弹一次

**推荐**:**B(两个都做)**。首次启动 modal 是关键防御 —— 用户在第一次失望前就被告知"这是 Beta"

**不决策时的默认**:A(Settings banner only)

**阻塞**:Day 5 工作

**决策**:[ ] A / [ ] B / [ ] 接受默认 A

---

### D3: 实施起点

**问题**:从哪一层开始动手?

**选项**:
- **A. Layer 3(AI prompt)先** —— 最大风险先消化。如果连 prompt 都写不出来,后面 Layer 1+2 都没意义
- **B. Layer 1(UI 翻译)先** —— 见效快,看到日文 UI 心里有底
- **C. 严格按 §7 的 Day 1-7 顺序** —— Layer 3 实际是 Day 1,所以 C ≈ A

**推荐**:**A(Layer 3 先)**

**不决策时的默认**:C(按 §7 顺序)

**阻塞**:无(只是顺序选择)

**决策**:[ ] A / [ ] B / [ ] C

---

### D4: 翻译文体

**问题**:日文 UI 文案统一用什么文体?

**选项**:
- **A. 全部「です/ます」敬体** —— 消费者向 app 标配,Apple HIG 日文版风格。一致性最高
- **B. 全部「体言止め」** —— 简洁有力,但偏冷静,适合工具类 app
- **C. 混合(UI 标签用「体言止め」,描述/说明用「です/ます」)** —— 最自然但最难统一,AI 容易翻车

**推荐**:**A(全部「です/ます」)**。一致性 > 风格,单人无 QA 下越统一越安全

**不决策时的默认**:A(§3.2 已经按这个标准写了)

**阻塞**:Day 3 Layer 1 翻译

**决策**:[ ] A / [ ] B / [ ] C / [ ] 接受默认 A

---

### D5: 日期格式

**问题**:日文文案里用西历(2026年)还是和暦(令和8年)?

**选项**:
- **A. 西历 only** —— 符合 Apple 系统惯例,国际化友好
- **B. 和暦 only** —— 日本本地味重,但年轻用户其实不太用
- **C. 西历+和暦 并列** —— 最严谨但啰嗦

**推荐**:**A(西历 only)**

**不决策时的默认**:A(§9.5 已经按这个建议)

**阻塞**:Day 1 Layer 3 prompt 写作(规则 4 提到日期换算)+ Day 3 日期相关 UI 字符串翻译

**决策**:[ ] A / [ ] B / [ ] C / [ ] 接受默认 A

---

### D6: AI 模型分工

**问题**:Layer 3 日文 prompt 用哪两个 AI 交叉检查?

**选项**:
- **A. GPT-4 生成 + Claude 复查** —— Claude 在文体一致性上更挑
- **B. Claude 生成 + GPT-4 复查** —— GPT-4 在日文示例自然度上略强
- **C. 同一个 AI 两次复查** —— **不推荐**,盲点一致,等于没复查
- **D. 用 Gemini / 其他** —— 可选,但需测试日文能力

**推荐**:**A(GPT-4 生成 + Claude 复查)**

**不决策时的默认**:A

**阻塞**:Day 1 工作

**决策**:[ ] A / [ ] B / [ ] C / [ ] D / [ ] 接受默认 A

---

### D7: AI 输出反馈入口

**问题**:ConfirmSheet(用户看到 AI 提取结果那个界面)要不要加「この翻訳が不自然」按钮?

**选项**:
- **A. 只在 Settings 有反馈入口** —— 简单
- **B. Settings + ConfirmSheet 都有** —— 在用户撞到烂翻译的那一刻就给反馈出口,转化率高,信号最准

**推荐**:**B(两个都做)**。AI 输出问题的反馈在用户失望当下最容易拿到

**不决策时的默认**:A(Settings only)

**阻塞**:Day 3-4 UI 工作

**决策**:[ ] A / [ ] B / [ ] 接受默认 A

---

### 决策快速汇总表

| ID | 决策 | 推荐 | 默认(不决策时) | 阻塞 |
|---|---|---|---|---|
| D1 | 反馈渠道 | B Google Form | A mailto | Day 5 |
| D2 | Beta 首次启动 onboarding | B 两个都做 | A Settings only | Day 5 |
| D3 | 实施起点 | A Layer 3 先 | C 按 §7 顺序 | 无 |
| D4 | 翻译文体 | A です/ます | A です/ます | Day 3 |
| D5 | 日期格式 | A 西历 | A 西历 | Day 1+3 |
| D6 | AI 模型分工 | A GPT-4+Claude | A GPT-4+Claude | Day 1 |
| D7 | AI 输出反馈入口 | B Settings+ConfirmSheet | A Settings only | Day 3-4 |

**最小决策路径**:如果只想做最少决策就开干,只需回答 **D1 + D2**(其他全部接受默认)。D4/D5/D6 默认值已经是推荐值,D3 是顺序选择,D7 可以实施到 Day 3 时再决定。

---

## 9. 附录:已知的 AI 在日文上的失败模式

(供未来调试 / 改进 prompt 时参考)

### 9.1 词汇歧义

- **「今度」**:可以是"下次" / "最近" / "刚才"
- **「近日」**:可以是"近期" / "未来几天"
- **「来週中」**:可以是"下周内某天" / "下周末"
- **「明後日」**:后天;但部分地区方言指"昨天"
- **「月末」**:本月最后一天,但跨月时歧义

### 9.2 文体混用

- **です/ます(敬体)**:消费者向 app 标配
- **だ/である(常体)**:正式文档 / 学术
- **体言止め**:用名词结尾(「会議の準備」),简洁,UI 标题常用
- **混用是机翻的标志**:母语用户立刻识破

### 9.3 助词微妙差异

- 「水曜日**に**」= 在周三(时间点)
- 「水曜日**まで**」= 到周三为止(截止)
- 「水曜日**は**」= 周三(主题)
- 一字之差意思完全不同,AI 偶尔会错

### 9.4 计数词

- 不同对象有不同计数词:一個、一本、一枚、一件、一匹、一台...
- AI 大部分时候对,但偶尔错

### 9.5 日期格式

- **令和 N 年**:日本年号,2026 年 = 令和 8 年
- **20XX 年**:西历
- **消费者向 app**:建议统一用西历,符合 Apple 系统惯例

---

## 10. 参考资料

- `Voice/SpeechRecognitionLanguage.swift` —— 语音语言 enum 定义
- `Voice/VoiceInputManager.swift` —— 语音识别实现
- `Extractor/TodoExtractorService.swift` —— AI 提取调用入口
- `Extractor/NetworkClient.swift` —— 代理网络层
- `AIProxy/worker.js` —— Cloudflare Worker 入口
- `AIProxy/src/adapters/base.js` —— **system prompt 和 few-shot 示例的真正位置**
- `Resources/Localizable.xcstrings` —— 530 个 UI 字符串
- `VoiceTodo/InfoPlist.xcstrings` —— 4 个权限说明
- `project.yml` —— XcodeGen 配置(knownRegions)

---

## 变更记录

| 日期 | 变更 |
|---|---|
| 2026-08-02 | 初版,基于 `/grill-me` 9 轮访谈后整理 |
| 2026-08-03 | 扩展 §8 为完整决策清单(D1-D7),每条带默认值,允许延后决策;顶部加实施前必读 callout |
| 2026-08-15 | 语言范围拍板:v1.0 只上 zh + en,本计划(含 ja)推迟到 v1.1;状态改为「v1.1 执行」,更新 §0 范围行 |
| 2026-08-18 | **挂账**:首次语音试用引导新增 11 个 key(`onboarding.button.try_voice` / `onboarding.done.trial_title` / `onboarding.done.trial_desc` / `home.first_trial.hint` / `home.first_trial.example` / `home.first_trial.got_it` / `home.added_toast.first_trial` / `home.added_toast.first_trial_generic` / `home.added_toast.first_trial_elsewhere %lld %lld` / `home.added_toast.go_look` / `a11y.first_trial.hint`)目前只有 zh-Hans + en,是首启体验文案,ja 补齐时**必须覆盖**(见 docs/onboarding-first-voice-trial.md §3.7) |
