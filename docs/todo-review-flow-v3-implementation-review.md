# 复盘流程 v3 —— 实施代码审阅（交接稿）

> 状态：**一轮核实与修改完成（2026-09-07），待二轮 review**。各条目下「处置」小节为一轮记录。
> 审阅基线 `797eae2`（`main` / `claude/review-flow-breakpoints-x8izga`，两者同一提交）。
> 审阅对象：v3 五批实施 `fdc13a5`→`73f1eae` + 两轮双审修正 `26ddc59` / `407ded2`。
> 方案原文：`docs/todo-review-flow-v3.md`（含审阅修订一 / 二 / 三）。
> ⚠️ **本次审阅是纯静态的**：审阅环境无 Swift 工具链（`swift --version` 不存在，无 Xcode），
> **没有编译过任何文件，没有跑过任何测试**。下面所有断言都来自读代码，
> 凡标「待核实」的都必须在能编译的环境里复验后才能采信。

---

## 给下一位（核实与修改者）的工作约定

1. **逐条核实，不要照单全收。** 每条发现都给了 `文件:行号` 与推理链，请自己回代码验一遍。
   审阅者读错、行号漂移、对 SwiftUI 语义判断有误都是可能的——**推翻我是预期内的结果**，
   但推翻要给出代码证据，不要只写「我认为没问题」。
2. **区分三类条目**（下文用标题标注）：
   - `【缺陷】`——判定为真问题，应改。
   - `【待定】`——问题成立但修法有取舍，**需要人拍板**，不要自己选一条就改掉。
   - `【留档】`——不是问题，是实施者做对但方案里没有的东西，记下来防止将来被「优化」掉。
3. **改动范围限制**：只动本文点名的位置。看到别的可改点，写进本文末尾的「新增发现」，
   不要顺手改——本轮要的是可回溯的小 diff。
4. **每改一处，同步改测试**，并在本文对应条目下追加「处置」小节，写明：改了什么、
   测试怎么变、以及**你是否真的编译/跑过**（跑不了就明说跑不了，不要含糊）。
5. 改完后本文回到我这里做二轮 review，验收标准见文末。

---

## 总体判断

实施质量高于方案。具体地：

- 注释把每个决定的**理由**和**「别改回去」的约束**都写进了代码（`initialBacklogCount`、
  `ReviewSummary.oneOffCompletionCount`、`InsightID.placeholderText` 三处尤其到位）。
- 审阅修订二要求的三条回归护栏单测**真的写了**，且夹具方向正确：
  `testPlaceholderPicksByPriorityNotByValue`（energyWindow needMore=2 < effortOrdering needMore=3
  仍选 effortOrdering——按数值取最小的实现会在这条上红）、
  `testSameDayJudgmentDenominatorIsOneOffNotTotal`、`testSameDayJudgmentThresholdBoundary`。
- i18n 干净：新增键 `pool_intro` / `pending_note` / `sameday_judgment` / `pinned_outcome_hero` /
  `scope_since` / `scope_first` / `decided_none` / `gate_hint` / `need_more.<id>` 三语齐全；
  废弃键 `need_more_merged` / `tl_nodefer` / `recap.scope` / `recap.last_pinned_outcome` 已删除。
- 共用组件边界守住了：`RecapHeroSection` 新增 `heroContent` 带默认值 `.countSummary`，
  `promotesSameDay` 仍默认 false，回顾页（`ReviewView.swift:257` 走 `monthSummary`）零变化；
  `RecapEvidenceRow` 经确认**只有复盘第 1 步在用**，新增的 `pending_note` 行不会漏到回顾页。

**一个缺陷让 ③ 屏这一整批工作在触发它的场景里不可见**（发现 1），其余为一个口径边界（发现 2）
与三条小项。

---

## 【缺陷】发现 1 · ③ 屏跳过条件把自己的成果一起跳掉了

**位置**：`UI/Review/Flow/ReviewFlowView.swift:364`

```swift
ladderNeedMore = ladder.rottingOnlyNeedMore     // :363
skipsInsightsWhenEmpty = ranked.isEmpty         // :364
```

**问题**：跳过只看 `ranked.isEmpty`，但第 3 步的可渲染内容有**三块**：

