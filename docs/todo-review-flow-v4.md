# 复盘流程 v4 —— 第 3 步(观察)没话说

> 状态：**已实施（fupan3 分支，2026-09-21/22 批 1–5 全部落地，待合并 main）**（方案 2026-09-20；拍板 2026-09-21——方案五条全部按建议采纳，批 3 开工前补拍第 6 条；实施补注见文末）。方案基线 `cab54b3`（main）；实施基线 `2d874a0`（main，晚于方案基线，无冲突）。开发分支 `claude/review-flow-decision-output-959xqn`（文档）/ `fupan3`（代码）。
> 走查条件：**英文环境 + 19 条积压 + 近 30 天完成 ≥15 条（`.full` 档）+ 上次复盘 Sep 16（本期窗口 3 天）+ 有历史会话（Aug 22 留过笔记）**。
> 与 v2/v3 走查的关键差别：**这一轮数据是够的**——降级阶梯走到 `.full` 档，四条规则全跑。上两轮的结论「数据不够所以屏是空的」在本轮不成立。
> 前作：`docs/todo-review-flow-design.md`（v1，已实施）、`docs/todo-review-flow-v2.md`（v2，已实施 2026-09-02）、`docs/todo-review-flow-v3.md`（v3，已实施 2026-09-05）。
> 相关文件：`UI/Review/Flow/ReviewStepInsights.swift`、`ReviewFlowView.swift`、
> `Protocols/Domain/Insights/InsightEngine.swift`、`InsightContext.swift`、`TriageRanking.swift`、
> `Protocols/Domain/Insights/Rules/{RottingRule,ReactiveVsPlannedRule,EffortOrderingRule,EnergyWindowRule}.swift`、
> `Protocols/ReviewSessionStore.swift`、`Resources/Localizable.xcstrings`。
> 环境提示：Swift 需在 Xcode 26 编译验证；`Protocols/` 纯逻辑可 `swift test` 单跑。

## Context

v3 修好了「五屏各自成立、串起来断了」。这一轮的问题收敛到一屏：

> **第 3 步整屏只有一行 12pt 灰字**——"Finish 1 more high-priority tasks to see whether you tackle easy or hard things first"，下面是整屏空白。

外部走查稿的处置是「Insights 直接砍掉，5 屏压成 3 屏」。**不采纳**，理由见「为什么不砍这一步」。但走查稿的核心判断成立：**这一屏在报告数字之前，先得有话可说**。

本轮的根因与前两轮不同：不是数据不够，是**这一步的内容模型只有「警报」没有「事实」**。四道闸各自都合理，串起来把内容清零。

---

## 根因核实：四道闸

### 闸 1 · 每条规则都是二值警报，中间地带明确返回「不显示」

| 规则 | 警示触发 | 好转触发 | 沉默条件（`.hidden`） | 代码 |
|---|---|---|---|---|
| 03 救火 vs 计划 | ratio ≥ 0.50 | ratio ≤ 0.20 | **0.20 < ratio < 0.50** | `ReactiveVsPlannedRule.swift:50-68` |
| 01 先易后难 | 高优中位 ≥ max(其他 × 倍数, 下限) | 高优中位 ≤ 其他中位 | 两者之间 | `EffortOrderingRule.swift:63-82` |
| 05 精力窗口 | 峰值在上午 **且** 深夜占比超线 | — | 任一不满足 | `EnergyWindowRule.swift:49-61` |
| 02 腐烂 | 腐烂列表非空 | — | 列表空 | `RottingRule.swift:38-43` |

`ReactiveVsPlannedRule.swift:67` 的注释原话：「0.20 < ratio < 0.50:中间地带,无可行动信号,不显示」。

**这是设计意图，不是 bug**——但它的后果是：**用户行为越普通，这一步越空**。一个不极端的用户，四条规则可以全部合法地闭嘴，而这样的用户恰恰是多数。

### 闸 2 · 唯一冷启动可用的规则有 21 天门槛

