# 复盘流程（五步）—— 设计方案与实施计划

> 状态：**已实施（v1 = 阶段 0–4，2026-08-21，分支 `fupan`，commits `46b439e..5b3311e`）**。文档创建于 2026-08-21；同日评估拍板（见「拍板决定（2026-08-21）」）并完成实施（见文末「实施落地记录」）。阶段 5 为可选增强，未实施。
> 行号基准：`5f90585`（分支 `claude/todo-review-flow-design-6iyjlb` HEAD）。
> 实施后请在此处补「实施落地记录」节，并把状态改为「已实施」（沿用
> `docs/moat-plan-personalization-and-review.md` / `docs/day-clock-day-boundary-inconsistencies.md` 的体例）。
> 环境提示：Swift 代码需在 **Xcode 26** 编译验证（iOS 26 部署目标）；
> `Protocols/` 纯逻辑可用 `swift test` 单跑；AIProxy(Worker) 的 JS 用 `node --test AIProxy/worker.test.js`。
> 相关文件：`UI/Review/ReviewView.swift`、`Protocols/Domain/ReviewAggregator.swift`、
> `Store/SwiftDataModels.swift`、`Store/TodoStore.swift`、`Store/TodoQueryActor.swift`、
> `Protocols/Domain/DayClock.swift`。

## Context

现有的「回顾」页（`UI/Review/ReviewView.swift`）是一张**成绩单**：完成数、streak、完成率、分类横条、每日趋势、最忙一天。真实用户反馈是——他们要的不是成绩单，是**复盘**：没做完的怎么办、我的做事习惯是什么（比如「他习惯先完成比较简单的事情」）。成绩单只回答「我做了多少」，不回答「我为什么没做」和「下周改什么」。

本方案把复盘做成一条**五步流程**（回顾 → 处理没做完的 → 观察 → 下周三件事 → 收尾），挂在现有回顾页里。核心不是加图表，是让每一个观察都能落成一个**决定**（排进下周 / 划掉 / 拆小 / 存成规则）——一个观察如果不能变成一条约束，它就只是好看。

洞察的计算口径、阈值、样本量下限、文案模板另有一份规格文档（`voicetodoinsightspec.md`，随本次需求提供），本文档在需要偏离它的地方会显式标出。

### 已确认的四个方向

| 决策 | 选择 |
|---|---|
| 推迟数据 | 新建事件表，从现在起记；历史不回填推断 |
| 第一版范围 | 五步骨架 + 当前数据能诚实支撑的洞察；语音提问和规则按钮只做存储 + 回访，不做效果逻辑 |
| 页面结构 | `ReviewView` 保留为默认页，顶部加「开始这次复盘」入口卡，点进去是全屏五步流程 |
| 「重要」标记 | 复用 `Priority.high`，不新增字段 |

### 拍板决定（2026-08-21，评估后定稿）

代码评估核实了「现状盘点」的全部断言（一处补充：`Store/TodoStore.swift:910` 还有一处 `dueDate` 赋值，但那是启动迁移 `migrateDueDatesFromHints()` 的 nil→首次排期，按 §1.3 规则本就不记，choke point 结论不变）。基于评估拍板：

| # | 决定 | 选择 | 理由 |
|---|---|---|---|
| 1 | abandoned 与完成率分母 | **留在分母**，账本/完成率卡明示口径 | 堵死「划掉保数字」的 gaming 路径；首次大清理完成率下跌是真实信息 |
| 2 | v1 洞察范围 | **只做 02（腐烂）+ 03（计划 vs 救火）** | 02 唯一冷启动可用且直连第 2 步动作；01/05 待阶段 0 体检，06 待 ≥4 完整周，04 涉及可编辑 accountability 映射、v2 再做 |
| 3 | TaskEvent 记录范围 | **只记 `deferred` / `abandoned` / `split`** | created/completed 从 `createdAt`/`completedAt` 推导；widget 进程完成不经事件表，completed 记了反而比字段更不全 |
| 4 | 规律任务 vs 第 2 步卡片堆 | **排除**（`recurrenceRule == nil && abandonedAt == nil`），标题写明「一次性任务」 | 规律父任务永远 `isCompleted == false` 会刷屏；右滑「排下周」会移动整个系列，语义不明 |
| 5 | `TaskEventOrigin` | 删 `widget`，集合为 `app \| review \| detail` | 已核实 widget/AppIntents 无 dueDate 写入点，`deferred` 不可能在 widget 进程发生 |
| 6 | 下周三件事置顶 | **独立置顶标记**，不动 `sortOrder` | `sortOrder` 承载手动拖拽序（含 sort_order 迁移），复盘改它会破坏用户自排的序 |
| 7 | 撤销范围 | **只覆盖「划掉」** | 拆小的 undo 要删两条子任务+恢复原任务，成本高；排进下周/今天就做不提供 undo |

### 现状盘点（已核实）

