# 复盘流程 v2 —— 改版方案

> 状态：**已实施**（2026-09-02，fupan `6be3d96`…`73e2f62`，见文末「实施补注」）。
> 文档创建于 2026-09-01；基线 `22236f7`（`main`）。v1 见 `docs/todo-review-flow-design.md`（状态：已实施）。
> 环境提示：Swift 需在 **Xcode 26** 编译验证（iOS 26 部署目标）；`Protocols/` 纯逻辑可 `swift test` 单跑。
> 相关文件：`UI/Review/Flow/ReviewFlowView.swift`、`ReviewStepTriage.swift`、`ReviewStepCommit.swift`、
> `ReviewStepLedger.swift`、`ReviewStepInsights.swift`、`UI/Review/RecapComponents.swift`、
> `UI/Home/HomeCalendarState.swift`、`Protocols/ReviewSessionStore.swift`、
> `Protocols/Domain/Insights/TriageRanking.swift`（新增）。

## Context

v1（五步复盘流程）上线后做了一次真机走查，结论是流程在**真实数据下会塌**。走查条件：英文环境 + 35 条积压待办 + 事件表冷启动（无推迟历史）。这三条同时成立时，五屏里有四屏是坏的。

走查稿引用的界面文案已逐条在代码里核对，**全部属实**：

| 走查引用 | 代码 key | 位置 |
|---|---|---|
| `Record 7 more to see your work habits` | `review.flow.insights.ladder_hint_%lld` | 第 3 步降级阶梯 |
| `Nothing scheduled for next week yet` | `review.flow.commit.empty` | 第 4 步空候选池 |
| `35 tasks → 35 remaining` | `review.flow.ledger.summary_%lld_%lld` | 第 5 步账本 |
| `Never deferred` | `review.flow.triage.tl_nodefer` | 第 2 步推迟时间轴 |

### 根因：一件事，不是五件

`ReviewFlowView.swift:150`：

```swift
static func triageInput(from todos: [TodoItemData]) -> [TodoItemData] {
    todos.filter { !$0.isCompleted && $0.abandonedAt == nil && $0.recurrenceRule == nil }
}
```

**没有排序，没有截断。** 35 条积压就是 35 张卡，顺序是 `store.todos` 的原始序（`sortOrder`）——最该被决定的那几张甚至不在前面。用户在第 8 张退出时，看到的是最无聊的 8 张。

顺下去整条链就通了：第 2 步没人做完 → `state.scheduled` 空 → 第 4 步必然撞空池（`ReviewStepCommit.emptyPool`）→ 第 5 步 `inputCount == remainingCount` 且五行全 0。**第 4、5 步的难看不是它们自己的问题，是第 2 步的下游症状。**

所以 v1 的真正缺陷是：**降级阶梯只做在了洞察层，没做在流程层。** v1 §2.3 花大篇幅设计了「完成记录 <5 / 5–14 / 15–24 / ≥25」四档降级，却默认「待处理任务」这一路总是健康的——对新用户是 0 条，对真实用户是 35 条，两头都没设计。

---

## 拍板决定（2026-09-01）

| # | 决定 | 选择 | 理由 |
|---|---|---|---|
| 1 | 第 2 步卡堆规模 | **排序后取前 8**，尾部给批量出口 | 周复盘应 3 分钟结束；35 次逐张决策是苦役 |
| 2 | 排序主键 | **推迟次数 desc → 停滞天数 desc**（字典序，非乘积） | 事件表冷启动时推迟次数恒 0，乘积会全为 0；字典序自动退化成纯按停滞天数排，数据长出来后主键平滑接管 |
| 3 | 批量出口的落点 | **复用「稍后」**（清 `dueDate` + `timeBucket` + `dueHint`），不新增 `somedayAt` 终态 | 零新字段、零迁移；「稍后」本就是「知道要做但没排期」的抽屉，语义吻合 |
| 4 | 账本主角 | **「你决定了 N 件」**，批量推后单独一行 | 逐张决定的 28 件 ≠ 一键扫掉的 28 件，不能用同一句话庆祝 |
| 5 | 第 1 步 streak | **删除** | v1 §2.5 反 gaming 本就写了「不做连续复盘 streak 奖励」，这张卡是从旧回顾页继承的漏网项 |
| 6 | 第 3 步占位行 | **合并成一行**，不再逐条 `ForEach` 堆叠 | 刺眼的是四行「再记 N 条」的堆叠，不是单条文案 |

