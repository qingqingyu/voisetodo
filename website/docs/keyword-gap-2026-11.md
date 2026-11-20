# 关键词空白调研(2026-11)

> 目的:按 Rasty / Vault Air 的打法,找出「竞品不做网页内容、但用户在搜」的长尾词,决定指南文章的写作顺序。
> 调研日期:2026-11-15 · 状态:**假设清单,待 Search Console 数据验证**

## 0. 方法与局限

- **方法**:4 类共 16 个搜索词,逐个看搜索结果前排是谁。判定标准:
  - 🟢 **空白**:前排是 Apple 社区旧帖、论坛、两年以上的旧博客、厂商小博客 → 有机会。
  - 🟡 **中等**:有一两个像样的页面,但内容过时或角度不对 → 换角度可争。
  - 🟠 / 🔴 **拥挤**:大公司专题页、大站榜单,或者一整屏同类 App → 不主攻。
- **局限**(用数据验证前务必记住):
  1. 用的是网页搜索工具,排序与 Google 实际结果相近但不完全一致。
  2. **没有搜索量数据**,只知道「谁在占这个词」,不知道「多少人搜」。
  3. 只看了英文、美区口径。

## 1. 核心结论

1. **「语音待办 App」品类本身很拥挤。** 搜 "voice to do list app iphone",结果几乎全是 App Store 页面,十几个同类 App(Settle、TaskTalk、Voice Do、Tudo、SmartLists、SpeakToDo…),从 App ID 看大多是这一两年上架的。和 Vault Air 面对的「老对手不做 SEO」不同,这里是**一大群新对手**。
2. **但这些 App 只在 App Store 里竞争,基本不写网页内容。** 搜具体问题时,前排是 Apple 社区旧帖、2022 年前后的博客、零散的厂商博客,没有一个语音待办 App 在认真做内容。**这才是空白。**
3. **最大的空白在「Siri / 系统提醒事项的痛点」。** 一句话说好几件事,Siri 会合并成一条或拆错。Apple 社区抱怨很多,没有官方解法,大家用快捷指令变通。这正是 VoiceTodo 的核心能力(一句话拆成多条、各带日期/重复)。

## 2. 风险与约束

| 风险 | 说明 | 对策 |
|---|---|---|
| **Todoist "Ramble"** | Todoist 有个叫 Ramble 的功能,做的就是「听写 → 拆成多条任务」,其帮助文档占着 "dictate tasks" 一类词 | 文案避免用 "ramble" 一词(`PROMOTION_COPY.md` 的 Subtitle "One ramble. Planned todos." 需要复核是否仍在用);不正面争 "dictate tasks" |
| **苹果在补短板** | iOS 26 提醒事项新增「New Reminder」控件(可放操作按钮/锁屏/控制中心);系统锁屏小组件本来就能勾选完成 | 文章必须**诚实对比**系统能做什么、做不到什么,不写「系统做不到」 |
| **ADHD 文案被检查脚本禁用** | `scripts/checks.mjs` 的禁用规则:`ADHD copy reserved for phase 3 with real experience` | ADHD / brain dump 方向的文章**暂不写**,等三期有真实用户经验后再解禁 |
| **事实边界** | 只写真实能力(`checks.mjs` 禁用说法扫描 + 任务书 §0.2) | 每篇写完跑 `npm run build` + 检查脚本 |

## 3. 逐词结果