- **数据层**：SwiftData，App Group 容器（`Store/AppGroupModelContainerProvider.swift`）。Schema 单一注册点 `VoiceTodoSchema.schema`（`Store/SwiftDataModels.swift:619`）。**无 `VersionedSchema` / `SchemaMigrationPlan`**——新字段必须 optional 或带默认值才走轻量迁移（既有模式见 `:14-16`、`:23`、`:52-60`、`:66-68`）。
- **`TodoItem`** 有 `createdAt` / `completedAt` / `dueDate` / `hasDueTime` / `priorityRaw` / `categoryRaw`。**没有** `abandonedAt`、`parentTodoId`、推迟计数。
- **写入 choke point**：所有 dueDate 变更最终都汇进 `TodoStore.updateFull`（`Store/TodoStore.swift:283`）——`updateTime` 是 `TodoDetailUpdating` 的协议默认实现（`Protocols/TodoStoreProtocol.swift:75-104`），`HomeView.moveTodoToTomorrow`（`:2568`）/ `changeTodoTime`（`:2608`）/ `pickTodoDate`（`:2630`）全部经由它。**埋点只需要改一个地方。**
- **没有自动顺延**：过期任务原地留着，不会滚到今天。所以规格文档里的 `auto_rollover` origin 在本 App 不存在。
- **日界**：`DayClock`（`Protocols/Domain/DayClock.swift`）已实现用户可配的日起始小时，全部聚合走 `startOfUserDay`。规格里「日界在凌晨 4 点」这条**已经有更好的实现**，直接复用，不要另写。
- **设计系统**：`UI/Shared/DesignSystem.swift` 的 `WarmTheme` / `WarmSpacing` / `WarmRadius` / `WarmFont` / `PaperTextureBackground`。HTML 原型的珊瑚色 `#E2794F` ≈ 现有 `WarmTheme.primary #FF8A6B`，**用现有 token，不要引入原型里的新配色**。
- **本地化**：`Resources/Localizable.xcstrings`，source = `en`，已有 `zh-Hans` / `ja`。所有新文案必须走 `String(localized:)`。
- **Xcode 工程**：`project.yml` 按目录收源码（`UI/Review` 已在列），但 `VoiceTodo.xcodeproj/project.pbxproj` 是入库的——新文件需同步注册（参考 `prepare_xcode_project.sh`）。

---

## 阶段 0 · 数据体检（先做，半天，决定后面砍什么）

洞察 01 和 05 都依赖 `Priority.high` 当「重要」。如果真实库里 high 占比极低，这两条永远不会触发，做了也白做。

写一个一次性的 debug-only 诊断（可挂在 `HomeSettingsSheet` 的 DEBUG section，或写成 `VoiceTodoTests` 里跑真机导出库的用例），打印：

1. `priority == .high` 的任务总数、其中已完成数、占全部任务比例
2. `hasDueTime == true` 的任务占比（洞察 05 需要重要任务有明确钟点，否则退化用 `completedAt` 小时）
3. 已完成任务总数、有 `dueDate` 的任务数、分类分布（每类 n）
4. 最早一条 `createdAt` 到今天的周数（洞察 06 需要 ≥4 个完整周）

**判据**（拍板 2 后语义微调：01/05 本就不在 v1，体检决定的是**何时值得启用**）：若已完成的 high 任务 < 8 条且没有增长趋势，01/05 长期搁置，不投实现精力；同时考虑在详情页把「重要」标记做得更显眼（现在只有 `UI/Home/WarmTodoCard.swift:306` 的字重差异，用户可能根本不知道能标）。

---

## 阶段 1 · 数据地基

没有这一层，洞察 01/02 都做不准，返工成本最高。先做。

### 1.1 新增 `TaskEvent` @Model

新文件 `Store/TaskEventModels.swift`：

```swift
@Model
final class TaskEvent {
    @Attribute(.unique) var id: UUID
    var todoId: UUID
    var typeRaw: String        // deferred | abandoned | split（拍板 3：只记推导不出的三类）
    var fromDate: Date?        // deferred 时的原 dueDate
    var toDate: Date?          // deferred 时的新 dueDate
    var at: Date
    var originRaw: String      // app | review | detail（拍板 5：无 widget 写入点）

    #Index<TaskEvent>([\.todoId], [\.at], [\.typeRaw])
}
```

配套纯枚举放 `Protocols/Domain/TaskEventKind.swift`（`TaskEventType` / `TaskEventOrigin`，`String` raw + `tolerant(_:)` 容错构造，照 `TodoCategory`（`Protocols/Models.swift:23`）的写法）。

**在 `VoiceTodoSchema.schema`（`Store/SwiftDataModels.swift:621`）注册。** ⚠️ Widget 的 `readOnly()` 容器打开同一个库，schema 必须一致——`VoiceTodoSchema` 是单一来源所以天然同步，但**首次打开旧库要建索引**，需按 `docs/completed-todos-performance.md §6.4` 的方式用有数据的旧库实测，别只在空模拟器上验。

> 为什么用事件表而不是 `TodoItem` 上放一个 `deferCount` 计数器：计数器在编辑、撤销、跨设备同步时会失真，且无法回答「这次推迟发生在什么时候、从哪天推到哪天」。

### 1.2 `TodoItem` 加两个 optional 字段

`Store/SwiftDataModels.swift` — 照 `eventEndDate`（`:72`）的既有模式，optional 走轻量迁移：

- `var abandonedAt: Date?` — 复盘里「划掉」的时刻。**必须和删除分开**：删除是数据消失，划掉是一个有意义的决定，要进复盘账本、要能撤销、**要留在完成率的分母里**（否则复盘变成一台洗数据的机器，用户会学会用划掉保住数字）。
- `var parentTodoId: UUID?` — 拆小后指向原任务。

同步更新 `TodoItemData`（`Protocols/Models.swift:530`）、`TodoItem.toData()`（`:178`）、`TodoItem.from(_ data:)`（`:360`）。

**所有现有的「未完成」过滤都要补 `abandonedAt == nil`** —— 这是最容易漏的一处。检查点：`UI/Home/HomeCalendarState.swift`、`Protocols/Domain/WidgetTodoFilter.swift`、`TodoQueryActor.recentUncompleted` / `pendingItems`、`TodoStore.todos` 的消费方。