---

## 逐屏改版

### 第 1 步 · 从数字墙改成判词

**现状**：`ReviewStepRecap` → `RecapHeroSection`（总数 40pt + 周期标签 + sameDay 小字 13pt）+ `RecapStatsRow`（streak 卡 + 完成卡）+ `RecapCategoryChartSection`。

**改**：

- **sameDay 升为判词主体**。`review.hero.sameday_%lld`（「其中 %lld 件是当天记下、当天做完的」）文案已在，只是被压成 13pt 副行。它是全屏唯一一句「只有你的数据能说出来的人话」，应该和总数同级。
- **删 streak 卡**（拍板 5）。`RecapStatsRow` 退化成单卡时直接换成一行文字，不要留一个孤零零的卡片。
- **删第 1 步的分类横条**。分类计数是描述不是判断；同一份数据在第 3 步做**滞留时长对比**才有判断力。回顾页（`ReviewView`）保留分类图不动——那里就是给人随手看描述的。
- **补「新增」数**：窗口内 `createdAt` 落在区间的任务数。「完成 9 / 新增 12 / 还挂着 35」三个数并排，本身就是判词的证据链——清单在变长，不是变短。

⚠️ `RecapCategoryChartSection` 只从第 1 步移除，**不要删组件**，`ReviewView` 仍在用。

### 第 2 步 · 8 张，不是 35 张

**现状**：`triageInput` 全量无序（见上）。卡上已有推迟时间轴（`ReviewStepTriage.timeline`，`:406`），冷启动显示「还没推迟过」。

**改**：

1. **排序**（拍板 2）。`triageInput` 之后接一个纯函数排序，主键 `deferCount` 降序、次键停滞天数（`now - createdAt`）降序：

   ```swift
   // Protocols/Domain/Insights/TriageRanking.swift（新增，纯函数可单测）
   static func rank(_ todos: [TodoItemData], deferCounts: [UUID: Int], now: Date) -> [TodoItemData]
   ```

   `deferCounts` 已有现成来源：`state.insightContextValue?.deferCounts`（`ReviewStepTriage.swift:407` 已在用）。⚠️ **注意时序**：`insightContext` 是异步载入的，而 deck 在 `ReviewFlowState.init` 就构造好了。排序必须在 context 到位后重排，或者把 deck 构造推迟到 context 就绪——否则冷启动那一帧排出来的是错的。

2. **截断到前 8**。剩余的不进卡堆。

3. **批量出口**：只覆盖剩余里**停滞 ≥ 30 天**的那部分，文案写明条数（「另外 27 件超过 30 天没碰过」）。剩余里不满 30 天的**既不进卡堆也不进批量出口**，原样留着——这一点必须在 UI 上说清楚，否则用户会以为「其他都被处理了」。

4. **卡面主线索改成停滞天数**。走查稿说「已推迟 4 次是全 App 最有洞见的数据，别藏」——方向对，但**现在这个数据不存在**：事件表 2026-08-21 才建，且拍板了不回填历史（见 v1 文档「三个取舍」第 1 条），老任务恒为 0。所以卡面头条现在应该是「记下 N 天了」（`createdAt` 立即可算），推迟次数攒够了再自动顶上来。时间轴组件不动，只调头条优先级。

### 第 3 步 · 一个发现，且能当场处理

**现状**：`ReviewStepInsights` 用 `ForEach(placeholders)` 逐条渲染未达标洞察的「再记 N 条」，四条不达标就是四行。

**改**：