`RottingRule.swift:25-26`：`deferThreshold = 3` / `ageThresholdDays = 21`，`:38` 是 `guard defers >= 3 || ageDays >= 21 else { continue }`。

本轮走查数据里 19 条积压最老的也只有几天 → 列表空 → `.hidden`。**唯一一条带当场动作（跳回第 2 步卡片 / 当场不做了）的规则天然沉默**，而它沉默的时候，屏上没有任何东西顶替它。

### 闸 3 · 冷却按「复盘次数」算，与周复盘节奏冲突

`ReviewCooldownHistory.input`（`ReviewSessionStore.swift:143-157`）：`reviewsSinceLastShown = sessions.count - 1 - lastIndex`。落库发生在收尾（`finishSession`），引擎跑在流程启动，所以**上期刚展示过 → 本期 `reviewsSinceLastShown == 0`**。

`InsightEngine.cooldown`（`InsightEngine.swift:283-296`）放行需要任一：
- 效应量相对变化 ≥ 15%；
- `reviewsSinceLastShown >= 3`。

复盘节奏是**每周一**（`ReviewNotificationScheduler.weeklyIdentifier`）。所以一条上周成立、这周**依然成立且效应量稳定**的洞察，会被静音三周。而「依然成立」恰恰是复盘最该说的那类话——冷却原本是防「同一句说教反复刷屏」，代价是把「这个问题你还没解决」也一起静音了。

### 闸 4 · 整步存活判定把一行灰字当作「有内容」

`ReviewFlowView.swift:377`：

```swift
skipsInsightsWhenEmpty = ranked.isEmpty && !hasPlaceholderText && ladderNeedMore == nil
```

**只要有一行占位文案，这一步就照样出整屏**。而占位行的渲染是裸 `Text`（`ReviewStepInsights.swift:70-81`，`caption(12)` + `textMuted`），连卡片壳都没有，且只渲染优先序第一条（`InsightID.placeholderPriority`，v3 拍板 6 反对四行堆叠）。

v3 拍板 7 写这个判定的理由原话是「**空屏 + 错误指令的占位行比不出这一步更差**」——现在这一屏正是它想避免的那个形态。判定写成了「有没有字」，而它想问的是「有没有话」。

### 四道闸叠起来

```
四条规则 →(闸1 中间地带沉默)→ 0 张卡
        →(闸2 21 天门槛)→ 腐烂卡也沉默
        →(闸3 冷却)→ 即使触发也可能被扣掉
        →(闸4 一行灰字算内容)→ 整步照出
= 一屏 12pt 灰字
```

---

## 为什么不砍这一步

1. **四条规则说的话别处拿不到**。真出现极端模式时（半数任务当天记当天做完、重要的事永远排在深夜），这是待办 App 独有的观察，砍掉等于把护城河砍掉。
2. **02 腐烂是唯一直连处理动作的洞察**（点击跳回第 2 步卡片 / 当场不做了），它是第 3 步与第 2 步之间唯一的引用关系。
3. **步数本来就是自适应的**（`skipsInsights` + `skipsInsightsWhenEmpty`），硬编码成 3 屏等于把有数据用户的洞察一起删掉。

问题不在「这一步没用」，在「**它不该只有警报层**」。

---

## 方案：第 3 步改成两层内容模型

```
地板层(本期事实,永远算得出来) ← 新增,本轮主改
   +
规则层(洞察卡,极端模式才出)   ← 既有四条规则,不动判定
```

地板层的约束（同时也是与反 gaming 章程的对账，`InsightEngine.swift` 文件头四条）：
- **只报事实，不打分、不评级、不给「你应该」**——与 §2.2「文案止于观察」同口径；
- **每块必须带下游动作出口**，否则就是走查稿批评的「报告数字」；
- **零值退化成不渲染**，不出现「0 条超过 21 天」这类噪音行。

### 地板 A · 积压年龄（本轮主改，与既有拍板无冲突）