| 搜索词 | 前排是谁 | 判定 |
|---|---|---|
| siri add multiple reminders at once | Apple 社区帖、2022 年 iDownloadBlog、The Sweet Setup 快捷指令变通法 | 🟢 **最大空白**,痛点与卖点完全对上 |
| siri reminder merges items into one | MacRumors 论坛、Apple 社区,无官方解法 | 🟢 空白,与上一个合成一篇 |
| recurring reminder by voice (every Mon/Wed/Fri) | 小厂商博客、MacMost 手动设置教程;有来源称 Siri 处理复杂重复不稳定 | 🟢 空白(VoiceTodo 支持按星期/每 N 周/每月某日) |
| how to put to do list on iphone lock screen | 2020 年 Apple 社区帖、GadgetHacks、Things 2022 年博客 | 🟢 内容过时,可写 iOS 26 版;已有 `/lock-screen-to-do-list` |
| check off reminders from lock screen without unlocking | iPhone Life 旧文、Apple 社区误触抱怨 | 🟡 系统小组件也能做到,写成对比 |
| interactive to do widget iphone | 一堆小组件 App + Tom's Guide 写 iOS 17 测试版的旧文 | 🟡 内容过时,中等 |
| apple reminders alternative voice | 一个 pages.dev 小站、AlternativeTo、App Store 页面 | 🟡 中等;**提交 AlternativeTo** 本身就是动作 |
| action button add task iphone | 9to5Mac、Todoist 帮助中心、iOS 26 提醒事项新控件 | 🟡 大站和苹果都在,换「操作按钮放什么最好」角度 |
| turn voice memo into to do list | Taskade、Zapier、PCWorld | 🟠 有大站 |
| brain dump app voice | 一堆 Brain Dump App + Plaud、Spokenly 榜单 | 🔴 拥挤(且受 ADHD 禁用规则影响) |
| brain dump technique adhd | 大量博客与工具站 | 🔴 拥挤,暂不写 |
| adhd to do list app voice | 一堆 ADHD 待办 App + Any.do 博客 | 🔴 拥挤,暂不写 |
| dictate to do list multiple tasks | Todoist Ramble 帮助文档 | 🔴 大公司在占 |
| how to stop forgetting things you need to do | Bustle、MakeUseOf、Routine 等大站 | 🔴 难,且下载意愿弱 |
| voice to do list app iphone | 十几个同类 App 的 App Store 页面 | 🔴 拥挤;已有落地页,保留即可 |
| voicetodo app(品牌词) | "Voices ToDo"、"Speech to Text - Voice Todo"、"Voice Todo List AAKA AI" 等近似名;**无完全同名** | 名字可用,靠统一写法 "VoiceTodo" 建立辨识度 |

## 4. 文章写作顺序

| # | 文章(英文标题) | slug | 对应空白 | 状态 |
|---|---|---|---|---|
| 1 | How to Add Several Reminders at Once on iPhone | `add-several-reminders-at-once-on-iphone` | Siri 一次加多条 / 合并多条 | ✅ 已发布(2026-11-18 翻 draft:false,指向工具①) |
| 2 | How to Set Recurring Reminders by Voice | `how-to-set-recurring-reminders-by-voice-on-iphone` | 语音设复杂重复 | ✅ 已写(draft:true,指向工具②,待审改) |
| 3 | Put a To-Do List on Your Lock Screen (iOS 26) | `keep-to-do-list-visible-on-iphone`(已改版) | 锁屏待办教程过时 | ✅ 已改版(draft:true,重定位 iOS 26,待审改) |
| 4 | What Siri Can't Do With Your To-Do List | `apple-reminders-vs-voice-to-do-apps` | 替代方案 / 系统局限 | ✅ 已写(draft:true,指向工具①②,待审改) |
| 5 | iPhone Interactive To-Do Widgets - 2026 Guide | `interactive-to-do-widgets-iphone-2026` | 小组件教程过时 | ✅ 已写(draft:true,待审改) |
| 6 | Best Things to Put on Your iPhone Action Button | `fastest-way-to-capture-tasks-on-iphone`(已调整) | 操作按钮 | ✅ 已调整(draft:true,换题+补 iOS 26 New Reminder 控件,待审改) |