- **占位行合并成一行**（拍板 6），或数据太少时整块不出。用户是来复盘的，开屏告诉他「你还没资格看」是最差的开场。
- **数据不够时显示当下能算出的最小事实**，而不是锁。例：「你目前只有 2 周记录，先说说这周」。
- **洞察卡带当场动作**。走查稿的两个例子：「工作类你要等 6.2 天才动手」（对比条）、「『去跑步』你连续 3 周推到下周 → 从清单删掉 / 排周三 19:00」。

  ⚠️ 这**看起来**像把 2026-08-22 移除的「存成规则」链路请回来了，其实不是：当时移除的理由是「规则只存档、不驱动任何下游行为」；这里是**对一个具体任务执行一个具体动作**，有下游行为。区别写在这里，避免下次回看以为自己出尔反尔。
- 「问问自己」的 `TextEditor`（`ReviewStepInsights.swift:308`）**移到第 5 步**，见下。

### 第 4 步 · 候选池不能只有刚才排的

**现状**：`ReviewStepCommit` 的池子就是 `state.scheduled`（第 2 步右滑的）。第 2 步被跳过 → 池空 → `emptyPool` 死路。

**改**：候选池 = `state.scheduled` ∪ **本来就排在下周的未完成任务**（`dueDate` 落在下周 且 `abandonedAt == nil` 且 `!isCompleted`）。走查稿「下周一共有 6 件排期任务，不选进来的不会消失」正是这个补法。这样第 2 步跳过时池子也不空，死路自然消失。

闸门维持 2026-08-22 拍板（至少选 1 件，池空放行）不变。

### 第 5 步 · 收尾是确认，不是审判

**现状**：`ReviewStepLedger.detailCard` **无条件渲染五行**（scheduled / today / abandoned / split / pinned），全 0 时就是五行 0。`summaryCard` 是「35 条变 35 条」。

**改**：

- **零值行不渲染**；全零时整张 `detailCard` 不出。
- **主角换成决定数**：「你决定了 N 件」（N = scheduled + today + abandoned + split）。批量推后的另起一行「另有 M 件推到以后」，**不合并计数**（拍板 4）。
- **决策明细降级成一行小字**（「今天做 2 · 拆小 1 · 下周 3 · 推后 27」）。
- **把「问问自己」输入框搬到这里**，且带具体承诺（「下次复盘会给你看」）。放中间没人填；放最后、且说清楚会被回看，才有填的理由。

---

## 批量出口的实现细节（拍板 3 落地）

「稍后」= `HomeCalendarState.unscheduledTodos`。命中条件（`HomeCalendarState.swift:168-180`）：

```
dueDate == nil && recurrenceRule == nil && !isCompleted && abandonedAt == nil
&& extractionOutcome == .parsed
&& timeBucket == nil && (dueHint ?? "").trimmed.isEmpty
```

**⚠️ 最大的坑：`hasTimeSignal` 根本不看 `dueDate`**，只看 `timeBucket` 和 `dueHint`。只清 `dueDate` 的任务会落进**「待定日期」**（`pendingDateTodos`）——那是另一个照样挂着「选日期」按钮催你决定的抽屉，批量出口等于白做。

所以每条要走 `updateFull`，三个字段一起清：

```swift
TodoDetailUpdate(
    title: todo.title, detail: todo.detail,
    category: nil, priority: nil,          // nil = 保留原值
    dueDate: nil,                          // nil = 清除日期
    hasDueTime: false,
    timeBucket: nil,                       // nil = 不保留模糊时段
    dueHint: "",                           // ⚠️ 空串 = 清除；nil = 保留原值
    recurrenceRule: todo.recurrenceRule
)
```

`dueHint` 的三态语义见 `Protocols/Models.swift:484`。传 `nil` 是最容易犯的错。

**两条已核实的良性副作用**：