| 项 | 内容 |
|---|---|
| 数据 | `InsightContext.openTasks[].createdAt`（现成，`InsightContext.swift:16-22`） |
| 渲染 | 三档分布条：0–7 天 / 8–20 天 / 21 天以上；下面点名最老 3 条 |
| 动作 | 每条带「不做了 / 排下周 / 拆小」——复用第 2 步既有写库路径与 `abandonFromInsight` 同序（先写库后改状态） |
| 无腐烂时 | 说真话：「19 条里最久的 9 天，没有一条超过 21 天」——**一句事实，不是一扇锁着的门** |
| 零积压时 | 整块不渲染（此时第 2 步卡堆也是空的，无话可说是诚实的） |
| 与 02 腐烂卡去重 | 腐烂卡触发时，A 只出分布条，点名部分让位给腐烂卡（腐烂卡的列表更细：带推迟次数） |
| 下游 | 点名过的条目应能进第 4 步候选池（与「第 4 步兜底池」一并考虑，见附带发现 2） |

⚠️ **口径一致性（必须同源）**：`TriageRanking.stagnationDays`（`TriageRanking.swift:43-49`）用的是 `calendar.dateComponents` 自然日差；`RottingRule`（`:32-37`）用的是 `DayClock` **用户日**（用户可配日起始小时）。两者在边界会差一天。地板 A 的分档必须选定其一并与腐烂卡统一，否则同屏会出现「这条 21 天」与「21+ 档 0 条」并存。**建议统一到 `DayClock` 用户日**（洞察侧既有口径），并把 `stagnationDays` 的差异记进注释。

### 地板 B · 本期进出（分两步落）

| 项 | 内容 |
|---|---|
| 现在能做 | 本期完成 N / 新增 M / **净变化**（`ReviewAggregator.createdInWindow` + `summarize` 已有） |
| 与第 1 步的差别 | 第 1 步是成绩单语气（「4 completed」）；这里要的是**方向**——积压在缩还是在涨 |
| 现在做不了 | 跨期趋势线（sparkline） |
| 阻塞原因 | `ReviewSession` **没有持久化积压总数**。`ReviewLedger.inputCount` 是**卡堆口径**（`processedIDs.count + deck.count`，v2 拍板 1 截断后 ≤ 8 + 已处理数），不是积压总数；`ReviewFlowState.initialBacklogCount` 才是，但它不落库 |
| 解法 | `ReviewLedger` 加 `backlogCount`（旧 payload 缺键必须给默认值，照抄 `somedayCount` 的自定义解码先例，`ReviewSessionStore.swift:31-34`）。攒 2–3 期才有线可画 |

### 地板 C · 积压集中在哪（需加原料字段）

| 项 | 内容 |
|---|---|
| 数据缺口 | `InsightOpenTask` **没有 `category`**（`InsightContext.swift:16-22`）；`InsightCompletedEvent` 有（`:5-13`） |
| 改动 | `TodoQueryActor.insightContext(from:to:)` 取数时补一个字段 |
| 渲染 | 只出最集中的一条 + 对照组：「Work 5 条躺了两周，Personal 全清」 |
| 为什么值得 | 这是唯一能直接指向「该砍哪边」的事实，且与第 5 步「问问自己」的领域提示（`askDomainHintCategory`）天然接得上——那个提问现在是按历史会话数**轮换**选分类的，有了 C 就能改成**问积压最集中的那个领域** |

---

## 拍板决定（2026-09-21）

方案五条全部按建议采纳；第 6 条为批 3 开工前补拍。

