# 复盘流程 v3 —— 走查核实与改版方案

> 状态：**待实施**。基线 `7959174`（`claude/review-flow-breakpoints-x8izga`）。
> 2026-09-04 审阅修订（一轮，15 条断言全部核实属实后修方案层）：拍板 3 表格与正文对齐（`Still open` 保持全时段口径）、删除 ① 屏跨口径算式、hero 空态补回退、sameDay 判词语义修正、② 屏积压数改 init 快照、占位键 4→3（rotting 无占位分支）、untouched 文案去掉「都不满 30 天」断言、⑤ 屏 N=0 边界、引擎前移连带项补齐。
> 前作：`docs/todo-review-flow-design.md`（v1，已实施）、`docs/todo-review-flow-v2.md`（v2，已实施 2026-09-02）。
> 走查条件：**英文环境 + 25 条积压 + 26 条近 30 天完成 + 事件表无推迟历史**（与 v2 走查同一台设备，数据长了一轮）。
> 环境提示：Swift 需在 Xcode 26 编译验证；`Protocols/` 纯逻辑可 `swift test` 单跑。
> 相关文件：`UI/Review/Flow/ReviewStepRecap.swift`、`ReviewStepTriage.swift`、`ReviewStepInsights.swift`、
> `ReviewStepCommit.swift`、`ReviewStepLedger.swift`、`ReviewFlowView.swift`、`UI/Review/RecapComponents.swift`、
> `Protocols/Domain/ReviewAggregator.swift`、`Protocols/Domain/Insights/Rules/EffortOrderingRule.swift`、
> `Resources/Localizable.xcstrings`。

## Context

v2 修好了「真实数据下流程会塌」——第 2 步不再是 35 张苦役，第 4 步不再撞空池，第 5 步不再是五行 0。这一轮走查的问题换了一层：**五屏各自都成立，串起来断了。**

一条完整的复盘线应该是：

> 上周发生了什么 → 欠账怎么处理 → 我看出了什么 → 下周承诺什么 → 留一句话下次带回来

现在断在三处：①③④ 三屏各自与前后屏没有引用关系，②⑤ 有引用关系但没在界面上说出来。

---

## 走查断言核实

走查稿的每条断言都在代码里核对过。**九条属实，三条需要修正，另有三条走查没看见但更要紧。**

### 属实（九条）

| # | 走查断言 | 代码证据 |
|---|---|---|
| 1 | ① 屏三个时间窗口并列 | `review.flow.recap.scope` 写死「近 30 天」；`RecapSummaryBuilder.monthSummary` 窗口 = `-1 month`；`lastReviewDate` = 昨天；而 `ReviewNotificationScheduler.weeklyIdentifier` 的节奏是**每周一 9:00** |
| 2 | ① 屏三个数字算不平（73−26≠25） | 三个数**三种口径**，见下表 |
| 3 | ① 屏闭环行被藏起来 | `ReviewStepRecap.scopeHeader` 用 `WarmFont.caption(11)` + `textMuted`；`RecapHeroSection` 用 `serifDisplay(40)` + `primary` |
| 4 | ① 屏 sameDay 判词无所指 | `review.hero.sameday_%lld` 只陈述件数，无好坏判定、无下游动作 |
| 5 | ② 屏筛选口径自相矛盾（文案层面） | 标题说「未完成的一次性任务」，底部只解释**尾部**的 30 天门槛，卡堆前 8 张凭什么入选无处可读 |
| 6 | ② 屏「Never deferred」+ 空进度条 | `ReviewStepTriage.timeline`：`deferCount == 0` → `nodes == 0` → 渲染成「一个点 + 一条线 + 一个圈」 |
| 7 | ③ 屏是必须点 Next 跳过的空屏 | `rankedResults` 空 + `ladderNeedMore == nil`（26 ≥ 15 → `.full` 档）→ 整屏只剩 `placeholderSummaryRow` 一行灰字 |
| 8 | ④ 屏标题与分组标题打架 | `commit.hint`「挑出下周的重点」 vs `commit.group.existing`「本来就在下周的」 |
| 9 | ⑤ 屏「Other」是兜底分类漏进文案 | `TodoCategory.allCases` 含 `.other`，`askDomainHintCategory` 不排除它，`category.other` = "Other" |

