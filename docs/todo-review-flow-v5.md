<!-- /autoplan restore point: "/Users/TWJ/工作/git/doflow/VoiceTodo/.worktrees/fupan/.gstack/tmp/autoplan/fupan-autoplan-restore-20261010-205135.md" -->
## Implementation plan
# 复盘流程 v5 —— 深度补强（真实体感回看 + grill 盘问）

> 状态：**方案 + 拍板 2026-10-10，未实施**。基线 main `8b02ac0`（fupan worktree）。
> 来源：grill 盘问会（走查 → 七题逐分支拍板）。定调修正：开发者本人是**测试者不是真实用户**，行为采访作废，盘问对象为设计本身（假设换成 GTM 后的真实用户）。
> 前作：`docs/todo-review-flow-design.md`（v1）、`-v2`、`-v3`、`-v4`（均已实施合 main）。
> 相关文件：`UI/Review/Flow/ReviewFlowView.swift`、`ReviewStepRecap.swift`、`ReviewStepLedger.swift`、
> `Protocols/Domain/Insights/InsightEngine.swift`、`Rules/*.swift`、`TriageRanking.swift`、
> `Protocols/ReviewSessionStore.swift`、`App/ReviewNotificationScheduler.swift`。

## Context

两条真实体感发起本轮：

1. **「有些页是空的」**——v4 地板层之后仍有瘦屏场景（解剖见下）。
2. **「复盘不够深入」+ 手打笔记「没必要、写了不一定看得到」**。

盘问确认的四条深度方向（跨期趋势 / AI 深读 / 规则加密降阈 / 洞察→行动）**全部要做**，但不是并行工程——有依赖链（§拍板 1）。

---

## 空屏残余解剖（v4 之后仍成立的场景）

按触发概率排：

1. **规则层集体哑火**：01 中间地带 hidden、05 两腿极难同时成立、03 中间只给一行字、02 触发后可能在冷却中——四条全空时整屏只剩地板。
2. **阶梯压制**：完成 <5 条规则层不跑（skipStep 档只出地板 A）；5–14 条只有 02（零积压时 02 也 hidden）。
3. **典型瘦屏**：完成 8 条 + 零积压 → 02 hidden、03 占位一行、地板 A/C 为 nil、B 一行数字 → 整屏 ≈ 两行字。

## 空屏与「不深入」的共同根因

- 规则全是**单维横截面**对着固定阈值切（21 天 / 50% / 2 倍 / 22 点），无跨期趋势；宁漏勿报取向（01/05 中间 hidden、05 组合信号）让普通用户合法地什么也看不到。
- 深度素材在手里没用：笔记 topics 只做「上次说 X→本期 Y N 条」对照；commit 三件事历史兑现率无回看；defers×分类×时段交叉分析为零。
- 冷启动 4 周内 03/05 到不了 minSample。

---

## 拍板 1 · 深度施工顺序：3-lite → 2 → 1，4 后置（2026-10-10）

四条都要，按依赖排序：

### 3-lite：01/05 中间地带降为事实行（v4 拍板 3 的自然延伸）

- `EffortOrderingRule` 中间地带（`highMedian` 介于 `other` 与触发线之间）从 `.hidden` 降为 `.fact`——只报两组中位天数，不带判断；两组各 ≥3 条的前置保留，不足维持现有占位/hidden。
- `EnergyWindowRule` 单腿信号降为 `.fact`：峰值小时可单独报（「完成高峰在 N 点」）；带钟点高优 ≥2 件时深夜占比也可单独报。两腿同时成立仍走 `.fired` 警示。
- 与 v4 拍板 6 同口径：事实行**不走冷却、不记 `shownInsights`**，但算「规则层有内容」。
- **不降触发线**——密度来自中间地带可见，不来自制造误报；反 gaming 章程不破。
- 事实行的最小样本线低于 fired 线即可，原则「说出来不误导」，具体数值实施时定（阈值清单随实施批注落回本文档）。

### 2：AI 深读（reflect 升级）

- 前置依赖：3-lite 先把事实层变密——**AI 只复述已算出的事实/数字**（接地约束，防无数据支撑的空话），跨期叙事由方向 1 喂料。
- 计费沿 reflect 现口径**不计费**；失败降级为不显示，绝不空话兜底。
- 输出位置（新卡 or 并入 recap 屏）与提示词形态：实施前单独审阅，未定。

### 1：跨期趋势线

- `ReviewLedger.finalBacklogCount` 序列（09-24 起在攒）+ 洞察效应量跨期变化，作为 2 的叙事素材；趋势可视化本体的形态未定（先喂 AI，图形后置亦可）。

### 4：洞察→当场具体行动（「排周三 19:00」式卡内排期）

- **GTM 后**。v2 因「缺交互设计」推迟过，本轮维持后置；与前三条无依赖。

---

## 拍板 2 · 笔记双侧改造（2026-10-10）

「写了基本看不到」在 08-23 拍板 5（笔记全量可见）之后依然成立——可见性修复没打中根子。根子两截：

- **输入侧**：voice-first app 让用户手打反思是气质错配。补「问问自己」麦克风 UI（注入链已通，挂账⑥），手打退兜底；AI 草稿代笔（方向 2 的产出预填笔记框，用户改/删/补，白板变编辑）。复盘录音 paywall 豁免（旧拍板：累计第 5 次弹）随麦克风一起做。
- **输出侧**：笔记消费时机前移——上期笔记原话在**第 1 步 recap** 就亮出来对质（面对这期做了什么的时刻并置上期写下的），不再只躺在第 5 步末尾与回顾页时间线。

---

## 拍板 3 · 批量出口门槛 30→21 天，对齐地板 A（2026-10-10）

- **supersede v2 拍板 3 的 30 天门槛**（v2 的「复用稍后」保留，仅改天数）。
- 理由：地板 A 以 21+ 天点名（`RottingRule.ageThresholdDays` 同尺），批量出口却要 30 天——系统「指着它说该处理了，却不给动作」，两套话。对齐后统一语义：**21 天没动 = 要么处理，要么承认稍后**。
- `extractionOutcome == .parsed` 门槛保留（不承诺做不到的落点）。改动点：`TriageRanking.batchStagnationDays`。
- 注意连锁：门槛降低 → 批量出口更早可用 → `somedayCount` 会变大，②屏「其余 N 件先不动」计数与批量行文案需同步核对。

---

## 拍板 4 · 入口发现性：现状 + 验埋点（2026-10-10）

- 不加新入口（Home 保持日历专注）；通知维持固定周一 9:00。
- 前提动作：**核实遥测能否重建「入口曝光 → 开始复盘」漏斗**；不能则补埋点。GTM 后用数据决定是否动入口。