| # | 决定 | 选择 | 理由 / 与既有拍板对账 |
|---|---|---|---|
| 1 | 地板层是否走冷却 | **不走** | §2.4 冷却是为「同一句判断反复说教」设计的；事实每期都该重述（积压这周就是比上周老 7 天）。冷却对**规则层**的作用不变 |
| 2 | 冷却本身是否放宽 | **本轮不动** | 动 §2.4 影响四条规则全体，且连带 `shownInsights` 历史语义；地板层已能兜住空屏，没必要同轮改两处。地板层上线后若仍觉得「该说的话被静音」，再单开一轮 |
| 3 | 03 中间地带是否降级成一行事实 | **降级成一行事实**（只报占比，不带判断、不带建议） | 与 §2.2「文案止于观察」一致；对账反 gaming 章程——不打分、不评级、不放大完成率。**明确推翻** `ReactiveVsPlannedRule.swift:67`「无可行动信号,不显示」的原判断：一屏什么都不说，比说一个中性事实更糟；且该事实正是第 5 步「问问自己」的素材 |
| 4 | `InsightOpenTask` 加 `category` | **加** | §1.4「原料级 DTO 不替规则做形状设计」——加字段属原料级，不违。地板 C 依赖它；不卡批 1 |
| 5 | 降级阶梯（ladder）改口 | **`skipStep` 档改为「只出地板 A」**，整步跳过只保留给「零积压 + 零完成」 | v1 §2.3 的 `<5 完成记录 → 整步跳过` 隐含假设「**洞察 = 完成记录的函数**」。地板 A 只依赖 `openTasks`，与完成了几条无关——一个从没完成过任何任务、却攒了 19 条积压的用户，恰恰最需要看到积压年龄 |
| 6 | 03 中间地带事实行走不走冷却 / `shownInsights` | **不走、不记**（批 3 开工前补拍） | 事实行已被拍板 3 定义为「只报占比、不带判断」，与地板层同口径。按规则层走冷却 → 首期展示后被静音 3 期，与「事实每期都该重述」矛盾；记进 `shownInsights` → 中间地带升级为真警报（ratio ≥ 0.50）时会被冷却吃掉。不记历史 ⇒ 真警报首现永远首期放行 |

**拍板 5 的连带改动（随批 2 一起落，不单列拍板）**：`skipsInsightsWhenEmpty`（闸 4）在地板层上线后基本恒为 false，判定改写成「**地板层与规则层是否都空**」，而不是现在的「有没有占位文案」。**本次改写整体取代 2026-09-07 拍板①「三块可渲染内容（洞察卡/占位行/最小事实行）全空才跳」的判定**（`3ef0246` 落地、已合 main）：占位行从「有内容」的判据降为地板块下方的脚注，不再参与判定、不再单独撑起一屏。

**本轮明确不做的**（记一笔，防下轮重复讨论）：不砍第 3 步（理由见「为什么不砍这一步」）、不动四条规则的触发阈值（除拍板 3 的中间地带分支）、不动冷却参数（拍板 2）、不硬编码步数。

---

## 附带发现（本轮确认，不在主线）

1. **`ReviewLedger.inputCount` 的注释与实现不符**。`ReviewSessionStore.swift:17-18` 写「流程开始时的待处理一次性任务数(N)」，但 v2 拍板 1 卡堆截断后实现是 `processedIDs.count + deck.count`（`ReviewFlowState.Ledger` 的注释有说明）。两处注释打架，做地板 B 时必须先对齐，否则会拿 `inputCount` 当积压总数画出错误的趋势线。
2. **第 4 步空池在本轮实证发生**。v2 已用「候选池 = 本会话排进下周的 ∪ 本来就排在下周的」补过一次，但本轮数据（没排任何东西进下周 + 库里无下周 due）依然撞空池，且闸门放行（`canPassCommit` 的 `commitPool.isEmpty` 分支）→ **流程唯一的输出屏输出了零**。建议下一轮单独处理（兜底池：从卡堆剩余 + 尾部按 `TriageRanking` 序取前几条），**注意它会连带改变闸门语义**，与 2026-08-22「复盘自愿、不强迫」拍板有张力。
3. **英文单复数全局缺失**。整个 `Localizable.xcstrings` 只有 `review.insight.rotting.headline_%lld` 一个键做了 variations，其余 count 类键全是裸 `%lld` → "You decided on 1 tasks"、"Finish 1 more high-priority tasks"。这是全局问题，不止复盘流程。
4. **`review.hero.sameday_%lld` 零值被放大**。`RecapComponents.swift:83-91` 在 `summary.total > 0` 时无条件渲染，而第 1 步传 `promotesSameDay: true`（15pt + `primaryText`）→ 「0 of them were captured and done the same day」以主文案级别出现，读起来像指责。缺一个零值分支。
5. **`review.flow.insights.ask.domain_hint` 写死 "this week"**，但窗口是「上次复盘至今」（本轮 3 天）。与 v3 拍板 1 的窗口统一口径不一致。