**①屏三数的三种口径**（`RecapEvidenceRow`）：

| 卡片 | 函数 | 时间窗口 | 含规律任务？ | 含已完成？ |
|---|---|---|---|---|
| Done 26 | `ReviewAggregator.summarize` | 近 30 天 | ✅ 含 occurrence 完成记录 | — |
| Added 73 | `ReviewAggregator.createdInWindow` | 近 30 天 | ✅ 含规律父任务 | ✅ 含 |
| Still open 25 | `ReviewAggregator.pendingOneOffCount` | **全时段，无窗口过滤** | ❌ 排除 | ❌ 只数未完成未划掉 |

三个数没有任何算术关系可言。`pendingOneOffCount` 的注释写着「三处数字必须同源」——它说的是**与入口卡、第 2 步卡堆同源**（这一点确实成立），但它与同一行的另外两个数不同源，注释没提，界面更没提。

### 需要修正（三条）

**A · ② 屏中间两个按钮「没有文字标签」——错，标签在代码里，是布局把它挤没了。**

`ReviewStepTriage.padCapsuleButton` 是 `Label(title, systemImage: icon)`，`review.flow.triage.action.today` = "Do today"、`.split` = "Split"，三语齐全。截图里只剩图标，是 `pad` 这个 `HStack` 在 iPhone 宽度下被两侧 56pt 圆钮 + `WarmSpacing.lg` 挤到中段 `Label` 的 title 塌掉。

**这改变了修法**：不是补文案（文案已有），是改布局——中段两个胶囊必须拿到确定宽度，或改成与两侧圆钮同构的「图标 + 下方小标签」。走查稿把它归进「文案打磨」，实际是布局 bug，优先级更高：这是四个动作里唯二不可猜的两个，而且在中文/日文下同样会塌。

**B · ④ 屏选的东西「必须在下次 ① 屏被点名验收，否则不闭环」——闭环已经实现了，只是被排版埋了。**

链路完整存在：`commitSelection` → 过闸时写 `ReviewPinningStore` → 下次会话 `lastPinnedIDs` 注入 → `ReviewFlowState.lastPinnedOutcome(todos:pinnedIDs:)` 从原始快照对账 → `ReviewStepRecap` 的 `review.flow.recap.last_pinned_outcome` 行。截图里那句 "Priorities from last review: 0 done, 2 still open" **就是它**。

**这改变了成本**：走查稿把这条列为「三件事之一」的重活，实际只是把一行 11pt `textMuted` 提成主标题——是本方案里最便宜、收益最高的一改。

**C · ② 屏「8 + 17 = 25 正好是上屏 still open，但两屏没有呼应」——数确实同源，且这是全流程唯一一处真正对得上的数。**

`ReviewFlowState.triageInput` 与 `ReviewAggregator.pendingOneOffCount` 是逐字相同的谓词（`!isCompleted && abandonedAt == nil && recurrenceRule == nil`）。所以这里**不需要改数据，只需要改一句文案**，把已经成立的关系说出来。相比之下 ① 屏那三个数是真的对不上，得改口径。

### 走查没看见的（三条，其中两条比上面任何一条都严重）

**D · ⑤ 屏的主角卡根本没渲染，整屏名不副实。**

`ReviewStepLedger.summaryCard` 的守卫是 `state.decidedCount > 0 || ledger.somedayCount > 0`。走查时第 2 步一张没处理 → `decidedCount == 0`、`somedayCount == 0` → **「你决定了 N 件」整张卡静默消失**。

这就是截图里那一屏的真相：一个叫「Ledger」的步骤，账本不在上面。v2 拍板 4 把「你决定了 N 件」定为收尾主角，理由是「不能用同一句话庆祝」；但零决定时主角直接缺席，剩下的三张卡（历次笔记 / 问问自己 / 下次复盘）没有一张是收尾语义。

v2 实施补注的原意是「『你决定了 0 件』是审判，不是确认」——方向对，处置错了：**零决定不是没内容可说，是有另一句话该说**（「这次一件都没决定，25 件原样留着」——这是事实陈述，不是审判）。静默消失让用户以为这一屏坏了。

