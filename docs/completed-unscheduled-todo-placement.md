# 无日期任务完成后应归档到哪一天

> 状态：**待实施**。含 bug 修复 + 一项设计决策记录。
> 落点文件：`UI/Home/HomeCalendarState.swift`

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
`Self.occurrences(on: selectedDate, in: occurrencesByDay, calendar: calendar)`，
按选中日过滤过。两条路径的差别就在这里。

渲染侧：`UI/Home/HomeSelectedDayListView.swift:120-135` 把两者放进同一个
「已完成」分区，分区计数 `totalCount` 也把未过滤的那批算了进去，
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
3. **数据现成**：`completedAt` 字段已存在（`Protocols/Models.swift:459`，
   现有排序逻辑即在使用），无需新增任何字段或迁移
4. **历史不断层**：次日回看今天，条目仍在正确的位置

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

## 修复落点

`UI/Home/HomeCalendarState.swift:174-176`，在 filter 中加入日期比对。
`selectedDate` 与 `calendar` 在该 `private init` 作用域内均可直接使用。

示意（非最终代码）：

```swift
self.completedUnscheduledTodos = noSchedule
    .filter { todo in
        guard todo.isCompleted, let completedAt = todo.completedAt else { return false }
        return calendar.isDate(completedAt, inSameDayAs: selectedDate)
    }
    .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
```

修好后 `HomeSelectedDayListView` 的分区计数会自动跟着正确，无需另改。

## 边界情况（必须处理）

1. **`completedAt == nil` 的历史数据**
   该字段可能是后加的，老条目会是 nil（`Protocols/Models.swift:545` 存在
   `self.completedAt = nil` 的构造路径）。
   建议：**不显示在任何一天**（即上面示意代码里 `guard let` 直接返回 false），
   而不是兜底塞进今天——否则一批陈年任务会突然涌入今日列表。

2. **取消完成（uncheck）**
   `isCompleted` 变回 false 后，条目应回到「未安排」/「待定日期」等未完成分区。
   按现有 filter 结构应天然成立，但需实测验证。

## 验证

- 新建一个无日期任务 → 标记完成 → 确认**只出现在今天**的「已完成」分区
- 切到明天 / 昨天 / 上个月任意一天 → 确认该条目**不出现**
- 次日再打开 App 看「昨天」→ 确认条目仍在昨天的已完成区（历史不丢）
- 取消完成 → 确认回到未完成分区，且不再出现在任何一天的已完成区
- 「已完成」分区的计数徽章数字与实际条目数一致
- 老数据（`completedAt == nil` 的已完成无日期任务）不出现在任何一天

## 附带记录（不在本次修复范围）

`UI/Home/HomeView.swift` 的 `selectedDayStats()` 基于 `monthOccurrences` 计算，
**不包含无日期任务**。因此顶部进度环（`n/m`）与「已完成」分区的计数口径本就不一致。
这是独立于本 bug 的既有问题，需要时另行处理。