---

## 确认不动（本轮显式过盘，勿再翻案）

| 议题 | 结论 |
|---|---|
| 窗口三叉（①屏上次复盘至今 / 洞察近 30 天 / 回顾页 30 天） | 维持——各屏自带窗口声明（09-24 修订④）已够，不统一 |
| 中途杀 app 原子性 | 接受现状——决定已即时落库，丢的只是元记录；半会话会污染账本差/冷却语义，不做部分持久化 |
| 冷却 3 期 | 不动——事实行不走冷却后空屏已被接住 |
| 04 对谁失约 / 06 周内衰减 | 维持搁置 |
| 存规则/回访链路 | 维持移除（08-22 拍板，继续有效） |

旁注（D6 口径，2026-10-10 增量审定稿）：完成记录 **<3 条**时第 3 步合法表面 = 地板 A/C + 一行窗口声明，不空屏；此为设计口径，不视为遗漏。

D3 四格表（F2/D3，2026-10-11 随 T4 批 C 落档）：复盘录音付费墙豁免 landed-behind-flag **默认关**。flag 关（软启动 4 周读数窗口内，现状）——免费：复盘录音不计入 recording_count、不触发付费墙（与首页录音的「累计第 5 次弹」口径在此窗口内不并轨）；Pro：同免费，无付费墙。flag 开（窗口结束后）——免费：复盘录音计入累计第 5 次弹付费墙（旧拍板语义，PaywallSource 待定 reviewCount 或新增 source）；Pro：无付费墙。计数接线在 flag 开启时实施，本期零代码。

## 待实施清单

1. 3-lite：01/05 事实行（阈值见文末 C1 义务块）+ 阈值批注回填本文档
2. 笔记输出侧：recap 对质区
3. 拍板 3：`batchStagnationDays` 30→21 + 连锁文案核对
4. 埋点核实（入口曝光/开始复盘事件是否存在）
5. 麦克风 UI + paywall 豁免（**独立可先行**，不依赖方向 2；spec 评审 CL-1 拆包）
6. AI 草稿 + AI 深读 + 趋势线（方向 2/1 合批，含提示词与输出位置审阅）——**UC1 已裁决 2026-10-10**（最终门批准：维持 GTM 前可做；F1 埋点前置 / F2 flag 默认关 / F12 裁剪顺序三道保险生效，时间紧仍先砍 2 再砍 1）

## GTM 前旧账（非本轮产生，勿丢）

- 真机 5 档矩阵 + 三语 AX5（v3/v4 挂账，重点 ③ 层占位行）
- Localizable 501/776 键缺 ja、widget 名缺 ja

<!-- autoplan-accepted:ceo -->
- C1 (SELECTIVE EXPANSION cherry-pick, accepted 2026-10-10): skipStep 档(完成记录<5)也计算并渲染事实行——与 v4 拍板 5「skipStep 只出地板 A」叠加而非取代(地板照出,规则层事实行补充)。**阈值随本条定死(spec 评审 C-1 修正)**:05 峰值小时事实行=≥3 条完成记录(直方图最小意义样本);01 事实行沿用两组各≥3 前置(故只在 rottingOnly/full 档可能出);03 占位行照现有机制。验收=skipStep 夹具(3 条完成+有积压)第 3 步有地板 A+05 峰值事实行;单测覆盖 ladder 三档事实行渲染判定。
- 维持既有拍板不动:窗口三叉/原子性/冷却/04/06/存规则回访维持 v5「确认不动」表;C2 sparkline 延后(TODOS);C3 拒绝。
- CEO声部F1(高,采纳): 施工顺序重排——埋点核实(原第4项)提前为最先施工项;深度方向拍板顺序(3-lite→2→1)不变。
- CEO声部F2(高,采纳): 第5项 paywall 豁免部分 landed-behind-feature-flag 默认关,软启动读数窗口(4周)内不改变免费用户可见付费墙表面,窗口结束后放开。
- CEO声部F5(中,采纳): 05 峰值事实行 n<5 时行内标注样本量,不呈现误导性精确钟点;C1 夹具验收同步检查该标注。
- CEO声部F6(中,采纳): 第3项连锁核对清单补两项——Later/待定日期计入进度条的口径交互、地板A点名与批量出口同周双触达走查夹具。
- CEO声部F8(中,采纳): 待实施各项验收标准含「新字符串 zh+en+ja 三语同批落地」。
- CEO声部F3(中,采纳): 第6项实施前审阅含「黄金输出盲评」——瘦/常/富三档事实层 vs 深读产出并排盲评,无感知增量则砍深读仅保留 AI 草稿。
- CEO声部F7/F12(采纳): 第6项审阅清单补「深读调用限额继承代理侧成本闸」与「时间盒裁剪顺序=先砍2(AI深读)再砍1;明示方向2在方向1落地前仅当周复述价值」。
- S2(采纳): 第5项验收补「麦克风权限拒绝/转写失败降级手打+ErrorMessages 常量」。
- S3(采纳): 第5项纳入 AI 同意 gate 覆盖——复盘内录音是第三方 AI 转写新场景,需独立披露文案(沿 5.1.1 六路径先例)。
- 拒绝CEO声部F4(事实行折叠/轻量冷却): 与 v4 拍板 1「事实每期都该重述,冷却只作用于规则层判断」直接冲突,不翻案。
<!-- /autoplan-accepted:ceo -->

