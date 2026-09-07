# 复盘入口卡范围标与流程窗口失配 —— review 意见

> 状态：**已核实 / 已实施**（2026-09-07，逐条复验全部成立，见文末「核实记录」）。文档创建于 2026-09-06。
> 基线：`797eae2`（`main`）。
> 性质：这是一份 **review 意见**，不是已拍板方案。下述「已核实事实」请核实人逐条复验后再动手；
> 「判断与建议」部分可以推翻，推翻时请在文末「核实记录」写明理由。
> ⚠️ **本次 review 未编译、未跑测试**——审阅环境无 Swift 工具链（`swift: command not found`），
> 全部结论来自静态阅读。凡涉及运行时行为的，请以真机/模拟器为准。
> 相关文件：`UI/Review/ReviewView.swift`、`UI/Review/Flow/ReviewStepRecap.swift`、
> `UI/Review/RecapComponents.swift`、`Protocols/ReviewSessionStore.swift`。
> 前置文档：`docs/review-window-tab-decoupling.md`（本次 review 的对象）、`docs/todo-review-flow-v3.md`（v3）。

---

## 一句话

统计页入口卡上写着「近 30 天」，点进去复盘第 1 步却是「上次复盘以来」（首次复盘是「近 7 天」）——**承诺和违背之间只隔一次点击**。

---

## 已核实事实（请逐条复验）

### F1. 入口卡的范围标是硬编码的「近 30 天」

`UI/Review/ReviewView.swift:192`：

```swift
Text(String(localized: "review.window.last30d"))
```

`review.window.last30d` 三语值：zh `近 30 天` / en `Last 30 days` / ja `過去 30 日間`。

复验：`grep -n "review.window.last30d" UI/Review/ReviewView.swift` → 应得两处（`:192` 入口卡、`:260` 统计页 Hero 标签）。

### F2. 复盘流程第 1 步的窗口不是 30 天

`UI/Review/Flow/ReviewStepRecap.swift:33` 调的是 `RecapSummaryBuilder.weekSummary(since: lastReviewDate, ...)`，不是 `monthSummary`。

`weekSummary`（`RecapComponents.swift:495`）的窗口：

```swift
let sinceDay = since.map { DayClock.startOfUserDay(for: $0, calendar: calendar) }
    ?? (calendar.date(byAdding: .day, value: -7, to: todayStart) ?? todayStart)
```

即：**上次复盘至今；首次复盘回落近 7 天**。

同文件 `:30-32` 的注释明写这是 v3 拍板 1 的有意决定：

> v3 拍板 1：窗口 = 上次复盘至今（与每周一的提醒节奏对齐；首次复盘回落近 7 天）。回顾页/统计页仍走 `monthSummary`（滚动 30 天），**两窗有意不同**——复盘回答「这一段做了什么」，统计页看长趋势。

### F3. 第 1 步显示的范围文案与入口卡不一致

`ReviewStepRecap.swift:72-73`：

```swift
lastReviewDate != nil ? "review.flow.recap.scope_since" : "review.flow.recap.scope_first"
```

三语值：

| key | zh-Hans | en | ja |
|---|---|---|---|
| `review.flow.recap.scope_since` | 上次复盘以来 | Since your last review | 前回のふりかえりから |
| `review.flow.recap.scope_first` | 回顾近 7 天 | The last 7 days | 過去 7 日間をふりかえる |

第 1 步 Hero 的周期标签另由 `weekSummary` 内部生成（`RecapComponents.swift:508`），是「8月28日–9月6日」式的显式日期区间。

### F4. 入口卡上那个数字本身也不是 30 天口径

`ReviewView.swift:165-167`：

```swift
let pendingCount = allTodos.filter { item in
    !item.isCompleted && item.abandonedAt == nil && item.recurrenceRule == nil
}.count
```

**没有任何日期过滤**——是全量未完成一次性任务数。所以「近 30 天」这个标既不描述它正上方的数字，也不描述它点开后的窗口。

### F5. 这是两次独立改动之间的接缝，不是谁疏忽

