# 官网页面规划：要做哪些页面、每页讲什么

> 2026-11-02 起草。本文档是 `docs/task-seo-website.md` 的**页面内容规格**，两份一起交给执行者。
> 技术要求（SEO、结构化数据、性能）以 `task-seo-website.md` 为准；本文只管「页面结构和每页讲什么」。
> 英文文案是方向稿，执行者可以润色，但**事实不能改**，也不能出现 `task-seo-website.md` §0.2 的禁用说法。
> `{{APP_NAME}}` 等占位符同 §0.1。

---

## 1. 网站地图

```
/                                   首页                         【一期】
├── /voice-to-do-list               语音记待办                   【一期】
├── /lock-screen-to-do-list         锁屏待办                     【一期】
├── /iphone-to-do-widget            桌面小组件                   【一期】
├── /features                       全部功能（事实页）           【一期】
├── /guides                         指南列表                     【一期】
│   ├── /guides/stop-forgetting-things-you-need-to-do           【一期，草稿待审】
│   ├── /guides/plan-your-day-in-2-minutes                      【一期，草稿待审】
│   ├── /guides/keep-to-do-list-visible-on-iphone               【一期，草稿待审】
│   ├── /guides/fastest-way-to-capture-tasks-on-iphone          【一期，草稿待审】
│   ├── /guides/brain-dump                                      【二期】
│   ├── /guides/too-many-tasks-where-to-start                   【二期】
│   ├── /guides/why-your-to-do-list-keeps-piling-up             【二期】
│   ├── /guides/weekly-review-template                          【三期】
│   └── /guides/adhd-task-paralysis                             【三期】
├── /brain-dump-to-task-list        Brain dump 页 + 免费小工具    【二期】
├── /simple-to-do-list-app          简单待办                     【二期】
├── /to-do-app-without-account      免注册待办                   【二期】
├── /todoist-alternative            Todoist 轻量替代             【三期】
├── /adhd-to-do-list                ADHD 友好                    【三期】
├── /support                        技术支持                     【一期】
├── /privacy                        隐私政策                     【一期】
├── /about                          关于开发者                   【一期】
└── /404                                                        【一期】
```

一期共 **13 个页面**（含 4 篇指南草稿和 404）。

---

## 2. 全站通用部分

### 顶部导航

`{{APP_NAME}}`（logo，回首页）· Voice · Lock Screen · Widgets · Guides · **[Download on the App Store]**

- 手机上折叠成菜单，App Store 按钮始终可见。

### 页脚

| Product | Guides | Company |
|---|---|---|
| Voice to-do list | Stop forgetting things | About |
| Lock Screen to-do list | Plan your day in 2 minutes | Support |
| iPhone widget | Keep your list visible | Privacy |
| All features | All guides | |

最下方一行：`Requires iPhone with iOS 26 or later.` · © 年份 {{APP_NAME}}

### 每页底部 CTA 区（统一组件）

> **Stop typing your to-do list.**
> Say it once. See it all day.
> [Download on the App Store] · Free to start. No account needed.

---

## 3. 一期页面

### 3.1 首页 `/`

**目的**：让第一次来的人 5 秒内明白：说话就能建清单，而且一直在锁屏上看得到。
**主搜索**：voice to do list app for iPhone；AI voice to do list app
**Title**：`Voice To-Do List for iPhone — Say It, See It on Your Lock Screen | {{APP_NAME}}`

| # | 区块 | 内容 |
|---|---|---|
| 1 | 首屏 | **H1**：Say your plan once. See it on your Lock Screen all day.<br>副标题：Speak everything on your mind. {{APP_NAME}} turns it into a checklist with the right dates — and you can check things off right from your Lock Screen.<br>[App Store 按钮] · Free to start · No account<br>右侧：录音截图（`screenshots/en/01-recording.png`）→ 确认清单截图 |
| 2 | 问题共鸣 | **H2**：Planning isn't the hard part. Remembering is.<br>三句话描述痛点：早上想好了，白天就忘了；打字记待办太麻烦，干脆不记；清单越堆越长，看着就累。 |
| 3 | 三步怎么用 | **H2**：How it works<br>① **Say it** — "Call the dentist tomorrow, buy milk, and send the report by Friday."<br>② **It's organized** — three separate to-dos, each on the right day.<br>③ **See it all day** — on your Lock Screen and Home Screen. Tap to check off. |
| 4 | 卖点 1 | **H2**：No typing. Just talk.<br>一句话说好几件事，自动拆开、排好日期。能听懂 "next Friday"、"end of the month"、"every Monday"。→ 链 `/voice-to-do-list` |
| 5 | 卖点 2 | **H2**：Your list, always in sight.<br>锁屏小组件、桌面小组件，不打开 App 也能看、能勾。→ 链 `/lock-screen-to-do-list`、`/iphone-to-do-widget` |
| 6 | 卖点 3 | **H2**：A list that doesn't pile up.<br>每周复盘：拖着的事，这周做、推到下周、拆小，或者划掉。（截图 `05-review.png`） |
| 7 | 隐私 | **H2**：No account. Your list stays on your iPhone.<br>不用注册；待办存在手机上；说的话转成文字后由 AI 整理，**不会被保存**；录音本身从不上传。→ 链 `/privacy` |
| 8 | FAQ | 见下 |
| 9 | 底部 CTA | 统一组件 |