---

## 实施顺序

| 批 | 内容 | 依赖 |
|---|---|---|
| 1 | 地板 A（积压年龄块 + 当场动作）+ 口径统一到 `DayClock` | 无拍板冲突，可立即开工 |
| 2 | 拍板 5：ladder 改口 + `skipsInsightsWhenEmpty` 判定改写 + 占位行降级为脚注 | 依赖批 1（拍板已定） |
| 3 | 拍板 4 + 地板 C（`InsightOpenTask.category`）；拍板 3（03 中间地带事实行） | 依赖批 2（拍板已定） |
| 4 | 地板 B：`ReviewLedger.backlogCount` 落库（含旧 payload 解码兜底）+ 本期净变化行；趋势线等数据攒够再开 | 依赖附带发现 1 先对齐 |
| 5 | 附带发现 3/4/5 文案批（单复数 variations 全局补、零值分支、窗口文案） | 独立 |

批 3 → 批 2 是刻意排序而非数据依赖：批 2 承载拍板 5（本轮最要紧），先行落地让核心回归场景（档 5）尽早可验。代价是 `skipsInsightsWhenEmpty` 的判定在批 3 落地时要再扩一次（纳入地板 C 与 03 事实行）；若先落批 3，判定可一次改到位，但核心场景上线推迟——两害取其轻。

## 验证

**单测（`Protocols/` 纯逻辑，可 `swift test`）**
- 地板 A 分档：19 条全新 → 21+ 档为 0，点名最老 3 条；含 1 条 21 天 → 进 21+ 档且与腐烂卡去重；0 积压 → 整块不渲染。
- 口径边界：用户日起始小时 ≠ 0 时，地板 A 的档位与 `RottingRule` 判定在 20/21 天边界必须一致。
- 拍板 5：完成记录 0 条 + 积压 19 条 → 第 3 步**不跳过**，只出地板 A；完成 0 + 积压 0 → 整步跳过。
- 地板 B：旧 payload（无 `backlogCount`）解码不抛错、默认值不污染趋势。

**手测数据档位矩阵**（每档都要真机过一遍第 3 步）

| 档 | 积压 | 近 30 天完成 | 期望 |
|---|---|---|---|
| 1 | 0 | 0 | 整步跳过 |
| 2 | 19（全新） | 0 | 只出地板 A，说「没有一条超过 21 天」 |
| 3 | 19（全新） | ≥15 | 地板 A + 占位脚注（不再独占一屏） |
| 4 | 含 21+ | ≥15 | 地板 A 分布条 + 02 腐烂卡（点名不重复） |
| 5 | 含 21+ | ≥15，且上期展示过 02 | 冷却扣掉腐烂卡，地板 A 仍在 → **屏不空**（这是本方案的核心回归场景） |

期望列按**批 1+2 落地后的状态写**（核心回归场景档 5 只依赖这两批，可先行验证）。后续批次在同档上叠加：批 3 后，有积压的档（2–5）另加地板 C，完成 ≥15 的档（3–5）在 03 ratio ∈ (0.20, 0.50) 时另加一行中间地带事实；批 4 后，本期有进出的档另加地板 B（净变化）。逐批落地后各档要重对一次期望。

## 未决问题

