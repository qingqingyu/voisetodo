# 统计页周/月 tab 与复盘窗口的割裂 —— 修复方案

> 状态：**待实施**。文档创建于 2026-09-02。
> 基线：`7959174`（`main`）。
> 环境提示：Swift 需在 **Xcode 26** 编译验证（iOS 26 部署目标）。
> 相关文件：`UI/Review/ReviewView.swift`、`UI/Review/RecapComponents.swift`、
> `UI/Review/Flow/ReviewFlowView.swift`、`Resources/Localizable.xcstrings`。
> 前置文档：`docs/todo-review-flow-design.md`（v1）、`docs/todo-review-flow-v2.md`（v2）。

## Context

统计页（`ReviewView`）顶部有一个吸顶的周/月 segmented picker。但复盘流程（`ReviewFlowView`）的窗口**固定是近 30 天**（`ReviewFlowView.swift:599`，`byAdding: .month, value: -1`），不随 picker 变。

用户反馈：选了「周」，进复盘看到的还是 30 天的数据，很割裂。

### 结论：不让复盘窗口跟随 tab

先说清楚为什么**不**采用「窗口跟着 tab 变」这个直觉方案——四条理由，前两条是硬的：

**1. 选「周」会让洞察集体哑火。** 已实现四条洞察的样本量门槛：

| 洞察 | minSample | 文件 |
|---|---|---|
| 03 计划 vs 救火 | 15 | `Rules/ReactiveVsPlannedRule.swift:24` |
| 05 精力窗口 | 15 | `Rules/EnergyWindowRule.swift:18` |
| 01 先易后难 | 6（两组各 3） | `Rules/EffortOrderingRule.swift:19` |
| 02 腐烂 | 3 | `Rules/RottingRule.swift:22` |

7 天内完成 15 条一次性任务，普通用户做不到。切到周 tab 再进复盘，第 3 步会退化成一屏「再记 N 条」占位行——**正是 v2 刚花力气修掉的那个状态**（见 v2 文档「根因」）。

**2. 跨期对照会变成拿 7 天比 30 天。** `ReviewSession` 存 `periodStart` / `periodEnd`（`ReviewSessionStore.swift:94-95`），`ReviewTopic.periodCount`（`:82`）存「提取当期的计数」，下次复盘展示「本期 N 件（上期 M 件）」。窗口浮动 → 上期是月、本期是周，括号里的数字直接骗人。冷却机制（效应量变化 ≥15% 才重复展示）同理：窗口不固定，两期效应量之间没有可比性。要修就得给 `ReviewSession` 加 `windowDays` 并只跟同窗口的上期比——成本远超收益。

**3. 卡堆根本不受窗口影响，改了反而更割裂。** `ReviewFlowState.triageInput`（`ReviewFlowView.swift:150`）取全部未完成一次性任务，与窗口无关。所以窗口只管第 1 步成绩单和第 3 步洞察；第 2、4、5 步一动不动。用户切到「周」期待这次复盘轻一点，结果**要处理的任务一条没少**——比现在更难受。

**4. 复盘节奏是周、数据窗口是月，是有意的。** `App/ReviewNotificationScheduler.swift:25` 每周一 9:00 推送，账本写「下次复盘 下周一」。**做复盘的频率**和**看数据的窗口**本就该分开：每周坐下来一次，但看滚动 30 天——「先易后难」「救火 vs 计划」这类习惯需要一个月才看得出来，7 天只能看出噪音。

### 真正的问题

割裂的来源不是窗口值，是**归属歧义 + 缺文案锚定**：

1. picker 用 `safeAreaInset(edge: .top)` 吸顶（`ReviewView.swift:139-141`），视觉上像管整页；
2. 入口卡夹在 picker 管辖的内容中间（`content` 里 `RecapStatsRow` 之后、`RecapCategoryChartSection` 之前，`:350-352`）；
3. 入口卡上**没有任何窗口说明**——「回顾近 30 天」在 2026-08-23 被移进了流程第 1 步（`reviewFlowEntryCard` 注释自述），但那是**点进去之后**才看到，而割裂感发生在**点之前**。

---

## 拍板决定（2026-09-02）

