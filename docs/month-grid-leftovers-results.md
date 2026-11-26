# 结果文档:月历两轮记录在案的遗留修复

> 来源:用户 2026-11-25 指派(月历「+N」任务书推送后追加:「这里面说的几个小问题也都要改一下」,
> 经确认范围 = 我修两个遗留)。即上轮结果文档 §7(eventEndDate)与 §8 第 1 条(待定日期组入口)。
> 「+N」间隙任务在 `docs/month-grid-plus-n-gap-task.md`,由另一执行者负责,与本分支无文件交集。
> 分支:`task/month-grid-leftovers`,基线 `main` @ `a6341cc`。

## 1. 提交

| 提交 | 内容 |
|---|---|
| `13716e0` | `fix(month-grid): 移到明天平移跨天终点 + 待定日期组「移到稍后」入口`(代码 + 测试 + 注释) |
| 第 2 提交 | `docs(month-grid): 遗留修复结果文档` —— 即本文件;提交 hash 无法自引用,以分支 HEAD 为准 |

## 2. 修复一:`moveTodoToTomorrow` 丢跨天结束日(数据丢失 bug)

- 根因(上轮结果文档 §7 判定属实):`UI/Home/HomeView.swift` 的 `moveTodoToTomorrow`
  构造 `TodoDetailUpdate` 不传 `eventEndDate`(默认 nil),而 `TodoStore.updateFull`
  无条件写入 → 跨天事件「移到明天」结束日被清、变单天。
- 修法 = `docs/multi-day-span-events.md` §7 当年规定但一直没接线的方案:
  `TodoSpan.shiftedEnd`(函数与单测均已存在,本分支是第一个生产调用方)按新
  dueDate 平移终点、跨度不变。该设计文档人工回归第 3 条(14→16 三天,选中 15 号
  移到明天 → 跨度仍 3 天)由新增组合契约测试 `testShiftedEnd_composedWithNextDay_preservesSpan`
  锁住(TodoSpanTests 17 → 18 条)。
- 边界:单天 / 重复 / 无日期任务 `shiftedEnd` 自然返回 nil,行为与改前等价;
  `dueHint: ""` 等既有语义未动。顺带把 `Store/TodoStore.swift` 落库处的
  「所有调用方传 nil」注释更正为现状(本改动使其不再成立,双 review 留档项)。

## 3. 修复二:「待定日期」组没有「移到稍后」入口

- 根因(上轮结果文档 §8 第 1 条):该组用 `PendingDateTodoRow`,没接 context menu;
  `HomeCalendarState.canMoveToLater` 对「待定日期」本就放行(移时清时段 + 提示),
  只缺 UI 入口。
- 修法:`PendingDateTodoRow` 加可选 `onMoveToLater`(nil 不挂菜单,与 WarmTodoCard
  注入模式一致);`HomeSelectedDayListView` 把视图已有的 `onMoveToLater` 回调接进
  卡片。菜单项复用 `card.menu.move_to_later`(zh/en/ja 三语齐备)+ `canMoveToLater`
  过滤 + `.contentShape(.contextMenuPreview)` 圆角预览,全部照 WarmTodoCard 同款。
- `HomeView` 无需改动(回调注入 1920 行已存在)。

## 4. 测试

- `arch -arm64 swift test`(SPM 协议目标):**437 执行 / 1 失败 / 0 跳过** —— 失败为
  CLAUDE.md 记录的 CN 时区恒红基线 `TodoDueDateShifterTests.testDSTSpringForward_fallsBackToMidnight`,
  非回归;`TodoSpanTests` 18/18。
- `xcodebuild test -only-testing:VoiceTodoTests`(iPhone 17 Pro / iOS 26.5 模拟器):
  **521 执行 / 0 失败 / 2 跳过**,与上轮绿基线完全一致(跳过 = VoiceInputTests 两条
  权限弹窗用例,自带 skip)。注:`TodoSpanTests` 属 SPM 协议目标、不在 iOS bundle
  (定向验证执行 0 条),与上轮口径相同。
- 首跑因 worktree 缺 `Config/Secrets.xcconfig` 构建失败(memory 已记录的 worktree
  陷阱,从主检出拷贝后通过;该文件 gitignored,不入库)。

## 5. 双 review 循环(2026-11-26)

**2 轮收敛,状态 DONE**:第 2 轮 Three Check 与 code-review-expert 均 0 问题,无冲突。
第 1 轮各有一个观察项(Three Check 低危留档 / code-review-expert 一个 P3 候选),
经评估均为「修法劣于现状」的无效改进,两 skill 独立得出同一结论,不修。

循环范围外留档(不在本分支处理):
1. **同类丢跨天 bug 仍在其他写路径**:`updateTime`(`HomeView.changeTodoTime` /
   `pickTodoDate` 走它)、`UI/Review/Flow/ReviewStepTriage.swift`、
   `UI/Detail/TodoDetailView.swift:1232` 构造 `TodoDetailUpdate` 时同样不传
   eventEndDate —— 「带钟点的跨天事件改时间/改日期」仍会清跨度。
   建议另开任务统一接 `TodoSpan.shiftedEnd`。
2. 空菜单瞬态:`PendingDateTodoRow` 完成过渡窗口(~0.75s)内长按菜单为零项,
   部分 iOS 版本可能弹空预览 —— 条件挂载修法会切换 ConditionalContent 分支、
   丢视图身份,打断「原地保留」勾号动画(docs/todo-completion-feedback.md
   既定产品行为),维持 WarmTodoCard 同款取舍不修。
3. 真机长按手感与 contextMenu 预览圆角观感未走查(需真机)。

## 6. 与指派不一致的地方 / 自己做的判断

1. 范围按用户确认的「我来修两个遗留」执行;「+N」任务书内容(间隙/三位数/
   结果文档更正)未动,`UI/Home/HomeMonthGridButton.swift` 未碰。
2. `TodoStore.swift` 注释更正超出最初 4 文件 diff:由本改动直接引发,随本分支
   交付,双 review 第 2 轮确认无异议。
3. 待定日期组菜单只加「移到稍后」一项,未加「移到明天」:指派只点名入口缺口;
   无日期任务加「移到明天」涉日期语义(是否把 dueDate 设为明天)属产品决定,
   未擅自扩范围。