| 内容 | 数据源 | 渲染位置 |
|---|---|---|
| 洞察卡 | `state.rankedResults` | `ReviewStepInsights.swift:57`（`cards` 的 ForEach） |
| 占位行 | `state.insightPlaceholders` | `ReviewStepInsights.swift:59` → `:71` |
| 最小事实行 | `state.ladderNeedMore` | `ReviewStepInsights.swift:30` → `:88` |

后两块在 `ranked` 为空时**照样有内容**，却随整步一起被跳过，永远渲染不到。

**受害者 A —— 走查场景里，发现 E 的修复一次都不会显示。**
26 条完成 → ladder `.full` → 四条规则跑完零触发 + `EffortOrderingRule` 占位 `needMore = 3`
→ `ranked.isEmpty` → 整步跳过。那句新写的、说真话的
`review.flow.insights.need_more.effortOrdering_%lld`（「再做完 3 条高优先级任务…」）
在**当初暴露问题的那个数据集上**不可达。

这不是推测——现有测试自己把矛盾写进了断言。`VoiceTodoTests/Review/ReviewFlowStateTests.swift:167`
`testEmptyInsightResultsSkipInsightsStep`：

```swift
XCTAssertTrue(state.skipsInsightsWhenEmpty, "引擎零结果——整步跳过")
XCTAssertEqual(state.insightPlaceholders.first?.id, .effortOrdering, "唯一占位:高优组缺口")
XCTAssertEqual(state.insightPlaceholders.first?.needMore, 3)
```

算出了占位、断言了它的 id 与值，然后断言承载它的那一步不出现。
按现状，占位行只在「**至少一条洞察触发** + 另一条规则占位」时才可达——比设计意图窄得多。

**受害者 B —— 5–14 档的最小事实行成了死代码。**
该档（`InsightEngine.ladder` 的 `.rottingOnly`）只跑 `RottingRule`，而该规则只有
`.hidden` / `.fired` 两态、永不产出占位。腐烂不触发 → `ranked` 空 → 跳过 →
`ladderNeedMore` 明明非 nil 也渲染不到。

方案 `docs/todo-review-flow-v3.md` ③ 屏改动 3 白纸黑字：「**最小事实保留**。`ladderHint` 的
5–14 档逻辑不动。」v2 更早定过「数据不够时显示当下能算出的最小事实，而不是锁」。
代码留着，路径断了。

**责任归属（写清楚，免得核实者以为是实施者擅自发挥）**：
方案拍板 7 把「空态整步跳过」与「占位行报真实解锁条件」并列写，**没有定义「空」指的是
`rankedResults` 空还是整屏无可渲染内容**。实施照字面做了，是方案的缺陷。
但意图明确是后者——「有话说才出这一步」，占位行和最小事实都是话。

**建议修法**（判定按「这一步会不会渲染出东西」，复用已有的单一来源，不新写选条逻辑）：

```swift
// InsightID.firstPlaceholder + placeholderText 已是选条与文案的单一来源
// (Protocols/Domain/Insights/InsightEngine.swift:48 / :66),直接复用
let hasPlaceholderText = InsightID.firstPlaceholder(in: newPlaceholders)
    .flatMap { $0.id.placeholderText(needMore: $0.needMore) } != nil
skipsInsightsWhenEmpty = ranked.isEmpty && !hasPlaceholderText && ladderNeedMore == nil
```

⚠️ 注意 `ladderNeedMore` 的赋值（`:363`）必须在这一行之前，现状已满足，改动时别调换顺序。

**测试要求**：
- `testEmptyInsightResultsSkipInsightsStep`（`:167`）语义翻转 → 改名如
  `testEmptyResultsWithPlaceholderKeepsInsightsStep`，断言 `skipsInsightsWhenEmpty == false`
  且 `advance()` 从 `.triage` 停在 `.insights`。
- **新增**「真空态」用例：`ranked` 空 + 无占位 + `ladderNeedMore == nil` → 跳过。
  构造要点：ladder 需为 `.full`（≥15 条完成，`ladderNeedMore` 才是 nil），
  且让 `EffortOrderingRule` 两组各 ≥3（`minPerGroup`，走 `.hidden` 而非占位）、
  `EnergyWindowRule` / `ReactiveVsPlannedRule` 样本 ≥15 且效应量不触发。