**E · ③ 屏那句「Record 3 more」在说谎，且代码里早写明了它会说谎。**

26 条完成 → `InsightEngine.ladder` = `.full` → 四条规则全跑。`EnergyWindowRule.minSample = 15` 已满足，所以 needMore = 3 只可能来自 `EffortOrderingRule`（`minPerGroup = 3`，`needHigh = 3 - 0`）——意思是**「再标 3 条高优先级任务」**，不是「再记 3 条任务」。

`EffortOrderingRule.swift:36-38` 的注释原话：

> 高优组有缺口时优先报高优缺口——解锁条件是「高优任务」，**通用占位文案会误导用户去记普通任务**。

而 v2 拍板 6 把四条占位合并成一行通用文案 `review.flow.insights.need_more_merged_%lld`，**正好把这条注释警告的事做了**。合并解决了「四行堆叠刺眼」，代价是把唯一一条带具体解锁条件的占位降级成了错误指令。按现在的文案照做（再记 3 条普通任务）永远解不开这条洞察。

**F · ④ 屏 Next 是灰的，但屏上没有一个字说明为什么。**

`canPassCommit = commitPool.isEmpty || !commitSelection.isEmpty`。候选池非空 + 未选 → 按钮禁用。`hint` 那句「at least 1, 3 recommended」在屏幕最顶端，滚动一屏后就看不见了，而按钮在最底部。这才是「④ 屏像死路」的直接原因——比候选池没筛过更早撞上。

顺带：`preexistingNextWeek` **完全没有排序**，是 `store.todos` 的原始序过滤后的结果。走查稿说「候选池没筛过」属实，但更准确的说法是**连排都没排**。

### 附带发现（不在主线，但该记一笔）

`review.hero.count_%lld`、`review.stat.streak`、`review.stat.upcoming_7d_%lld` 以及全部 7 个 `category.*` 键**缺 ja 本地化**。v2 实施补注说「新增 24 键全部 zh/en/ja 三语」——新键属实，这些是 v2 之前的老键。日文环境下 ① 屏主标题和 ⑤ 屏领域提示会回落英文。`docs/mvp-japanese-launch/` 存在，说明日语是发布目标，应在同一轮补齐。

---

## 拍板决定（2026-09-04）

| # | 决定 | 选择 | 理由 |
|---|---|---|---|
| 1 | ① 屏时间窗口 | **统一到「上次复盘至今」**，首次复盘回落近 7 天 | 提醒节奏是每周一；30 天窗 + 「Sep 2026」标签 + 昨天复盘三件并列，读者无法知道在总结哪一段 |
| 2 | ① 屏主标题 | **换成上次承诺的兑现结果**，`26 completed` 降为证据行 | 闭环行已有数据（修正 B），只是排版倒置；完成数是虚荣指标，兑现率才是复盘的意义 |
| 3 | ① 屏三数口径 | Done/Added 随拍板 1 统一到同一窗口；**`Still open` 保持全时段口径不动**，同屏补一行说明它与左两数不同窗 | 三种口径同屏且无标注，用户一定会算这笔账；但 `pendingOneOffCount` 与 ② 屏卡堆、入口卡三处同源是硬约束（修正 C），动口径连带三处，解释一行比迁移三个数收益高风险低 |
| 4 | ② 屏中段按钮 | **改成与两侧同构的「图标 + 下方标签」**，不靠 `Label` 自适应 | 布局塌陷（修正 A），中日文同样会塌 |
| 5 | ② 屏筛选说明 | **卡堆上方一句说清「为什么是这 8 张」**，尾部说明保持 | 现有文案只解释尾部，入选理由无处可读 |
| 6 | ② 屏零推迟时间轴 | **`deferCount == 0` 时整块不渲染**，只留卡头「记下 N 天」 | 一个点一条线一个圈不携带任何信息 |
| 7 | ③ 屏空态 | **`rankedResults` 为空时整步跳过**；占位行改为**报具体解锁条件** | 空屏 + 错误指令（发现 E）比不出这一步更差 |
| 8 | ④ 屏分组与排序 | 标题改「下周你要认真做哪几件」；候选池**按停滞天数 desc 排序** | 消解标题打架；从琐事里挑焦点，挑完没有分量 |
| 9 | ④ 屏闸门 | **禁用态按钮上方常驻一行原因** | 死路感的直接来源（发现 F） |
| 10 | ⑤ 屏零决定 | **主角卡改为永远渲染**，零决定走「原样留着」文案 | 名叫 Ledger 的屏上没有账本（发现 D） |
| 11 | ⑤ 屏领域提示 | **`.other` 排除出轮换**；标题与占位符统一成同一个问题 | 兜底分类不该当提问对象；一个输入框不能问两件事 |

