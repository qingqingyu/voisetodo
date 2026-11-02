# 任务书：产品官网（英文，带完整 SEO 功能）——关键词规划 + 网站结构 + 建站

> 2026-11-02 起草。本文档同时是**关键词规划**和**交给执行者的建站任务书**。
> 完成后把结果写进 `docs/task-seo-website-results.md`（格式见 §10），交回审查。
> **页面内容规格**（每页讲什么、区块和文案方向）见 `docs/task-seo-website-pages.md`，两份一起执行。

---

## 0. 前提和红线

### 0.1 动手前必须先定（产品决定，执行者用占位符先做）

| 占位符 | 含义 | 现状 |
|---|---|---|
| `{{APP_NAME}}` | 产品名 | 未定（VoiceTodo / Unpile） |
| `{{DOMAIN}}` | 域名 | 未买，名字定了再买 |
| `{{APP_STORE_URL}}` | App Store 链接 | 上架后才有 |

占位符集中放在一个配置文件里，定下来后改一处全站生效。

### 0.2 只写产品真实具备的能力

官网文案**只能写下表左列**。右列一律不写，哪怕关键词里有。

| ✅ 可以写（已在代码里核实） | ❌ 不能写 |
|---|---|
| 一句话说出好几件事，自动拆成多条带日期的待办 | 「无限次」（Pro 是每天 100 次） |
| 支持 Siri、Action Button（支持的机型）、主屏幕小组件（中/大） | 「完全免费」（只能写 free to start：每天 3 次语音录入，Pro 7 天免费试用） |
| **锁屏小组件，可直接勾选完成**（`LockscreenRectangularWidget` 带勾选） | 「多设备同步 / iPad / Mac / Android」（都没有） |
| 不需要注册账号 | 「完全离线」（AI 整理需要联网；没网时先存下，联网后再整理） |
| 待办存在你的 iPhone 上；语音转成的文字会发给 AI 整理，**不存档** | 「数据从不离开手机」（转写文字会经服务器发给 AI） |
| 重复任务、提醒、截止日期、每周复盘 | 任何医疗宣称：「治疗 / 改善 ADHD」「临床验证」 |
| 英文、中文、日文 | 价格写死（各地区不同，写「Free to start, Pro available」，不写具体金额） |
| 要求：iPhone，iOS 26 及以上 | |

ADHD 相关页面只用「ADHD-friendly」「for scattered minds」这类说法。
健康类内容谷歌按高标准（YMYL）审，必须真实、有作者署名，**禁止用 AI 批量生成文章**。

---

## 1. 定位：从「用户的问题」切入，不从「工具品类」切入

全站主信息（首页首屏用）：

> **Say your plan once. See it on your Lock Screen all day.**
> Speak everything on your mind — {{APP_NAME}} turns it into a clean checklist with the right dates, and lets you check things off right from your Lock Screen. No account. No typing.

三条支撑卖点，按优先级：

1. **不用打字**：说一句话，拆成多条、排好日期（对应「我不想手动输入」）
2. **一直看得见**：锁屏和桌面小组件，不打开 App 也能看、能勾（对应「计划了但白天会忘」）
3. **待办不越堆越多**：每周复盘把拖着的事处理掉（对应「事情很多不知从哪开始」）

---

## 2. 关键词分组 → 页面

优先级依据：P1 = 直接体现我们的差异（语音输入、锁屏可见）；P2 = 需求明确但竞争较激烈；P3 = 痛点抽象或竞争极激烈。

### 2.1 落地页（Landing pages）