| # | 决定 | 内容 |
|---|---|---|
| A | 划清 picker 辖区 | Hero / Stats / 入口卡**固定近 30 天**；picker 去掉吸顶、下移到入口卡之后，只管它下方的图表区 |
| B | 文案锚定 | 入口卡上加「近 30 天」范围标；Hero 周期标签改为固定 30 天口径 |
| C | 顺手修 | 补 `review.period.*` 与 `review.nav_title` 缺失的日文 |

### 与既有拍板的关系（重要，别当成疏漏）

**A 部分修正 2026-08-23「先情绪回报再派活」**——但不反转。原拍板：有数据时 Hero/统计在前、入口卡在后；空态入口卡置顶。本方案**入口卡仍在 Hero/Stats 之后**，只是把 picker 和图表挪到入口卡下方。「先回报后派活」的顺序不变，且入口卡不再被夹在 tab 内容中间。

> ⚠️ **不要**把入口卡移到 picker 上方或页面最顶端。那才是真的反转 8-23，且周一提醒深链落到本页时会破坏「先回报」的节奏。

**B 部分回退 2026-08-23「『回顾近 30 天』移进流程第 1 步」**——有限度地。原决定的理由是「旧三行卡读起来像信息展示，不像动作」。本方案**不恢复三行卡**：只在既有一行动作行上加一个次要范围标（小字号 / muted 色），信息层级明确低于主文案，不会把动作行变回信息卡。流程第 1 步的 `review.flow.recap.scope` 保留不动，两处都有是刻意的——入口处说明范围，进去后确认范围。

---

## A · 划清 picker 辖区

### A1. `ReviewView` 拆成两个窗口

`ReviewView` 目前只有一个 `summary`（`:263-265`，用 `selectedPeriod` 算）。改成两个：

```swift
/// 固定近 30 天：Hero / Stats / 入口卡用。
private var fixedWindowSummary: ReviewSummary { ... }

/// 随 picker 变：分类图 / 每日趋势 / 最忙一天用。
private var periodSummary: ReviewSummary { ... }
```

**`fixedWindowSummary` 直接复用已有的 `RecapSummaryBuilder.monthSummary`**（`RecapComponents.swift:358`）——**不要新抽共享函数、不要自己算窗口**。已核实它内部的窗口与 `ReviewFlowView.loadInsightContext`（`:599-600`）逐字相同：

```swift
// RecapSummaryBuilder.monthSummary 内部（:365-367）
let todayStart = DayClock.startOfUserDay(for: today, calendar: calendar)
let start = calendar.date(byAdding: .month, value: -1, to: todayStart) ?? todayStart
let end = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? todayStart
```

而且 `ReviewStepRecap`（流程第 1 步）用的就是它——两边调同一个 builder，天然同源，这正是本次要的效果。

`periodSummary` 保留 `ReviewView` 现有的那套（`:263` 起，用 `selectedPeriod.startDay/endDay`），只是不再喂给 Hero/Stats。

### A2. 布局调整

`ReviewView.body`（`:104-152`）与 `content`（`:344-366`）：

- **删掉 `.safeAreaInset(edge: .top) { stickyPeriodHeader }`**（`:139-141`）。
- `stickyPeriodHeader` 改名并降级为内联分组头（去掉 `background(WarmTheme.cardBackground)` 与底部 1px divider 那套吸顶装扮，保留 `periodPicker`）。

`content` 的新顺序：

```
RecapHeroSection(summary: fixedWindowSummary)      // 30 天
RecapStatsRow(summary: fixedWindowSummary)         // 30 天
reviewFlowEntryCard                                 // 30 天，位置不变
── 分组边界（picker 从这里开始管） ──
periodPicker（内联）
RecapCategoryChartSection(byCategory: periodSummary.byCategory)
dailyTrendSection                                   // 用 periodSummary
busiestDaySection                                   // 用 periodSummary
── 分组结束 ──
reviewNotesSection                                  // 不受 picker 管
```

**空态分支（`:112-127`）不动**：`summary.total == 0` 的判定改用 `fixedWindowSummary.total`，入口卡仍置顶（8-23 拍板「新用户行动入口必须第一眼可见」不变）。