---

## 逐屏改版

### ① Recap · 主角换成兑现，不是产量

**改动**

1. **窗口统一**。`RecapSummaryBuilder` 增加 `weekSummary(since:)`，起点 = `previousSessions.last?.completedAt`（无则 `today - 7d`）。`periodLabel` 不再用日历月（现在 `26 completed / Sep 2026` 是**错的**：26 是滚动 30 天的数，标签却声称是九月的数，而今天才 9 月 4 日），改成窗口本身的描述（「Aug 28 – Sep 4」）。
   `review.flow.recap.scope` 随之改成「上次复盘以来」。
2. **主副对调**。`lastPinnedOutcome` 从 `caption(11)/textMuted` 升到 `serifDisplay(32)/primary`，文案改判词式：「上次定的 2 件，1 件做完了」；`review.hero.count` 降到 `RecapEvidenceRow` 的 Done 卡（数字仍在，位置降级）。
   ⚠️ `RecapHeroSection` 是**回顾页与本步共用**（`RecapComponents.swift` 头注释、v2 审阅缺口 A）：沿用 `promotesSameDay` 的模式加 `heroContent: HeroContent` 参数，默认值 = 回顾页现状，**回顾页零变化**。
   ⚠️ 空态回退：`lastPinnedOutcome == nil`（首次复盘 / 上次没置顶 / 上次置顶的已全删）时，主标题**回退现状的 `review.hero.count_` 句式**，不硬造「上次没有承诺」的空标题——兑现判词是有上次承诺才有的话，没有就别占这个位置。`HeroContent` 实际三态：回顾页默认 / 兑现判词 / 回退。
3. **三数同窗**。`pendingOneOffCount` 保持全时段口径（它必须与 ② 屏卡堆同源，见修正 C），`RecapEvidenceRow` 补一行 `caption(11)` **只做一件事：说明 `Still open` 与左两数不同窗**——「Still open 25 是全部积压，不只这一窗」。**不写减法算式**：窗口统一后 Done/Added 虽同窗，但「Added − Done」仍不是任何真实集合——Done 含窗口前记下、本期做完的，Added 含已完成与已划掉的；算式一旦上屏就是新的自相矛盾，恰是本方案要消灭的东西（审阅修订：删去初稿「73 − 26 = 47 件进了清单」）。
   **候选方案（更彻底）**：`Still open` 换成窗口内新增且未完成的数，全时段积压另起一行。本方案取前者——`triageInput` 同源是硬约束，动它会连带 ② 屏与入口卡三处对不上。
4. **sameDay 给指向**。`11 of them were captured and done the same day` 后接一句判定：占比 > 40% 时「大多是记下当天就做完的——清单在被当即时备忘用，提前一天以上记下的完成得少」，否则整句不出（沿用 `summary.total > 0` 的既有守卫模式）。
   ⚠️ 判词不能写「清单被绕过 / 没进过清单」（审阅修订）：sameDay 的定义就是「**记下**当天做完」，这些事恰恰进了清单——高占比说明的是提前量不足（清单在记录、不在驱动），不是绕过。走查稿的直觉文案会被用户一眼证伪。

**验收**：① 屏任意时刻只出现一个时间口径；主标题是上次承诺的结局；三个数要么同窗口，要么有一行说明它们不同窗口。

### ② Catch Up · 把已经成立的关系说出来

**改动**

