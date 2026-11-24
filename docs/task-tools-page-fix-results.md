# 结果文档:工具页/代理 web 档审计修复

> 输入:外部审计报告(2026-11-24,「代理 web 档鉴权/IP 限流/全局预算 + 工具页 6 项」)。
> 上一轮背景:`docs/task-seo-website-results.md`。
> 分支:`task/tools-page-fix`,基线 `main` @ `4817003`。

## 1. 提交

| 提交 | 内容 |
|---|---|
| `<commit-1>` | `feat(web-tools): 工具②改走 AI 解析 + 时区 Auto + 日期 basis 过滤` |
| `<commit-2>` | `fix(proxy): web 档 IPv6 /64 折叠 + token 常数时间比较` |
| `<commit-3>` | `content(guides): 发布两篇指南,更正检查器描述` |
| `<commit-4>` | `docs(tools): 审计修复结果文档`(本文件) |

(hash 自引用不可行,见月历修复轮结果文档 §6.6 同款处理:以分支 HEAD 逐个对应。)

## 2. 逐项落地情况(按审计编号)

1. **工具②改走 AI 提取(必修)**:`recur-check.js` 重写为调用与工具①同一条上游
   (`/v1/web/todo-extractions`),只渲染响应中的重复规则(`describeModelRecurrence`)与
   「接下来五次」(新增 `modelRuleOccurrences` 展开模型规则:支持 interval/weekdays/
   day_of_month/end_date)。共用每天 3 次额度(X-Web-Client-IP 转发口径不变)。
   模型没给重复规则时诚实展示「No repeat in this phrase」并列出会被建成普通任务的标题,
   不再用本地解析器编规则;本地 `resolveRecurrence`/`describeRule` 保留在 lib(与 Swift
   RecurrenceResolver 的对照测试仍在),只是不再对外展示。工具②页文案同步:chips 区
   从「本地确定性解析器认识这些」改为「AI 解析示例」,配额提示改为共用。
   `modelRuleOccurrences` 口径:起点严格晚于今天(与既有 nextOccurrences 一致);
   interval>1 以第一个匹配日为锚(App 端锚任务首个 dueDate,检查器没有任务,取第一个
   匹配日等价);end_date 截断;迭代上限 400 步防畸形规则死循环。
2. **时区默认 UTC(必修)**:两个工具页下拉新增默认项「Auto — detected from your
   connection」;`resolveFormTimezone`('auto' → 服务端 `request.cf.timezone`,Intl 校验,
   失败回落 UTC;显式选项仍走白名单)。X-Local-Date 按解析出的时区计算,代理侧漂移
   校验不受影响。美西傍晚 "tomorrow" 不再错一天。
3. **日期 basis 过滤(应修)**:`split.js` 的 `whenText` 按 App 端
   `applyDueDateBasisFilter`(SwiftDataModels.swift:425)同口径过滤:`due_date_basis` 非
   `user_explicit` 不显示日期;钟点/时段/提醒照常(App 端清日期时保留这两样)。
   结果页底部那句「saved with the dates shown above」保留(镜像后不再超承诺)。
4. **IPv6 /64 绕限(应修)**:`webClientIp` 对含 `:` 的地址折叠到 /64 前缀再做哈希
   (`ipv6Prefix64`,支持 :: 压缩与内嵌 IPv4);IPv4-mapped 特判用其 IPv4 部分按 IPv4
   粒度(否则所有 mapped 地址折进同一桶);畸形地址归 anonymous 共享桶(既有收紧口径)。
5. **providerToken 占位(应修)**:`website/src/config.mjs:15` 的 `pt` 是 App Store Connect
   的来源参数,**真实值只能由账号持有者在 ASC 生成**(App 分析 → 来源参数),代码侧
   无法代办。本分支未改动该行;拿到 pt 后改一处 + `npm run build` 即全站生效(该值的
   人工步骤已在 tools-pages 落地文档列为 ASC token 项)。**待用户提供**。
6. **指南未收录(应修)**:`how-to-set-recurring-reminders-by-voice-on-iphone`(工具②
   配套)与 `apple-reminders-vs-voice-to-do-apps`(指向工具①)翻 `draft:false`。发布前
   更正了前文与工具②新行为不符的段落(原稿「local repeat rules — no AI involved」,
   现改述为「runs the same AI parse the app runs + 共享配额」)。`npm run build` 的
   sitemap/索引检查随发布自动覆盖(21 页全过)。
7. **小问题**:
   - `validateWebToken` 的 `===` 改为逐字节异或常数时间比较(`timingSafeEqualString`,
     长度差参与 diff;Bearer 前缀形式保留)。
   - 「Sat and Sun every week → Every Sunday and Saturday」:工具②切 AI 后此问题随本地
     解析器一起退出展示面(模型给的 weekdays 顺序即展示顺序),无需单独修。
   - Pages 未接 Git:运维项,需在 Cloudflare 控制台把 Pages 项目连到 GitHub 仓库,
     代码侧无法代办,记录待办。

## 3. 测试

- 官网 Functions:`npm run test:functions` —— **执行 53 / 失败 0**(原 28 + 新增 25:
  recur-check 全新 12 条、split basis/tz 4 条、modelRuleOccurrences 9 条)。
- 代理:`cd AIProxy && npm test` —— **执行 459 / 失败 0**(原 455 + 新增 4:
  /64 折叠 ×3、token 比较语义 ×1)。
- 官网构建:`npm run build`(astro build + og-images + checks)—— **21 页全部通过**。
- 审计报告口径的「代理 455 用例、Functions 28 用例」在本分支分别增至 459 / 53。

## 4. 与审计不一致 / 自己做的判断

1. **basis 过滤选了审计给的简化口径**(非 user_explicit 一律不显示日期),没有移植
   Swift 的 `hasExplicitTimeCue` + transcript 兜底重算。已知偏差:App 对 user_explicit
   但 transcript 无时间线索的日期也会清,网页仍显示;方向是「多显示」而非「超承诺
   日期」,且需要整段日期解析器才能消除,任务书级取舍记在这里。
2. **「接下来五次」的 interval 锚**:App 锚任务首个 dueDate;检查器没有任务,取第一个
   匹配日。展示口径差异已写进 `modelRuleOccurrences` 注释与页面文案。
3. **本地解析器代码保留**(只退出展示面):它与 Swift v1 的对照测试锁着两边行为,
   删掉会丢这层对照。
4. **`readForm` 错误文案合并**:lib 化后「非表单提交」与「表单解析失败」统一成一条
   文案(两者都是 400,用户可分辨性不受影响)。
5. **#5 providerToken 与 Pages 接 Git** 不是代码能完成的项,本分支只留配置点与待办。

## 5. 部署提醒(与代码分离的运维项)

- 代理改动(worker.js)需 `wrangler deploy` 才生效(惯例由用户执行)。
- 官网改动需 Pages 重新构建/部署(当前生产是本机直传,`--branch main` 口径)。
- 两个工具页新增 Auto 时区依赖 `request.cf.timezone`,Pages 运行时原生提供,无需配置。