<!-- autoplan-accepted:design -->
- D1(高,采纳): 三层视觉语言定稿——fired=警示样式+判断动词;fact=中性样式+纯数字陈述(不用警示色);占位=弱化灰+样本说明;随实施批注落文档并纳入 F8 三语 AX5 验收。
- D2(高,采纳): 对质区版面顺序=先本期事实(Hero/统计)后上期原话;框架文案「上期你写了」+中性引用样式;禁差距评判语句;验收=上期笔记为负面时首屏无指责性表述。
- D3(高,采纳): 补「flag 关/开 × 免费/Pro」四格状态表(每格首触/第5次/第6次表现),旧拍板「复盘录音累计第5次弹付费墙」豁免语义完整引回;随第5项实现批注落文档。
- D4(高,采纳): 深读卡仅就绪后整体出现(无骨架屏);接地校验=深读数字与事实层逐一对不上→整卡不显示;该校验规则写进 F3 盲评材料。
- D5(中,采纳): 占位行仅在规则层(fired+fact)整空时兜底,否则隐藏;并入 C1 三档单测判定。
- D6(中,采纳): 完成<3 条时第 3 步合法表面=地板 A/C+一行窗口声明(不空屏);写入文档旁注(确认不动表同页)。
- D7(中,采纳): 事实行与上期完全相同时行尾加「与上期相同」弱化标注——仍重述不折叠不冷却(与 v4 拍板 1 相容,F4 拒绝的是折叠/冷却);与 F5 样本标注一并定稿。
- D8(中,采纳): 第5项麦克风交互形态(press-to-talk/自动停/时长上限/引导语)列为一票否决开工前置;引导语若成题库进 F8 三语。
- D9(中,采纳): 对质区按时间全量排列、逐条 lineLimit+minimumScaleFactor;AI 草稿保存带来源标记,对质区只呈现用户确认内容或明示「AI 草稿(你保留的)」。
- D10(中,采纳): 05 深夜占比 fact 分母=带完成时刻的记录数,行内沿用 F5 样本标注;写进阈值回填表。
- D11(中,采纳): 第6项旁明示——若方向2/1均被裁,本轮对「不深入」的回应=事实层加密+对质区,深度诉求 GTM 后重评(防后续误判遗漏)。
- D12(中,采纳): F6 走查夹具加「大 somedayCount(40+)」档,②屏三语 AX5 截图验收。
- Pass6(采纳): 新 UI 元素(事实行/对质区/麦克风钮)补 VoiceOver 标签规范,并入 F8 验收。
<!-- /autoplan-accepted:design -->

<!-- autoplan-accepted:eng -->
- E1(高,采纳): C1 实施口径写死——skipStep 档**仅评估 01/05 且仅收集 `.fact`**;`.fired`/`.placeholder` 一律丢弃;RottingRule 在 skipStep 档不评估(保 runInsightEngine 原 guard 的冷却不变量:下期冷却不得把没看过的当看过)。单测断言:<5 完成+21 天积压会话的 shownInsights 为空数组。
- E2(高,采纳): 05 深夜占比 fact 分母改为**复用 fired 同一分母(带钟点高优任务数)**,撤销 D10 的「带完成时刻记录数」——同屏一把尺;文案两档共用「排在深夜」语义。
- E3(中,采纳): 05 fact 档峰值小时扫描窗扩为 **0...23**(fired 档维持 5...23 不动),凌晨用户不再被误导;加 0–4 点夹具单测。
- E4(中,采纳): D7「与上期相同」比较**结构化数值**(规则 id+关键数字)而非本地化文本;ReviewSession 新增结构化事实记录键,decodeIfPresent 兜底(沿 somedayCount/backlogCount 先例);不记 shownInsights 不变(v4 拍板 6 保持)。
- E5(中,采纳): 深读提示词要求输出**机器可读数字块**(事实 id→值 JSON),客户端按 id 精确比对做 D4 接地校验(不做自由文本数字抽取);写进第6项审阅清单与 F3 盲评材料。
- E6(中,采纳): AI 同意 gate 按「本次会话是否有内容发往代理」收口——录音/草稿/深读**三入口同 gate**,披露文案一条覆盖;键盘路径的 AI 草稿不得绕过(S3 扩围)。
- E7(中,采纳): 拍板 3 批量资格判定从自然日改**用户日**(DayClock),与地板 A/RottingRule 真同尺——根因修复优于只加夹具;F6 夹具仍加 startHour>0 边界档(20/21/22 天)。
- E8(中,采纳): T1 施工先落事件口径说明再写代码——入口曝光按 session 去重(每次进统计页不刷量)、开始=ReviewFlowView init、完成=finishSession 补第三环;参数脱敏,绝不带笔记文本。
- E9(低,采纳): 新增 xcstrings 键逐条列出,一次性过序列化器流程(单 commit),不分散落。
- E10(低,采纳): 第5项验收补——录音中断/失败时已有部分转写预填笔记框,不丢弃(永不丢话先例)。
- E11(低,采纳): 第6项审阅输出明确深读限额参数(继承 DAILY_REQUEST_LIMIT 或独立 reflect 限额+KV 键,二选一写死);AI 草稿入 voiceNote 设长度上限,与手打输入同尺。
<!-- /autoplan-accepted:eng -->
## Review record

<!-- autoplan-accepted:ceo -->
- C1 (SELECTIVE EXPANSION cherry-pick, accepted 2026-10-10): skipStep 档(完成记录<5)也计算并渲染事实行——与 v4 拍板 5「skipStep 只出地板 A」叠加而非取代(地板照出,规则层事实行补充)。**阈值随本条定死(spec 评审 C-1 修正)**:05 峰值小时事实行=≥3 条完成记录(直方图最小意义样本);01 事实行沿用两组各≥3 前置(故只在 rottingOnly/full 档可能出);03 占位行照现有机制。验收=skipStep 夹具(3 条完成+有积压)第 3 步有地板 A+05 峰值事实行;单测覆盖 ladder 三档事实行渲染判定。
- 维持既有拍板不动:窗口三叉/原子性/冷却/04/06/存规则回访维持 v5「确认不动」表;C2 sparkline 延后(TODOS);C3 拒绝。
- CEO声部F1(高,采纳): 施工顺序重排——埋点核实(原第4项)提前为最先施工项;深度方向拍板顺序(3-lite→2→1)不变。
- CEO声部F2(高,采纳): 第5项 paywall 豁免部分 landed-behind-feature-flag 默认关,软启动读数窗口(4周)内不改变免费用户可见付费墙表面,窗口结束后放开。
- CEO声部F5(中,采纳): 05 峰值事实行 n<5 时行内标注样本量,不呈现误导性精确钟点;C1 夹具验收同步检查该标注。
- CEO声部F6(中,采纳): 第3项连锁核对清单补两项——Later/待定日期计入进度条的口径交互、地板A点名与批量出口同周双触达走查夹具。
- CEO声部F8(中,采纳): 待实施各项验收标准含「新字符串 zh+en+ja 三语同批落地」。
- CEO声部F3(中,采纳): 第6项实施前审阅含「黄金输出盲评」——瘦/常/富三档事实层 vs 深读产出并排盲评,无感知增量则砍深读仅保留 AI 草稿。
- CEO声部F7/F12(采纳): 第6项审阅清单补「深读调用限额继承代理侧成本闸」与「时间盒裁剪顺序=先砍2(AI深读)再砍1;明示方向2在方向1落地前仅当周复述价值」。
- S2(采纳): 第5项验收补「麦克风权限拒绝/转写失败降级手打+ErrorMessages 常量」。
- S3(采纳): 第5项纳入 AI 同意 gate 覆盖——复盘内录音是第三方 AI 转写新场景,需独立披露文案(沿 5.1.1 六路径先例)。
- 拒绝CEO声部F4(事实行折叠/轻量冷却): 与 v4 拍板 1「事实每期都该重述,冷却只作用于规则层判断」直接冲突,不翻案。
<!-- /autoplan-accepted:ceo -->

