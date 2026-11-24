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
| `<commit-4>` | `docs(tools): 审计修复结果文档`(本文件初稿) |
| `<commit-5>` | `fix(web-tools): 双 review 循环收敛修复(6 轮,16+7 项)`——同源表单闸、isValidModelRule、形状校验/归一化、自适应展开上限、weekly 窗口公式等(见 §4.5);§3 测试数以本提交后的口径为准 |

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
   匹配日等价);weekly+weekdays+interval>1 按 App `occurs()` 的 weekDiff 窗口公式
   (窗口内所有 weekdays 都出现);end_date 截断;迭代上限自适应(保底 400 步,按
   count×周期放大,硬顶 5000 步防畸形规则拖垮 Function)。结果卡「接下来 N 次」按
   实际展开条数说,一条都没有明说,不渲染空列表;混合短语里没有重复规则的任务
   也会如实列出(「Also kept as plain task(s) without a repeat」),与「无重复」
   分支同一口径。另加 `isValidModelRule` 闸门
   (镜像 Swift 严格解码 + isValid):App 会丢弃的畸形规则(weekly 空 weekdays、
   monthly 越界日号、非整数 interval/weekdays)一律判无效,走「无重复」诚实页。
2. **时区默认 UTC(必修)**:两个工具页下拉新增默认项「Auto — detected from your
   connection」;`resolveFormTimezone`('auto' → 服务端 `request.cf.timezone`,Intl 校验,
   失败回落 UTC;显式选项仍走白名单)。X-Local-Date 按解析出的时区计算,代理侧漂移
   校验不受影响。美西傍晚 "tomorrow" 不再错一天。
3. **日期 basis 过滤(应修)**:`split.js` 的 `whenText` 按 App 端
   `applyDueDateBasisFilter`(SwiftDataModels.swift:425)同口径过滤:`due_date_basis` 非
   `user_explicit` 不显示日期;钟点/时段/提醒照常(App 端清日期时保留这两样)。
   结果页底部那句「saved with the dates shown above」保留(镜像后不再整批超承诺;
   残余个例偏差见 §4.1)。
4. **IPv6 /64 绕限(应修)**:`webClientIp` 对含 `:` 的地址先过 `expandIpv6` 完整语法
   校验,合法则折叠到 /64 前缀再做哈希(支持 :: 压缩与段内嵌 IPv4;内嵌 IPv4 只允许
   在地址最末段);IPv4-mapped(前 5 组全 0 + 第 6 组 ffff)特判用其 IPv4 部分按 IPv4
   粒度(否则所有 mapped 地址折进同一桶);畸形地址归 anonymous 共享桶(既有收紧
   口径,含点但非 mapped 形状的畸形也不例外)。
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

- 官网 Functions:`npm run test:functions` —— **执行 72 / 失败 0**(原 28 + 新增 44:
  recur-check 全新 19 条、split 新增 7 条(basis/tz 4 + 上游形状 2 + 同源表单闸 1)、
  modelRuleOccurrences/有效性闸门 18 条;含展开数不足按实际条数说 / 空列表明说 /
  合法 JSON 形状不对显式 502 / 非对象 todos 元素归一化 / 非字符串 title 不渲染
  [object Object] / App 会丢弃的畸形规则(weekly 空 weekdays、monthly 越界日号、
  非整数 interval/weekdays)判无效走「无重复」诚实页 / 跨站 Origin 拒 403 /
  零任务走「Nothing to check」不谎报「No repeat」 /
  UTC+12+ 时区(Auckland)锚点自适应不晚一天不漏首次)。
- 代理:`cd AIProxy && npm test` —— **执行 461 / 失败 0**(原 455 + 新增 6:
  /64 折叠 ×3、token 比较语义 ×1、含点非 mapped 畸形 IPv6 归 anonymous ×1、
  内嵌 IPv4 放中间/出现两次归 anonymous ×1)。
- 官网构建:`npm run build`(astro build + og-images + checks)—— **21 页全部通过**。
- 审计报告口径的「代理 455 用例、Functions 28 用例」在本分支分别增至 461 / 72。

## 4. 与审计不一致 / 自己做的判断

1. **basis 过滤选了审计给的简化口径**(非 user_explicit 一律不显示日期),没有移植
   Swift 的 `hasExplicitTimeCue` + transcript 兜底重算。两个已知偏差(都要移植整段
   cue 探测器才能消除,任务书级取舍记在这里):
   - user_explicit 但 transcript 无时间线索:App 清日期,网页仍显示 —— 网页多显示,
     残留个例超承诺;
   - title_mention/inferred/nil 且 transcript 有 cue:App 按 transcript 重算日期保留,
     网页隐藏 —— 网页少显示,不构成超承诺(重算结果可能与模型日期不同)。
