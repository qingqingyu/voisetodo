# VoiceTodo 宣传文案手册(PROMOTION_COPY)

> 配套 `PROMOTION_PLAN.md`(策略与执行)使用。本手册 = **对外文案资产包**,全部英文(英文市场)。
> 定稿: 2026-08-14 · 状态: 草稿 v1(上线前需按 §6 一致性红线核一遍)

---

## 0. 使用说明

- 所有文案基于 `PROMOTION_PLAN.md` 的 12 项决策,并**假定 §2.1 gating 清单已完成**(Free 3/day、wow-first onboarding、AI 成本已解)。若上线时 `DAILY_REQUEST_LIMIT` 仍是 2,所有写 "3" 的地方必须改成 "2"。
- 字符上限按 App Store 规则标注。**提交前用字符计数器逐条核**,不要信肉眼。
- Reddit 帖子草稿是"骨架 + 语气示范",发帖当天必须按当时 sub 的 rules 和最近热帖再调一遍。

---

## 1. 核心信息(Core Messaging)

### 1.1 One-liner(主 H1,全渠道统一)

> **One ramble. Planned todos.**

变体(按场景选):

| 场景 | 文案 |
|------|------|
| App Store Subtitle | One ramble. Planned todos. |
| Reddit 帖标题 | …turns one spoken ramble into structured todos |
| 落地页 H1 | Say it all at once. Get it all planned. |
| 一句话功能版 | Speak one sentence — get N todos with dates, recurrence and categories. |

### 1.2 电梯稿(30 秒,EN)

> Capture is where every to-do system breaks: by the time you've typed one task, the thought is gone. VoiceTodo takes one spoken ramble — "meeting tomorrow 10am, report due Friday, rent on the 1st every month" — and returns fully structured todos: dates resolved to real dates, recurrence set, categories assigned, reminders scheduled. Nothing to type, nothing to configure. iOS-native, with Lock Screen widgets and an Action Button shortcut.

### 1.3 Wow demo 剧本(15s GIF,Week 0 制作)

| 时间 | 画面 |
|------|------|
| 0-3s | 按 Action Button 开始录音,出字幕:"*tomorrow 10am meeting, quarterly report by Friday, grab the package, rent on the 1st every month, drink water at 3, 5 and 7*" |
| 3-4s | 松手 |
| 4-10s | 确认页 5 条 todo 逐条流入,日期/分类/重复/多时段提醒 badge 依次点亮 |
| 10-13s | 点确认 → 周视图自动填充 |
| 13-15s | 黑底白字: **VoiceTodo — One ramble. Planned todos.** |

---

## 2. App Store Listing(EN)

### 2.1 字段

| 字段 | 上限 | 文案 | 字符数 |
|------|------|------|--------|
| App Name | 30 | `VoiceTodo: AI Voice To-Do List` | 30(贴边,勿加字) |
| Subtitle | 30 | `One ramble. Planned todos.` | 26 |
| Promotional Text | 170 | 见下 | ~165 |
| Keywords | 100 | 见下 | 97 |

**Promotional Text(≤170):**

> Speak one ramble — "meeting tomorrow 10am, report by Friday, meds nightly at 8" — and get structured todos with dates, reminders and categories. No typing. No menus.

**Keyword field(97/100,逗号分隔无空格;不重复 Name/Subtitle 已含词):**

```
reminder,task,list,speech,dictation,gtd,planner,calendar,recurring,organizer,assistant,widget,siri
```

### 2.2 Description(前 3 行是 hook,之后才铺开)

```
Dump everything on your mind in one breath. VoiceTodo turns one spoken ramble into fully structured todos — dates resolved, recurrence set, categories assigned, reminders scheduled.

"Tomorrow 10am meeting, quarterly report due Friday, pick up the package, rent on the 1st every month" → 5 todos. Each with the right date, time and category. Automatically.

Built for people who think faster than they type.

— What it understands —
• Relative dates: "by Friday", "end of the month", "next Wednesday" → real dates
• Recurrence: "every Mon/Wed/Fri", "monthly on the 1st", "every two weeks" → repeating rules
• Fuzzy plans: "this weekend" → asks you Saturday or Sunday, never guesses
• Times: "tonight at half past ten" → 22:30 reminder
• Multiple reminders: "water at 3, 5 and 7" → three reminders on one todo
• Priority & category: urgent tone → high priority; auto-filed into Work / Life / Health / Finance…
• Your language: speaks English, 中文, 日本語 — mixed sentences are fine

— Built into your iPhone —
• Lock Screen widgets & Live Activity
• Action Button to capture in one press
• Siri & App Intents
• Writes to Apple Calendar
• Works offline: voice notes are saved and structured when you're back online

— Pricing —
Free: 3 AI extractions per day, forever.
VoiceTodo Pro: $4.99/month or $39.99/year after a 7-day free trial. Unlimited-feel daily allowance (fair-use cap), no ads.

Privacy: speech recognition uses Apple's Speech framework. To structure todos, the transcript text (not audio) is sent to our server and an AI provider. Audio is not stored. No account required.
```