| 优先级 | URL | 主关键词 | 次关键词 / 用户原话 | 搜索意图 |
|---|---|---|---|---|
| P1 | `/` | voice to do list app for iPhone | AI voice to do list app；todo app no typing；Is there a to-do list app where I can just tell it what I need to do | 找产品 |
| P1 | `/voice-to-do-list` | voice activated todo list app | can I create a to-do list using my voice；todo app that doesn't require typing；fastest way to capture tasks on iPhone | 找功能 |
| P1 | `/lock-screen-to-do-list` | iPhone lock screen to do list app | lock screen task manager for iPhone；check off tasks from Lock Screen；how can I keep my to-do list visible on my iPhone | 找功能 |
| P1 | `/iphone-to-do-widget` | todo list app with widgets | iPhone widget for today's tasks；check off tasks without opening the app | 找功能 |
| P1 | `/brain-dump-to-task-list` | brain dump to task list | turn messy thoughts into a to-do list；organize everything in my head（第二阶段放免费小工具，见 §5） | 解决问题 |
| P2 | `/simple-to-do-list-app` | simple todo list app | todo app that doesn't require a lot of setup；lightweight to do list；minimal todo app iPhone | 比较产品 |
| P2 | `/to-do-app-without-account` | todo app without account | no sign up to do list；private to do list app iPhone | 比较产品 |
| P2 | `/todoist-alternative` | lightweight Todoist alternative | I don't need a full project management tool；simple alternative to Todoist | 比较产品 |
| P2 | `/adhd-to-do-list` | to do list app for ADHD | ADHD brain dump app；ADHD-friendly planner app（措辞按 §0.2） | 解决问题 |
| P3 | `/features` | — | simple recurring tasks app；todo app with due dates；todo app with reminders | 事实页（见 §4.3） |

对比页（`/todoist-alternative`）只写可核实的事实对比，不贬低对方，不使用对方 logo。

### 2.2 指南文章（`/guides/…`，回答「问题型」搜索）

| 优先级 | URL | 对准的问题 | 引向 |
|---|---|---|---|
| P1 | `/guides/stop-forgetting-things-you-need-to-do` | How can I stop forgetting things I need to do? / best app to remember daily tasks | 锁屏页、语音页 |
| P1 | `/guides/plan-your-day-in-2-minutes` | best app for planning my day / I make plans every morning but forget them | 首页 |
| P1 | `/guides/keep-to-do-list-visible-on-iphone` | How can I keep my to-do list visible on my iPhone? | 锁屏页、小组件页 |
| P1 | `/guides/fastest-way-to-capture-tasks-on-iphone` | fastest way to capture tasks on iPhone（Siri / Action Button / 小组件对比） | 语音页 |
| P2 | `/guides/brain-dump` | how to brain dump / brain dump template | brain dump 页 |
| P2 | `/guides/too-many-tasks-where-to-start` | I have too many tasks, where do I start? / busy but nothing gets done | 首页 |
| P2 | `/guides/why-your-to-do-list-keeps-piling-up` | to do list keeps growing / overwhelmed by to-do list | 复盘功能 |
| P3 | `/guides/weekly-review-template` | weekly review template | 复盘功能 |
| P3 | `/guides/adhd-task-paralysis` | ADHD task paralysis（需真实经验，按 §0.2） | ADHD 页 |

### 2.3 必备页面

| URL | 说明 |
|---|---|
| `/support` | App Store「技术支持网址」要用；常见问题 + 联系方式 |
| `/privacy` | 隐私政策，内容迁自现在的 GitHub Pages（`PaywallLegal.privacyPolicyURL`），旧地址加跳转 |
| `/about` | 独立开发者介绍：真实的人、为什么做这个（作者可信度，E-E-A-T） |
| `/404` | 自定义 404，带回首页和主要页面的链接 |

---

## 3. 每页的内容规格

### 3.1 落地页模板

1. **H1**：直接写主关键词对应的问题或承诺（如 `/voice-to-do-list` → "A to-do list you can just talk to"）
2. **首屏一句话说明 + App Store 按钮**
3. **场景段**：用用户原话描述问题（来自 §2 次关键词）→ 我们怎么解决
4. **3 张真实截图**（或短视频），带说明文字和 alt 文本
5. **怎么做到的**：3 步（说话 → 自动拆分排期 → 在锁屏上勾选）
6. **FAQ**：4～6 条，**问题直接用用户会问 ChatGPT 的原话**（§2 次关键词），答案第一句就给结论，2～3 句说完
7. **底部 CTA** + 链到 2～3 个相关页面

