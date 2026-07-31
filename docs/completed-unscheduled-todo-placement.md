# 无日期任务完成后应归档到哪一天

> 状态：**已实施**。`abfaa588`（修复）+ `8b3e3f09`（补回归测试），均已在 `main`。
> 本文保留为**设计决策 + 实施记录**。
> 落点文件：`UI/Home/HomeCalendarState.swift`
> 行号基准：现状引用 = `4b1eaa6`；「修复前」代码引用 = `8813f07`（已被 `abfaa588` 取代）。
>
> ✅ **遗留项已修**（原归档比对用自然日、未走 `DayClock`，`startHour > 0` 时与回顾页口径分裂）：
> 已在 `docs/day-clock-day-boundary-inconsistencies.md` 的「缺陷 3」中修复，
> 实施提交 `8e5758f`（已合并 `main`）。归档比对已改为
> `isSameUserDay(completedAt, userDayStart(onNaturalDay: selectedDate))`，与 `ReviewAggregator` 同源。

---

## 现象（修复前）

无安排日期（`dueDate == nil && recurrenceRule == nil`）的任务被标记完成后，
**同时出现在每一天的「已完成」分区**——今天有、明天有、上个月的某天也有。

## 根因（修复前）

`UI/Home/HomeCalendarState.swift:174-176` @ `8813f07`：

```swift
self.completedUnscheduledTodos = noSchedule
    .filter { $0.isCompleted }
    .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
```

**只按 `isCompleted` 筛选，完全没有与 `selectedDate` 做任何比对。**
该数组不随选中日期变化，因此在任何一天打开都会渲染同一批条目。

对照组行为正常：`completedOccurrences` 源自
`Self.occurrences(on: selectedDate, in: occurrencesByDay, calendar: calendar)`
（现 `HomeCalendarState.swift:185`），按选中日过滤过。两条路径的差别就在这里。

渲染侧：`UI/Home/HomeSelectedDayListView.swift:123-138` 把两者放进同一个
「已完成」分区，分区计数 `totalCount`（`:137`）也把未过滤的那批算了进去，
所以计数同样偏大。

---

## 设计决策：按 `completedAt` 归到「完成那天」

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
   原有排序逻辑即在使用），勾选时由 `Store/TodoStore.swift:148` 写入，
   无需新增任何字段或迁移
4. **历史不断层**：次日回看今天，条目仍在正确的位置
5. **与回顾页同源**：`ReviewAggregator` 就是按 `completedAt` 把任务归到某一天的
   （`Protocols/Domain/ReviewAggregator.swift:81,110`）

   ⚠️ 第 5 条只在「用哪个字段」这一层成立。**「怎么把字段折算成某一天」这一层
   并没有对齐**——回顾页走 `DayClock.startOfUserDay`，本次实施走自然日。
   这就是上面那条遗留项。

### 已否决的方案

| 方案 | 否决原因 |
|---|---|
| 完成后留在「未安排」区，仅做灰化下沉 | 条目会越堆越多；用户会觉得「做完了怎么还挂在这」；且与代码注释声明的原始意图（「让无安排任务的完成行为和有安排任务对齐」）相反 |
| 只在「今天」显示 | 次日即消失，等于抹掉历史记录，比现状更糟 |

### 需要承认的代价

同一个「已完成」分区内混两种归档口径：
有日期的按**计划日**、无日期的按**完成日**。

严格说这不够纯粹。但判断为可接受——**用户不会感知到这个区别**：
对用户而言两类都是「这天相关的已完成事项」，混在一起读起来很自然。
为理论一致性牺牲实际体验不划算。

---

## 实施记录

`abfaa588` 落地，现 `UI/Home/HomeCalendarState.swift:174-181`：

```swift
self.completedUnscheduledTodos = noSchedule
    .filter { todo in
        // 无日期任务按「完成日」归档(对照:有日期任务按计划日)。`completedAt == nil`
        // 的历史数据不显示在任何一天。详见 docs/completed-unscheduled-todo-placement.md。
        guard todo.isCompleted, let completedAt = todo.completedAt else { return false }
        return calendar.isDate(completedAt, inSameDayAs: selectedDate)
    }
    .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
```

与本文原示意代码的**唯一差异**：日期比对用 `calendar.isDate(_:inSameDayAs:)`（自然日），
而非 `DayClock` 的用户日。这一条差异曾作为文首遗留项，
记录在 `docs/day-clock-day-boundary-inconsistencies.md`「缺陷 3」—— **现已修复**（`8e5758f`），
比对改为 `isSameUserDay(completedAt, userDayStart(onNaturalDay: selectedDate))`。

`HomeSelectedDayListView` 的分区计数如预期自动跟着正确，未另改。

### 测试覆盖（已完成）