时间线（`git log --oneline` 可复验）：

| commit | 内容 |
|---|---|
| `d8f9c33` | 统计页窗口割裂修复落地。**此时流程窗口 = 30 天，入口卡标签正确** |
| `9c5fac9` | v3 批次 4：流程第 1 步窗口改为「上次复盘至今」 |

`9c5fac9` **确实改过 `ReviewView.swift`**，但只动了 `periodSummary` 的字段接线（`:303-322`，补 `oneOffCompletionCount`），**没有碰入口卡**。而且它的 commit message 明确声明范围：

> Impact：复盘第 1 步任意时刻只出现一个时间口径……**回顾页/统计页路径零变化（monthSummary 未动）**

也就是说：v3 批次 4 有意把统计页排除在改动范围外，在它自己的范围内做得是对的；`d8f9c33` 在它落地那一刻也是对的。**问题出在两个范围的交界处——入口卡属于统计页，但它描述的是流程。** 双方都没错，缝在中间。

顺带一提，`9c5fac9` 的 commit message 说它修的是「屏三个时间窗口并列（文案 30 天 / 聚合滚动 30 天 / 提醒节奏每周一）」——**和本 review 是同一类问题**，只是它修的是第 1 步屏内，本 review 指的是往前一屏的残留。

`ReviewView.swift:189-191` 的注释仍写着该标的用途是：

> 范围标（2026-09-04 拍板 B1）：**点进流程前就锚定窗口口径**——割裂感发生在点之前。

用途声明的是「锚定流程的窗口」，而它现在锚的是统计页的窗口。

---

## 判断与建议（可推翻）

### J1. v3 让两窗分叉，这个决定本身没问题

统计页看长趋势（滚动 30 天）、复盘回答「这一段做了什么」（上次复盘至今），两者服务不同目的，分开是对的。**不要为了消除失配去回退 v3 拍板 1。**

### J2. 错的是入口卡，因为它是复盘的入口

入口卡是**启动复盘流程的按钮**。它上面的范围标该跟着**流程**走，不该跟着它所在的**页面**走。

### J3. 这重新制造了本来要修的那个问题

`docs/review-window-tab-decoupling.md` 要解决的原始诉求是「统计页显示的范围 ≠ 复盘实际的范围」。现在这个失配没有消失，只是**从「tab vs 复盘」搬到了「入口卡 vs 复盘第一屏」**，而且距离更近、更容易被用户抓到。

### J4. F4 那一重错是原方案规格的锅

`review-window-tab-decoupling.md` 的 B1 只说了「加一个范围标」，没写清**这个标修饰的是什么**（是上方的数字？还是点开后的窗口？）。实现者按注释理解成后者，是合理的。修的时候顺带把语义定死。

---

## 建议改法

### 推荐：入口卡范围标与第 1 步同源

`ReviewView.swift:192` 改为与 `ReviewStepRecap.swift:72-73` 相同的三元判断：

```swift
Text(String(localized: lastReviewDate != nil
    ? "review.flow.recap.scope_since"     // 上次复盘以来
    : "review.flow.recap.scope_first"))   // 回顾近 7 天
```

**数据通路已存在，无需新增**：

- `ReviewView.loadReviewNotes()`（`:412-413`）已经在调 `ReviewSessionStore.shared.allSessions()`。
- `allSessions()` 返回**升序**（`ReviewSessionStore.swift:196` 的 `sessions(since:)` 注释与 `ReviewFlowView.swift:155` 的 `previousSessions` 参数注释均写明升序），故 `.last` 是最近一次。
- 与流程侧同源：`ReviewFlowView.swift:815` 注入的正是 `state.previousSessions.last?.completedAt`。

建议做法：在 `ReviewView` 加一个 `@State private var lastReviewDate: Date?`，在 `loadReviewNotes()` 里与 `reviewNotes` 一起赋值（同一次 `allSessions()` 调用，不要调两遍）。

**i18n 零工作量**：`scope_since` / `scope_first` 两个键已存在且三语齐全。