字数 600～1200 词。不堆关键词：主关键词在 title、H1、首段、一个 H2、alt 中自然出现即可。

### 3.2 指南文章模板

1. 标题直接是问题或答案（如 "How to Stop Forgetting Things You Need to Do (Without Another Complicated System)"）
2. **开头 2～3 句直接给答案**（AI 搜索最常引用这一段）
3. 正文给通用可行的方法（不只是推销），其中一节自然介绍 {{APP_NAME}} 怎么帮到
4. 作者署名 + 发布 / 更新日期
5. 相关文章 + CTA

### 3.3 文案约束

- 第一批文章由执行者起草，**产品负责人逐篇审改后才发布**；不批量生成。
- 不出现 §0.2 右列的说法。
- 美式英语。

---

## 4. SEO 功能（技术要求）

### 4.1 站点

- **静态生成**：Astro（或同类静态站生成器），输出纯静态 HTML，默认零客户端 JS。
- **托管**：Cloudflare Pages（项目已在用 Cloudflare）。
- **位置**：本仓库新建 `website/` 目录，不影响 App 和代理的构建。
- **URL**：全小写、连字符、无尾斜杠（全站统一一种）；每页带 canonical。
- **多语言预留**：目录结构按 `/`（英文）、`/ja/`、`/zh/` 设计，这次只做英文；hreflang 生成逻辑先写好，只有一种语言时不输出。

### 4.2 每页 `<head>`（由布局组件统一生成，页面只填数据）

- `<title>`：≤ 60 字符，每页唯一，格式 `主关键词短语 | {{APP_NAME}}`
- `meta description`：≤ 155 字符，每页唯一，含主关键词和一个具体好处
- canonical、Open Graph（title / description / image / url）、Twitter Card
- **每页一张 OG 图**（1200×630），构建时按模板自动生成
- **Apple Smart App Banner**：`<meta name="apple-itunes-app" content="app-id=…">`（App ID 用占位符）
- `theme-color`、favicon、apple-touch-icon

### 4.3 结构化数据（JSON-LD）

| 页面 | 类型 |
|---|---|
| 全站 | `WebSite`、`Organization`（或 `Person`，独立开发者） |
| 首页、`/features` | `MobileApplication`：name、operatingSystem「iOS 26 or later」、applicationCategory `ProductivityApplication`、offers（price 0 + 说明含内购）、inLanguage |
| 含 FAQ 的页面 | `FAQPage`（与页面上可见的 FAQ 内容完全一致） |
| 指南文章 | `Article`（author、datePublished、dateModified、image） |
| 所有二级页 | `BreadcrumbList` |

`/features` 是**事实页**：平台要求、全部功能、免费与 Pro 的区别、支持语言、隐私要点，用简单列表写清楚。
AI 搜索推荐产品时最依赖这种清楚、可引用的事实。

### 4.4 抓取与收录

- 自动生成 `sitemap.xml`（含 lastmod），`robots.txt` 指向它
- `robots.txt` **允许** AI 搜索爬虫（`OAI-SearchBot`、`GPTBot`、`PerplexityBot`、`ClaudeBot`、`Google-Extended`）：我们希望被 AI 搜索推荐
- 可选：根目录放一份 `llms.txt`，用几行概述产品和主要页面（成本很低）
- 部署说明里写明：接入 **Google Search Console** 和 **Bing Webmaster Tools**（ChatGPT 搜索大量依赖必应的索引），开启 Cloudflare 的 IndexNow / Crawler Hints

### 4.5 性能与可访问性

- 移动端 Lighthouse：Performance ≥ 95、SEO = 100、Accessibility ≥ 95、Best Practices ≥ 95
- 图片：AVIF/WebP + 宽高属性 + 懒加载（首屏图除外）；字体自托管或用系统字体
- 所有图片有描述性 alt；语义化标题层级（每页一个 H1）