> 标题定稿与上表拟稿有出入(多为过 60 字符构建限制收敛,#2/#5 拟稿本就未超限,属措辞选择):#2 去掉 "on iPhone"、#3/#6 缩短、#4 改为 "Can't" 单侧 + 描述补全、#5 用连字符。

现有 4 篇草稿的处理:

- `keep-to-do-list-visible-on-iphone`、`fastest-way-to-capture-tasks-on-iphone`:方向对,按上表 #3、#6 调整标题与重点后发布。
- `stop-forgetting-things-you-need-to-do`、`plan-your-day-in-2-minutes`:对应词竞争大、下载意愿弱,**最后发布**,不必急着优化。

## 5. 站外动作

- [ ] 提交 AlternativeTo(挂在 "Apple Reminders alternatives" 下)
- [ ] 提交 Product Hunt
- [ ] Reddit 帖子(见 `PROMOTION_PLAN.md`)里带官网链接

## 6. 用数据验证(接上 Search Console 后)

每条假设对应一个可验证的指标:

| 假设 | 验证方式 | 通过标准(初定,有数据后再调) |
|---|---|---|
| 🟢 词确实有人搜 | GSC「搜索结果」→ 按查询筛选文章对应的词 | 发布 4–6 周内出现曝光 |
| 文章能排上去 | 同上,看平均排名 | 8 周内进入前 20 |
| 排上去能带来点击 | 点击率 | 曝光高、点击率 < 1% → 改 title/description |
| 点击能带来下载 | ASC 分析按 `ct` 参数看来源(需先填真实 `providerToken`) | 每篇文章有可归因的下载 |

验证后回填本文件:把 🟢/🟡 判定改成「已验证 / 已否定」,并记下日期和数据。

## 7. 来源

- 语音待办同类 App:[Settle](https://apps.apple.com/app/id6758559575) · [TaskTalk](https://apps.apple.com/us/app/id6751711332) · [Voice Do](https://apps.apple.com/us/app/id6746357453) · [Tudo](https://apps.apple.com/app/id6757683912) · [SmartLists](https://apps.apple.com/us/app/id6751716229) · [SpeakToDo](https://apps.apple.com/app/id6754497779)
- Todoist Ramble:[Dictate to add tasks with Ramble](https://get.todoist.help/hc/en-us/articles/21532676695580-Dictate-to-add-tasks-with-Ramble) · [Todoist Controls on iOS](https://www.todoist.com/help/todoist/features/use-todoist-controls-on-ios-XZDxdz9y4)
- Siri 多条提醒:[Apple Community: multi-word reminders](https://discussions.apple.com/thread/254558936) · [iDownloadBlog: Siri grocery list](https://www.idownloadblog.com/2022/10/17/siri-grocery-list/) · [The Sweet Setup: Reminders + Shortcuts](https://thesweetsetup.com/reminders-as-my-day-to-day-lifeline-powered-by-shortcuts/) · [MacRumors: Reminders, Siri and "and"](https://spy.macrumors.com/threads/reminders-siri-and-the-use-of-and.2207544) · [Apple iPhone User Guide: Add reminders](https://support.apple.com/en-kg/guide/iphone/add-reminders-iph88463e18/14.0)
- 语音设重复:[MacMost: repeating reminders](https://macmost.com/creating-regular-repeating-reminders.html) · [yougot.ai: voice reminders](https://www.yougot.ai/blog/technology/setup-guides/how-do-i-use-voice-to-set-reminders-on-iphone)
- 锁屏待办:[Apple Community: to-do list on lock screen](https://discussions.apple.com/thread/251684042) · [GadgetHacks](https://smartphones.gadgethacks.com/how-to/pin-reminders-your-iphones-lock-screen-so-you-stop-forgetting-things-0141397) · [Things: Lock Screen widgets (iOS 16)](https://culturedcode.com/things/blog/2022/09/lock-screen-widgets-for-ios-16) · [iPhone Life: complete from Lock Screen](https://iphonelife.com/blog/32671/tip-day-how-snooze-or-mark-reminders-complete-your-lock-screen) · [Apple Community: accidental ticking](https://discussions.apple.com/thread/255149241)
- 小组件:[Tom's Guide: iOS 17 interactive widgets](https://www.tomsguide.com/how-to/how-to-use-interactive-widgets-on-the-iphone)
- 操作按钮:[9to5Mac: iOS 26 Reminders](https://9to5mac.com/2025/10/28/ios-26-gives-apples-reminders-app-a-new-faster-way-to-add-tasks/) · [MacRumors: new reminder with single tap](https://www.macrumors.com/how-to/create-new-reminder-single-tap-ios/)
- 替代方案:[Stay Composed: Apple Reminders alternatives](https://staycomposed.pages.dev/alternatives/apple-reminders) · [AlternativeTo](https://alternativeto.net/software/apple-reminders/?p=2)
- 拥挤词:[Taskade](https://www.taskade.com/convert/tasks/voice-memo-to-task-list) · [PCWorld](https://www.pcworld.com/article/3187055/this-chatgpt-prompt-turns-rambling-voice-memos-into-clean-to-do-lists.html) · [Plaud](https://www.plaud.ai/blogs/articles/best-brain-dump-apps) · [Spokenly](https://spokenly.app/blog/brain-dump-app) · [Any.do](https://www.any.do/blog/the-best-to-do-list-app-for-adhd-how-to-stay-organized-when-your-brain-fights-structure/) · [MakeUseOf](https://www.makeuseof.com/stop-forgetting-things-at-work/) · [Routine](https://routine.co/blog/posts/how-to-stop-forgetting-things)
- 品牌近似名:[Voices ToDo](https://apps.apple.com/mz/app/voices-todo/id1559364884) · [Speech to Text - Voice Todo](https://apps.apple.com/lc/app/speech-to-text-voice-todo/id6755744642) · [Voice ToDo List AAKA AI](https://appshunter.io/ios/app/voice-todo-list-aaka-ai/id6751731333)
