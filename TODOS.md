# TODOS

延后项（按优先级）。来源：复盘 v5 autoplan 审查（2026-10-10，CEO/Design/Eng 三相位收敛）。

## P2 — recap Hero 积压趋势 sparkline
- **What:** 在 recap Hero 区加 finalBacklogCount 序列的迷你趋势图。
- **Why:** 跨期趋势可视化；v5 拍板「先喂 AI 后图形」，图形形态等方向 1 数据管道落地后再定。
- **Pros:** 用户一眼看到积压走势；护城河数据资产的直接展示。
- **Cons:** 形态未定（sparkline vs 数字对照），过早做可能返工。
- **Context:** v5 方向 1 = 跨期趋势线喂 AI 深读；finalBacklogCount 自 2026-09-24 起在攒。起点：docs/todo-review-flow-v5.md 拍板 1。
- **Depends on:** 方向 2/1（待实施清单第 6 项，pending UC1）。

## P3 — 瘦屏收拢自适应（F9）
- **What:** 极干净期（如 8 条完成+零积压）复盘流程步数自适应收拢（「本期很干净，一屏了结」）。
- **Why:** 与「垫事实行保流程」是两条路线，v5 未同台比较；GTM 真实用户数据后议。
- **Context:** CEO 相位 F9；与 v3 拍板 5/v4 地板哲学交叉，勿提前翻案。
- **Depends on:** GTM 数据。

## P3 — 清空庆祝后「记一句?」反思路钩（F11）
- **What:** 今日清空大庆祝后弹轻量「记一句?」入口连到复盘笔记。
- **Why:** 零新表面的天然反思路钩；拍板 4 隐式否决未析，GTM 后数据决定。
- **Depends on:** GTM 数据。

## P3 — tap-chips 结构化快答输入（F10 残余）
- **What:** 「问问自己」加结构化快答 chips 作为零同意摩擦的第三输入通道。
- **Why:** 比录音更快、无同意成本；与麦克风/手打并列评估。
- **Depends on:** 第 5 项麦克风落地后评估。

## P3 — 立正式 DESIGN.md（/design-consultation）
- **What:** 跑 /design-consultation 把 DesignSystem.swift+文本布局规则升格为正式 DESIGN.md。
- **Why:** 设计相位 Pass5 评分 6/8 的天花板原因；后续 UI 改动有单一校准源。
- **Depends on:** GTM 后（v5 上线优先）。

## 待定 — 解析改两段式:LLM 只拆条 + 填 5W1H,后续判断交给代码(用户想法,2026-11-27 记录)
- **What:** 用户一口气说一大段、里面有多件事时,LLM 的第一步只做一件事:把内容重新整理成一条一条的待办,每条带上 5W1H(谁做、为谁/和谁、什么时候、在哪、做什么、为什么、怎么做),时间类字段保留用户原话。整理成这种结构之后,后面的分析和判断(算具体日期、重复规则、提醒、分组等)尽量直接用纯代码做。
- **Why:** 现在的提示词让 LLM 同时负责拆条和推算,规则越写越长(例如英文提示词 rule 4 的「next <weekday>」机械算法、「月底 = 当月最后一天」等约定),每类日期说法都要在三种语言的提示词里各教一遍,错了只能靠 eval 回归发现。改成「LLM 理解语义、代码做确定性计算」后,推算逻辑可以写单元测试、结果稳定可复现。
- **Pros:** 日期/重复等推算可测、可复现,不随模型和服务商变化;提示词变短,换模型成本更低;5W1H 结构化后,复盘统计等功能可以直接按「谁」「在哪」聚合。
- **Cons:** 要定义一套能覆盖口语时间表达的中间格式(原话短语 → 代码解析),三种语言的时间说法都要在代码里实现一遍;输出 schema 变更涉及 AIProxy、iOS 解码、eval 用例三处联动。
- **Context:** 已有先例:重复任务的结束边界 `recurrence_end` 就是「LLM 只分类(after_count / weekday / month_end…),具体日期由客户端算」(`AIProxy/src/adapters/base.js` 英文提示词 rule 5b),`recurrence_rule.end_date` 也明确要求 LLM 不算。可以沿这个模式逐个字段迁移,不必一次推翻。现有输出字段见同文件提示词的 JSON shape(title / due_date / due_hint / due_time / time_bucket / recurrence_rule / due_date_basis / category_hint 等)。
- **待定的问题:** 5W1H 里哪些字段对待办真正有用(「为什么」「怎么做」可能大多为空);分类(category_hint)这类需要语义判断的是否仍留给 LLM;先从哪个字段开始迁移(建议从 due_date 推算开始,收益最大);对解析延迟和 token 成本的影响。
- **Depends on:** 用户确定优先级后再出方案;动 schema 前需要 eval 基线(`AIProxy/eval/`)。