### 2.3 截图文案(6.7" 1290×2796,前 3 张 = wow)

| # | 大字(Headline) | 小字(Caption) | 画面 |
|---|----------------|----------------|------|
| 1 | **Say it all at once.** | One breath. Any length. | 录音界面 + 字幕浮层 |
| 2 | **5 todos. Automatic.** | Dates, times, categories — parsed for you. | 确认页 5 条拆好的 todo |
| 3 | **It understands time.** | "By Friday" → real date. "Every Mon/Wed/Fri" → repeats. "This weekend" → asks you. | 日期解析特写 |
| 4 | **On your Lock Screen.** | Widgets + Live Activity. | 锁屏 widget 组合 |
| 5 | **Deep in your iPhone.** | Action Button. Siri. Calendar. | Action Button / Siri / 日历三联 |
| 6 | **Your language, kept.** | English · 中文 · 日本語 — mixed is fine. | 三语言混输示例 |

---

## 3. Reddit 帖子草稿(4 sub × 4 周)

### Week 1 · r/iosapps(容错最高,首发)

**Title:**
> I built a to-do app that turns one spoken ramble into structured todos — dates, recurrence, categories, all parsed automatically

**Body:**

```
The thing that always broke my to-do system wasn't the system — it was capture. By the time I've typed one task, the other four thoughts are gone.

So I built VoiceTodo. You speak one ramble, it returns structured todos.

Real example — I said:

  "Tomorrow 10am meeting, quarterly report by Friday, grab the package,
   rent on the 1st every month, remind me to drink water at 3, 5 and 7"

And got back 5 todos:
  • Meeting — Fri… (tomorrow, 10:00) · Work
  • Submit quarterly report — by Friday · Work
  • Pick up package — no date · Life
  • Pay rent — monthly on the 1st · Finance
  • Drink water — 3 reminders: 15:00 / 17:00 / 19:00 · Health

Three build decisions I'm proud of:

1. Relative dates become real dates. "By Friday" resolves against today's date. You never see "Friday" in a date field.
2. "This weekend" deliberately does NOT resolve. Saturday or Sunday? That's your call — the app asks instead of guessing. Guessing is how trust dies.
3. Numbers stay out of your content. Your titles stay exactly in the language you spoke (English, 中文, 日本語 — mixing is fine).

Honest limits: iOS 17+. The structuring step needs network (it's AI), voice notes queue offline. Free tier is 3 AI extractions/day; Pro is $4.99/mo or $39.99/yr after a 7-day trial — AI calls cost real money per extraction, so that's the honest way to price it.

What's your capture flow today — and where does it break?
```

**发帖注意:** 发前重读 sub rules;48h 内每条评论必回;不要在评论区贴付费链接,有人问再答。

### Week 2 · r/getdisciplined(GTD 人群,[Method] 姿态)

**Title:**
> [Method] The 3-second capture habit that finally made my system stick (I also built the tool)

**Body 骨架:**

```
My systems always died at the same place: capture friction. GTD says "capture everything" — but opening an app, typing, setting a date… that's 4 decisions per thought. At 20 thoughts a day, that's 80 decisions before any actual work.

The habit that stuck: one voice note, no decisions. Everything else gets structured later by something that doesn't get tired.

1. Press (Action Button / widget) → speak the whole jumble in one breath
2. Let the tool split it: dates resolved ("by Friday" → actual date), repeats set ("every Mon/Wed/Fri"), categories filed
3. Review once a day — confirm, adjust, done

The review step is where judgment belongs. The capture step should cost zero.

I ended up building the tool I wanted (VoiceTodo, iOS) because nothing did the second step — but the habit works with any voice memo + a weekly review. The principle: move ALL structure decisions out of the capture moment.

What does your capture step cost you, in seconds?
```

**发帖注意:** 这里的姿态是"分享方法,顺带是我做的工具"。评论区有人问 app 名再给链接,帖内链接放最尾且只一次。

### Week 3 · r/productivity(最严,价值优先,app 是配角)

**Title:**
> My voice-first capture workflow: from thought to structured week in 20 seconds

**Body 骨架:**

