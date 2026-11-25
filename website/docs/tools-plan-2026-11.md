# 工具页计划(2026-11,已落地)

> 背景:软启动硬指标是 4 周内 install→Pro 转化 ≥5%(project_gtm_soft_launch)。
> 工具页的任务是给这个漏斗前端送安装量,不是单独开一条业务线。
> 关键词依据:`docs/keyword-gap-2026-11.md` §3 —— 两个 🟢 空白词:
> `siri add multiple reminders at once` 与 `recurring reminder by voice`。
> (brain dump 方向已否决:🔴 拥挤 + checks.mjs 禁用 ADHD 文案。)

## 落地内容

### 阶段 1:技术底座 ✅

**零 JS 交互方案(拍板:表单,不加 JS 白名单)**

- 工具页 = 静态 Astro 页 + 原生 `<form method="post">` → Pages Function
  (`functions/api/split.js` / `functions/api/recur-check.js`)服务端渲染结果页。
- 全站继续零客户端 JS,checks.mjs 验收规则不变(第 9 条照旧全绿)。
- 结果页(`functions/lib/render.mjs`)不经过 Astro 构建,checks.mjs 扫不到,
  靠同一套纪律手工维持:无 `<script>`、App Store 链接带 pt+ct、不用禁用说法。
- 时区:零 JS 读不到浏览器时区 → 原生 `<select>`(`functions/lib/timezones.mjs`
  白名单,47 个常用 IANA 区,默认 UTC)。拆句工具把它折算成 `X-Local-Date`
  转发代理(代理侧 resolveQuotaDate 有漂移校验);重复检查器直接在此时区算
  「接下来 5 次」。

**代理 web 档(AIProxy/,独立于 App 档)**

- 新路由 `POST /v1/web/todo-extractions`:
  - 鉴权:`X-Web-Token`(secret,`wrangler secret put WEB_EXTRACT_TOKEN`),
    与官网 Pages Function 共享,浏览器拿不到。与 APP_TOKEN 分离;无
    ALLOW_UNAUTHENTICATED_PROXY 逃生门,fail-closed。
  - 客户端 IP:Pages Function 转发访客 `CF-Connecting-IP` 到
    `X-Web-Client-IP`(代理自己看到的 CF-Connecting-IP 是 Pages 出口,全网共享)。
  - 闸门(全部 web 命名空间,与 App 档互不影响):
    每 IP 每天 3 次(`WEB_IP_DAILY_LIMIT`,默认 3=App 免费档同口径);
    每分钟 6 次(`WEB_IP_RATE_PER_MINUTE`,默认 6,web 是新攻击面默认开);
    全局预算独立桶 `GLOBAL_WEB_DAILY_LIMIT`(已设 300,trip 错误码
    `global_budget_exceeded_web`;**共池会刷爆 App 免费档,这是独立桶的原因**)。
  - 输入上限 1000 字符(`WEB_MAX_TRANSCRIPT_CHARS`,App 档是 4000)。
  - 只服务 extract 模式;复用主流程的 extraction cache / provider failover /
    遥测;无设备/订阅配额(响应不带 X-Quota-*)。
- 全局预算函数重构成三档注册表(free/pro/web,`GLOBAL_BUDGET_TIERS`),
  ip-daily 的 DO/KV 路径参数化(subjectKey/kvKeyPrefix/rateLimitType)。

**埋点**

- ct 体系:`web-tool-split-result` / `web-tool-recur-result`(结果页 CTA)、
  `web-tool-split-page` / `web-tool-recur-page`(工具页 CtaBand)、
  `web-tools-index`(索引页)。
- 工具使用次数:代理遥测里 web 档调用量(requestContext.channel=web)。

### 阶段 2:两个首发工具 ✅

| 工具 | 路径 | 实现要点 |
| --- | --- | --- |
| ① 一句话拆多条 | `/tools/add-multiple-reminders-at-once` | 调代理 web 档;结果页展示拆分列表(日期/时间/重复)+ 可整段复制的只读 textarea;不给提醒/重复落地/小组件/Siri |
| ② 重复说法检查器 | `/tools/recurring-reminder-checker` | **2026-11-25 更新(审计修复轮):** 走代理 web 档 AI 提取,与工具①同一条上游、共用每天 3 次额度;只渲染响应的重复规则与「接下来五次」。原方案(`recurrence.mjs` 本地解析器移植,零模型成本)已被审计推翻——本地解析器代码保留在 lib 作 Swift 对照,不再对外展示 |

