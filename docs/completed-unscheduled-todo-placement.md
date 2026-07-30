# 无日期任务完成后应归档到哪一天

> 状态：**待实施**。含 bug 修复 + 两项设计决策记录。
> 落点文件：`UI/Home/HomeCalendarState.swift`
> 行号基准：`8813f07`（= 当前 `origin/main`）。

---

## 现象

无安排日期（`dueDate == nil && recurrenceRule == nil`）的任务被标记完成后，
**同时出现在每一天的「已完成」分区**——今天有、明天有、上个月的某天也有。

## 根因

`UI/Home/HomeCalendarState.swift:174-176`：

```swift
self.completedUnscheduledTodos = noSchedule
    .filter { $0.isCompleted }
    .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
```

**只按 `isCompleted` 筛选，完全没有与 `selectedDate` 做任何比对。**
该数组不随选中日期变化，因此在任何一天打开都会渲染同一批条目。

对照组行为正常：`completedOccurrences` 源自
`Self.occurrences(on: selectedDate, in: occurrencesByDay, calendar: calendar)`
（`HomeCalendarState.swift:180-183`），按选中日过滤过。两条路径的差别就在这里。

渲染侧：`UI/Home/HomeSelectedDayListView.swift:121-140` 把两者放进同一个
「已完成」分区，分区计数 `totalCount`（`:137`）也把未过滤的那批算了进去，
所以计数同样偏大。

---

## 设计决策 A：按 `completedAt` 归到「完成那天」

### 先厘清一个前提

**有日期的任务，「已完成」是按「计划日」归档的，不是按「完成日」。**
周一提前做完周三的任务，它仍显示在**周三**的已完成区。

无日期任务没有计划日，这套语义没法照搬，必须另择时间锚点。

### 结论

采用 `completedAt`，即归档到**用户实际完成它的那一天**。

理由：

1. **唯一有意义的锚点**：无日期任务唯一确定的时间事实就是「我在这天做完了它」
2. **契合分区的实际用途**：「已完成」区回答的是「我这天干了啥」，带回顾与成就感性质，
   无日期任务放进去语义自洽
3. **数据现成**：`completedAt` 字段已存在（`Protocols/Models.swift:462`，
   现有排序逻辑即在使用），勾选时由 `Store/TodoStore.swift:148` 写入，
   无需新增任何字段或迁移
4. **历史不断层**：次日回看今天，条目仍在正确的位置
5. **与回顾页同源**：`ReviewAggregator` 就是按 `completedAt` 把任务归到某一天的
   （`Protocols/Domain/ReviewAggregator.swift:81,110`），首页照做即两页口径统一

### 已否决的方案

| 方案 | 否决原因 |
|---|---|
| 完成后留在「未安排」区，仅做灰化下沉 | 条目会越堆越多；用户会觉得「做完了怎么还挂在这」；且与代码注释声明的原始意图（「让无安排任务的完成行为和有安排任务对齐」）相反 |
| 只在「今天」显示 | 次日即消失，等于抹掉历史记录，比现状更糟 |

### 需要承认的代价

修复后，同一个「已完成」分区内会混两种归档口径：
有日期的按**计划日**、无日期的按**完成日**。

严格说这不够纯粹。但判断为可接受——**用户不会感知到这个区别**：
对用户而言两类都是「这天相关的已完成事项」，混在一起读起来很自然。
为理论一致性牺牲实际体验不划算。

---

## 设计决策 B：用「用户日」而非自然日做比对

这条容易被漏掉，但漏了就是 bug。

项目支持用户自定义「一天起始时刻」（`Protocols/Domain/DayClock.swift`，
`startHour` 可设 0–23，设置项见 `4d49c44`）。`startHour = 3` 时，
凌晨 0:00–2:59 完成的任务在语义上仍属于**前一天**。

**必须走 `DayClock`**，理由：

- `DayClock` 自己的文档注释划定了适用范围——「只影响语义今天边界（首页 selectedDate、
  回顾聚合、Widget 可见区间等）」。首页「已完成」分区按完成时刻归档，正落在这个范围内。
- 回顾页已经这么做了（`ReviewAggregator.swift:81,110` 用
  `DayClock.startOfUserDay(for: event.completedAt)`）。首页若用自然日，
  `startHour = 3` 时凌晨 1 点勾掉的任务会出现在「回顾页算昨天、首页算今天」的分裂状态。
- `startHour = 0`（默认值）时 `DayClock` 行为完全等价于 `Calendar.startOfDay`，零回归。

### ⚠️ 一个必须避开的写法

**不要写 `DayClock.isSameUserDay(completedAt, selectedDate, calendar: calendar)`。**

`selectedDate` 在 `private init` 拿到时已被归一化成**自然日 0 点**
（`HomeCalendarState.swift:72` / `:97` 的 `calendar.startOfDay(for:)`）。
`startHour > 0` 时，把这个 0 点时刻再喂给 `startOfUserDay`，它会判定
「还没到今天的起始时刻」从而掉到**前一个用户日**——整个分区错位一天。

正确做法是**只折算 `completedAt` 一侧**，再拿折算结果的自然日与 `selectedDate` 比：

```swift
let completedDay = DayClock.startOfUserDay(for: completedAt, calendar: calendar)
return calendar.isDate(completedDay, inSameDayAs: selectedDate)
```

验算（`startHour = 3`）：`completedAt = 3/16 01:00` → `startOfUserDay` = `3/15 03:00`
→ 自然日 `3/15` → 归到 3 月 15 日 ✅。这与 `ReviewAggregator` 的分桶键完全同构。