**反向检查点（拍板 1）**：`ReviewView.swift:159` 的 `dueByTodayCount`（完成率分母）**不过滤** `abandonedAt`——划掉的任务要留在分母里。两处方向相反，别改串了。

### 1.3 埋点

新文件 `Store/TaskEventRecorder.swift`——一个薄的写入器，`TodoStore` 持有：

- **`deferred`**：只在 `TodoStore.updateFull`（`:283`）一处记。判定：`新 dueDate` 的用户日 > `旧 dueDate` 的用户日才记；**往前改不记**；旧 dueDate 为 nil（从未排期 → 首次排期）不记。`origin` 由调用方传入（新增一个带默认值的参数，默认 `.app`，复盘流程传 `.review`）。
- **`abandoned`**：新增 `TodoStore.abandon(_ id:)` / `unabandon(_ id:)`。
- **`split`**：复盘拆小时记，同时写子任务的 `parentTodoId`。
- **不记 `created` / `completed` / `reopened`（拍板 3）**：三者从 `TodoItem.createdAt` / `completedAt` 直接推导。特别是不记 `completed`——Widget/AppIntent 进程的完成走自己的 context、不经 `toggleComplete`，事件表覆盖天生残缺，记了反而比字段更不全、误导分析。

**统计推迟次数时排除 `origin == .review`**——复盘里主动做的排期不该被算成推迟，否则用户越认真复盘，数字越难看。

### 1.4 查询下沉

`ReviewView` 现在用三个 `@Query` 直读全表（包括一个**无过滤的 `allTodos` 全表查询**，`ReviewView.swift:79`），且 `summary` 是计算属性、每次 body 求值都重算。**洞察规则叠上去会把这个问题放大成数倍全表扫描。**

按 `docs/moat-plan-personalization-and-review.md` 里当初就写了、但实施时被跳过的 B1 方案补回来（该文档「⚠️ 实施时的偏离决策」一节已记录这笔欠账）：在 `TodoQueryActor`（`Store/TodoQueryActor.swift`）加只读方法，返回值类型 DTO：

```swift
func insightContext(from: Date, to: Date) async throws -> InsightContext
```

一次性取齐规则要的原料（完成事件、未完成任务、区间内到期任务、推迟事件计数），组装成一个 `Sendable` 的 `InsightContext` 结构体（放 `Protocols/Domain/Insights/`）。UI 侧在 `.task` 里 await 一次存进 `@State`，不放 body。

---

## 阶段 2 · 洞察引擎

纯函数层放 `Protocols/Domain/Insights/`，与 `ReviewAggregator` 同级，全部可单测、无 SwiftData 依赖。

### 2.1 骨架

`Protocols/Domain/Insights/InsightEngine.swift`：

```swift
enum InsightID: String, CaseIterable {
    // v1 只实现 rotting / reactiveVsPlanned（拍板 2）。
    // 其余四个 case 仅预留 ID，不建规则文件——待阶段 0 体检（01/05）、
    // 数据攒满（06）或 v2（04）再启用。
    case effortOrdering     // 01 先易后难（待体检）
    case rotting            // 02 任务在腐烂 ← v1
    case reactiveVsPlanned  // 03 计划 vs 救火 ← v1
    case brokenPromises     // 04 对谁失约（v2）
    case energyWindow       // 05 精力窗口（待体检）
    case weeklyDecay        // 06 周内衰减（待 ≥4 完整周）
}
enum InsightStrength { case high, medium, lowData }
enum InsightAvailability { case fired(InsightResult), placeholder(needMore: Int), hidden }

protocol InsightRule {
    var id: InsightID { get }
    var minSample: Int { get }
    func evaluate(_ ctx: InsightContext) -> InsightAvailability
}
```

`InsightResult` 携带 `strength` / `headline` / `body` / `viz: VizPayload`（枚举，六种图各一个 case）/ `suggestedRule: ReviewRule?` / `sampleNote` / `score`。

**排序分数**（规格 §1.1）：

```
score = normalizedEffect × confidence
normalizedEffect = min(1.0, 实际效应量 / 满分效应量)
confidence       = min(1.0, 实际样本量 / (2 × minSample))
```

`confidence` 用 2 倍下限做满分，让刚过样本线的洞察自动排后面——这是防止「3 条数据看出惊天规律」的主要机制。

**强度标签**：`score ≥ 0.62` → 信号强；`0.35 ≤ score < 0.62` → 信号中；`n < 1.5 × minSample` → 数据偏少（不管 score 多高，强制标）。

### 2.2 规则口径（v1 实现 02/03，拍板 2；其余条目的口径保留备用）

全部按规格文档 §2 实现，**除了下面这些必须的偏离**：