1. **中段按钮改同构布局**（拍板 4）。`padCapsuleButton` 换成 `padRoundButton` 同款结构（图标 44pt 圆 + 下方 `caption(11)` 标签），四个按钮走同一个 `HStack(spacing:)`，中段两个用 `.layoutPriority(1)` 保证标签不塌。视觉层级靠尺寸区分（两侧 56pt / 中段 44pt），不靠有无标签区分。
2. **卡堆入选理由**。`ledeText` 上方加一行接上屏：「25 件积压里，推迟最多、放得最久的 8 件在这儿」。数字取 **init 快照的积压总数**——`ReviewFlowState` 增加 `initialBacklogCount`（= 排序前 `triageInput(from:).count`，init 一次算好），与 ① 屏 `Still open` 天然同源（修正 C）。
   ⚠️ 不能在渲染期用 `ledger.inputCount + tail.count` 动态求值（审阅修订）：批量推「稍后」落地后 `tail` 缩水，同屏数字会从 25 跳到 8——恰是本方案要消灭的同屏矛盾。快照数在整个会话内恒定。
3. **零推迟不画时间轴**（拍板 6）。`timeline(_:)` 加 `guard deferCount > 0`；`review.flow.triage.tl_nodefer` 键删除。卡头 `review.flow.triage.born_days_%lld`（「Noted 3 days ago」）已经承载了「放了多久」，不重复。
4. **尾部文案接上文**。`review.flow.triage.batch.untouched_%lld` 现在读起来像在解释卡堆的筛选口径，改成明确指向尾部：「余下 17 件这次不动——下次复盘还会回来」。
   ⚠️ 文案不要断言「都不满 30 天」（审阅修订）：`untouchedTailCount` 里除了不满 30 天的，还有 ≥ 30 天但 AI 识别失败（`.rawFallback` / `.unparsed`，永不丢话原则的手动卡）被批量出口排除的条目——对它们这句话是假的。现状 en 文案 "newer than 30 days" 同样有此问题，本次一并修掉；30 天门槛语义由出口行标题「超过 30 天没碰过」承载，不在这行重复。

**验收**：四个按钮都能读出动作名（中/英/日三语）；卡堆数与 ① 屏 `Still open` 的关系在屏上可读；零推迟卡片上没有空进度条。

### ③ Insights · 有话说才出这一步

**改动**

1. **空态整步跳过**（拍板 7）。`ReviewFlowState` 增加 `skipsInsightsWhenEmpty`：`runEngine` 跑完若 `rankedResults.isEmpty`，走与 `skipsInsights` 相同的跳过路径（`advance`/`retreat` 已有分支，复用即可）。
   ⚠️ 时序：`runEngine` 在 `ReviewStepInsights.task` 里跑，此时已经在第 3 步了。**必须把引擎前移**到 `ReviewFlowView` 拿到 `insightContextValue` 之后（与 `configureInsightsLadder()` 同一时机），结果存 `state`，视图只读。否则会出现「进了第 3 步再被弹走」的闪屏。
   引擎前移连带三处，一并做掉（审阅修订补齐）：① `rankedResults` / `placeholders` / `ladderNeedMore` 从视图 `@State` 迁入 `ReviewFlowState`；② `ReviewStepInsights` 的 `.task { runEngine() }` 与 `.onChange(of: insightContextValue)` 两个触发点删除——重试路径走 `loadInsightContext` 重跑，引擎随跑、flag 随更新；③ `stepBarFill` 的跳过态视觉目前只读 `skipsInsights`，新 flag 同样要接，否则步骤条上 ③ 段不显示跳过态。
2. **占位行报真实解锁条件**（拍板 7，修 发现 E）。`placeholderSummaryRow` 不再只取 `max(needMore)`，改成取 `needMore` 最小（最接近解锁）的那条，并按 `InsightID` 选对应文案：
   - `.effortOrdering` → 「再标 3 条高优先级任务，就能看出你是先易后难还是先难后易」
   - `.energyWindow` → 「再记 N 条完成时间，就能看出你的精力窗口」
   
   新增 3 个 `review.flow.insights.need_more.<id>_%lld` 键（三语：`reactiveVsPlanned` / `effortOrdering` / `energyWindow`——`RottingRule` 只有 hidden/fired 两态、永不返回占位，无需配键；审阅修订：初稿误计 4 个），删除 `need_more_merged_%lld`。
   这不是回退拍板 6（拍板 6 反对的是**四行堆叠**）：仍然只出一行，只是这一行说真话。