### 4.6 内链

- 每篇指南至少链到 1 个落地页和 1 篇相关指南
- 每个落地页链到 2～3 个相关页面
- 页脚：主要落地页、指南列表、支持、隐私、关于

### 4.7 统计（不需要 Cookie 弹窗）

- **Cloudflare Web Analytics**（无 Cookie）看访问量
- **每个页面的 App Store 链接带来源参数**：`?pt={{PROVIDER_TOKEN}}&ct=<页面标识>`（如 `ct=web-lock-screen`），这样 App Store Connect 的「App 分析」里能看到每个页面带来多少下载
- 不接任何第三方追踪脚本

---

## 5. 免费小工具：Brain dump → 待办清单（第二阶段）

页面 `/brain-dump-to-task-list` 第二阶段加入一个网页小工具：

- 用户粘贴或输入一段话，页面拆成一条条待办，标出识别到的日期（"next Friday" → 具体日期）
- **完全在浏览器里运行**：规则解析（英文先行），不调用任何服务器，不存储输入
- 结果可勾选、可复制；下方 CTA：「Want this from your voice, on your Lock Screen? Get {{APP_NAME}}」
- 用 `AIProxy/eval/` 里的英文评测句子做测试
- 本阶段**只规划，不实现**；单独出任务书

---

## 6. 分阶段

| 阶段 | 时间 | 内容 |
|---|---|---|
| **一（本任务）** | 上线前后 | 站点框架 + §4 全部 SEO 功能；页面：首页、3 个 P1 落地页（语音、锁屏、小组件）、`/features`、`/support`、`/privacy`、`/about`、`/404`；4 篇 P1 指南（只出草稿，等审） |
| 二 | 上线后 1～2 个月 | brain dump 小工具；P2 落地页；P2 指南 |
| 三 | 有数据后 | ADHD 页和文章（需真实经验）、对比页、日文版 / 中文版 |

---

## 7. 衡量（写进 `website/README.md`）

每月看一次：

- Search Console：每组关键词（§2）的曝光、点击、平均排名；哪些问题型搜索在带来点击
- App Store Connect：按 `ct` 看各页面带来的下载
- 哪些页面有曝光没点击 → 改 title 和 description；有点击没下载 → 改页面内容

---

## 8. 执行约束

- 从最新 `main` 拉新分支（名字自定），**不要直接在 main 上改**；推送后交回审查，**不合 main**。
- **不部署、不买域名**；在结果文档里写清部署到 Cloudflare Pages、接入 Search Console / Bing 的步骤。
- 不改 App 和代理的任何代码；隐私政策只迁移内容，不改条款（App 里的链接改动另行处理）。
- 截图用真实 App 截图（`screenshots/en/`），不用生成的假界面。
- 提交信息里不要出现模型名称。

---

## 9. 验收

- `website/` 能本地构建，产物为纯静态文件。
- 移动端 Lighthouse 达到 §4.5 的分数（每类页面各测一个，附截图）。
- 每页 title / description 唯一且不超长（写一个构建时检查脚本，超长或重复则构建失败）。
- 结构化数据用 Schema.org 校验器和 Google 富媒体搜索测试检查通过（附结果）。
- `sitemap.xml` 包含所有页面；`robots.txt` 符合 §4.4。
- 全站 App Store 链接都带 `ct` 参数（构建时检查）。
- 全文搜索确认没有 §0.2 右列的说法（unlimited、free forever、offline、sync、Android、iPad、cure、treat 等关键词检查）。

---

## 10. 结果格式（`docs/task-seo-website-results.md`）

1. 技术选型和目录结构。
2. 页面清单：URL、title、description、主关键词。
3. Lighthouse 分数和结构化数据校验结果。
4. 4 篇指南草稿的位置（标明「待审」）。
5. 部署与接入步骤（Cloudflare Pages、域名、Search Console、Bing、IndexNow、App Store 来源参数）。
6. 偏离任务书的地方及理由（没有就写「无」）。