- **时间口径用 `DayClock.startOfUserDay`**，不是规格里写的固定 4 点。用户已经能在设置里配日起始小时（`UI/Home/HomeSettingsSheet.swift:122`），洞察必须跟随，否则同一天数据在首页和复盘页对不上。
- **规律任务全部排除在洞察与第 2 步卡片堆之外（拍板 4 扩大了原口径）。** 规格文档没处理这个。`TodoOccurrenceCompletion`（`Store/SwiftDataModels.swift:489`）只有 `completedAt` / `occurrenceDate`，**没有 per-occurrence 的 `createdAt`**——洞察 01（记下到做完的滞留）和 03（当天记当天做）在它上面根本算不出来。强行混进去会得到系统性偏低的滞留时间。且规律父任务永远 `isCompleted == false`，进卡片堆会刷屏、右滑「排下周」还会移动整个系列。做法：洞察输入与第 2 步 triage 输入都只取一次性 `TodoItem`（`recurrenceRule == nil && abandonedAt == nil`），第 2 步标题写明「处理没做完的一次性任务」；现有成绩单（第 1 步）继续 union 两者不变。这个差异要写进 `sampleNote`（如「47 条一次性任务，不含规律任务」）。
- **洞察 02「腐烂」冷启动只走 age 分支。** 推迟分支（`defers ≥ 3`）在事件表攒够之前恒为空。判定：未完成 且 `abandonedAt == nil` 且（有效推迟 ≥3 **或** `now - createdAt ≥ 21 天`）。这条是六条里**唯一冷启动就能用的**，也是唯一直接连着第 2 步处理动作的，最快能验证用户是否在意。
- **洞察 04「对谁失约」（v2，拍板 2）的分母必须含已划掉的任务**（`abandonedAt != nil`）。`Accountability { external, self }` 的默认映射：`.work` / `.finance` → external，其余 → self，**并允许用户改**（放在第 3 步卡片上的一个小入口，或设置页；有些人的副业有合伙人）。
- **洞察 05「精力窗口」（待阶段 0 体检，拍板 2）的重要任务时段**：`hasDueTime == true` 时用 `dueDate` 小时，否则退化用 `completedAt` 小时（规格 §2-05 已写）。阶段 0 的体检结果决定这条走不走。**文案止于观察，不要写成「你应该早起」**——数据只说明错位，不说明该往哪边调：有人的解法是把重要任务挪到上午，有人的解法是重新定义什么叫重要。
- **`auto_rollover` origin 不存在**，origin 集合是 `app | review | detail`（拍板 5 删 `widget`：已核实 widget/AppIntents 无 dueDate 写入点，`deferred` 不可能在 widget 进程发生）。

### 2.3 降级阶梯（规格 §3）

| 已完成记录数 | 第 3 步显示（v1 只有 02/03，拍板 2） |
|---|---|
| < 5 | 整个第 3 步跳过，第 2 步直连第 4 步 |
| 5–14 | 只跑洞察 02，加一句「再记 N 条，就能看出你的做事习惯了」 |
| ≥ 15 | 跑 02 + 03，未达阈值的**不显示**（不是显示「无异常」） |

未实现的规则（01/04/05/06）v1 **不显示占位行**——占位行机制（「还需 N 条」）只对已实现规则生效；其余规则按拍板 2 的条件启用时，再把各自的占位行加回降级阶梯。

占位行要写清楚**还差多少**。用户看到「还需 11 条」会继续用；看到「数据不足」会觉得这个功能坏了。新用户第一次点复盘就会撞上这个状态——它比主流程更影响留存，值得先把降级路径做扎实。

### 2.4 冷却（规格 §1.3）

同一条洞察连续三次复盘都说同样的话，用户就不看了。满足任一条件才重复展示：

1. 距上次展示 ≥3 次复盘
2. 效应量相对上次变化 ≥15%（变好也算，「这条你改过来了」）
3. 用户上次为它存了规则（要回访规则有没有生效）

效应量变好时**换一套文案**（各条的「好转文案」）——复盘只报坏消息，用户会停止复盘。需要的历史记录见阶段 4。

### 2.5 反 gaming（规格 §4，写进代码注释别丢）

复盘指标一旦成为分数，用户就会去优化分数而不是优化生活。所以：不给复盘打总分、不做效率评级、不把完成率放大成主指标（用户会少建任务、只建容易的）、不做连续复盘 streak 奖励（复盘该是自愿的，漏一次不该有惩罚感）。

---

## 阶段 3 · 五步流程 UI

新目录 `UI/Review/Flow/`，按步骤拆文件，避免又出一个 691 行的单文件：

| 文件 | 内容 |
|---|---|
| `ReviewFlowView.swift` | 流程容器：步骤条、底部主按钮、步骤间转场、`ReviewFlowState`（`@Observable`，持有本次复盘的所有决定） |
| `ReviewStepRecap.swift` | 第 1 步 · 回顾。**复用现有 `ReviewView` 的成绩单组件**，压到 10 秒能看完 |
| `ReviewStepTriage.swift` | 第 2 步 · 处理没做完的。卡片堆 |
| `ReviewStepInsights.swift` | 第 3 步 · 观察。洞察卡列表 + 语音提问 + 跨期对照卡 |
| `ReviewStepCommit.swift` | 第 4 步 · 下周三件事 + 本次存下的规则 |
| `ReviewStepLedger.swift` | 第 5 步 · 收尾账本 |
| `InsightCardView.swift` + `InsightVizViews.swift` | 洞察卡容器 + 图的 SwiftUI 实现（v1 只有 02/03 两种图，拍板 2） |

### 第 2 步 · 卡片堆（真实用户最直接的诉求，优先级最高）

输入（拍板 4）：未完成 且 `abandonedAt == nil` 且 `recurrenceRule == nil` 的一次性任务。步骤标题写明「处理没做完的一次性任务」，让范围自明。