3. **最小事实保留**。`ladderHint` 的 5–14 档逻辑不动。

**验收**：③ 屏要么有至少一张洞察卡，要么整步不出现；占位文案里的动作照做能真的解锁对应洞察。

### ④ Next Week · 先说清为什么不能过，再谈挑什么

**改动**

1. **闸门原因常驻**（拍板 9，修 发现 F）。`ReviewFlowView` 底部主按钮上方，`canAdvanceCurrentStep == false` 时渲染一行 `caption(12)/primaryText`：「至少选 1 件才能继续」。这是**流程级**改动，`Step.commit` 是目前唯一有硬闸门的步骤，但按钮禁用无说明是通用缺陷。
2. **标题消歧**（拍板 8）。`review.flow.commit.hint` 改「下周你要认真做哪几件？选中的会在下次复盘里被点名」——后半句显式声明与 ① 屏的引用关系（这条链路本就存在，修正 B）。分组标题 `group.existing` 改「已排在下周（还没选为重点）」，把「排期」与「重点」两个概念拆开。
3. **候选池排序**（拍板 8）。`preexistingNextWeek` 与 `scheduled` 各自按 `TriageRanking.stagnationDays` 降序——放得最久的排最前。**复用 ② 屏已有的排序原语，不引入新的重要性模型**（任务没有 estimate 字段，按「大小」排在当前数据模型下做不到；停滞天数是现成且有意义的代理）。

**验收**：Next 禁用时屏上有原因；标题与分组标题不打架；候选列表最上面是放得最久的。

### ⑤ Ledger · 账本永远在

**改动**

1. **主角卡不再消失**（拍板 10，修 发现 D）。`summaryCard` 去掉外层守卫，改三态：
   - `decidedCount > 0` → 现状「你决定了 N 件」
   - `decidedCount == 0 && somedayCount > 0` → 只出批量行（现状已支持）
   - **全零 → 「这次一件都没决定，N 件原样留着」**（N = `initialBacklogCount`，与 ② 屏 lede 同一快照口径）+ 既有 caption
   - 边界（审阅修订）：全零且 N == 0（本期本就没有积压）时整卡仍不出——「0 件原样留着」是无信息量的噪音；守卫从「有决定或有批量」改成「N > 0」。
   
   新增 1 键 `review.flow.ledger.decided_none_%lld`（三语）。这是**事实陈述不是审判**：v2 补注担心的「你决定了 0 件」的问题在于用「决定」这个正向动词报零，换成「原样留着」就没有这个语气问题，而且它同时回答了「那 25 件去哪了」。
2. **领域提示排除 `.other`**（拍板 11）。`askDomainHintCategory` 的 `present` 过滤加 `$0 != .other`；全为 `.other` 时返回 nil（提示行本就有 nil 分支）。
3. **一个输入框只问一个问题**（拍板 11）。`ask.placeholder` 从「这周是什么挡住了你？」改成与 `ask.domain_hint` 同题的续写引导（「随便写两句」）。标题行负责提问，占位符负责降低起笔门槛，不再抢着提第二个问题。
4. **补齐 ja 本地化**（附带发现）：`review.hero.count_%lld`、`review.stat.streak`、`review.stat.upcoming_7d_%lld`、`category.*` 共 10 键。

**验收**：⑤ 屏在任何路径下都至少有一张交代本次会话结果的卡；提问不出现「Other」；日文环境无英文回落。

---

## 落地顺序

按「收益/成本」排，前三项是走查稿点名的三件事的**修正版**（B 使第一项从重活变轻活）：

1. **① 屏主副对调**（拍板 2）——纯排版 + 一个默认参数，闭环数据已在（修正 B）。
2. **② 屏中段按钮布局**（拍板 4）——纯布局，文案已在（修正 A）。
3. **⑤ 屏主角卡三态**（拍板 10）——去掉一个守卫 + 一个新键，修最严重的名不副实（发现 D）。
4. **③ 屏空态跳过 + 占位真话**（拍板 7）——含引擎前移，是本方案唯一有时序风险的改动。
5. **④ 屏闸门原因 + 排序 + 文案**（拍板 8/9）。
6. **① 屏窗口统一 + 三数说明**（拍板 1/3）——改动面最大（`RecapSummaryBuilder` 是两页共用），放最后单独验。
7. **② 屏文案接续 + 零推迟时间轴**（拍板 5/6）、⑤ 屏 `.other` 与提问统一（拍板 11）、ja 补齐。