<!-- autoplan-accepted:design -->
- D1(高,采纳): 三层视觉语言定稿——fired=警示样式+判断动词;fact=中性样式+纯数字陈述(不用警示色);占位=弱化灰+样本说明;随实施批注落文档并纳入 F8 三语 AX5 验收。
- D2(高,采纳): 对质区版面顺序=先本期事实(Hero/统计)后上期原话;框架文案「上期你写了」+中性引用样式;禁差距评判语句;验收=上期笔记为负面时首屏无指责性表述。
- D3(高,采纳): 补「flag 关/开 × 免费/Pro」四格状态表(每格首触/第5次/第6次表现),旧拍板「复盘录音累计第5次弹付费墙」豁免语义完整引回;随第5项实现批注落文档。
- D4(高,采纳): 深读卡仅就绪后整体出现(无骨架屏);接地校验=深读数字与事实层逐一对不上→整卡不显示;该校验规则写进 F3 盲评材料。
- D5(中,采纳): 占位行仅在规则层(fired+fact)整空时兜底,否则隐藏;并入 C1 三档单测判定。
- D6(中,采纳): 完成<3 条时第 3 步合法表面=地板 A/C+一行窗口声明(不空屏);写入文档旁注(确认不动表同页)。
- D7(中,采纳): 事实行与上期完全相同时行尾加「与上期相同」弱化标注——仍重述不折叠不冷却(与 v4 拍板 1 相容,F4 拒绝的是折叠/冷却);与 F5 样本标注一并定稿。
- D8(中,采纳): 第5项麦克风交互形态(press-to-talk/自动停/时长上限/引导语)列为一票否决开工前置;引导语若成题库进 F8 三语。
- D9(中,采纳): 对质区按时间全量排列、逐条 lineLimit+minimumScaleFactor;AI 草稿保存带来源标记,对质区只呈现用户确认内容或明示「AI 草稿(你保留的)」。
- D10(中,采纳): 05 深夜占比 fact 分母=带完成时刻的记录数,行内沿用 F5 样本标注;写进阈值回填表。
- D11(中,采纳): 第6项旁明示——若方向2/1均被裁,本轮对「不深入」的回应=事实层加密+对质区,深度诉求 GTM 后重评(防后续误判遗漏)。
- D12(中,采纳): F6 走查夹具加「大 somedayCount(40+)」档,②屏三语 AX5 截图验收。
- Pass6(采纳): 新 UI 元素(事实行/对质区/麦克风钮)补 VoiceOver 标签规范,并入 F8 验收。
<!-- /autoplan-accepted:design -->

<!-- autoplan-accepted:eng -->
- E1(高,采纳): C1 实施口径写死——skipStep 档**仅评估 01/05 且仅收集 `.fact`**;`.fired`/`.placeholder` 一律丢弃;RottingRule 在 skipStep 档不评估(保 runInsightEngine 原 guard 的冷却不变量:下期冷却不得把没看过的当看过)。单测断言:<5 完成+21 天积压会话的 shownInsights 为空数组。
- E2(高,采纳): 05 深夜占比 fact 分母改为**复用 fired 同一分母(带钟点高优任务数)**,撤销 D10 的「带完成时刻记录数」——同屏一把尺;文案两档共用「排在深夜」语义。
- E3(中,采纳): 05 fact 档峰值小时扫描窗扩为 **0...23**(fired 档维持 5...23 不动),凌晨用户不再被误导;加 0–4 点夹具单测。
- E4(中,采纳): D7「与上期相同」比较**结构化数值**(规则 id+关键数字)而非本地化文本;ReviewSession 新增结构化事实记录键,decodeIfPresent 兜底(沿 somedayCount/backlogCount 先例);不记 shownInsights 不变(v4 拍板 6 保持)。
- E5(中,采纳): 深读提示词要求输出**机器可读数字块**(事实 id→值 JSON),客户端按 id 精确比对做 D4 接地校验(不做自由文本数字抽取);写进第6项审阅清单与 F3 盲评材料。
- E6(中,采纳): AI 同意 gate 按「本次会话是否有内容发往代理」收口——录音/草稿/深读**三入口同 gate**,披露文案一条覆盖;键盘路径的 AI 草稿不得绕过(S3 扩围)。
- E7(中,采纳): 拍板 3 批量资格判定从自然日改**用户日**(DayClock),与地板 A/RottingRule 真同尺——根因修复优于只加夹具;F6 夹具仍加 startHour>0 边界档(20/21/22 天)。
- E8(中,采纳): T1 施工先落事件口径说明再写代码——入口曝光按 session 去重(每次进统计页不刷量)、开始=ReviewFlowView init、完成=finishSession 补第三环;参数脱敏,绝不带笔记文本。
- E9(低,采纳): 新增 xcstrings 键逐条列出,一次性过序列化器流程(单 commit),不分散落。
- E10(低,采纳): 第5项验收补——录音中断/失败时已有部分转写预填笔记框,不丢弃(永不丢话先例)。
- E11(低,采纳): 第6项审阅输出明确深读限额参数(继承 DAILY_REQUEST_LIMIT 或独立 reflect 限额+KV 键,二选一写死);AI 草稿入 voiceNote 设长度上限,与手打输入同尺。
<!-- /autoplan-accepted:eng -->
<!-- autoplan-baseline-edits:ceo {"sourceSha256":"6a4930e4133fe55c58ea48f33ef955968774afaacb6f3a580f9210ee2bbce8ca","replacements":[{"oldText":"1. 3-lite：01/05 事实行 + 阈值批注回填本文档\n2. 笔记输出侧：recap 对质区\n3. 拍板 3：`batchStagnationDays` 30→21 + 连锁文案核对\n4. 埋点核实（入口曝光/开始复盘事件是否存在）\n5. 麦克风 UI + paywall 豁免 + AI 草稿（方向 2 落地时合批）\n6. AI 深读 + 趋势线（方向 2/1，含提示词与输出位置审阅）","newText":"1. 3-lite：01/05 事实行（阈值见文末 C1 义务块）+ 阈值批注回填本文档\n2. 笔记输出侧：recap 对质区\n3. 拍板 3：`batchStagnationDays` 30→21 + 连锁文案核对\n4. 埋点核实（入口曝光/开始复盘事件是否存在）\n5. 麦克风 UI + paywall 豁免（**独立可先行**，不依赖方向 2；spec 评审 CL-1 拆包）\n6. AI 草稿 + AI 深读 + 趋势线（方向 2/1 合批，含提示词与输出位置审阅）——**pending UC1**（GTM 时间盒挑战，Phase 4 门裁决，spec 评审 C-2）"}]} -->