- 右滑 → 排进下周（`updateFull` 改 dueDate，`origin = .review`，**不计入推迟次数**）
- 左滑 → 划掉（写 `abandonedAt`，**不是 delete**）
- 「今天就做」按钮 → dueDate = 今天
- 「拆小」按钮 → 见下
- 卡上那排斜杠是推迟次数，一道一次——比写「已推迟 4 次」更刺眼一点。冷启动没有推迟数据时，这排斜杠换成「记下 N 天了」。
- 手势用 `UI/Shared/SimultaneousDragGesture.swift`（iOS 26 下 SwiftUI `.simultaneousGesture(DragGesture)` 在容器内不可靠触发，那个文件的注释里写了原因和 FB 编号）。触觉用 `UI/Shared/Haptics.swift`。
- 滑动阈值：HTML 原型里是 85px。移动端做成**位移或速度任一达标**即触发（`DragTranslation.velocity` 已经提供了速度），纯位移阈值在小屏上偏难。
- **撤销只覆盖「划掉」（拍板 7）**——划掉是个决定，但用户会手滑。顶部留一个「撤销上一张」，仅恢复最近一次划掉；排进下周 / 今天就做 / 拆小不提供 undo（拆小的 undo 要删两条子任务+恢复原任务，成本高）。

**拆小（v1 手动，AI 版放阶段 5）**：底部弹 sheet，预填两条空的子任务输入框，用户自己填或按住麦克风说。提交后创建两条新 `TodoItem`（`parentTodoId` 指向原任务），原任务标 `abandonedAt`，记 `split` 事件。这样第一版流程是完整的，AI 拆小是纯增强。

### 第 3 步 · 洞察

- 参与的洞察按 `score` 降序排。**副作用**：每个月排序可能变化——最该看的在最上面（好），但用户找不到上次那条（坏）。第一版先按分数排，如果用户测试反馈找不到，再给每条加固定锚点。
- **折叠机制保留但 v1 常空载**（只有 02/03 两条）：强信号默认展开，其余折叠成「还有 N 个观察」。规则启用到 4+ 条时该机制自然生效，展开态可以 A/B。
- 每张卡右下角是样本量（「51 条带时间戳」「4 周 · 再攒 4 周更准」），右上角是信号强度标签。数据不够时要诚实地说，而不是假装确定。
- 图表用 SwiftUI 原生绘制（`GeometryReader` + `RoundedRectangle`），**不要为这六张图引 Swift Charts**——现有 `ReviewView` 的分类图当初就从 `SectorMark` 换回了手写横条（`ReviewView.swift:355` 的注释写了原因：2 类各 1 件时画成半圆纯属装饰）。只有第 1 步的每日趋势继续用现有的 `BarMark`。
- 滚动进入视野时才播入场动画（呼应原型的 IntersectionObserver，顺便解决一次性看六张图的疲劳感）。用 `.onScrollVisibilityChange` 或复用 `UI/Shared/CardEntranceModifier.swift`。
- **每张卡底部一个规则按钮**（「22 点后不排重要任务」这种）。点了带到第 4 步「这次存下的规则」，并计入最后的账。这是让洞察不停在「知道了」的关键。
- 洞察 02「腐烂」的任务**必须可点击直接跳回第 2 步的对应卡片**。指出腐烂却不给处理入口是最糟的设计。
- 语音提问：复用 `VoiceInputProtocol`（`Protocols/VoiceInputProtocol.swift`——`startRecording()` / `stopRecording()` / `transcript`）。⚠️ 实施时先确认这条链路**不消耗 AI 额度**（`Protocols/Quota.swift` 计的是提取调用；语音笔记只要转写、不走提取，理应免费）——如果实际会扣额度，改成本地 `SFSpeechRecognizer` 直调或允许纯文字输入。

### 第 4 步 · 下周三件事

从刚才排进下周的里挑，最多 3 件，**不选够不给过**。选中的下周一置顶——**用独立置顶标记（拍板 6），不动 `sortOrder`**：`sortOrder` 承载用户手动拖拽序（含 `sort_order` 迁移逻辑），复盘改它会破坏用户自排的序。置顶落为 `TodoItem` 的 optional 字段还是纯展示层标记，实施时再定。

### 第 5 步 · 收尾账本

一张账：N 条变 M 条、划掉几条、拆了几条、存了几条规则、下次复盘日期。

---

## 阶段 4 · 复盘会话持久化

用 App Group `UserDefaults` + JSON，**不进 SwiftData**——一年约 52 条记录，量小；SwiftData 每加一个 `@Model` 都要动 `VoiceTodoSchema` 并连带 Widget 的只读容器，风险不划算。照 `Protocols/PersonalGlossary.swift`（`PersonalGlossaryStore`）和 `Protocols/CorrectionTracker.swift` 的现成范式写。

新文件 `Protocols/ReviewSessionStore.swift`：

```swift
struct ReviewSession: Codable, Sendable {
    let id: UUID
    let completedAt: Date
    let periodStart: Date
    let periodEnd: Date
    let voiceNote: String?                // 第 3 步的语音回答（转写文本）
    let savedRules: [ReviewRule]          // 本次存下的规则
    let ledger: ReviewLedger              // 划掉 N / 拆 M / 置顶 K / 剩余 R
    let shownInsights: [InsightSnapshot]  // id + effectSize + strength，冷却判定用
}
```

支撑三件事：

1. **跨期对照卡**（「上次复盘你说过：想把晚上留给八字 App」）— 读上一条的 `voiceNote`，配一句本期数据的对照。
2. **冷却判定** — 读 `shownInsights` 的历史 effectSize。
3. **规则回访** — 存下的规则在下次复盘时回来问「这条生效了吗」。

**规则本身第一版只存储 + 回访，不做效果逻辑。** 先验证用户会不会点那个按钮——如果没人点，说明洞察本身还不够准，做效果逻辑是浪费。

---

## 阶段 5 · 可选增强