```
Workflow post, not an app pitch — the app I use is one I built, link at the bottom, but the workflow itself is the point and half of it works with stock iOS.

The problem: capture speed vs. structure. Apple Reminders + Siri is fast but flat — one reminder, no splitting, no recurrence parsing. Typed systems (Todoist, Things) are structured but slow. I wanted both.

Step 1 — Capture (3s): one voice note, plain rambles. Works with Voice Memos too.

Step 2 — Structuring (the actual trick): the sentence "quarterly report by Friday, also grab the package, rent on the 1st every month" contains THREE todos with different shapes — a deadline, a loose task, a monthly repeat. Doing this split by hand is where I always quit. I built VoiceTodo so a model does it: dates resolve against today, repeats become rules, categories file themselves.

Step 3 — Daily review (2min): confirm what was parsed, fix what wasn't. Judgment stays mine.

If you want the DIY version: Siri → Reminders for time-boxed ones, voice memo for the jumble, weekly triage. It works. I just got tired of step 2.

Link: [App Store]. iOS 17+, free tier 3 AI extractions/day, Pro $4.99/mo. Happy to answer build questions.
```

**发帖注意:** r/productivity 对 self-promo 最狠。骨架里"DIY version 也能做"这段是保命符,**不能删**。发帖前看 mod pinned post 和最近被删的 promo 帖。

### Week 4 · r/AppleiOS(生态整合向)

**Title:**
> I built an iPhone-first voice to-do that uses the Action Button, Lock Screen widgets and Live Activities

**Body 骨架:**

```
Native-first, not cross-platform-port. The parts of iOS that made this worth building:

• Action Button → one press, straight to recording. Capture has to be faster than the thought.
• Live Activity while recording — you can see the transcript build live from the Lock Screen.
• Lock Screen widgets: today's todos without unlocking.
• App Intents: "add to VoiceTodo" works from Siri and Shortcuts.
• Calendar integration: confirmed todos can write to Apple Calendar.

The AI part: one ramble in, structured todos out. "Every Mon/Wed/Fri at 8pm, gym" → a real weekly rule, not a text blob.

iOS 17+, free tier 3/day, Pro $4.99/mo or $39.99/yr (7-day trial).

What would you map the Action Button to, if capture were free?
```

---

## 4. 回应话术(Rebuttals & Templates)

### 4.1 "Todoist/TickTick already does this"(Reddit 必出现)

> Genuine question, not a rebuttal — here's one 20-second ramble → 5 todos with resolved dates ("by Friday" → actual calendar date), a monthly recurrence rule, and three separate reminder times. If Todoist parses that out of one voice note, tell me how; I looked, couldn't find it, and that gap is exactly why I built this. Happy to be shown wrong.

语气规则: 不 defensive、给具体事实、留"我可能错了"的口。绝不说 Todoist 不好,只说"我找不到这个能力"。

### 4.2 App Store 1-2 星差评公开回复模板(24h 内)

```
Thanks for the feedback — sorry [具体问题] got in your way. [一句话承认 + 说明,如果确属 bug 直接认]. A fix is queued for the next update. If you're open to it, [support email] — I'd like to make this right and would genuinely value the details.
```

规则: 不争辩、不复读道歉、每条评论的回复必须**具体**到对方批评的点。修好后回原评论追加 "fixed in x.y" 并邀请重评。

### 4.3 "Why does it need internet / privacy?"

> Speech recognition runs through Apple's Speech framework. To structure todos, the transcript (text, not audio) goes to our server and then to an AI provider — that's how "by Friday" becomes a real date. Audio isn't stored, transcripts aren't used for anything else, and no account is required.

### 4.4 "Why isn't it free?"

> Each extraction is a real AI call with real per-request cost. Free tier is 3 extractions a day, forever — enough to know if it sticks. Pro ($4.99/mo or $39.99/yr) is priced at Todoist level, not AI-hype level.

---

## 5. 上线日 Copy Checklist

- [ ] Name/Subtitle/Keywords 逐条字符数复核(30/30/100)
- [ ] Promotional Text ≤170
- [ ] Description 与**当时真实产品**一致: 免费额度数字、Pro 权益措辞(不许出现 "unlimited" 字样 —— PAID_DAILY_LIMIT 是有限值,写 "unlimited" 有 App Store 审核拒审风险)
- [ ] 截图 6 张导出 1290×2796,前 3 张 wow 顺序不变
- [ ] GIF ≤15s,自动播放无声可懂(带字幕)
- [ ] 每篇 Reddit 草稿发帖当天对照该 sub rules 与最近 3 天热帖语气再调
- [ ] 4.1-4.4 话术存进手机备忘录,评论出现 10 分钟内可粘贴微调

## 6. 文案与产品一致性红线(违反 = 拒审或差评)

1. **免费额度数字**(3/day)必须与线上 `DAILY_REQUEST_LIMIT` 一致
2. **禁止 "unlimited"**: Pro 是 fair-use 上限,不是无限(参见 `wrangler.toml.example` 内注释的拒审风险)
3. **禁止暗示 on-device AI**: 结构化是云端做的,privacy 文案必须照 4.3 口径
4. **语言宣称只写 EN/中文/日本語**,别写 "any language"(prompt 规则 10 是"跟随输入语言",但质量只在三语言上验证过)
5. **Android/Web 不存在**,任何渠道都别留"coming soon"式的口子