1. **不会污染推迟计数**。`TaskEventRules.isDeferral`（`Protocols/Domain/TaskEventKind.swift:64`）有 `guard let oldDueDate, let newDueDate else { return false }`，新值 nil 直接返回 false。批量出口不记 `deferred`，符合语义（推后不是推迟）。
2. **不会影响完成率**。完成率已于 2026-08-23 全面下线（`grep completionRate UI/` 无命中，`RecapDoneCard` 已换成绝对数）。v1 拍板 1「划掉留在分母堵 gaming」当前没有落点，本次不受它约束。

**一条要处理的例外**：`triageInput` 不过滤 `extractionOutcome`，所以卡堆里可能有 `.rawFallback` / `.unparsed` 的条目。这些即使清了三个字段也会落进**「没能识别」**而不是「稍后」。批量出口应把它们排除在外（或单独提示），不要承诺一个做不到的落点。

**账本**：`ReviewLedger`（`Protocols/ReviewSessionStore.swift:16`）加 `somedayCount: Int`。它是 `Codable` 且已落盘，旧 payload 无此键——解码要给默认值 0，照现有「旧键忽略」的前向兼容范式加单测。

---

## 与既有拍板的关系

| v1 拍板 | 本次 | 说明 |
|---|---|---|
| 拍板 1（abandoned 留在完成率分母） | **暂时无落点** | 完成率已下线，约束悬空。若日后恢复完成率，需重新评估批量出口是否要进分母 |
| 拍板 4（规律任务排除在卡堆外） | **不变** | `triageInput` 的 `recurrenceRule == nil` 保留 |
| 拍板 7（撤销只覆盖「不做了」） | **需扩展** | 批量推后 27 条必须可整批撤销——一键操作没有 undo 是不可接受的。这是本次唯一对拍板 7 的松动 |
| 2026-08-22（移除「存成规则」） | **不冲突** | 第 3 步的当场动作是对具体任务执行具体动作，有下游行为；当初移除的是「只存档不驱动」的抽象规则 |
| 2026-08-22（第 4 步闸门放宽） | **不变** | 至少选 1 件、池空放行 |

---

## 落地顺序

1. **第 2 步排序 + 截断 + 批量出口**——最高价值，且一改就把第 4、5 步的空态问题连带解决大半。注意 `insightContext` 异步到位的时序问题。（✅ `6be3d96`）
2. **第 5 步零值行不渲染 + 主角换成决定数**——几行代码，立竿见影。（✅ `6be3d96`，与第 2 步经 `ReviewLedger.somedayCount` 耦合，同提交落地）
3. **第 4 步候选池补下周已排期任务**——解掉最后一条死路。（✅ `2fc55a6`）
4. **第 1 步删 streak、sameDay 提为判词、补「新增」数**——文案已在，主要是排版。（✅ `ac7a754`）
5. **第 3 步占位行合并 + 洞察卡当场动作**——动作部分工作量最大，放最后。（✅ `73e2f62`）

---

## 验证

**单测**

- `TriageRanking.rank`：全 0 推迟次数 → 退化为纯按停滞天数降序；有推迟数据 → 推迟次数优先；同推迟次数 → 停滞天数决胜；空数组、单条。
- 批量出口的字段组合：清三字段后 `HomeCalendarState` 把它归进 `unscheduledTodos`（用现有 `HomeCalendarStateGroupingTests` 的夹具）；只清 `dueDate` 时归进 `pendingDateTodos`（**这条是回归护栏，必须有**）。
- `TaskEventRules.isDeferral(old: 某日, new: nil, ...)` == false。
- `ReviewLedger` 解码旧 payload（无 `somedayCount` 键）→ 默认 0。
- 账本零值行：全 0 时 `detailCard` 不渲染。

**真机手测**

1. **35 条积压场景**（本次改版的原始场景）：进第 2 步只见 8 张、且最上面是停滞最久的；批量出口条数与文案一致；走完五步账本有真实数字，不是五行 0。
2. **批量出口落点**：点完后去首页确认 27 条在**「稍后」**抽屉，不在「待定日期」；带 `dueHint` 的任务也正确落位。
3. **整批撤销**：批量推后 → 撤销 → 27 条回到原 `dueDate`。
4. **冷启动场景**：清库、只完成 3 条 → 第 3 步不出一堆占位行；第 4 步池子非空（若下周有排期）。
5. **英文环境走查**：本次问题是在 en 下暴露的，三语都要过一遍，重点看第 5 步账本和第 3 步占位文案。