- **AI 拆小**：在 `AIProxy` Worker（`AIProxy/src/adapters/base.js`）加一个 split 模式的 prompt，`Extractor/NetworkClient.swift` 加对应请求。要考虑额度计费（`Protocols/Quota.swift`）。
- **规则效果逻辑**：如「22 点后不排重要任务」→ 给重要任务设 22 点后的 dueDate 时弹一次轻提示（可忽略）；「重要的事排进上午」→ 新建 high 任务默认 dueDate 09:00；「推迟满 3 次就提醒我决定」→ 第 3 次推迟时一次性弹窗，选项「拆小 / 划掉 / 就是要留着」。
- **复盘提醒**：现有 `App/ReviewNotificationScheduler.swift` 已在每周一 9:00 推送并深链到回顾页（`App/AppCoordinator.swift:63` → `UI/Home/HomeView.swift:511`），改成深链到复盘流程即可。

---

## 入口与既有页面

`ReviewView.swift` 保持现状不动，只在 `content`（`:228`）最上方加一张入口卡：

- 标题「开始这次复盘」
- 副文案：待处理 N 条（未完成且 `abandonedAt == nil`）+ 上次复盘日期
- 点击 → `.fullScreenCover` 呈现 `ReviewFlowView`

日常随手看统计和郑重坐下来复盘是两种心智，不该混。

第 1 步复用成绩单时，把 `heroSection`（`:261`）/ `statsRow`（`:281`）/ `categoryChartSection`（`:357`）从 `ReviewView` 里抽成独立的 `internal` 组件（新文件 `UI/Review/RecapComponents.swift`），两处共用，别复制一份。顺带把 `statCard` / `completionRateCard` 里重复了两遍的背景块（`:321`、`:346`）和局部的 `reviewCard`（`:589`）也一起收进去。

---

## 本地化

所有新文案进 `Resources/Localizable.xcstrings`，键前缀 `review.flow.*` / `review.insight.<id>.*`。source language 是 `en`，需要补 `zh-Hans` 和 `ja`。

⚠️ 文案模板里带数字/日期的（如「标了重要的 {n} 件事，从记下到做完中位 {d} 天」）要用 xcstrings 的参数化格式，别在 Swift 里字符串拼接——日语的数量词和语序跟中文不同。顺带清理一下已经标 `stale` 的 `review.busiest.day_%lld`（已被 `review.busiest.oneline_%@_%lld` 取代）。

---

## 关键文件清单

**新增**

```
Store/TaskEventModels.swift                      TaskEvent @Model
Store/TaskEventRecorder.swift                    埋点写入器
Protocols/Domain/TaskEventKind.swift             事件类型/来源枚举
Protocols/Domain/Insights/InsightEngine.swift    引擎骨架 + 排序 + 强度 + 降级阶梯
Protocols/Domain/Insights/InsightContext.swift   规则的共享输入 DTO
Protocols/Domain/Insights/Rules/*.swift          v1 两条规则各一个文件（拍板 2）
Protocols/ReviewSessionStore.swift               复盘会话持久化
UI/Review/RecapComponents.swift                  从 ReviewView 抽出的成绩单组件
UI/Review/Flow/*.swift                           五步流程（见阶段 3 表格）
VoiceTodoTests/Protocols/Insights/*Tests.swift   验收用例
```

**修改**

```
Store/SwiftDataModels.swift          TodoItem +abandonedAt +parentTodoId；VoiceTodoSchema 注册 TaskEvent
Store/TodoStore.swift                updateFull 埋点（deferred）；新增 abandon/unabandon（拍板 3：不含 created/completed）
Store/TodoQueryActor.swift           新增 insightContext(from:to:)
Protocols/Models.swift               TodoItemData 同步两个新字段
Protocols/TodoStoreProtocol.swift    新增 TodoAbandonWriting 协议 + 组合进角色协议
UI/Review/ReviewView.swift           顶部入口卡；成分抽到 RecapComponents
Resources/Localizable.xcstrings      新文案
VoiceTodo.xcodeproj/project.pbxproj  注册新文件
```

---

## 验证

### 单测

`Protocols/` 纯逻辑可 `swift test` 单跑；Swift 全量需 Xcode 26。按规格文档 §5 的验收用例建夹具，每条洞察至少三个 case。**v1 只建 02/03/排序/冷却/降级的用例（拍板 2）；01/04/05/06 的用例保留作规格参考，各自规则启用时再建**：

```
02-A 触发：3 条推迟 ≥3 次 → 列表按推迟次数降序
02-B 触发：1 条 25 天前创建、0 次推迟 → 命中 age 分支
02-C 不计入：origin=review 的 4 次推迟 → 不触发
03-A 救火 ratio 0.62 n=42 / 03-B 正向 ratio 0.18 n=30 / 03-C 不触发 ratio 0.40
排序-A：全部触发 → score 降序，n < 1.5×minSample 强制 lowData
冷却-A：上次展示过、效应量变化 8% → 不展示
冷却-B：同上但用户存了规则 → 展示，用回访文案
降级-A：完成记录 3 条 → 第 3 步整步跳过

—— 以下为后续启用时的规格参考（v1 不建）——
01-A 触发：重要 10 条中位 7.1 天，普通 22 条中位 0.5 天 → high
01-B 不触发（比值够但绝对差不够）：重要 0.4 天，普通 0.1 天
01-C 不触发（样本不足）：重要 5 条
04-A 差距 0.68 触发 / 04-B 差距 0.30 不触发 / 04-C 只有 1 类 n≥6 不触发
05-A 峰值 9–11、重要中位 22 点 → 错位 12h / 05-C 仅 18 条带时间戳 → 占位行
06-A 5 周数据 0.79 vs 0.33 触发 / 06-B 仅 3 完整周不触发 / 06-C 周日桶 n=3 → 排除后重算
```