---

## 修复落点

`UI/Home/HomeCalendarState.swift:174-176`，在 filter 中加入日期比对。
`selectedDate` 与 `calendar` 在该 `private init` 作用域内均可直接使用；
`DayClock` 在 `Protocols/Domain/` 下，App target 直接编译该目录源码，**无需 import**
（同目录下 `UI/Home/HomeView.swift` 已在直接调用）。

示意（非最终代码）：

```swift
self.completedUnscheduledTodos = noSchedule
    .filter { todo in
        guard todo.isCompleted, let completedAt = todo.completedAt else { return false }
        // 与 ReviewAggregator 同口径：先把完成时刻折算到「用户日」起点，
        // 再和选中的自然日比对。不可反过来折算 selectedDate——见「设计决策 B」。
        let completedDay = DayClock.startOfUserDay(for: completedAt, calendar: calendar)
        return calendar.isDate(completedDay, inSameDayAs: selectedDate)
    }
    .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
```

修好后 `HomeSelectedDayListView` 的分区计数会自动跟着正确，无需另改。

### 连带要改的单测（会挂，不是可选项）

`VoiceTodoTests/UI/HomeCalendarStateGroupingTests.swift:76`
`testCompletedRawFallbackGoesToCompletedSection` 断言一条已完成条目落进
`completedUnscheduledTodos`；但它的构造辅助 `makeTodo`（`:200-218`）**从不设置
`completedAt`**，加上 `guard let completedAt` 后该条目会被直接滤掉，断言必然失败。

改法：给 `makeTodo` 加一个 `completedAt: Date? = nil` 形参并透传给 `TodoItemData`
（该 init 已有同名参数），在这条用例里传选中日当天的时刻。
顺便可补两条新用例：完成于**其他日**的条目不进本日分区、`completedAt == nil` 的
已完成条目不进任何一日分区。

## 边界情况（必须处理）

1. **`completedAt == nil` 的已完成条目**
   `TodoStore.toggle` 每次都会写 `completedAt`（`Store/TodoStore.swift:148`），
   正常路径不会产生 nil；但 SwiftData 里该字段是 optional
   （`Store/SwiftDataModels.swift:30`），历史数据 / 外部导入仍可能为 nil。
   建议：**不显示在任何一天**（即上面示意代码里 `guard let` 直接返回 false），
   而不是兜底塞进今天——否则一批陈年任务会突然涌入今日列表。
   这与 Widget 侧既有惯例一致：`Protocols/Domain/WidgetTodoFilter.swift:44-47`
   对无日期已完成项同样是 `guard let completedAt … else { continue }`。

2. **取消完成（uncheck）**
   `isCompleted` 变回 false 后，条目应回到「未安排」/「待定日期」等未完成分区。
   按现有 filter 结构应天然成立（`TodoStore.swift:148` 同时把 `completedAt` 清回 nil），
   但需实测验证。

3. **在「非今天」的日期上勾选** ← 本次修复引入的新行为，需先接受
   三个未完成分区（`unscheduledTodos` / `pendingDateTodos` / `unparsedTodos`）
   本身是**不按日期过滤**的，任何一天都显示同一批 backlog。
   于是用户停在「上个月某天」勾掉一条无日期待办时，它会从（日期无关的）未完成分区
   跳进（只认今天的）已完成分区，表现为**当场从当前视图整个消失**，
   要切回今天才看得到。

   判断为可接受：无日期任务本就不属于任何一天，用户在过去某天勾它是低频操作，
   且「消失」的语义（从 backlog 里划掉了）并不难理解。
   若实测觉得突兀，备选是加一个短暂的「已完成」淡出动画再移除，而不是改归档口径。

## 验证

- 新建一个无日期任务 → 标记完成 → 确认**只出现在今天**的「已完成」分区
- 切到明天 / 昨天 / 上个月任意一天 → 确认该条目**不出现**
- 次日再打开 App 看「昨天」→ 确认条目仍在昨天的已完成区（历史不丢）
- 取消完成 → 确认回到未完成分区，且不再出现在任何一天的已完成区
- 「已完成」分区的计数徽章数字与实际条目数一致
- 老数据（`completedAt == nil` 的已完成无日期任务）不出现在任何一天
- **设置「一天起始时刻」= 3:00，凌晨 1 点勾掉一条无日期任务 → 确认它归到「昨天」，
  且与回顾页的归属一致**（这条是设计决策 B 的回归闸门）
- 停在「上个月某天」勾选一条无日期任务 → 确认行为符合边界情况 3 的预期，不是崩溃/闪烁

## 附带记录（不在本次修复范围）

`UI/Home/HomeView.swift` 的 `selectedDayStats()`（`:723-738`）基于 `monthOccurrences` 计算，
**不包含无日期任务**。因此顶部进度环（`n/m`）与「已完成」分区的计数口径本就不一致。
这是独立于本 bug 的既有问题，需要时另行处理。

另注：核实上面那条时，发现 `HomeView.selectedDate` 的归一化口径在各赋值点之间不一致，
并已导致两处线上缺陷（其中「移到明天」在 `startHour > 0` 时会原地不动）。
根因与「设计决策 B」点名的双侧折算是同一个形状，
但**独立于本次修复**——已单独记录在 **`docs/home-selected-date-normalization.md`**。

本次修复不受它影响：`HomeCalendarState.make`（`:72`）会把传进来的 `selectedDate`
统一 `calendar.startOfDay` 一次，state 层拿到的恒为自然日 0 点。