---

## 不在本方案

- 恢复完成率（下线是 2026-08-23 的独立决定，与本次无关）。
- 新增 `somedayAt` 终态（拍板 3 已选复用「稍后」）。
- 洞察 04/06 启用（仍待样本量）。
- 历史推迟次数回填（v1 取舍 1 不变）。

---

## 实施补注（2026-09-02）

实施前对方案做了一轮代码级审阅，五个缺口在实施中按下述口径处置（审阅结论：方案的事实断言全部核实无误，含 `hasTimeSignal` 不看 `dueDate` 的坑、`dueHint` 三态、`isDeferral` 双非 nil 守卫、时序问题等）：

**A · 共享组件边界（审阅补的最大缺口）**：`RecapHeroSection` / `RecapStatsRow` / `RecapCategoryChartSection` 三件都是回顾页与第 1 步共用的（`RecapComponents.swift` 头注释明写「别在两处复制」），原方案只对 CategoryChart 提了「不要删组件」。处置：**回顾页零变化**——Hero 加 `promotesSameDay` 参数（默认 false = 原 13pt 副行），第 1 步传 true；streak 卡只从流程里下岗，`RecapStatsRow` 原样留给回顾页（注释已标注）。

**B · 候选池并集去重**：右滑「排下周」是**即时写库**（`markScheduled` 注释），并集必须按 id 去重，否则刚排的任务双行。处置：第二路（`nextWeekCommitted`）排除 `processedIDs`，「今天就做 / 不做了 / 拆小」处理过的下周条目同步退出。规律任务按文档字面口径不排除——锚点在过去的自然不命中，锚点恰在下周的可被置顶（置顶按 id 对账，语义成立）。**闸门行为变化**：跳过第 2 步但下周本有排期的用户，现在必须选 1 件才能过第 4 步（之前无条件放行）——「候选池为空放行」的原拍板语义不变，池子定义修正了。

**C · 「下次复盘会给你看」的兑现位**：语义对照行原来在第 3 步，而冷启动（<5 完成记录）第 3 步整步被 `skipsInsights` 跳过——承诺会落空。处置：**历次笔记卡（含语义对照行）随「问问自己」一起迁到第 5 步**，回看上次→写下这次的动线也顺；2026-08-25 轻修④的领域提示轮换随输入框同迁（留在原处等于轻修④失效）。附带好处：冷启动用户第一次能见到输入框。

**D · 批量出口的周而复始（立场）**：推「稍后」的条目下周仍在 `triageInput`（dueDate==nil 不过滤）且按停滞天数排最前——同一批古董任务每周回来占卡堆前排，「每周一键再推」是合法 snooze。这是**刻意设计**：复盘持续施压直到真决定（排期 / 划掉 / 做掉），与反 gaming 章程相邻但不冲突（出口不清零任何数字，只是换抽屉）。若实测变成无脑每周扫，候选缓解：连续 N 次批量推后的条目在第 2 步卡堆置顶并给「该划掉了」提示——待真机走查后再议。

**E · `ReviewLedger` 兼容的失败半径**：加非可选 `somedayCount` 后，自动合成的 Codable 遇旧 payload 缺键是**抛错**而非默认 0，一条会话解码失败会拖垮整个 `allSessions()` 列表。已手写 `init(from:)`（`decodeIfPresent ?? 0`），单测覆盖新旧 payload 与编码往返。

**范围裁剪（洞察当场动作）**：「排周三 19:00」式的具体排期建议**不做**——洞察卡内嵌日期选择缺交互设计，先落「不做了」（走既有 abandon 写路径，覆盖卡堆与尾部，计入决定数）与「去看看」（既有跳转）；具体排期待后续单独立项。