- 地板 A 的分档阈值（0–7 / 8–20 / 21+）沿用 `RottingRule.ageThresholdDays = 21` 的分界，21 这个数本身是 v1 从验收用例反推的（规格文档不在仓库）。三档是否够、要不要加 30+ 档（外部走查稿提的是 30 天），留待真机看过分布再定。
- 地板 B 的趋势线在会话数 < 3 时画什么：留白、还是只出本期净变化。倾向后者（与「零值不渲染」一致）。

---

## 实施补注（2026-09-21/22，fupan3 批 1–5：0599a9f → fe74367 → cc91667 → b654234 → 6e54085）

按「实施顺序」五批全部落地。与方案的偏差与关键取舍：

1. **地板 A「拆小」= 深链**：跳回第 2 步聚焦对应卡片并**自动打开拆小 sheet**（`triageAutoSplitID`），不在洞察步重造 AI 候选/说一句/手写三通道——「复用第 2 步既有写库路径」的字面落地。尾部条目（不在卡堆）也能开（`markSplit` 同步清尾部）。
2. **「排下周」落点收口单一来源**：新增 `ReviewFlowState.nextMondayUserDayStart`，第 2 步右滑与地板 A 共用（此前 triage 私有实现，三处 copy 有漂移风险）。
3. **地板 B 计入整步存活判定（超出批 2 文档预期，拍板 5 字面闭合）**：B 在容器层 `@Query` + 与第 1 步同一 `weekSummary`（上次复盘至今）快照一次、先于 `runInsightEngine` 落进 State——「零积压 + 1–4 条完成」的边缘态由 B 的净变化保住第 3 步，「整步跳过只留零积压+零完成」至此字面成立。窗口用复盘期而非 insightContext 的 30 天窗（与第 1 步数字同源，防同屏打架）。
4. **`backlogCount` 旧 payload 默认 -1 哨兵（非 0）**：0 是「本期零积压」的有效事实，默认 0 会把旧会话画成零积压污染趋势；<0 = 未记录，不进趋势。
5. **地板 C 的 `.other` 双排除**：focus 与对照组都排除 `.other`（AI 解析失败兜底不是领域；「其他方面清完了」不是有效对照）。对照组取「本期完成过且当前零积压」里完成数最多者。
6. **领域提示轮换退役**：`askDomainHintCategory` 改问积压最集中领域（`triageInput` 口径，与地板 C 同源同序）；积压不变连续几期问同一块是**有意的**（问题还在，plan-do-review 闭环）。`rotationSeed` 参数删除。
7. **03 事实行的机制**：`InsightAvailability` 加 `.fact(InsightFactLine)`，`collect` 分流——事实行不进 `results`（机械地实现拍板 6：不过冷却、不进 `shownInsights`、不参与排序），但计入存活判定。n ≥ 15 时 03 永远有话可说，「.full 档零积压整步跳过」从此不可达（批 2 阶段短暂存在过的路径消亡，相关测试随批 3 再翻转一次）。
8. **批 5 单复数的两类处置**：单计数键补 en variations（18 个，one/other）；**多 `%lld` 键不做 variations**（xcstrings 单复数单轴，多参键选轴有歧义）——改写成计数安全结构（7 个：decided_none / untouched / pool_intro / pinned_outcome_hero / added_toast.elsewhere ×2 / backlog_focus.line）。代价：多参键里「N days」在 N=1 时仍是 "1 days"（沿既有 rotting.body 「since %lld days ago」惯例，系统性的已知留白）。sameday 零值消隐的谓词收进 `ReviewSummary.showsSameDayLine`（可单测）；单复数护栏是**直读源码 catalog 的数据测试**——模拟器语言不定（本机 zh），运行时英文断言会随宿主语言漂移。

**测试基线**：`swift test` 303 例（仅既有 DST 环境红灯）；iPhone 17 Pro 模拟器 `VoiceTodoTests` 全量 700 例，仅 2 个既有环境红灯（DST / StoreKit 配置注入），零新增失败。

**未做（沿方案）**：趋势线（待 ≥3 期 `backlogCount` 攒够）、真机手测 5 档矩阵 + 三语 AX5。合并 main 前须过真机。