**FAQ**（`FAQPage` 结构化数据）：
1. Is there a to-do list app where I can just say what I need to do? → Yes — that's what {{APP_NAME}} does. You speak… it splits and schedules…
2. Can I check off tasks from my iPhone Lock Screen? → Yes, with the Lock Screen widget…
3. Is it free? → Free to start with 3 voice captures a day. Pro gives you 100 a day, with a 7-day free trial.
4. Do I need an account? → No.
5. Does it work in other languages? → English, Chinese and Japanese.
6. Which iPhones are supported? → iPhone with iOS 26 or later.

---

### 3.2 语音记待办 `/voice-to-do-list`

**目的**：接住「不想打字、想用语音记」的搜索。
**主搜索**：voice activated todo list app；can I create a to-do list using my voice
**Title**：`Voice Activated To-Do List App for iPhone | {{APP_NAME}}`

| # | 区块 | 内容 |
|---|---|---|
| 1 | 首屏 | **H1**：A to-do list you can just talk to<br>副标题：Say several things at once. Get a clean checklist with dates — no typing, no forms. |
| 2 | 示例对照 | **H2**：One sentence in, a whole list out<br>左边一段口语原话（含 "um"、改口、没有标点），右边拆好的 3～4 条待办和日期。用真实截图 `02-confirmsheet.png`。 |
| 3 | 能听懂的说法 | **H2**：Understands how you actually talk<br>列表：tomorrow / next Friday / mid-month / end of the month / every Monday / at 3pm / remind me 30 minutes before。 |
| 4 | 三种开口方式 | **H2**：Capture in seconds, from anywhere<br>App 里的录音按钮；Siri："Add todo in {{APP_NAME}}"；Action Button 一键开录（支持的机型）。录音时有实时活动显示。 |
| 5 | 改起来也简单 | **H2**：Not quite right? One tap to fix.<br>确认前可以改每一条；还能教它你自己的叫法（个人词库）。 |
| 6 | 没网也不丢 | **H2**：No signal? Nothing is lost.<br>没网时先存下你说的话，联网后自动整理。 |
| 7 | FAQ | 1. Can I create a to-do list using my voice? 2. Can I add several tasks in one sentence? 3. Does it work with Siri? 4. Does it work offline? （按第 6 区如实回答） 5. Is my voice recording uploaded? （录音不上传；转写文字由 AI 整理且不保存） |
| 8 | 内链 + CTA | → `/lock-screen-to-do-list`、`/guides/fastest-way-to-capture-tasks-on-iphone` |

---

### 3.3 锁屏待办 `/lock-screen-to-do-list`

**目的**：接住「想让待办一直看得见、在锁屏上勾选」的搜索。这是竞品较少强调的点。
**主搜索**：iPhone lock screen to do list app；check off tasks from Lock Screen
**Title**：`Lock Screen To-Do List for iPhone — Check Off Tasks Without Opening an App | {{APP_NAME}}`