- **新增** `.rottingOnly` 档用例：5–14 条完成 + 腐烂不触发 → `ladderNeedMore != nil`
  → **不跳过**（护住受害者 B）。
- `testNonEmptyInsightResultsKeepInsightsStep`（`:200`）应不受影响，复跑确认。

### 处置（2026-09-07，核实与修改者）

**核实：成立。** 三块内容的渲染位置、`testEmptyInsightResultsSkipInsightsStep`
的自相矛盾断言、5–14 档死代码路径逐一与代码对上（行号有小幅漂移：
`ReviewStepInsights.swift` 的 cards / 占位行 / 最小事实行实际在 :45 / :70 / :87）。

**修改**：按建议修法落地于 `runInsightEngine()` 末尾——
`skipsInsightsWhenEmpty = ranked.isEmpty && !hasPlaceholderText && ladderNeedMore == nil`，
其中 `hasPlaceholderText` 复用 `InsightID.firstPlaceholder(in: insightPlaceholders)`
+ `placeholderText(needMore:)`（与 `placeholderSummaryRow` 的渲染条件逐字同源）；
`ladderNeedMore` 赋值保持在判定行之前（顺序约束写进了行间注释）。
`skipsInsightsWhenEmpty` 属性注释与 `runInsightEngine` 文档注释同步改为
「三块可渲染内容全空才跳」。

**测试**：
- `testEmptyInsightResultsSkipInsightsStep` 语义翻转并改名
  `testEmptyResultsWithPlaceholderKeepsInsightsStep`（夹具不动，断言方向翻转，
  `advance()` 停在 `.insights`、`retreat()` 对称回 `.triage`）。
- 新增 `testTrueEmptyResultsSkipInsightsStep`：15 条完成（`.full`，ladderNeedMore
  为 nil）+ 四条规则全 hidden——高优 3 条跨度 3 / 普通组中位 2（effort 中间带）、
  救火 5/15 ≈ 0.33（reactive 中间带）、高优全无钟点（energy）、无未完成任务
  （rotting）——三块全空 → 整步跳过。
- 新增 `testRottingOnlyLadderWithNoTriggerKeepsInsightsStep`：8 条完成 →
  `.rottingOnly(needMore: 7)`、腐烂不触发 → **不跳**（护住受害者 B）。
- `testNonEmptyInsightResultsKeepInsightsStep` / `testSkippedLadderDoesNotRecordShownInsights`
  / `testAdvanceSkipsInsightsWhenLadderSaysSo` 复跑无变化。

**编译/测试**：✅ `xcodebuild test`（iPhone 17 Pro 模拟器，iOS 26.5）真的跑过，
`ReviewFlowStateTests` 全绿（含 3 条新增/改名）。

---

## 【待定】发现 2 · 「上次复盘以来」把上次复盘那一天整天算了进来

**位置**：`UI/Review/RecapComponents.swift:504`（`weekSummary`，函数起点 `:495`）

```swift
let sinceDay = since.map { DayClock.startOfUserDay(for: $0, calendar: calendar) }
    ?? (calendar.date(byAdding: .day, value: -7, to: todayStart) ?? todayStart)
let end = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? todayStart
```

窗口是 `[sinceDay, 明天0点)`，起点取上次复盘**当天的 0 点**。

**后果**：上次复盘在 9/3 早上 9:00，则 9/3 一整天都在本次窗口内——包括 9:00 之前、
**已经被上一次复盘统计过**的完成。周节奏下每次窗口都与前一次重叠一天，
`Done` 数被那天的复盘前完成重复计入。

界面文案是 `review.flow.recap.scope_since` = "Since your last review" / 「前回のふりかえりから」
/「上次复盘以来」，标签 `:508` 渲染成 "Sep 3–Sep 4"。按字面，9/3 复盘**之前**做完的事
不属于「上次复盘以来」。这与方案 ① 屏验收「任意时刻只出现一个时间口径」是同一类问题，
只是藏在边界里。

**为什么标【待定】**：两条修法各有代价，不该由核实者单方面选。

| 修法 | 代价 |
|---|---|
| 起点改 `sinceDay + 1 天` | 丢掉「复盘当天、复盘之后」完成的事——那些确实属于本期 |
| 这一处改用**时刻**粒度（直接用 `since` 不折算用户日） | 与全代码库的 `DayClock` 用户日约定不一致，是个破例 |
| 维持现状 | 需要承认重叠是有意的 |