### CEO Review Sections（2026-10-10 · SELECTIVE EXPANSION · [single-model：Claude only，Codex 端点未配模型]）

**S1 架构**：1 发现。AF1（中）：`InsightResult/InsightFactLine` 是展示对象（headline/body 已本地化字符串），AI 深读若直接喂会把 **UI 语言锁进提示词**且无法稳定解析——深读输入需新建结构化 facts DTO（纯数字+枚举+样本量，零本地化文案），在 `runInsightEngine` 产出侧并行构造。无新模块；各件独立可逆。深读数据流：

```
InsightContext(SwiftData 快照) ─▶ 规则层+地板层(纯函数)
        │                              │
        │                       ┌──────┴───────┐
        │                       ▼              ▼
        │              InsightResult(展示)  FactsDTO(新,数字+枚举)
        │                       │              │
        ▼                       ▼              ▼
   RecapHero/Triage 卡     ③屏渲染      reflect 深读模式(AIProxy) ─失败▶ 不显示
                                                    │
                                                    ▼
                                        ReviewSession.topics/deepObservation
```

**S2 错误与救援**：深读失败→不显示（已定）；麦克风权限拒绝/转写失败→降级手打（已入义务块）；无新增 catch-all。0 CRITICAL GAP。
**S3 安全**：2 发现均采纳——复盘录音纳入 AI 同意 gate（新第三方转写场景，义务块）；深读输出按**纯文本**渲染、禁 markdown 链接（防注入外跳，沿洞察卡现行纯文本策略）→记 T4。注入面：笔记文本进提示词=自有数据，风险低；代理侧已有 JWS/限速。
**S4 数据/交互边界**：对质区 nil path（上期无笔记）=整块隐藏；上期笔记长文本按文本布局规则 lineLimit+minimumScaleFactor；3 条完成并列峰值→F5 样本量标注（义务块）；21 天双触达+进度条口径→F6 走查（义务块）。
**S5 代码质量**：1 发现——`ReviewFlowView` 已 1300+ 行，对质区代码归 `ReviewStepRecap.swift`、麦克风归 `ReviewStepLedger.swift`，流程视图零增长（P5）。
**S6 测试**：新增可测面——ladder 三档事实行渲染数据测试（C1 夹具）、21 天边界 20/21/22、对质区 nil/短/长三态、F2 flag 开关两态。深读 worker 侧需扩 `AIProxy` 测试（npm test 现 318/318 基线）。语音路径模拟器不可测（CLAUDE.md 已知限制）→真机项。无 flakiness 引入（now 注入口径已有）。
**S7 性能**：无发现——深读 1 次 LLM/会话；allSessions 52 期上限已载入内存。
**S8 可观测**：1 缺口→并入埋点项：`review.deep_read.failed/succeeded` 事件，否则「失败不显示」不可诊断。
**S9 部署**：app 侧件随版本发布；AIProxy 深读模式需 wrangler deploy（UC1 门后）；F2 flag=默认关；回滚=各件独立 revert，无迁移。
**S10 轨迹**：可逆性 5/5；债务两项（xcstrings 键增长、ReviewFlowView 膨胀已 flag）；12 个月可读性——v1-v5 拍板链文档完整。
**S11 设计/UX**（UI scope=yes）：对质区使 recap 第一屏变重→建议置于 Hero 之后、默认展开一行摘要+可展开全文（细判留给 Phase 2 深审）；交互态：对质区 EMPTY=隐藏 / mic 权限拒绝=文案+手打 / 深读 FAILED=不显示。用户流：

```
回顾页入口卡 ─▶ recap(新增:上期笔记对质区) ─▶ triage ─▶ insights(事实行加密)
     └─通知深链─┘                                │
                                  skipStep档: 地板A+05事实行(新)
                                                  ▼
                              commit ─▶ ledger(新增:麦克风输入,AI草稿预填)
```

### NOT in scope（本轮显式排除）
- 瘦屏收拢自适应（F9：与 v3 拍板 5/v4 地板哲学交叉，GTM 数据后议）
- 清空庆祝后「记一句?」反思路钩（F11）、tap-chips 结构化快答输入（F10 残余，评估候选）
- C2 sparkline（已 defer TODOS）、04/06 规则、Home 入口/通知智能化（拍板 4 否决）

### What already exists
| 子问题 | 复用 |
|---|---|
| 事实行机制 | `InsightAvailability.fact` + 03 中间地带先例（ReactiveVsPlannedRule.swift:75） |
| AI 管道 | reflect 模式不计费不缓存（NetworkClient.swift:64）、split 模式降级先例 |
| 趋势数据 | `ReviewLedger.finalBacklogCount`（09-24 起攒） |
| 麦克风 | VoiceInputProtocol 注入链已通（AppCoordinator 私有持有） |
| 笔记读取 | `loadReviewNotes` 同源可取上期笔记 |

### Error & Rescue Registry（能力级）
| 路径 | 故障 | 处置 | 用户所见 |
|---|---|---|---|
| 深读代理调用 | 超时/5xx/坏 JSON | 不显示+遥测 | 无感（③屏照常） |
| 麦克风 | 权限拒绝 | 文案+手打兜底 | 明示提示 |
| 转写 | 失败/空 | 手打兜底 | 明示提示 |
| 事实行计算 | n/a 纯函数 | — | — |

### Failure Modes Registry
| 路径 | 失败模式 | RESCUED | TEST | USER | LOGGED |
|---|---|---|---|---|---|
| 深读 | 失败 | Y | worker 侧待加 | 不显示 | Y(S8 补) |
| 麦克风 | 拒绝/失败 | Y | 真机手测 | 明示 | N(低风险) |
| 21 天批量 | 误批量 | 撤销快照已有 | 边界单测待加 | 明示 | N |

### Dream state delta
本计划落地后：复盘从「五步有话说」进到「有话说+说的越来越懂你」（事实层全档覆盖→AI 接地深读→跨期趋势喂料）；距 12 个月理想（数据+AI 个人效率回看系统=护城河）还差：真实用户数据回流、方向 4 行动闭环、04/06 规则启用。

## Implementation Tasks
Synthesized from this review's findings. Each task derives from a specific finding above.