补上一直缺的 `ReviewAggregatorTests`（分类占比 / streak / 区间边界 / 空区间 / union 去重）——`docs/moat-plan-personalization-and-review.md` 的 B1 当初就要求了，实施时漏了。

`DayClock` 相关：把 `startHour = 3` 的场景加进洞察测试，确认 23:50 和 01:30 完成的任务落在同一个用户日（参考 `VoiceTodoTests/Protocols/DayStartHourBoundaryTests.swift` 的既有写法）。

### 真机手测（Xcode 26，iOS 26）

1. **迁移安全**：拿**有真实数据的旧库**升级安装，确认 App 和 Widget 都能打开（这是 `TaskEvent` + 两个新字段最大的风险点，空模拟器测不出来）。
2. **埋点**：详情页改日期往后 → 记 deferred；往前改 → 不记；「移到明天」→ 记；复盘里排进下周 → 记但 `origin=review`，且不进推迟计数。
3. **卡片堆**：左右滑、两个按钮、撤销、拆小后子任务带 `parentTodoId`、划掉的任务从首页消失但仍在完成率分母里。
4. **降级路径**（新用户最容易撞上，重点测）：清库 → 完成 3 条 → 第 3 步整步跳过；完成 8 条 → 只出洞察 02 + 「再记 N 条」；完成 20 条 → 02+03 齐跑。
5. **跨期**：连做两次复盘，第二次能看到「上次复盘你说过」和规则回访。
6. **本地化**：中/英/日三语各走一遍五步，确认参数化文案不串位、长月份名不挤爆标题行。

---

## 三个明确的取舍

1. **推迟数据前几周是空的。** 洞察 02 冷启动只能靠「躺了 21 天」这一条分支，卡片上那排斜杠也没得画。这是选「不回填推断」的必然代价——好处是数字永远对得上，用户查得到每一次推迟是什么时候发生的。
2. **洞察 01 和 05 押在 `Priority.high` 上。** 如果用户根本不标优先级，这两条会长期不触发。阶段 0 的体检就是为了尽早发现这件事，而不是等实现完了才知道。
3. **规律任务被排除在六条洞察之外。** 规格文档没处理这个，但 `TodoOccurrenceCompletion` 缺 per-occurrence 的 `createdAt`，洞察 01/03 在它上面算不出来。第 1 步的成绩单仍然把两者 union（保持现状不变），只有第 3 步的观察层排除。样本量文案要写明这一点，否则用户会发现第 1 步和第 3 步的条数对不上。

---

## 不在本计划

- 服务端复盘 / 云端洞察模型（坚持本地优先，六条规则全部本地计算，不需要服务端、不需要 LLM）。
- 历史推迟次数的推断回填（见取舍 1）。
- 复盘成绩的分享卡片（`moat-plan` 的 B4，仍标「可选 / later」）。
- 规则的实际生效逻辑（阶段 5，先验证用户会不会点）。

---

## 实施落地记录（2026-08-21）

v1（阶段 0–4）在分支 `fupan` 实施，commit 链：`46b439e`(阶段 0)→ `c3fbd08`(阶段 1)→ `8547df4`(阶段 2)→ `d282954`(阶段 3)→ `5b3311e`(阶段 4)。每个阶段实施后经 dual-review-loop（Three Check + code-review-expert 交替）审查至收敛（0–2 轮不等），测试基线 `arch -arm64 swift test` 279 例唯一失败为既有 DST 红灯（与本功能无关），新增单测合计 84 例（8+17+19+17+6+26 中的去重口径见各 commit），全 target BUILD SUCCEEDED。

### 实施时的偏离决策

- **阶段 0**：`TodoDiagnosticsReading` 协议无法包 `#if DEBUG`（Swift 协议继承列表不支持条件编译），DEBUG 裁剪落在 UI 层，Release 下留一个无调用方的读取方法。
- **阶段 1**：`updateFull` 的 `origin` 因「协议成员不能带默认参数」改为三参签名 + 协议扩展便捷入口（默认 `.app`）；`TaskEventType.tolerant` 对未知值返回 nil 而非兜底（无合理默认事件类型）。`pendingItems` 有意不过滤 `abandonedAt`（永不丢话原则）。
- **阶段 2**：规格文档不在库内，阈值从本文档验收用例夹逼（03：触发 ≥0.50、正向 ≤0.20、minSample 15；02：推迟 ≥3 或躺 ≥21 用户日、minSample 3 只影响 confidence 不挡触发）；`InsightRule.evaluate` 增 `calendar` 参数（测试需固定日历）；`InsightResult` 增 `tone/effectSize/sampleCount`（冷却与好转文案需要）。
- **阶段 3**：入口卡放在空态分支之上（新用户也能进卡片堆）；第 4 步候选池空时闸门放行（强迫排 3 件违背复盘自愿原则）；语音提问经核实**不耗 AI 额度**（转写走本地 SFSpeechRecognizer，Quota 只计代理提取），但 `VoiceInputProtocol` 与首页录音状态机耦合、注入不干净，v1 纯文字 TextEditor，麦克风待注入解耦后加；置顶 = `ReviewPinningStore`（App Group UserDefaults + HomeView 读排序浮顶，不动 `sortOrder`）；本地化 +51 键（⚠️ 审查过程中一次 checkout 事故后按代码引用重建，三语齐全格式校验过，**文案措辞建议人工过目 zh/ja**）。
- **阶段 4**：`ReviewLedger` 在文档四项外补 inputCount/todayCount/scheduledCount/savedRuleCount（账本卡渲染需要）；下次复盘日期保持「下周一」就地渲染未另存字段；规则回访只打扰上次仍 pending 的规则。