⚠️ `dailyTrendSection` / `busiestDaySection` / `xAxisDates` 内部都直接读 `selectedPeriod` 与 `summary`（`:494`、`:526`、`:529`）——改窗口拆分时这些调用点要一并指向 `periodSummary`，**别漏**，漏了会出现「图表是月、结论句是 30 天」的新割裂。

### A3. 共享组件不许动

`RecapHeroSection` / `RecapStatsRow` / `RecapCategoryChartSection` 是 `ReviewView` 与 `ReviewStepRecap` **共用**的（`RecapComponents.swift` 头注释明写「别在两处复制」，v2 审阅缺口 A 已经踩过一次）。

本方案只改**调用方传什么 summary**，不改组件签名与内部实现。`ReviewStepRecap` 侧零变化。

附带收益：改完之后 `ReviewView` 的 Hero/Stats 与 `ReviewStepRecap` 的 Hero/Stats 变成**同窗口同数字**——用户从统计页点进复盘，第 1 步的数字与刚才看到的一致，不再需要重新建立心智。

---

## B · 文案锚定

### B1. 入口卡加范围标

`reviewFlowEntryCard`（`:166-216`）：在主文案 `Text` 下方加一行次要范围标。

- 字号 `WarmFont.caption(11)`，颜色 `WarmTheme.textMuted`（信息层级明确低于主文案 `headline(15)`）。
- `lineLimit(1)` + `minimumScaleFactor(0.7)`（与本文件既有文本一致）。
- 主文案与范围标包进 `VStack(alignment: .leading, spacing: WarmSpacing.xxs)`，整体仍在原 `HStack` 里，尾部胶囊「开始 →」位置不变。

⚠️ 不要加成第三行、不要加图标——一个次要范围标即可，多了就退回 8-23 否掉的「信息展示卡」。

### B2. Hero 周期标签改口径（顺带修一个既有标签错配）

`RecapHeroSection` 渲染 `summary.periodLabel`（`RecapComponents.swift:24`）。

⚠️ **这里有一个已经上线的 bug**：`RecapSummaryBuilder.monthSummary` 的窗口是**滚动 30 天**（`todayStart - 1 month` 到 `todayStart + 1 day`），但它把 `periodLabel` 设成了**日历月名**（`:368-369`，`.year().month(.abbreviated)` → 「2026年9月」）。今天是 9 月 2 日时，窗口实际覆盖 8/2–9/3，标签却写「2026年9月」——**标注的和统计的不是同一段时间**。

所以 B2 不只是装饰，是修正。做法：给 `monthSummary` 加一个可选参数

```swift
static func monthSummary(
    today: Date = Date(),
    calendar: Calendar = Calendar.current,
    periodLabel: String? = nil,   // 新增：nil = 沿用现有日历月名（零回归）
    ...
)
```

`ReviewView` 与 `ReviewStepRecap` **两处都传** `String(localized: "review.window.last30d")`。两个调用方都改，否则流程第 1 步仍挂着错标签。默认值 `nil` 保留旧行为，是为了让参数新增不影响任何未列出的调用方（改完请 grep 确认只有这两处）。

`ReviewPeriod.periodLabel`（`ReviewView.swift:45-55`）保留——`periodSummary` 那一路仍要用它给图表区做标签。

### B3. 新增 / 复用字符串

| key | zh-Hans | en | ja |
|---|---|---|---|
| `review.window.last30d`（新增） | `近 30 天` | `Last 30 days` | `過去 30 日間` |
| `review.section.trends`（新增，图表分组头，可选） | `趋势` | `Trends` | `推移` |

- 入口卡范围标（B1）与 Hero 周期标签（B2）**共用** `review.window.last30d`。
- 流程第 1 步的 `review.flow.recap.scope`（`回顾近 30 天` / `The last 30 days` / `過去 30 日間をふりかえる`）**保留不动**，不要合并——那句是「回顾」动词句，入口处需要的是名词短语。
- `review.flow.entry.empty` 现文案 zh `都清完了,看看这一个月` / en `All sorted — see how the month went` 已隐含 30 天，加了范围标后语义重复但不冲突，**本次不改**（改文案要重新过三语措辞，不在本方案范围）。