- [ ] **T1 (P1, human: ~2h / CC: ~20min)** — Insights — 埋点核实前置：确认/补「入口曝光→开始复盘」漏斗事件+`review.deep_read.*`（F1/S8）
  - Files: App/VoiceTodoApp.swift、遥测映射文档；Verify: 事件在本地遥测日志可见
- [ ] **T2 (P1, human: ~3h / CC: ~25min)** — Insights — 3-lite：01/05 中间地带 `.fact` 分支+ladder 全档事实行+F5 样本量标注+C1 夹具三档单测（含 skipStep）
  - Files: EffortOrderingRule/EnergyWindowRule/ReviewFlowView(ladder 判定)；Verify: swift test 新增夹具绿
- [ ] **T3 (P1, human: ~1.5h / CC: ~15min)** — Triage — `batchStagnationDays` 30→21+边界单测 20/21/22+F6 双触达与进度条走查（拍板 3）
  - Files: TriageRanking.swift、②屏文案键；Verify: 单测+夹具走查记录
- [ ] **T4 (P1, human: ~2h / CC: ~15min)** — Ledger — recap 对质区（上期笔记一行摘要+展开，nil 隐藏）+麦克风 UI（44pt、权限/转写失败降级、ErrorMessages、consent gate、paywall 豁免 behind flag 默认关）（拍板 2/S2/S3/F2）
  - Files: ReviewStepRecap.swift、ReviewStepLedger.swift；Verify: 键盘路径模拟器+语音真机
- [ ] **T5 (P2, human: ~3h / CC: ~30min)** — AIProxy+iOS — 深读模式：FactsDTO（数字+枚举零本地化）+worker 测试+黄金输出盲评+调用限额+纯文本渲染（AF1/F3/F7/S3）——**pending UC1**
  - Files: Protocols/Domain/Insights/、Extractor/TodoExtractorService.swift、AIProxy/worker.js；Verify: npm test 扩+盲评记录
- [ ] **T6 (P2, human: ~1h / CC: ~10min)** — i18n — 全部新字符串 zh+en+ja 三语同批（F8）；Verify: xcstrings 数据测试
- [ ] **T7 (P3)** — TODOS：C2 sparkline（方向 1 数据管道后）
- [ ] **T8 (P3)** — GTM 后：F9 收拢自适应、F11 反思路钩、tap-chips 评估、入口数据复盘（拍板 4 后续）

<!-- AUTONOMOUS DECISION LOG -->
## Completion Summary（CEO Phase 1 · 2026-10-10）

```
+====================================================================+
|            MEGA PLAN REVIEW — COMPLETION SUMMARY                   |
+====================================================================+
| Mode selected        | SELECTIVE EXPANSION (autoplan 固定, auto)   |
| System Audit         | 复盘子系统无 TODO/FIXME;stash@{0} 用户留档  |
|                      | 勿动;热点=xcstrings/Paywall/Review 流程      |
| Step 0               | C1 接受/C2 延后/C3 拒;spec loop 2 轮 8→9/10 |
| Section 1  (Arch)    | 1 issue (AF1 FactsDTO)                      |
| Section 2  (Errors)  | 4 paths mapped, 0 GAPS                      |
| Section 3  (Security)| 2 issues, 0 High (consent/纯文本渲染已纳)   |
| Section 4  (Data/UX) | 4 edge cases mapped, 0 unhandled            |
| Section 5  (Quality) | 1 issue (文件归属约束)                      |
| Section 6  (Tests)   | Diagram produced, 1 gap (深读 worker 测试)  |
| Section 7  (Perf)    | 0 issues                                    |
| Section 8  (Observ)  | 1 gap (deep_read 事件→T1)                   |
| Section 9  (Deploy)  | 1 risk (flag 已纳)                          |
| Section 10 (Future)  | Reversibility: 5/5, debt items: 2           |
| Section 11 (Design)  | 1 issue (recap 密度→Phase 2 深审)           |
+--------------------------------------------------------------------+
| NOT in scope         | written (4 items)                           |
| What already exists  | written                                     |
| Dream state delta    | written                                     |
| Error/rescue registry| 4 rows, 0 CRITICAL GAPS                     |
| Failure modes        | 3 total, 0 CRITICAL GAPS                    |
| TODOS.md updates     | 1 item proposed (C2 sparkline)              |
| Scope proposals      | 3 proposed, 1 accepted (SELECTIVE)          |
| CEO plan             | written (~/.gstack/projects/VoiceTodo/)     |
| Outside voice        | codex: unavailable (端点未配 frontier 模型)  |
| Lake Score           | N/A (本轮决策均 kind 差异,无 coverage 打分) |
| Diagrams produced    | 3 (深读数据流/用户流/任务流隐含)            |
| Stale diagrams found | 0                                           |
| Unresolved decisions | 1 (UC1 排队 Phase 4 门)                     |
+====================================================================+
```

## Decision Audit Trail

| # | Phase | Decision | Classification | Principle | Rationale | Rejected |
|---|-------|----------|----------------|-----------|-----------|----------|
| 1 | ceo | 模式=SELECTIVE EXPANSION | Mechanical | autoplan 固定 | — | — |
| 2 | ceo | C1 skipStep 事实行 ACCEPT | Taste | P2 | 治冷启动空屏 | defer/skip |
| 3 | ceo | C2 sparkline DEFER | Taste | P3 | 形态未定先喂 AI | accept |
| 4 | ceo | C3 历史否决项 SKIP | Mechanical | P4 | 反 gaming+两轮拍板 | — |
| 5 | ceo | spec C-1/CL-1/C-2 三修正 | Mechanical | P1 | 内部一致性 | — |
| 6 | ceo | F1 埋点前置 ACCEPT | Taste | P1/P6 | 动机零数据,先测量 | 维持顺序 |
| 7 | ceo | F2 paywall flag ACCEPT | Taste | P1 | 保护软启动读数 | 直接上 |
| 8 | ceo | F5 样本量标注 ACCEPT | Taste | P5 | 不误导,改动最小 | 粗档 |
| 9 | ceo | F4 事实行冷却 REJECT | Taste | 既有拍板 | v4 拍板 1 冲突 | — |
| 10 | ceo | F6/F8/S2/S3/F3/F7/F12 验收条款 ACCEPT | Mechanical | P1 | 完整性补课 | — |
| 11 | ceo | F9/F11/tap-chips NOT in scope | Taste | P3 | GTM 数据后议 | — |
| 12 | ceo | UC1(GTM 时间盒) 排队 Phase 4 | User Challenge | — | 用户拍板方向保留 | — |


