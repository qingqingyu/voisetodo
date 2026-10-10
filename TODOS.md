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