| # | 区块 | 内容 |
|---|---|---|
| 1 | 首屏 | **H1**：Your to-do list, right on your Lock Screen<br>副标题：See what's next every time you pick up your phone. Tap to check it off. |
| 2 | 为什么要放锁屏 | **H2**：Out of sight, out of mind<br>你一天拿起手机几十次；清单放在锁屏上，就不会被忘掉。 |
| 3 | 锁屏样式 | **H2**：Lock Screen widgets<br>时钟下方两种：矩形（显示接下来几件事，可直接勾选）、圆形（剩余数量）。<br>时钟上方日期那一行还可以放一个单行样式（显示下一件事）——它不在时钟下方的小组件列表里，要点日期那一行才能添加，文案里要写清楚。每种配一张图。 |
| 4 | 设置步骤 | **H2**：How to add it (30 seconds)<br>长按锁屏 → 自定 → 锁屏 → 点时钟下方的小组件区 → 选 {{APP_NAME}}（矩形或圆形）。<br>单行样式：同一界面点**时钟上方的日期** → 选 {{APP_NAME}}。配步骤截图。 |
| 5 | 配合语音 | **H2**：Say it in the morning, see it all day<br>早上说一遍今天的计划 → 一整天都在锁屏上。→ 链 `/guides/plan-your-day-in-2-minutes` |
| 6 | FAQ | 1. Is there an iPhone app that lets me check off tasks from the Lock Screen? 2. How do I put my to-do list on my Lock Screen? 3. Does it show today's tasks only? （按实际显示规则回答，执行者核对 `WidgetTodoFilter`） 4. Can I add tasks from the Lock Screen? （如实：添加用 Siri 或 Action Button） |
| 7 | 内链 + CTA | → `/iphone-to-do-widget`、`/guides/keep-to-do-list-visible-on-iphone` |

> **已真机确认（2026-11-02，产品负责人）：锁屏勾选不需要先解锁。** 可以写「Check off tasks without unlocking your iPhone」，这是锁屏页的主要卖点之一。

---

### 3.4 桌面小组件 `/iphone-to-do-widget`

**目的**：接住「想在桌面看到待办」的搜索。
**主搜索**：todo list app with widgets；iPhone widget for today's tasks
**Title**：`To-Do List Widget for iPhone — Check Off Tasks From Your Home Screen | {{APP_NAME}}`

| # | 区块 | 内容 |
|---|---|---|
| 1 | 首屏 | **H1**：A to-do widget you can actually check off<br>副标题：Medium and large Home Screen widgets. Tap the circle, done — no need to open the app. |
| 2 | 两种尺寸 | **H2**：Pick your size<br>中号：最近几件；大号：更多。各配一张图。 |
| 3 | 点一下就完成 | **H2**：Check off without opening the app<br>可交互小组件；点标题进入详情。 |
| 4 | 设置步骤 | **H2**：How to add it<br>长按桌面 → 编辑 → 添加小组件 → {{APP_NAME}}。 |
| 5 | 和锁屏一起用 | → 链 `/lock-screen-to-do-list` |
| 6 | FAQ | 1. Is there a to-do app with an interactive widget? 2. Can I check off tasks from the widget? 3. Is there a small widget? （如实：目前中号和大号） |
| 7 | CTA | 统一组件 |

---

### 3.5 全部功能（事实页）`/features`

**目的**：给搜索引擎和 AI 搜索一个**清楚、可引用的事实清单**；也给想细看的人。不写营销腔，只写事实。
**Title**：`Features, Pricing & Requirements | {{APP_NAME}}`

| 区块（H2） | 内容（简单列表） |
|---|---|
| What it does | 说话 → 拆成多条带日期的待办；手动编辑；个人词库 |
| Capture | App 内录音、Siri、Action Button（支持的机型）、键盘输入 |
| Organize | 截止日期和时间、重复任务（每天/每周几/每月几号/间隔）、提醒、分类、拆小 |
| See & complete | 锁屏小组件（时钟下方：矩形可勾选、圆形；时钟上方日期行：单行）、桌面小组件（中、大，可勾选）、月历视图 |
| Review | 每周复盘流程、完成统计 |
| Calendar | 可选：同步到 Apple 日历、导入日历事件 |
| Languages | English、中文、日本語 |
| Free vs Pro | 表格：Free = 3 voice captures/day；Pro = 100/day；7-day free trial；monthly or yearly。不写价格，写 "Prices vary by region and are shown in the App Store." |
| Privacy | No account；待办存在本机；转写文字经我们的服务器发给 AI 整理，不存档；录音不上传；详见 `/privacy` |
| Requirements | iPhone, iOS 26 or later。不支持 iPad、Mac、Android；暂无多设备同步 |

---

### 3.6 指南列表 `/guides`

- **H1**：Guides for getting things out of your head and done
- 卡片列表：标题 + 一句摘要 + 更新日期。按发布时间倒序。

### 3.7 一期 4 篇指南（执行者出草稿，产品负责人审改后发布）

每篇 1200～1800 词，结构按 `task-seo-website.md` §3.2：**开头 2～3 句直接给答案** → 通用方法 → 一节介绍 {{APP_NAME}} 怎么帮 → 相关文章 + CTA。