### Design Phase 2（2026-10-10 · [single-model：Claude only] · mockup 不可用-无 OpenAI key → 纯文本评审）

```
DESIGN OUTSIDE VOICES — LITMUS SCORECARD:
═══════════════════════════════════════════════════════════════
  Check                                    Claude  Codex  Consensus
  1. Brand unmistakable in first screen?   NOT SPEC'D  N/A  N/A
  2. One strong visual anchor?             YES(Hero 数字) N/A  N/A
  3. Scannable by headlines only?          PARTIAL   N/A  N/A
  4. Each section has one job?             PARTIAL(D5) N/A  N/A
  5. Cards actually necessary?             YES(既有卡语汇) N/A N/A
  6. Motion improves hierarchy?            N/A(未涉动效) N/A N/A
  7. Premium without decorative shadows?    YES(轻量 iOS) N/A  N/A
  Hard rejections triggered:               0         N/A
═══════════════════════════════════════════════════════════════
```

**七 pass 评分（前→后）**：
- Pass1 信息架构 4→9（D1 三层视觉序/D2 对质区次序/D5 占位兜底——均采纳入义务块）
- Pass2 状态覆盖 3→9（D3 四格表/D4 深读就绪后出现+接地校验/D6 极瘦屏/D12 大 somedayCount——均采纳）
- Pass3 情绪弧线 5→9（D2 中性引用框架/D7「与上期相同」标注/D11 深度预期显式化——均采纳）
- Pass4 AI slop 5→8（硬拒绝 0；特异性经 D1/D2/D8 形态定稿提升；mockup 未生成故封顶 8，余量留实施后 /design-review 视觉 QA）
- Pass5 设计系统对齐 6→8（无 DESIGN.md——代码级基准 DesignSystem.swift+CLAUDE.md 文本布局规则；GTM 后建议 /design-consultation 立正式 DESIGN.md）
- Pass6 响应/a11y 5→8（44pt 触达/AX5 已在 CEO 义务；本 pass 补 VoiceOver 标签规范采纳）
- Pass7 决议登记：本 pass 解决 13 项（D1-D12+VoiceOver）；延后 3 项——对质区视觉方向 mockup（设计器无 key，实施后视觉 QA 补）、深读输出位置（随 UC1）、麦克风交互形态细节（D8 列为第5项开工前置）

**总评分：3/10 → 8/10**（初始最低 pass2=3；修后最低 pass4/5/6=8）。

**Design NOT in scope（新增）**：对质区/sparkline 视觉 mockup（设计器缺 key；/design-consultation 与实施后 /design-review 承接）、动效规范（本轮零动效面）。

**Design Implementation Tasks**：_No new tasks — D1-D12/Pass6 全部折叠进既有 T1-T6 验收标准（T2←D1/D5/D6/D7/D10、T4←D2/D3/D8/D9/VoiceOver、T5←D4、T3←D12）。_

### Eng Phase 3（2026-10-10 · [single-model：Claude only] · MODE=FULL_REVIEW scope accepted as-is）

**Scope Challenge**：复用地图=CEO 0B（零重写）；复杂度 9 文件+1 新类（FactsDTO）→ B 门触发 → auto-decide **Original arrangement**（P2 不减范围：文件与六项已批 scope 一一对应，无更小排列能保住承诺）；Scope 记录：`feature answers: v5 拍板 1-4+spec/CEO/Design 义务块; structure: Original(autoplan P2); accepted scope: 待实施清单 6 项+全部义务块; pending remedies: UC1`。

```
ENG DUAL VOICES — CONSENSUS TABLE:
  Dimension                           Claude  Codex  Consensus
  1. Architecture sound?               是(分层稳) N/A   N/A
  2. Test coverage sufficient?         计划已列11断言 N/A N/A
  3. Performance risks addressed?      无新风险   N/A   N/A
  4. Security threats covered?         E6/E11 收口 N/A  N/A
  5. Error paths handled?              E1/E5 补齐 N/A   N/A
  6. Deployment risk manageable?       flag+UC1 门 N/A  N/A
```

**S1 架构**：2 发现（E5 数字块契约、E11 限额参数）均采纳。分层不变：纯函数规则层→State 收集→视图只读；深读复用 reflect 不计费通道；麦克风复用注入链。S2 代码质量：3 发现（E4 session schema、E7 两把尺、E9 xcstrings 纪律）采纳；E7 根因修复（批量判定改用户日）。S4 性能：0 发现（1 LLM call/session；52 期上限；E11 长度上限并入）。

**S3 测试（覆盖图，计划态——全部为 GAP→已入测试计划工件）**：
```
CODE PATHS                                        USER FLOWS
EffortOrderingRule 中间地带→.fact  [GAP→T2]       冷启动首次复盘     [GAP→C1 夹具]
EnergyWindowRule 单腿→.fact+0..23  [GAP→T2/E3]    批量推稍后 40+     [GAP→D12]
collect skipStep 档仅 .fact        [GAP→E1]       录音失败降级       [GAP→S2/E10]
somedayBatch 21天用户日             [GAP→T3/E7]    深读失败无感       [GAP→D4]
对质区三态                         [GAP→T4]       gate 三入口        [GAP→E6]
深读 E5 数字块校验                  [GAP→T5→EVAL]  漏斗三事件         [GAP→E8]
worker deep-read mode              [GAP→T5→EVAL]
session E4 结构化键解码             [GAP→T2]
LLM: worker.js 触发 → AIProxy eval(npm test 318 基线+deep-read 黄金 fixture+F3 盲评)
COVERAGE: 0/11 现有 → 11 项全入测试计划(全新路径,计划态)
```
测试计划工件：~/.gstack/projects/VoiceTodo/TWJ-fupan-eng-review-test-plan-20261010-212646.md

**Failure modes（eng 视角新增）**：skipStep 冷却污染（E1，测试=断言空数组，用户=下期不误静音）；接地校验误杀/漏放（E5，测试=确定性假分析器，用户=无感）。0 项三无（无测试+无处理+静默）。

**TODOS.md**：新建，5 项（C2 sparkline P2 / F9 / F11 / tap-chips / DESIGN.md P3）。

**Eng Implementation Tasks**：_No new tasks — E1-E11 全部折叠进 T1(E8)/T2(E1/E2/E3/E4/E9)/T3(E7)/T4(E6/E10)/T5(E5/E11) 验收标准。_