**无论选哪条，现状都是「无意的」**：`weekSummary` 的文档注释只说「起点取上次复盘完成时刻的
用户日」，没说它含那一整天，也没说重叠是刻意的。

**核实者要做的**：确认上述行为描述属实（构造两次相邻复盘的夹具跑一遍最直接），
然后**把结论带回给人拍板**，不要自行改。拍板后无论选哪条，都要：
① 把结论写进 `weekSummary` 注释；② 加一条钉住边界的单测。

### 处置（2026-09-07，核实与修改者）

**核实：成立。** 窗口 = `[sinceDay, 明天0点)`、起点折算用户日（原
`weekSummary` 实现）；上次复盘 9/3 09:00 时，9/3 早晨的完成同时落在上次
窗口（上次 end = 9/4 0点）与本次窗口（起点 9/3 0点）——行为与描述一致。

**拍板：时刻粒度**（2026-09-07 用户三选一）。窗口 = [上次复盘完成时刻, 明天用户日起点)。

**修改**：
- `RecapSummaryBuilder.weekSummary`：起点直接用 `since` 原始时刻（首次复盘
  回落近 7 天保持日对齐）；标签仍显示用户日粒度（「9月3日–…」——展示说
  「从哪天起」，统计界「从哪刻起」，语义写进函数注释）。
- **连带改动，比选项表预估的大**（见「新增发现 1」）：`ReviewAggregator`
  四个窗口函数的下界从「折算用户日后按事件的用户日比较」改为「按传入时刻
  精确比较」——聚合核入口会把起点折回用户日，只改 `weekSummary` 传参是
  **静默空改**。上界维持用户日；日对齐起点的调用方（`monthSummary`、
  `ReviewView` 周月 picker）两种比较恒等，逐一核对过调用方与既有测试夹具，
  行为零变化。

**测试**：新增 `testWeekSummary_startIsSinceInstant_notSinceUserDay`（上次复盘
9/3 09:00；9/3 08:00 完成不计、9/3 10:00 完成计——旧实现下此测试红）；
`testWeekSummary_startIsSince_notRollingMonth` 的口径注释同步修正（夹具两种
语义下均通过，断言未动）；`ReviewRecapSameDayTests` / `DayStartHourBoundaryTests`
（用户日边界护栏）复跑全绿。

**编译/测试**：✅ 真的跑过（同上模拟器）。

---

## 【留档】发现 3 · 实施者补的两处、方案里没有，别被后人「优化」掉

这两条不需要改动，记录在案是为了防止将来有人看不懂而回退。

**3a · `runInsightEngine` 的 `.skipStep` 档提前返回**（`ReviewFlowView.swift:323`）

引擎从视图 `.task` 前移到流程启动后，降级跳过路径（<5 条完成）**也会跑了**。
`RottingRule` 的 age ≥ 21 天分支单条即触发，会在**从未展示**的情况下进 `shownInsights`
并随会话落库 → 下期冷却把「从没看过」当「上期看过」。
提前返回 + `resetShownInsights()` 挡住了这个。

这是引擎前移的真实副作用，**方案的「连带三处」没有列到它**。
`testSkippedLadderDoesNotRecordShownInsights` 连落库一起钉住了，做得对。

**3b · `EffortOrderingRule` 对照组缺口改 `.hidden`**
（`Protocols/Domain/Insights/Rules/EffortOrderingRule.swift`，原为
`.placeholder(minPerGroup - other.count)`）

理由已写在注释里：该分支的 `needMore` 是**非高优**缺口，套 effortOrdering 的文案写
「做完 N 条高优」照做永不解锁；而诚实版本（「去完成 N 条普通任务以解锁洞察」）
是在教用户为解锁洞察而优化行为，违反反 gaming 章程——没有可诚实建议的动作就不说。

这个推理比方案里「按 id 选文案」深一格，是对的。测试 `test01E_otherGroupTooSmall_noPlaceholder`
已覆盖。

**3c · `placeholderText` 的静态字面量约束**（`InsightEngine.swift:66`）