> **2026-11-25 更正(审计):** 下文原「已知口径注意」段已推翻。原文主张「本地解析器
> 如实展示、官网不能比 App 更聪明,否则是谎报产品行为」——但 App 的重复规则实际
> 来自 AI(prompt 每次都输出 `recurrence_rule`,本地 `RecurrenceRuleResolver` 只在
> 模型完全没返回该字段时兜底,`Protocols/Models.swift:392`)。原口径让工具替 App
> 说它做不到的事(「每周一三五」只认出 Every Monday),恰恰是往差了说、才是谎报。
> 现实现:工具②与工具①同走 AI 提取,展示口径 = App 实际行为;「每周一三五」
> 正确显示周一、三、五。

### 阶段 3:文章分组 ✅(部分)

- 指南 #1 `add-several-reminders-at-once-on-iphone`:已审改,翻 `draft: false`
  发布,正文与 Related 指向工具 ①。
- 指南 #2 `how-to-set-recurring-reminders-by-voice-on-iphone`:已按 2026-11-24 审计
  建议翻 `draft: false` 发布(正文同步更正为与工具② AI 口径一致),正文与 Related
  指向工具 ②。#4 对比篇 `apple-reminders-vs-voice-to-do-apps` 同日发布(指向工具 ①)。
- #3/#5/#6 按调研写作顺序另行处理,不在本次范围。

### 阶段 4:看数据(上线后 4-6 周)

- 曝光:GSC 按词筛选,4-6 周内出现(调研 §6)。
- 下载:ASC 按 ct 分页(`web-tool-*-result` 两口径)。
- 付费:工具页来源用户 install→Pro 转化不低于 Reddit 渠道。
- 成本:web 档全局预算(`GLOBAL_WEB_DAILY_LIMIT=300`)触发频率每周 ≤1 次。
- 有人用没人点 → 调网页/App 功能分界;没曝光 → 问题在选词不在工具,回调研。

## 部署清单

✅ 已上线(2026-11-23 实测打通;本项目 **Pages 未连接 Git**,生产部署方式是本机直传):

```bash
cd website && npm run build && npx wrangler pages deploy --branch main   # 官网
cd ../AIProxy && npx wrangler deploy                                      # 代理
```

- Pages 配置在 `website/wrangler.toml`(项目名/产物目录/兼容标志/[vars]),
  **[vars] 是纯文本变量的唯一来源**;`WEB_EXTRACT_TOKEN` 是面板里的 Secret。
- ⚠️ 轮换 `WEB_EXTRACT_TOKEN` 必须两边同步:代理 `wrangler secret put` +
  Pages `wrangler pages secret put --project-name voicetodo-app`,**之后必须
  重新部署 Pages**(secrets 只在新部署生效,2026-11-23 踩过:轮换后没重发,
  工具① 稳定 502)。
- ⚠️ 断连退款(连点保护)要两端都开 `enable_request_signal`:代理在
  AIProxy/wrangler.toml,Pages 在 website/wrangler.toml —— 已配,有测试守着
  (functions/lib/pages-config.test.mjs + wrangler-config.test.js)。
- ⚠️ 断开退款的真实机制(2026-11-23 隔离实验):客户端一断开,Worker 主流程
  的后续代码**不再执行**,只有事先登记进 ctx.waitUntil 的任务能跑完 —— 退款
  挂在 request.signal 的 abort 事件上登记,不能依赖 catch 块(单测主流程不会
  被杀,catch 路径测试全绿但线上空转,别再犯)。

待人工:

1. ASC Provider Token 生成后替换 `src/config.mjs` 的 `providerToken`
   (不填则所有 ct 归因都看不到 —— 阶段 0 先决条件,仍未做)。
2. GSC + Bing Webmaster 接入(README「上线后接入」节)。
3. Cloudflare 面板看下 Pages 项目要不要重新接 Git(现在只能手动部署)。

## 测试

- 代理:`cd AIProxy && npm test`(web 档 10 个新用例:鉴权/405/413/每日/
  每分钟/独立预算桶/不碰 App 设备配额/mode 拒绝)。
- 解析器移植 + 工具①表单处理:`cd website && npm run test:functions`
  (`functions/lib` 与 `functions/api` 下的用例,含与 Swift 行为对齐的口径断言、
  split.js 的断连信号透传)。
- 构建:`cd website && npm run build`(19 页全过验收检查)。