**账本字段去留**：`inputCount` / `remainingCount` 保留原语义（deck 侧口径——`inputCount` = 逐张决定 + 仍留卡堆，截断后尾部不计入），不再渲染但继续落盘，避免一次无收益的迁移；「N / M」计数器随截断自动变成「n / 8」。

**i18n 增删**：新增 24 键（batch 出口 7、账本 9、承诺 1、分组 2、证据行 2、占位合并 1、最小事实 1、卡面天数 1），删除 9 个无引用键（旧账本主行+五行 6、ladder_hint 1、need_more_tasks 1、need_more_high 1），全部 zh/en/ja 三语。

**新增测试**：`TriageRankingTests`（5）、`ReviewFlowStateTests` v2 扩展（排序截断 / 重排不回流 / 批量候选门槛 / 执行撤销闭环 / decidedCount / 旧 payload 解码 / 候选池并集去重 / 闸门 / abandonFromInsight）、`HomeCalendarStateGroupingTests` 批量出口落点护栏（`dueHint` 空串路径）、`TaskEventKindTests` `isDeferral(new=nil)`、`ReviewRecapSameDayTests` 证据链三数。

**真机回归待办**（模拟器不可验的部分）：三语长文本走查（第 5 步账本一行小字、批量出口标题）、批量出口落点真机确认（27 条进「稍后」抽屉）、整批撤销、连续两周批量推后的体验（见 D）。

---

## 审阅修正（2026-09-03）

对实施代码的一轮静态审查发现四处缺陷，处置如下（1、2 经拍板）：

1. **周窗口落点（两处，含一处既有代码）**：`ReviewStepTriage.nextMondayStart()`（v2 之前就有）与 `ReviewFlowState.nextWeekCommitted`（v2 新增）都把 `calendar.nextDate` 返回的**自然日 0 点**喂给了 `startOfUserDay(for:)`——该函数接收时刻、问「属于哪个用户日」，0 点会被判回前一用户日（`DayClock` 注释明言这是 bug，见 docs/day-clock-day-boundary-inconsistencies.md 同类问题）。后果：`startHour > 0` 的用户「排下周」落到周日、候选窗左移一天；`startHour = 0` 短路走 `startOfDay` 从未暴露。两处改用 `userDayStart(onNaturalDay:)`（DayClock 为归一化日专门提供的入口）。**行为变更**：`startHour > 0` 用户「排下周」落点从周日用户日改回周一用户日——朝本方案「下一个周一的用户日起点」的既定语义修正；写库落点与候选窗必须同坐标系（缺口 B 的前提），两处一起改。
2. **批量出口部分失败补偿**：原实现 27 条逐条写库、`catch` 只报错——第 N 条失败时前 N-1 条已落库（`updateFull` 逐条 `saveOrRollback`）但 state 完全不动：出口行还在、计数为 0、无快照无撤销路径，「报错但已静默生效」。改为逐条累计成功子集，失败时对成功子集照常落地 state（快照可整批撤销），失败条目留尾部可重推（幂等保留），错误如实上报。
3. **`markSomedayBatchExecuted` 不再二次求值候选集**：改签名收 `batch` 参数——原实现视图写库用一份候选、state 落地时又独立求值一次（`somedayBatchCandidates` 依赖 `Date()`，30 天门槛跨阈值时两次求值错位，快照与落库不是同一批）。传参后严格同批，兼作 2 的接口。
4. **`inputCount` 口径注明例外**：洞察腐烂卡当场「不做了」的尾部条目走 `abandonFromInsight` → `markAbandoned`（进 `processedIDs`），照常计入 `inputCount`——用户确实面对并决定了它（拍板 4：决定数同理），若排除会出现 `decidedCount > inputCount` 的口径倒挂。原「截断后尾部不计入」的注释（含上方实施补注）就此打补丁，**行为不变，只修文档**。

新增测试：非零 `startHour` 的周窗落点（`testNextWeekCommittedWindowWithNonZeroStartHour`）、部分成功子集的执行/撤销闭环（`testSomedayBatchExecuteWithPartialBatch`）。