注释指出：`String(localized:)` 对 String 插值生成 `%@`、对 Int 生成 `%lld`；
把 `rawValue` 插进键里，运行时查的是 `need_more.%@_%lld`，catalog 按 id 命名，
查不到会**整串回落键名**。所以键里的 id 段必须是静态字面量、三个 case 各写一行。
`testPlaceholderTextKeyedStaticallyById` 已钉住。这是会静默发生的坑，注释别删。

### 处置（2026-09-07，核实与修改者）

**核实：3a/3b/3c 均与代码对上，判断正确，未改动。** 3b 的推理（对照组缺口
按 effortOrdering 键写「做完 N 条高优」照做永不解锁；诚实版是在教用户为解锁
洞察而优化行为）与 3c 的静态字面量约束（String 插值进键变 `%@`，catalog 按
id 命名查不到整串回落键名）确如所述。相关护栏测试
`test01E_otherGroupTooSmall_noPlaceholder` / `testPlaceholderTextKeyedStaticallyById`
本轮全量单测复跑仍绿；3a 的护栏 `testSkippedLadderDoesNotRecordShownInsights`
在发现 1 修复后复跑仍绿。

---

## 【缺陷】发现 4 · 闸门原因文案写死为 commit 的键

**位置**：`UI/Review/Flow/ReviewFlowView.swift:891`

```swift
if !state.canAdvanceCurrentStep {
    Text(String(localized: "review.flow.commit.gate_hint"))
```

`bottomBar` 对**任何**步骤的闸门都渲染 commit 的文案。今天只有 `.commit` 有硬闸门
（`canAdvanceCurrentStep`，`:275`，其余步骤直接 `return true`），所以现状不出错；
但同一段的注释自称「**流程级改法**——任何步骤的硬闸门都必须在按钮旁说明原因」，
名实不符：将来给第二个步骤加闸门，会静默显示「至少选 1 件才能继续」。

**建议**：`switch state.currentStep` 选键（目前只有 `.commit` 一个分支 + 其余返回 nil / 不渲染），
或者退一步——把注释从「流程级」改成「当前仅 commit，新增闸门必须同时加键」的显式约束。
两者取其一即可，**倾向前者**：注释拦不住人，类型能。

### 处置（2026-09-07，核实与修改者）

**核实：成立。** `bottomBar` 对任何步骤的闸门渲染 `review.flow.commit.gate_hint`；
`canAdvanceCurrentStep` 目前仅 `.commit` 有硬闸门；注释自称「流程级」名实不符。

**修改**：取建议的前者——`ReviewFlowView` 新增 `gateHintText` computed
property，`switch state.currentStep` 选键（`.commit` 分支且仅闸门拦截时返回
`gate_hint` 文案；其余步骤返回 nil 不渲染）；`bottomBar` 改
`if let gateHint = gateHintText`。渲染行为与现状逐字等价（今天只有 `.commit`
会拦截），但第二个闸门出现时不会再静默借 commit 的文案——switch 穷举 +
注释双保险。注释同步从「流程级」口号改为「文案键按步骤选 + 新增闸门必须
同步加分支」的显式约束。

**测试**：无新增——现状行为等价替换，视图层渲染路径由真机手测第 3 项
（闸门路径）覆盖。**编译**：✅ 随全量单测编译通过。

---

## 【待定】发现 5 · ② 屏 pad 的 `layoutPriority` 给反了

**位置**：`UI/Review/Flow/ReviewStepTriage.swift:659` / `:671`（`pad` 内的中段两钮）

四钮同构后，`layoutPriority(1)` 给了**中段**两个（今天就做 / 拆小）。但四个标签里最长的是
**两侧**的 "Not doing it" / "Next week"（en）。优先级给了短的，塌陷风险从中段移到了两侧——
原缺陷（修正 A：中段 title 被挤没）换了个位置，不一定消失。

各语言最长标签：en `Not doing it` / `Next week`；zh `今天就做` / `排下周`；ja `今日やる` / `来週へ`。
**en 是最危险的一档，不是日文**——方案验证章第 4 项写的「日文『今日やる』最长，重点看它」是错的，
一并修正。

**为什么标【待定】**：这是布局观察，静态读代码给不出结论——`caption(11)` +
`lineLimit(1)` + `minimumScaleFactor(0.7)` 下究竟塌不塌，只有真机/模拟器能定。
方案验证章的真机手测 7 项**目前全部未做**（`docs/todo-review-flow-v3.md` 头注：「真机手测 7 项待做」）。