**改完的副作用**：`review.window.last30d` 只剩 `:260` 一个消费者（统计页 Hero 标签）——那个用法是对的，**保留，不要删键**。

### 备选：删掉入口卡的范围标

v3 已给第 1 步加了自己的 scopeHeader，锚定的活它干了。但这样就丢了「点之前就知道范围」，B1 的初衷落空。**不推荐**，除非核实后认为入口卡两行文字在 AX5 大字号下确实挤不下。

---

## 不要做什么

1. **不要回退 v3 拍板 1**（把流程窗口改回 30 天）——两窗分叉是有意的（J1）。
2. **不要改统计页 Hero 的 `review.window.last30d`**（`:260`）——统计页确实是滚动 30 天，那里没错。
3. **不要删 `review.window.last30d` 键**——改完仍有一个消费者。
4. **不要把 `pendingCount` 改成 30 天口径**去迁就标签——「N 件事等你决定」就该是全量待办数，这与第 2 步卡堆输入（`ReviewFlowState.triageInput`）同口径，是 v1 拍板 4 定的，不要动。
5. **不要在 `loadReviewNotes()` 之外再调一次 `allSessions()`**——它读 App Group UserDefaults 并解 JSON，一次刷新调两遍是浪费。

---

## 需要一并更新的验收标准

`docs/review-window-tab-decoupling.md` 的验收标准 #4 与 #8 按字面**已经不成立**（v3 让两窗有意分叉后失效），照旧标准验收会把人绕回去。建议改成：

| 原 | 新 |
|---|---|
| #4 从统计页点入口卡进流程，第 1 步 Hero 数字与统计页 Hero 数字相同 | #4 统计页 Hero（滚动 30 天）与流程第 1 步 Hero（上次复盘至今）**窗口有意不同**；要求改为：**入口卡的范围标与流程第 1 步的范围文案一致** |
| #8 统计页 Hero 与流程第 1 步 Hero 的周期标签文案相同 | #8 删除（被新 #4 取代） |

补一条新验收：

- **#9**：首次复盘（无历史会话）时，入口卡范围标显示「回顾近 7 天」，与第 1 步一致；有历史会话时两处均显示「上次复盘以来」。

---

## 核实清单（给核实人）

请逐条确认后在「核实记录」打勾或写明分歧：

- [x] F1：`grep -n "review.window.last30d" UI/Review/ReviewView.swift` 得两处
- [x] F2：`ReviewStepRecap.swift:33` 确为 `weekSummary`，且 `RecapComponents.swift:495-506` 的回落是 7 天
- [x] F3：`ReviewStepRecap.swift:72-73` 的两个 key 与 xcstrings 中的三语值一致
- [x] F4：`ReviewView.swift:165-167` 的 `pendingCount` 确无日期过滤
- [x] F5：`git show 9c5fac9 -- UI/Review/ReviewView.swift` 确认只动 `periodSummary` 字段接线、未碰入口卡；且 `d8f9c33` 早于 `9c5fac9`
- [x] J1–J4：判断是否认同；不认同请写明
- [x] 数据通路：`allSessions()` 确为升序（`.last` 是最近一次）

## 验证（改完之后）

**单测**

- 新增：给入口卡范围标的选择逻辑加一个可测的纯函数（如 `ReviewEntryScope.label(lastReviewDate:)`），断言 nil → `scope_first`、非 nil → `scope_since`。
  ⚠️ 若不愿为此抽函数（与 `review-window-tab-decoupling.md` 护栏 4「不为测试抽缝」的精神一致），可跳过单测、只做真机走查，但请在核实记录里写明选择。
- 回归：现有 `ReviewRecapSameDayTests` 全绿。

**真机手测**

1. **首次复盘**（清空 `ReviewSessionStore`）：入口卡显示「回顾近 7 天」，点进第 1 步同样显示「回顾近 7 天」。
2. **有历史会话**：两处均显示「上次复盘以来」。
3. 做完一次复盘后返回统计页，入口卡范围标应立即从「回顾近 7 天」变成「上次复盘以来」（`loadReviewNotes()` 在 `onChange(of: showReviewFlow)` 已有刷新，`:135-137`）。
4. 三语走查（zh / en / ja，含 AX5 大字号）：入口卡两行文字不挤爆、不换到三行；`Since your last review` 是三语里最长的，重点看 en + AX5。