---

## C · 顺手修：日文缺失

以下四个 key **只有 en 与 zh-Hans，没有 ja**，而 app 发 ja/ja-JP——日文设备上统计页 picker 与导航标题现在显示英文：

| key | 现有 | 补 ja |
|---|---|---|
| `review.nav_title` | en `Review` / zh `回顾` | `ふりかえり` |
| `review.period.title` | en `Period` / zh `周期` | `期間` |
| `review.period.week` | en `Week` / zh `周` | `週` |
| `review.period.month` | en `Month` / zh `月` | `月` |

⚠️ `review.period.title` 的 `extractionState` 是 `manual`，补 ja 时保留该字段，不要改成自动提取。

---

## 不要做什么（给实现者的护栏）

1. **不要让复盘窗口跟随 `selectedPeriod`**——这是本方案明确否掉的方向，理由见 Context「结论」四条。
2. **不要把入口卡移到 picker 上方或页面最顶端**（反转 8-23，见「与既有拍板的关系」）。
3. **不要修改 `RecapHeroSection` / `RecapStatsRow` / `RecapCategoryChartSection` 的签名或内部**（与 `ReviewStepRecap` 共用，v2 缺口 A 已踩过）。
4. **不要在 `ReviewView` 里另写一套窗口聚合**——复用 `RecapSummaryBuilder`，窗口计算抽共享函数。
5. **不要动 `ReviewFlowView` 的 30 天窗口值**——它是基准，`ReviewView` 向它对齐，不是反过来。
6. **不要删 `ReviewPeriod.periodLabel`**——图表区那一路还要用。
7. **不要只改 `ReviewView` 一处的 `periodLabel`**——`monthSummary` 的两个调用方（`ReviewView` 与 `ReviewStepRecap`）都要传，漏一个就会出现「统计页说近 30 天、流程里说 2026年9月」的新割裂。

---

## 验收标准

1. 统计页选「周」与选「月」，**Hero 数字、Stats、入口卡三处完全不变**；只有分类图 / 每日趋势 / 最忙一天跟着变。
2. 入口卡上可见「近 30 天」范围标，字号与颜色明显次于主文案。
3. picker 不再吸顶；滚动时它随内容滚走。
4. 从统计页点入口卡进流程，**第 1 步 Hero 数字与统计页 Hero 数字相同**。
5. 空态（近 30 天零完成）下入口卡仍置顶。
6. 日文设备上 picker 显示「週 / 月」、导航标题显示「ふりかえり」。
7. `ReviewStepRecap` 的 Hero **只有周期标签一处变化**（「2026年9月」→「近 30 天」），其余渲染与改动前一致（共用组件本体未被动过）。
8. 统计页 Hero 与流程第 1 步 Hero 的周期标签文案相同。

## 验证

**单测**

- 窗口共享函数：同一 `now` 下 `ReviewView` 与 `ReviewFlowView` 取到的 `[start, end)` 完全相同；`startHour = 0 / 3` 两种配置各测一次。
- `fixedWindowSummary` 不随 `selectedPeriod` 变化（构造两个 period 断言 summary 相等）。
- 现有 `ReviewRecapSameDayTests` / `HomeCalendarStateGroupingTests` 全绿（回归护栏）。

**真机手测**

1. 周/月来回切，确认验收标准 1 逐项成立。
2. 三语走查（zh / en / ja，含 AX5 大字号）：入口卡加了范围标后不挤爆、不换行到三行；日文 picker 显示正确。
3. 周一提醒深链进本页：入口卡在首屏可见（不需要滚动）。
4. 设置里把日起始小时改成 3，确认两处窗口仍一致。

---

## 不在本方案

- 砍掉周/月 tab（统计页也固定 30 天）。这是更彻底的统一，但需要先判断有多少用户真在切；若本方案落地后仍觉别扭，再单独立项。
- 复盘窗口可配置（用户自选 7 / 30 天）。需要给 `ReviewSession` 加 `windowDays` 并改跨期对照口径，成本高、收益存疑。
- `review.flow.entry.empty` 的三语措辞重写。