**核实者要做的**：如果你有模拟器，跑 en 环境第 2 步截图；跑不了就**明说跑不了**，
把这条留给真机回归，不要凭想象调 `layoutPriority`。

### 处置（2026-09-07，核实与修改者）

**核实：事实部分全部成立。** 四钮标签实测（`Localizable.xcstrings`）：en
"Not doing it"（12 字符）/ "Next week"（9）在两侧，中段 "Do today"（8）/
"Split"（5）较短；ja 最长仅 4 字符（今日やる）。v3 验证章第 4 项「日文最长」
确系错误。

**修改**：**未验证，留真机回归**——2026-09-07 用户拍板并入 v3 已挂起的真机
手测 7 项（第 4 项本来就是②屏三语按钮检查），不凭想象调 `layoutPriority`。
已做的文档修正：
- `docs/todo-review-flow-v3.md` 验证章第 4 项：错误句替换为「最危险的是 en
  （两侧最长 + `layoutPriority(1)` 在中段）」，标注修正日期与本文件出处；
- 同文档第 5 项顺带对齐发现 1 修复后的跳过语义（跳过条件收窄为「真空态」——
  仅 ranked 空但有占位/阶梯提示时第 3 步照常出）。

代码 `layoutPriority` 本轮不动，待 en 环境真渲染截图定论后另行处置。

---

## 【留档】发现 6 · 两处小的一致性，可改可不改

**6a · `preexistingNextWeek` 每次读都重排**（`ReviewFlowView.swift:253`）

computed property 内含 `TriageRanking.sortByStagnation(..., now: Date())`。
第 4 步一次 body 求值会读到 3–5 次（`canPassCommit` → `commitPool`、
`ReviewStepCommit` 的 `.isEmpty` 与 `candidateList`），各排一遍。

**影响很小**：`canAdvanceCurrentStep`（`:275`）只在 `.commit` 步骤才求值 `canPassCommit`，
其余步骤直接 `return true`——所以卡片拖拽动画期间**不会**触发排序（我最初的担心不成立）。
池子规模也就几十条。

真要清理：`canPassCommit` 只需要 `isEmpty`，可以走未排序的 `nextWeekCommitted`；
或把排序结果缓存进 state。**优先级低，本轮可以不动。**

**6b · 同一拍板的排序落在两层**

`preexistingNextWeek` 在 state 里排（`:253`），`state.scheduled` 在视图里排
（`ReviewStepCommit.swift:27`）。不影响行为（`commitPool` 只被 `isEmpty` 使用，
无顺序敏感的消费者），但下次动它容易漏一边。**本轮可以不动**，若顺手统一到 state 层更好。

### 处置（2026-09-07，核实与修改者）

**核实：6a/6b 均与代码对上。** 6a 的关键前提——`canAdvanceCurrentStep` 只在
`.commit` 步骤求值 `canPassCommit`，卡片拖拽动画期间不触发排序——确认成立；
池子规模几十条，影响可忽略。6b 两层排序现状确认。按本文建议**本轮不动**。
（发现 4 落地的 `gateHintText` 仍走 `canPassCommit`，不改变 6a 的读法。）

---

## 已核实为「无问题」的部分（不必重查，除非你有反证）

- `RecapHeroSection` 的 `heroContent` / `promotesSameDay` 双默认值 → 回顾页零回归。
- `RecapEvidenceRow` 仅第 1 步使用 → `pending_note` 行不会漏到回顾页。
- `monthSummary` 新增的 `periodLabel: String?` 是中间位带默认值参数 → Swift 具名实参，源码兼容。
- `scope_first`（"The last 7 days"）与 `weekSummary` 的 `since == nil` 回落 7 天 → 文案与逻辑同源。
- `askDomainHintCategory` 的 `.other` 排除（`ReviewFlowView.swift`）写法正确，
  全为 `.other` 时返回 nil，提示行本就有 nil 分支。
- `timeline` 改 `@ViewBuilder` + `deferCount > 0` 守卫、`tl_nodefer` 键删除 → 一致。
- `removeFromDeck` 不从 `tail` 回填 → `poolIntroRow` 的「8 件」与 headerRow 的
  「n / 8」（`ledger.inputCount`）同源，不是不一致。