---

## 核实记录

**2026-09-07 核实**（核实环境：`fupan1` worktree，基线 `1d35db5` = `797eae2` + 本文档；核实含编译与回归测试）。

**逐条结论（F1–F5 / 数据通路全部属实，无分歧）：**

- **F1 ✅** 两处：`:192`（入口卡）与 `:260`（`fixedWindowSummary` 的 `periodLabel` 参数，喂统计页 Hero）。
- **F2 ✅** `ReviewStepRecap.swift:33` 为 `weekSummary(since: lastReviewDate, ...)`；`RecapComponents.swift:503-505` 回落 `todayStart − 7 天`。
- **F3 ✅** 三语值与 xcstrings 逐字一致（zh `上次复盘以来`/`回顾近 7 天`；en `Since your last review`/`The last 7 days`；ja `前回のふりかえりから`/`過去 7 日間をふりかえる`）。
- **F4 ✅** 过滤条件仅 `isCompleted`/`abandonedAt`/`recurrenceRule`，无任何日期谓词。
- **F5 ✅** `git merge-base --is-ancestor d8f9c33 9c5fac9` 通过；`9c5fac9` 对 `ReviewView.swift` 的 diff 仅 6+/1−，全部在 `periodSummary` 内补 `oneOffCompletionCount` 接线，未碰入口卡。
- **数据通路 ✅** `ReviewSessionStore.load(from:)`（`:260`）显式 `.sorted { $0.completedAt < $1.completedAt }`（升序）；`ReviewFlowView.swift:815` 注入的正是 `state.previousSessions.last?.completedAt`。

**J1–J4 全部认同。** J2 的直接证据：F1 处代码注释自述用途「点进流程前就锚定窗口口径」——用途声明的是**流程**，锚的却是**统计页**窗口，与自身注释矛盾。

**最终改法：按「推荐」方案实施。**

- `ReviewView` 新增 `@State private var lastReviewDate: Date?`；
- `loadReviewNotes()` 改为取一次 `let sessions = allSessions()`，`reviewNotes` 与 `lastReviewDate` 同源赋值（遵守「不要调两遍」）；
- 入口卡范围标改三元 `lastReviewDate != nil ? scope_since : scope_first`，注释改写锚定对象为流程窗口并注明与第 1 步同源；
- 未动：统计页 Hero（`fixedWindowSummary`）、`pendingCount` 口径、`review.window.last30d` 键——改后 grep 确认该键仅剩 `fixedWindowSummary` 一个消费者。

**单测选择：跳过 `ReviewEntryScope.label` 纯函数抽缝，不新增单测。** 理由：该三元与 `ReviewStepRecap.scopeHeader` 的既有内联三元同形，只给入口卡一侧抽缝防不了两处漂移（流程侧仍是内联），同源靠「键一致 + 注释互指」在构造上保证——与 `review-window-tab-decoupling.md` 「不为测试抽缝」的既有拍板一致。回归：`ReviewRecapSameDayTests` + `HomeCalendarStateGroupingTests` 全绿（xcodebuild，iPhone 17 Pro / iOS 26.5）。

**超出原 review 的一点补充：** 验收标准失效清单不止 #4/#8——**#2（「入口卡上可见『近 30 天』范围标」）按字面同样失效**，本次改法直接替换了那行字。已在 `review-window-tab-decoupling.md` 一并修订（#2/#4 改口径、#8 删除、新增 #9，修订记录 2026-09-07 条）。

**实施 commit：**代码 `8747e64`（fix(review): 入口卡范围标改与流程第 1 步同源——上次复盘以来/回顾近 7 天）；文档与本记录随后同批提交。

**真机手测 4 项（首次复盘 / 有历史 / 收尾后切换 / 三语 AX5）待做。**