### Eng Completion Summary
- Step 0 Scope Challenge：scope accepted as-is（Original arrangement, P2）
- Architecture Review：2 issues（E5/E11，采纳）
- Code Quality Review：3 issues（E4/E7/E9，采纳）
- Test Review：diagram produced，11 gaps 全入测试计划工件
- Performance Review：0 issues
- NOT in scope / What already exists：CEO 相位已写，eng 无新增
- TODOS.md updates：5 items（已写入仓库 TODOS.md）
- Failure modes：0 critical gaps
- Unresolved decisions：0（eng 内全部处置；UC1 归 Phase 4 门）
- Outside voice：codex unavailable（端点未配 frontier 模型）
- Parallelization：T1→T2/T3 并行→T4→T5（UC1 后）；Lane A: T1→T2 / Lane B: T3 → 合并 → T4 → T5
- Lake Score：N/A（本相位决策无 coverage 打分）

<!-- audit-eng -->
| # | Phase | Decision | Classification | Principle | Rationale | Rejected |
|---|-------|----------|----------------|-----------|-----------|----------|
| 13 | eng | 结构=Original arrangement | Taste(auto) | P2 | 文件↔已批 scope 一一对应 | Smaller |
| 14 | eng | E1 skipStep 仅收集 .fact | Mechanical | P1 | 冷却不变量 | 全评估 |
| 15 | eng | E2 fact 复用 fired 分母 | Taste(auto) | P5 | 同屏一把尺 | 新分母 |
| 16 | eng | E3 fact 扫描 0..23 | Mechanical | P1 | 凌晨不误导 | 维持 5..23 |
| 17 | eng | E7 批量判定改用户日 | Taste(auto) | P5 | 根因修复 | 仅加夹具 |
| 18 | eng | E4/E5/E6/E8/E9/E10/E11 采纳 | Mechanical | P1 | 口径补全 | — |

### Eng 增量审（standalone /plan-eng-review · 2026-10-10 · 终稿装配态 · [single-model]）

**Scope**：只审装配后终稿（原拍板+39 义务块+审计表）的一致性与遗漏；上轮 autoplan Phase 3 审的是审前稿。复杂度 0 文件 0 类 → B 门跳过。Scope Challenge 结果：scope accepted as-is（MODE=FULL_REVIEW）。

**发现与处置**：
- Δ1 [P2] (9/10) :109 — 已裁决门标注残留（第 6 项 pending UC1，实际已在最终门裁决维持原方向）→ **已修**（清单第 6 项改「UC1 已裁决+三道保险」）。
- Δ2 [P2] (9/10) 义务块 E7 — 口径切换爆炸半径未列 → **勘误追加**（见下），不动 autoplan 义务块字节。
- Δ3 (6/10) 占位行语义分散三处 → **压附录**：三档单测（测试计划工件）已钉死行为，交叉引用属锦上添花，不构成 gap。
- Δ4 [P3] (7/10) D6 旁注时机含糊 → **D1 问询拍板：现在就写**（已写入确认不动表旁注）。

**E7 勘误（Δ2，证据行已核）**：`stagnationDays` 自然日→用户日的口径切换影响 **5 个生产调用点**——`TriageRanking.swift:35/:71`（rank/sortByStagnation 排序）、`ReviewFlowView.swift:342`（preexistingNextWeek 排序）、`:752`（somedayBatch 批量资格）、`ReviewStepTriage.swift:634`（卡头「记下 N 天了」显示）、`ReviewStepCommit.swift:27`（scheduled 排序）。全部改一致；**预期收益**=卡头与地板 A 同屏差 1 天的既有显示毛刺（v4 走查已记录）随之消失；deck 相对序在 startHour>0 用户微移（无害）；`InsightEngine.swift:316` 「有意不同」注释需同步更新；F6 夹具顺带核对卡头 N 天新值。

**Decision ledger（本审）**：D1 D6 旁注时机 → A 现在就写（已执行）。Approval readiness: PASS（Δ1/Δ2 事实性修正免问，D1 已答，无遗留）。

**Outside Voice**：Codex unavailable（自定义端点未配 frontier plan-review 模型——本日第 4 次同因；修复 `gstack-config set model_frontier_openai <id>`）。[single-model]。

**Completion summary**：Scope Challenge: scope accepted as-is（增量）; Architecture 0 新发现; Code Quality 1（Δ2）; Test 0 新缺口（Δ2 勘误补 F6 项）; Performance 0; issues_found=3（Δ1/Δ2/Δ4），0 critical gaps，0 unresolved; Parallelization: 不变（T1→T2∥T3→T4→T5→T6）。

### CEO + Design 增量审（standalone · 2026-10-10 · HOLD SCOPE / 增量确认 · [single-model]）

**CEO 增量**（模式 HOLD SCOPE；无新裁决）：Phase 1 后四处变更（UC1 裁决标注/D6 旁注/E7 勘误/TODOS.md）逐一战略透镜核查——前提/复用/梦想态均不变，延后项全带上下文落档；**0 发现，方向确认**。
**Design 增量**：四处变更中仅 D6 旁注触设计面=Design 相位 D6 义务落稿关闭；其余无 UI 面；Phase 2 评分（3→8）与 litmus 结论维持。**0 发现**。
两相位 Outside Voice 沿 unavailable（同端点配置）。Approval readiness: PASS。

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` (autoplan + standalone 增量) | Scope & strategy | 2 | CLEAR | P1: 3 proposals, 1 accepted, 1 deferred; 12 findings 采9拒1; 增量: 0 findings 方向确认 |
| Outside Review | codex (via /autoplan ×3 相位) | Independent 2nd opinion | 3 | unavailable | 端点未配 frontier 模型，无外部完成记录 |
| Eng Review | `/plan-eng-review` (autoplan Phase 3 + 本 standalone 增量) | Architecture & tests (required) | 2 | ISSUES OPEN | P3: 11 issues 采全部, 0 critical; 增量: 3 issues (Δ1 修/Δ2 勘误/Δ4 拍板), 0 critical |
| Design Review | `/plan-design-review` (autoplan + standalone 增量) | UI/UX gaps | 2 | CLEAR | P2: score 3/10 → 8/10, 13 decisions; 增量: 0 findings |
| DX Review | — | 无 developer-facing scope | 0 | SKIPPED | — |

- **OUTSIDE COVERAGE:** codex, phases ceo/design/eng, unavailable（自定义 OpenAI 端点未配模型,本日 4 次同因）; standalone 增量审同因 unavailable。全部单模型,CROSS-MODEL 不可评估。
- **VERDICT:** CEO + DESIGN CLEARED; ENG ISSUES OPEN（实施未开始,发现均已处置入计划;代码落地后跑 /review 或双 review 循环收口）——eng review required before ship。
NO UNRESOLVED DECISIONS