### 实施后拍板变更（2026-08-22，用户裁决）

1. **规则回访整体移除**：`ReviewRuleStatus` 状态机、`RuleOutcome`、`ReviewSession.followUps`、`recordRuleOutcomes`、第 4 步回访卡全部删除——v1 里回访答案只存档不驱动任何下游行为（用户原话「只是存档的话完全可以先不要」）。冷却的「上次存了规则」放行条件随之删除，冷却剩两个放行条件（≥3 次复盘 / 效应量变化 ≥15%）。
2. **「存成规则」链路整体移除**：`ReviewRule` 结构、洞察卡规则按钮、第 4 步规则卡、账本「存下规则」行（`ReviewLedger.savedRuleCount`）、`ReviewSession.savedRules` 全部删除——回访砍掉后规则只剩当次展示+计数，无任何下游消费者。旧会话 payload 的 `savedRules`/`followUps`/`status`/`savedRuleCount` 键解码时忽略（前向兼容有单测）。
3. **第 4 步闸门放宽为至少选 1 件**：不再强制选满 min(3, N)——强制凑满 3 件会把「只想清卡堆」的用户卡在半路，养复盘习惯比单次产出更重要。文案仍鼓励选满 3（`review.flow.commit.hint`）。空池放行不变。
4. 同日新增（另一 commit，`a7edfa8`）：成绩单 Hero「其中 N 件是当天记下、当天做完的」（`sameDayCount`）+ 入口卡「回顾近 30 天」口径点明（周/月切换器只管统计页，复盘固定近一个月）。
5. **第 2 步滑卡交互改版落地**（对标用户 swipe HTML 的三通道形态）：拖动 stamp 印章（24→85pt 渐显，静止 opacity 0）/ 底部按钮 pad（✕不做了·左、今天就做·拆小·中、→排下周·右，位置即方向）/ 长按 0.5s confirmationDialog 全动作菜单 / 首卡 nudge 教学（每会话一次）/ 拖拽微旋转 + 方向性飞出 / 卡面升级（分类标签+记下日、推迟时间轴、rawTranscript 引号原文——无假波形）/「N / M」计数器 / 双层 ghost 卡。文案「划掉」→「不做了」（含账本行）。阈值不变（85pt 或 800pt/s）。第 1 步维持快扫口径（Hero+统计+分类），每日趋势/最忙一天只在统计页——demo 曾一度带入第 1 步，同日拍板退回。

### 拍板变更(2026-08-25,实际复盘对照)

对照用户实际复盘习惯(每周固定一次 / 数据→处理→方向动线 / 下周重点=存量延续 / 规律发现=固定几问)逐分支盘问:五步骨架全部成立不动;确认四个差别,轻修两个、两个留 backlog:

1. **上次定的重点回看(落地)**:plan-do-review 闭环补齐——上次置顶未完成的,第 2 步卡头带「上次重点」pin chip(不做浮顶重排,已否);第 1 步口径行下加结局行「上次定的重点:N 件完成、M 件待处理」。数据源 = `ReviewPinningStore` 流程启动快照(`setPinned` 整体覆写 → 新会话启动时集合恰好是上次的),零新存储;结局从原始快照计数(deck 数不出已完成的那部分),已删 id 两边都不计。
2. **「问问自己」领域提示轮换(落地)**:承接实际复盘「心里过一遍分领域进度」的口问习惯——标题下加提示行,只在快照出现过的分类里按历史会话数取模轮换(否掉固定 7 分类全轮换、否掉数据驱动最弱分类)。
3. **排期盲排(backlog)**:第 2/4 步看不见日历上已有的下周承诺,会撞车——涉及日历读权限,pre-GTM 不做。
4. **清单外时间盲区(backlog)**:实际复盘素材三路(任务/日历/领域),日历路(会议、杂事、救火)完全缺位,同上推迟。

### 持续注意事项

**xcodegen 会静默删 scheme 的 TestAction `StoreKitConfigurationFileReference`**（2.45.3 生成不出 `test.storeKitConfiguration`，该引用是手工配置）：每次 `xcodegen generate` 后必须 `git checkout -- VoiceTodo.xcodeproj/xcshareddata/xcschemes/VoiceTodo.xcscheme` 恢复，绝不提交其删除。

### 待真机手测清单（模拟器测不了/未测）

1. **迁移安全**：有真实数据的旧库升级安装，App + Widget 均能打开（TaskEvent 建表 + 两字段 + 索引轻量迁移）。
2. **埋点**：详情页改日期往后记 deferred / 往前不记；「移到明天」记；划掉任务从首页/Widget/Siri 消失但仍在完成率分母；abandon→撤销往返。
3. **卡片堆**：左右滑（位移 85pt 或速度 800pt/s 任一）、今天就做、拆小 sheet（子任务带 parentTodoId）、撤销只回划掉、腐烂卡深链跳回第 2 步。
4. **降级路径**：清库 → 完成 3 条 → 第 3 步跳过；8 条 → 只有腐烂；20 条 → 两条齐跑。
5. **跨期**：连做两次复盘，「上次你说过」出现/消失；入口卡日期出现。
6. **置顶**：置顶任务在首/日历两 tab 浮顶。
7. **三语走查**：中/英/日（含 AX5 大字号）过五步，对照卡与账本长文本不挤爆。
8. **数据体检**：设置 → DEBUG「运行数据体检」，Console.app 过滤 subsystem `com.qingqingyu.voicetodo` 看 `diagnostics.result`，判据 highCompleted < 8 则 01/05 搁置。