| URL | H1 | 开头直接给的答案 | 正文要点 |
|---|---|---|---|
| `/guides/stop-forgetting-things-you-need-to-do` | How to Stop Forgetting Things You Need to Do | 别靠记性：想到就立刻记下来（越省事越好），再把清单放在一定会看到的地方。 | 为什么会忘（工作记忆有限）；捕捉要快（语音、Siri）；放在看得见的地方（锁屏）；每周清一次 |
| `/guides/plan-your-day-in-2-minutes` | How to Plan Your Day in 2 Minutes (Even If You Hate Planning) | 早上花两分钟把今天的事说一遍，挑出最重要的三件，放在锁屏上。 | 两分钟流程；只挑 3 件；白天随时补；晚上不用整理 |
| `/guides/keep-to-do-list-visible-on-iphone` | How to Keep Your To-Do List Visible on Your iPhone | 用锁屏小组件和桌面小组件，让清单在你每次拿起手机时都出现。 | 系统提醒事项的做法；锁屏小组件；桌面小组件；专注模式下的显示 |
| `/guides/fastest-way-to-capture-tasks-on-iphone` | The Fastest Way to Capture Tasks on iPhone | 最快的是不用打开任何 App：Action Button 或 Siri 一句话。 | 对比：打字 / 系统提醒事项 / Siri / Action Button / 锁屏；各自几秒；推荐组合 |

文章里提到系统自带的「提醒事项」等工具时，要客观介绍，不贬低。

### 3.8 技术支持 `/support`

- **H1**：Support
- 常见问题：怎么添加锁屏小组件；语音识别不准怎么办（检查语言设置、个人词库）；怎么恢复购买；怎么取消订阅（设置 → Apple ID → 订阅）；每天额度什么时候重置；数据存在哪
- 联系方式：邮箱（占位符 `{{SUPPORT_EMAIL}}`）；也可以在 App 里用「反馈」
- 这一页的地址要填进 App Store Connect 的「技术支持网址」

### 3.9 隐私政策 `/privacy`

- 内容**原样迁移**现在的隐私政策（`PRIVACY_POLICY.md` 对应的线上页），不改条款
- 顶部加一段三句话的摘要（与首页隐私区块一致）
- 旧的 GitHub Pages 地址加跳转到新地址（部署步骤里写，App 内链接改动另行处理）

### 3.10 关于 `/about`

- **H1**：Made by one person who forgets things too
- 内容：你是谁（独立开发者）、为什么做这个（真实的个人原因）、做产品的原则（不要账号、不卖数据、不打扰）、联系方式
- 一张真人照片或手绘头像。这一页是作者可信度的来源，**由产品负责人亲自写**，执行者只搭框架、放占位文字

### 3.11 404

- **H1**：This page got lost (we know the feeling)
- 链接：首页、语音、锁屏、指南

---

## 4. 二期、三期页面（先列要点，到时单独出任务书）

| 页面 | 讲什么 |
|---|---|
| `/brain-dump-to-task-list` | H1：Turn a brain dump into a to-do list。说明 brain dump 是什么；**免费网页小工具**（粘贴一段话 → 拆成待办 + 日期，浏览器内运行、不上传）；引导 App |
| `/simple-to-do-list-app` | H1：A simple to-do list that doesn't need setting up。没有项目、标签、看板；打开就能说；对比「功能越多越不想用」 |
| `/to-do-app-without-account` | H1：A to-do list app with no account and no sign-up。不注册；数据在本机；坦白说明没有多设备同步 |
| `/todoist-alternative` | H1：A lightweight alternative to Todoist for daily tasks。事实对比表（适合谁 / 不适合谁）；坦白说明什么情况下 Todoist 更合适 |
| `/adhd-to-do-list` | H1：An ADHD-friendly to-do list: talk, don't type。基于真实用户或自身经验；不做医疗宣称 |
| 二期指南 | brain dump 方法；事情太多从哪开始；为什么清单越堆越多（引出复盘） |
| 三期指南 | 每周复盘模板；ADHD task paralysis（需真实经验） |

---

## 5. 截图和图片需求

| 用途 | 来源 | 现状 |
|---|---|---|
| 录音、确认清单、月历、今天、复盘 | `screenshots/en/01～05` | 已有 |
| **锁屏小组件**：时钟下方的矩形、圆形 + 时钟上方日期行的单行 | 需新截 | **缺** |
| **桌面小组件**（中、大） | 需新截 | **缺** |
| Siri / Action Button 使用 | 需新截或示意 | **缺** |
| 设置步骤（添加小组件） | 需新截 | **缺** |
| OG 分享图 | 构建时按模板生成 | — |

缺的截图由产品负责人在真机上截，执行者先放占位图并在结果文档里列出清单。