`VoiceTodoTests/UI/HomeCalendarStateGroupingTests.swift`，共 13 个用例。
本次相关的 5 个：

| 用例 | 覆盖 |
|---|---|
| `testCompletedUnscheduledTodoOnlyShownOnCompletionDay:98` | 主 bug 回归 |
| `testCompletedUnscheduledTodoVisibleOnPastCompletionDay:122` | 次日回看昨天，历史不丢（`8b3e3f09` 补） |
| `testCompletedUnscheduledTodoNilCompletedAtShownNowhere:146` | 边界 1（老数据） |
| `testUncheckRemovesFromCompletedSection:164` | 边界 2（取消完成） |
| `testCompletedRawFallbackGoesToCompletedSection:78` | 既有用例，改为显式传 `completedAt`——本意是验 outcome 路由，不是日期过滤 |

辅助构造 `makeTodo`（`:301-321`）已加 `completedAt: Date? = nil` 形参并透传。

---

## 边界情况

1. **`completedAt == nil` 的已完成条目 —— ✅ 已实施**
   不显示在任何一天（`guard let` 直接返回 false），而不是兜底塞进今天。
   由 `testCompletedUnscheduledTodoNilCompletedAtShownNowhere` 锁定。

   依据：`TodoStore.toggle` 每次都会写 `completedAt`（`Store/TodoStore.swift:148`），
   正常路径不产生 nil；但 SwiftData 里该字段是 optional
   （`Store/SwiftDataModels.swift:30`），历史数据 / 外部导入仍可能为 nil。
   与 Widget 侧既有惯例一致：`Protocols/Domain/WidgetTodoFilter.swift:44-47`
   对无日期已完成项同样是 `guard let completedAt … else { continue }`。

2. **取消完成（uncheck）—— ✅ 已实施**
   `isCompleted` 变回 false 后条目回到未完成分区，且 `TodoStore.swift:148`
   同时把 `completedAt` 清回 nil。由 `testUncheckRemovesFromCompletedSection` 锁定。

3. **在「非今天」的日期上勾选 —— ⏳ 已上线，待观察**
   三个未完成分区（`unscheduledTodos` / `pendingDateTodos` / `unparsedTodos`）
   本身**不按日期过滤**，任何一天都显示同一批 backlog。
   于是用户停在「上个月某天」勾掉一条无日期待办时，它会从（日期无关的）未完成分区
   跳进（只认今天的）已完成分区，表现为**当场从当前视图整个消失**，要切回今天才看得到。

   `abfaa588` 未提及此场景，也没有测试覆盖——行为已上线但没人验证过体验是否突兀。
   若真机上觉得突兀，备选是加一个短暂的「已完成」淡出动画再移除，而不是改归档口径。

---

## 验证

自动化已覆盖（`8b3e3f09` 自陈 5/6）：

- ✅ 标记完成 → 只出现在完成当天的「已完成」分区
- ✅ 切到其他日期 → 条目不出现
- ✅ 次日回看昨天 → 条目仍在昨天的已完成区（历史不丢）
- ✅ 取消完成 → 回到未完成分区
- ✅ 老数据（`completedAt == nil`）不出现在任何一天

仍需真机 / 端到端：

- ⏳ 「已完成」分区的计数徽章数字与实际条目数一致
- ⏳ 边界情况 3 的体验是否可接受
- ✅ **设置「一天起始时刻」= 3:00，凌晨 1 点勾掉一条无日期任务 → 归到「昨天」，与回顾页一致**
  （原为「归到今天、与回顾页分裂」的遗留项，`8e5758f` 已修；详见 `docs/day-clock-day-boundary-inconsistencies.md` 缺陷 3）。回归闸门：两者必须显示同一天

---

## 附带记录（不在本次修复范围）

`UI/Home/HomeView.swift` 的 `selectedDayStats()`（`:723-738`）基于 `monthOccurrences` 计算，
**不包含无日期任务**。因此顶部进度环（`n/m`）与「已完成」分区的计数口径本就不一致。
这是独立的既有问题，`abfaa588` 的提交说明里也明确留待后续。

另注：核实上面那条时发现 `HomeView.selectedDate` 的归一化口径在各赋值点之间不一致，
曾导致两处线上缺陷（其中「移到明天」在 `startHour > 0` 时会原地不动）。
与本文遗留项同属「自然日 / 用户日 口径混用」一族，三者合并记录在
**`docs/day-clock-day-boundary-inconsistencies.md`**——**三处缺陷均已修复**
（`8e5758f`，已合并 `main`）。

本次实施不受那个不一致影响：`HomeCalendarState.make`（`:72`）会把传进来的
`selectedDate` 统一 `calendar.startOfDay` 一次，state 层拿到的恒为自然日 0 点。