2. **「接下来五次」的 interval 锚**:App 锚任务首个 dueDate;检查器没有任务,取第一个
   匹配日。展示口径差异已写进 `modelRuleOccurrences` 注释与页面文案。
2a. **结构化截止 `recurrence_end` 未展开**:契约上模型把重复终点放顶层
   `recurrence_end`(after_count/month_end,客户端确定性算日期),检查器只支持
   `recurrence_rule.end_date`(契约上恒 null,但客户端对它是绝对优先,模型给了就截断)。
   有界重复按无界展示「接下来五次」;终点截进前五时网页多显示。页面结果卡已有
   「确认后才会保存」兜底;完整展开需移植 App 端 RecurrenceEndResolver,未做。
2b. **monthly/daily interval>1 与 App 端既有张力**:检查器 monthly 按日历月差、
   daily 按 N 天步长过滤(与模型契约「每三天/每三个月」、与 App 的系统日历镜像
   一致);但 App 端 `RecurrenceRule.occurs(on:startDate:)` 对 monthly/daily 都
   忽略 interval(App 内部 in-app 展开与日历镜像两边不一致,App 侧既有问题,
   不属本分支)。weekly interval>1 则已对齐 App 的 weekDiff 窗口公式(锚点后
   同一个 7 天窗口内的所有 weekdays 都出现)。
3. **本地解析器代码保留**(只退出展示面):它与 Swift v1 的对照测试锁着两边行为,
   删掉会丢这层对照。
4. **`readForm` 错误文案合并**:lib 化后「非表单提交」与「表单解析失败」统一成一条
   文案(两者都是 400,用户可分辨性不受影响)。
5. **同源表单闸(双 review 追加,超审计范围)**:两个工具端点新增 `isSameOriginForm`
   —— Origin 头存在且与 request.url 的实际源不一致时 403(缺失放行,fail-closed 于
   解析失败)。防第三方页面借访客浏览器自动 POST 烧掉访客 IP 的共享配额;按实际源
   比较,主域/pages.dev 旧域/preview 部署自动全部正确。工具端点无 cookie 无会话,
   这是反 CSRF 的最小形式。
6. **#5 providerToken 与 Pages 接 Git** 不是代码能完成的项,本分支只留配置点与待办。
7. **零任务诚实页 + lastmod(全局双 review 追加)**:上游 200 但 `todos` 为空时,
   recur-check 走专门的「Nothing to check」页(与 split.js「No tasks found」同口径),
   不再说「No repeat in this phrase」—— 那句暗示解析到了任务、只是不重复;
   两个工具页的 `pages.mjs lastmod` 从 2026-11-18 提到 2026-11-24(页面内容在本分支
   被实质改写,sitemap lastmod 直接消费该字段,不更新会向爬虫谎报「未变更」)。
8. **UTC+12+ 时区锚点自适应(全局双 review 追加,超审计范围)**:`modelRuleOccurrences`
   原固定从 k=1(锚点次日)起算,但 UTC 正午锚在偏移 ≥ +12 的时区(白名单内唯一
   Pacific/Auckland,+12 冬 / +13 夏)已是本地「明天」——全部日期整体晚一天,
   且 weekly 命中明天的规则漏报真实首次(node 实测修前 daily next3 = 11-20/21/22、
   weekly-Thu = 11-26,应分别为 11-19/20/21、11-19)。修法:按锚点实际本地 iso
   自适应起始步数(`startK`,+12+ 时区取 0 其余取 1),daily/weekly 节奏锚相对
   startK;全白名单 45 时区 + 6 个非白名单极端时区(Kiritimati +14、Pago_Pago -11、
   Chatham +13:45 等)实测 daily 首个未来日均严格 = 明天。既有 `nextOccurrences`
   (基线代码,已无生产调用方,仅剩与 Swift v1 的对照测试在用)同款锚缺陷,
   不在本分支 diff 内,记为后续项未动。

## 5. 部署提醒(与代码分离的运维项)

- 代理改动(worker.js)需 `wrangler deploy` 才生效(惯例由用户执行)。
- 官网改动需 Pages 重新构建/部署(当前生产是本机直传,`--branch main` 口径)。
- 两个工具页新增 Auto 时区依赖 `request.cf.timezone`,Pages 运行时原生提供,无需配置。