- 废弃键四个已从 catalog 删除，无残留引用。

---

## 二轮 review 的验收标准

回到我这里时，我会按下面逐条验，请对着准备：

1. **发现 1 已修**：`skipsInsightsWhenEmpty` 的判定包含占位与阶梯提示；
   三条测试（翻转 + 真空态 + `.rottingOnly` 档）存在且断言方向正确。
2. **发现 2 有结论**：无论选哪条修法，`weekSummary` 注释写清边界语义，且有单测钉住。
   若拍板「维持现状」，注释必须写明重叠是有意的——**不允许沉默地留着**。
3. **发现 4 已处置**：二选一，且注释与实现不再互相矛盾。
4. **发现 5 有交代**：跑过就给结论，没跑过就明确写「未验证，留真机回归」。
   方案验证章第 4 项「日文最长」的错误一并修掉。
5. **每条都有「处置」小节**，写明改了什么、测试怎么变、**是否真的编译/跑过**。
   跑不了就写跑不了——本文自己就是这么写的，别在这上面含糊。
6. **反驳同样算完成**：任何一条你认为不成立，给出代码证据写进「处置」即可，不必改。
7. **不要扩大范围**：本文之外的改动写进下节，不要直接改。

---

## 新增发现（核实者填写）

<!-- 核实过程中发现的、本文未覆盖的问题写在这里。只记录，不要在本轮直接修改。 -->

### 新增发现 1 · 「时刻粒度」修法不能只改 weekSummary——聚合核会把起点折算回去

（核实发现 2 时发现；因与该条修法直接绑定，已随拍板一并实施，理由与影响面如下。）

`ReviewAggregator` 的四个窗口函数（summarize / sameDayCompletions /
createdInWindow / oneOffCompletions）入口处都会
`DayClock.startOfUserDay(for: startDay)` 把起点折算成用户日，再用**事件的
用户日**比较边界。因此本文发现 2 选项表里「这一处改用时刻粒度（直接用
`since` 不折算用户日）」若按字面只改 `weekSummary` 传参，是**静默空改**——
时刻进聚合核即被折回用户日，重叠一天原样保留（且任何测试都不会红）。

真正的实施 = 聚合核四个函数的下界改「按传入时刻精确比较」（上界维持用户
日）。影响面已逐一核实：日对齐起点的调用方两种比较恒等——`monthSummary`
（todayStart − 1 月）、`ReviewView` 周月 picker（`startDay(from:)` 返回用户日
起点）、既有测试夹具（正午/日对齐起点，无「起点当天更早时刻」的事件）全部
零行为变化；唯一语义变化的就是传时刻的 `weekSummary`，边界由
`testWeekSummary_startIsSinceInstant_notSinceUserDay` 钉住。

教训归档：发现 2 选项表把该修法的代价标成「weekSummary 一处的破例」，
低估了实施面——根因是审阅时只读了传参处、没读聚合核内部。后续改窗口
口径时，先追进 `ReviewAggregator` 再下结论。

### 新增发现 2 · 全量单测基线状态（本轮实测，供二轮对照）

本机（Xcode 26.6 / iPhone 17 Pro 模拟器 iOS 26.5）全套 `VoiceTodoTests`：
除 `TodoDueDateShifterTests.testDSTSpringForward_fallsBackToMidnight` 外全绿。
该 DST 用例经 stash 对照在**未改动的基线 `93e3ea2` 上同样红**（时区环境
问题，worktree 既有红灯），与本轮改动无关。

> **二轮复测补记（2026-09-07）**：二轮全量复跑时另有一条
> `ProductsStorekitGuardTests.testStorekitConfigurationActuallyLoadsProducts`
> 红（商品返回 0/2，本地测试商店配置未被 runtime 加载——CLI 跑测试注入
> StoreKit 配置的既有环境限制）。经 stash 对照在未改动工作树上**同样红**，
> 与本轮 diff 无关；Review 相关套件（ReviewFlowStateTests /
> ReviewRecapSameDayTests / DayStartHourBoundaryTests）全绿。上述一轮
> 「除 DST 外全绿」是一轮当时实测，二轮环境下基线红灯共两条（DST +
> StoreKit 守卫），对照时以 stash 基线为准。

_（其余待填）_