1–3 可以一个 commit 走完，是独立可发布的一批。

---

## 验证

**单测**

- `RecapSummaryBuilder.weekSummary`：起点取上次复盘时刻；`previousSessions` 为空 → 回落 7 天；`periodLabel` 是窗口而非日历月（**这条是回归护栏**——现状 `Sep 2026` 标签配 30 天滚动数是错的）。
- `ReviewFlowState.askDomainHintCategory`：快照只有 `.other` → nil；含其他分类 → 不返回 `.other`；轮换仍按 `previousSessions.count` 前进。
- `ReviewFlowState` 空洞察跳过：`rankedResults` 为空 → `advance()` 从 `.triage` 直达 `.commit`，`retreat()` 反向对称；非空 → 正常停在 `.insights`。
- `preexistingNextWeek` / `scheduled` 排序：停滞天数降序，同天数按 id 决胜（与 `TriageRanking.rank` 同款确定性）。
- `ReviewStepLedger` 三态：全零 → 渲染「原样留着」行；N == 0 → 整卡不出（现有 `ReviewFlowStateTests` 的 `decidedCount` 夹具可复用；⚠️ `ReviewFlowStateTests` 现有断言「全零——收尾主卡不出」描述的是旧行为，随本改版翻转）。
- `initialBacklogCount`：init 一次算好；批量推「稍后」、卡堆逐张处理后均不随 `ledger` / `tail` 变动。
- Hero 三态：`lastPinnedOutcome` 非 nil → 兑现判词；nil → 回退 `review.hero.count_` 句式；回顾页默认参数渲染不变。
- 占位文案选取：`EffortOrderingRule` 报 needMore=3 且 `EnergyWindowRule` 满足 → 选中 effortOrdering 文案，不出通用句。

**真机手测**

1. **本次走查场景复现**（25 积压 / 26 完成 / 无推迟历史 / **英文环境**）：五屏依次走完，每屏都能指出它与前一屏的引用关系。
2. **零决定路径**：五屏全部点 Next 不做任何决定 → ⑤ 屏有主角卡，且数字与 ① 屏 `Still open` 一致。
3. **闸门路径**：④ 屏不选任何一件 → 按钮禁用且上方有原因行；选 1 件 → 原因行消失、按钮可点。
4. **② 屏三语按钮**：中/英/日下四个按钮标签都完整可读（日文「今日やる」最长，重点看它）。
5. **③ 屏两条路径**：有洞察 → 正常出；无洞察 → 第 2 步 Next 直达 ④ 屏，**无闪屏**（引擎前移的验收点）。
6. **闭环跨会话**：本次 ④ 屏选 2 件 → 下周复盘 ① 屏主标题点名这 2 件的结局。
7. **无承诺路径**（审阅修订补）：上次复盘第 4 步没选任何重点（或首装）→ 本次 ① 屏主标题回退 count 句式，不出现空承诺文案；② 屏 lede 与 ⑤ 屏「原样留着」数字与 ① 屏 `Still open` 一致。

---

## 不在本方案

- **任务大小 / estimate 字段**。④ 屏「从琐事里挑焦点」的根治要有任务量级信息，当前数据模型没有，另立项。停滞天数排序是本方案的代理方案。
- **洞察 04/06 启用**（仍待样本量，v2 结论不变）。
- **恢复完成率**（2026-08-23 独立决定，不受本方案影响）。
- **`Still open` 换成窗口内口径**。见 ① 屏改动 3 的候选方案——会连带 `triageInput` 与入口卡三处，收益不抵风险。
- **批量出口周而复始**（v2 补注 D 的待观察项）：本轮走查 `somedayBatchCandidates` 为空（25 条全部不满 30 天），没有新证据，维持原立场。
