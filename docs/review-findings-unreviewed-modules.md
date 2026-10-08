# 上线前补审结果:小组件 / Siri / 本地提醒 / 系统日历

> 2026-10-08 执行,依据 `docs/review-plan-unreviewed-modules.md`(含同日 §0 评审修订)。
> 分支:`claude/pre-launch-review-jy86zk`,不合 main,待人工编译 + 真机验证。
> 方法:按方案 §5「先读后判」——每个结论追到全部调用方与兜底路径;单测可证明的
> 修复均已红绿验证(先证红、后修绿);依赖系统行为的只出结论与复现步骤。

---

## 1. 发现总表(按严重度)

| # | 严重度 | 模块 | `文件:行号` | 问题(一句话) | 触发场景 | 置信度 | 处置 |
|---|---|---|---|---|---|---|---|
| 1 | 高 | P2 | `App/CalendarSyncService.swift:171` × `App/SystemCalendarWriter.swift:87` | replace 的「写新」被 writer 首写幂等过滤吞掉,编辑已同步待办 = 删旧事件 + 不写新事件,日历镜像静默丢失且永不自愈(标识仍指旧事件,后续编辑永远 skip) | 用户开启日历同步后,编辑任意一条已同步待办(改名/改时间) | 已证实(代码链 + 红→绿回归测试) | **已修**(副本清旧标识再写新;mock 忠实化后 `testReplaceRemovesOldEventAndWritesNewEvent` 承载回归,无修复时 3 断言全红) |
| 2 | 高 | P1 | `App/Intents/AddTodoIntent.swift:144`(修复前行号) | Siri 新增带提醒待办后不排通知——intent 写库不走活着的 TodoStore,`$todos` 不发布,不开 App 提醒永远不响 | 用户对 Siri 说「明天 9 点提醒我 X」,之后不打开 App | 已证实(调用链穷尽:save 后仅 markExternalDataChanged + reload) | **已修**(落库后逐条 `IntentNotificationReconciler.reconcile`,与 CompleteTodoIntent 同模式) |
| 3 | 中 | P1 | `App/Intents/DeleteTodoIntent.swift:89`(修复前行号) | Siri 删除待办不撤已排提醒,提醒照响到原定时刻,直到下次开 App 全量对账 | Siri 删除一条已排提醒的待办,提醒时刻前不开 App | 已证实 | **已修**(新增 `IntentNotificationReconciler.removeNotifications` + 调用 + 2 条 spy 测试) |
| 4 | 中 | P0 | `Store/TodoStore.swift:951` | `refreshIfStale` 先 fetch 数据、后回读版本号,窗口内的外部写(save+mark)被吸收进 lastSynced,主 App 漏看这次写直到再下一次外部写 | 回前台刷新期间(毫秒级窗口)Widget/Siri 恰好写库 | 已证实(时序推演;窗口窄) | **已修**(进门快照版本号随 `refreshTodos(syncedExternalChangeVersion:)` 落账) |
| 5 | 中 | P1 | `Protocols/Domain/NotificationPlanner.swift:97-100` | repeating 全保留 + 一次性填剩余额度(默认 60):重复项多的用户,一次性**近期**提醒被静默挤掉 | 用户有 60+ 条带钟点的重复待办,再新建一次性提醒 | 已证实(纯函数逻辑) | 不修(理由:重复项优先是既定取舍,改排序语义需产品拍板;建议上线后遥测 pending 满额比例再定) |
| 6 | 中 | P1 | `UI/Home/HomeSettingsSheet.swift:182` | 系统通知权限 denied/未决与 App 内开关显示不同步,无「提醒不会响」提示 | 用户拒绝通知权限,或在系统设置关闭后回 App 看 | 已证实 | 不修(UI 改动需设计拍板;reconcile 侧已正确:denied 清空、notDetermined 懒申请) |
| 7 | 低 | P0 | `Store/SwiftDataModels.swift:509` × `App/Intents/ToggleTodoIntent.swift:163` | 双进程同日完成同一重复待办可插两条同 `occurrenceKey` 记录(`@Attribute(.unique)` 不拦,`addBatch` 注释已自认),残留后难以通过 toggle 清干净 | 主 App 与 Widget 在互相看不见对方完成记录的瞬间各自完成同一条 | 推断(依赖 SwiftData 跨进程 fetch 时序) | 不修(窗口极窄;日志可观测 `findCompletion` 重复) |
| 8 | 低 | P2 | `App/Intents/DeleteTodoIntent.swift:9-10` × `App/AppCoordinator.swift:939` | Siri 删除不清理系统日历镜像事件,留孤儿;其注释声称「与 TodoStore.delete 一致」已过时——主 App 实际删除路径 `deleteTodo` 会清理 | 待办已同步到系统日历,经 Siri 删除 | 已证实 | 不修(需拍板日历清理归属层——现状在 coordinator,intent 复刻会引入 EventKit 权限请求入 Siri 上下文;建议后续做前台孤儿对账) |
| 9 | 低 | P2 | `App/SystemCalendarWriter.swift:159-162` | EventKit 事件 ID 失效(事件被移动日历)后删除/替换走 `event_missing`,无 `calendarItemIdentifier` 兜底,孤儿事件累积 | 用户在系统日历 App 里把镜像事件移动到其他日历,再回 App 删除/编辑该待办 | 推断(EventKit 文档行为) | 不修(需拍板是否冗余存第二标识;真机先验证 ID 确实会变) |
| 10 | 低 | P2 | `App/CalendarSyncService.swift:218-226` | `persistSystemCalendarResults` 回写失败 → 清理刚建事件;清理**也**失败才留孤儿 + 下次同步重复创建 | 连续两次存储/日历操作都失败 | 推断(双失败窗口) | 不修(已有尽力自愈 + error 日志,代价是极端场景一条重复事件) |
| 11 | 低 | P1 | `App/TodoNotificationSync.swift:33-39` × `App/LocalNotificationScheduler.swift:20-66` | 两次 reconcile 的 await 交错可短暂把「刚取消的提醒」又排回去,极端时序下一次误响,随下一次触发收敛 | 相隔 >500ms 的两次待办变化,恰与前一轮回前台对账的 await 交错 | 推演成立(窗口毫秒级) | 不修(自收敛;加串行队列是可选加固,非上线阻断) |

「需真机」项(只有结论与复现步骤,不改代码)见 §3 真机验证清单。

严重度口径:高=数据丢失/核心承诺静默失效;中=可见错误但可恢复或需特定时序;低=体验瑕疵/日志口径。
置信度口径:已证实=调用链穷尽或测试复现;推断=逻辑推演但依赖系统行为或未构造出复现。

---

## 2. §4 检查点逐条结论(22/22,含「不成立」)

### 2.1 P0:跨进程写库

| # | 检查点 | 结论 | 证据 |
|---|---|---|---|
| 1 | 并发写同一条待办的结果 | **无法从代码完全判断(需真机)**;代码层事实:无冲突检测、无合并逻辑,SwiftData/SQLite 行级串行,按脏字段 last-writer-wins,只有存储级错误会抛;intent 侧 save 失败有日志 + widget 60s 错误提示(Siri 返回失败对话) | `ToggleTodoIntent.swift:63-71`、`AddTodoIntent.swift:150-157` |
| 2 | 主 App 陈旧内存覆盖「已完成」 | **不成立(编辑路径)**:`updateFull` 不写 `isCompleted`(仅 recurrence 重建分支重置,是既有约定),不存在「编辑保存把已完成覆盖回未完成」;真正的未知在主 App 长生命周期 context 对已注册对象是否返回跨进程新值 → 需真机(清单 #6)。附带发现 #4(TOCTOU)已修 | `Store/TodoStore.swift:313-345`、重读时机=`TodoStore.swift:951` + `ToggleTodoIntent.swift:44` |
| 3 | 时间戳版本号同毫秒/时钟回拨漏检 | **不成立(原问法)**:Double 时间戳亚微秒分辨率,两进程同值概率可忽略;`!=` 比较对回拨免疫。**成立(相邻问题)**:fetch→回读吸收窗口 = 发现 #4,已修 | `AppGroupConfig.swift:59-65`、`TodoStore.swift:951-962` |
| 4 | `nonisolated(unsafe)` 容器缓存竞态 | **不成立**:`NSLock` 全程包住检查+建+缓存,`nonisolated(unsafe)` 仅在锁内读写;连点两次也串行建一个容器 | `AppGroupModelContainerProvider.swift:10-37` |
| 5 | 只读容器读到旧快照 | **代码层不成立**:每次查询新建 `ModelContext`(行不缓存),容器缓存不缓存数据;跨进程 WAL 提交可见性属系统行为 → 真机(清单 #6) | `QueryTodosIntent.swift:62`、`TodoEntityQuery.swift:35/62/94`、`TodoWidgetProvider.swift:100` |
| 6 | widget 交互错误用户看不到/残留 | **不成立**:widget 本体渲染(medium/compact 两处),60s 保留自动过期(timeline 挂到期条目),下次成功即清 | `TodoWidgetComponents.swift:134/243`、`TodoWidgetProvider.swift:80-85`、`WidgetConfig.interactionErrorRetention=60`(`Constants.swift:190`)、`ToggleTodoIntent.swift:43` |
| 7 | occurrenceKey 归一化口径 | **一致**:两侧均 `Calendar.current` + `startOfDay` + `dayKey`(同设备同 timeZone);`occurs(on:)` 默认参数亦同。残留:发现 #7(同 key 双插,窄) | `TodoStore.swift:620-626` vs `ToggleTodoIntent.swift:135-140`、`SwiftDataModels.swift:515-532`、`RecurrenceRule.swift:110` |
| 8 | 删除连带清日历/撤提醒 | **成立**:两者都不做;提醒已修(#3),日历清理不修(#8,注释「与主流程一致」过时) | `DeleteTodoIntent.swift:9-10/89-91`、`AppCoordinator.swift:939-943` |

### 2.2 P1:本地提醒

| # | 检查点 | 结论 | 证据 |
|---|---|---|---|
| 1 | 64 上限截断排序 | **成立(挤占)**:planner 限额 60 < 系统 64,未击穿;但 repeating 全保留 + 一次性按触发时间填剩余 → 重度重复用户的一次性近期提醒被静默挤掉(#5)。另:扩展就地 reconcile 理论可让 pending 短暂 >64,系统丢弃行为真机(清单 #9 附带) | `NotificationPlanner.swift:41/97-100`、`TodoNotificationSync.swift:35` |
| 2 | 一周不开 App,第 65 条后还响吗 | **成立(按设计)**:重排只在待办变化/冷启动/回前台/开关变化触发;App 不开则额度冻结在最后一次 reconcile——repeating 照响、top-60 一次性照响、61+ 静默不响。叠加更糟的 #2(Siri 新增完全不排)已修 | `VoiceTodoApp.swift:329/355`、`TodoNotificationSync.swift:17-29` |
| 3 | 时区/夏令时 | **结论已出(壁钟语义,无丢失)**:一次性=绝对日期分量、重复={时分}/{weekday,时分}/{day,时分},均不带 `timeZone` → 系统按触发时用户当前时区解释;跨时区后「明早 9 点」= 新时区 9:00;DST 切换由重复触发器自然处理。真机抽验(清单 #7) | `NotificationPlanner.swift:72-76/136-174` |
| 4 | 提前量的其他钳制 | **不成立**:monthly 1 号→00:00 已文档化;weekly 跨日 weekday 回退取模正确;daily 天然成立;全天待办被 `hasDueTime` 守卫跳过(不提醒,正确);offset 防御性钳 0...1440 | `NotificationPlanner.swift:51-65/143-174` |
| 5 | 权限懒申请与开关同步 | **懒申请正确成立;显示不同步成立(#6)**:notDetermined 且有内容才请求;denied 清空;但设置页只绑 App 内开关,无系统权限状态提示 | `LocalNotificationScheduler.swift:23-38`、`HomeSettingsSheet.swift:182-190` |
| 6 | 两次对账并发 | **成立(窄,#11)**:交错可短暂误排已取消项,自收敛;无误删持久化风险 | `TodoNotificationSync.swift:33-39`、`LocalNotificationScheduler.swift:20-66` |
| 7 | 扩展与主 App 双写 identifier | **不成立**:两侧标识同出 `NotificationPlanner`(同 ID add = 替换非重复);扩展前缀删除覆盖全部变体(-d/-w/-m/base) | `IntentNotificationReconciler.swift:76-80`、`NotificationPlanner.swift:67/152/172/207` |
| 8 | 三个入口完成后撤销提醒 | **部分成立**:非重复待办——主 App(全量对账)/widget 勾选/Siri 完成(就地 reconcile)都撤 ✓;重复待办「完成今天」→ 今天的 repeating 仍会响(重复触发器机制性,无法「只停今天」;改一次性展开会引入「App 不开则断」的更差权衡,维持现状),明天照响 ✓;Siri 删除不撤 → #3 已修 | `IntentNotificationReconciler.swift:75-100`、`NotificationPlanner.swift:51` |

### 2.3 P2:系统日历

| # | 检查点 | 结论 | 证据 |
|---|---|---|---|
| 1 | 整组删除含用户改过的实例 | **需真机 + 产品拍板**:`span: .futureEvents` 删系列是镜像一致性语义(待办=系列);用户在系统日历手动改过的单次实例是否随系列删属 EventKit 行为(清单 #10);导入的外部事件不持标识、确认不误删 ✓ | `SystemCalendarWriter.swift:141-163`、`SystemCalendarEventMapper`(导入无标识,方案 §4.3 已核) |
| 2 | ID 失效兜底 | **成立(#9)**:无 `calendarItemIdentifier` 冗余,`event_missing` 仅警告 | `SystemCalendarWriter.swift:159-162` |
| 3 | 替换原子性 | **设计不成立(先写后删正确)**:写新失败保旧可重试、删旧失败留孤儿(已知取舍、warning 不阻断);「写新被过滤吞掉」是 #1,已修 | `CalendarSyncService.swift:149-203` |
| 4 | 回写失败重复创建 | **成立(低,#10)**:仅双失败窗口(回写失败→清理又失败)才孤儿+下次重复 | `CalendarSyncService.swift:205-227` |
| 5 | 权限撤销后的表现 | **成立(报错不静默)**:granted=false → throw → 失败 toast(诚实但每次编辑都打扰,可讨论降级策略) | `SystemCalendarWriter.swift:96-99`、`CalendarSyncService.swift:39-46` + `observeCalendarSync` |
| 6 | 跨进程删除/修改的日历同步时机 | **成立(#8)**:widget 无删除入口;Siri 删除留孤儿事件;toggle 完成不动日历事件与主 App 完成路径一致 ✓;编辑仅主 App 入口 → 修复后 replace 正常 | `DeleteTodoIntent.swift:9-10`、`AppCoordinator.swift:949-958`(完成不动日历) |

统计:成立 9 / 不成立 8 / 需真机或产品拍板 5。

---

## 3. 真机验证清单

> 每条给复现步骤与预期;标注〔修后〕的依赖本次修复,验证通过后方可合 main。

1. 〔修后 #1〕开启「App+系统日历」→ 建带钟点待办 → 系统日历出现事件 → App 内编辑改名保存。**预期**:旧事件删除、新事件带新标题出现(修复前:旧事件删除、无新事件,且再编辑也不出现)。
2. 〔修后 #2〕Siri:「用 VoiceTodo 记录,明天上午 9 点买牛奶」→ 完全不打开 App → 锁屏等到点。**预期**:提醒响(修复前:永不响)。注意沙盒/真机通知权限首次弹窗只会在 App 内出现,intent 侧不弹属预期。
3. 〔修后 #3〕Siri 建带提醒待办 → Siri 删除该待办 → 到点不开 App。**预期**:不响;`xcrun simctl`/真机通知中心 pending 列表无该条。
4. 〔修后 #4 冒烟〕窄窗口难构造,冒烟即可:widget 勾选完成 → 回 App 状态正确。
5. 〔4.1.1〕确认页批量保存进行中(多条)→ 恰好 widget 勾选其中一条。**预期**:双方字段级合并(标题/完成态共存),无报错、无整行丢失。
6. 〔4.1.2 / 4.1.5〕主 App 前台常驻 → Siri 完成同一条待办。**预期**:主 App 勾选态在下次前台切换后正确;此前编辑该条并保存,不把完成态覆盖回去。
7. 〔4.2.3〕设一条明天 9:00 一次性 + 一条每天 9:00 重复 → 系统设置切换时区(如东京→纽约)。**预期**:两条均按新时区壁钟 9:00 触发。
8. 〔4.2.8〕重复待办在提醒时刻前完成「今天这次」。**预期**:今天到点仍响(机制性,预期内),明天照常。
9. 〔4.2.1〕构造 65+ 条带钟点一次性待办。**预期**:planner 只排最近 60 条,第 61+ 不响(截断预期);顺带观察 pending 是否曾 >64 及系统丢弃行为。
10. 〔4.3.1〕同步一条重复待办 → 在系统日历手动修改其中一个实例 → 回 App 删除该待办。**预期(待确认)**:系列被删;记录被改实例是否一并消失,交产品拍板是否接受。
11. 〔4.3.5〕系统设置撤销日历权限 → 回 App 编辑已同步待办。**预期**:失败 toast、日历不写、App 数据完好。
12. 〔#7〕(选做)双端同时完成同一条每日重复待办。**预期**:不出现两条同日完成记录;若出现,日志有 `findCompletion` 可溯源。

---

## 4. 范围外发现(只列不修)

1. **通知内容构造双拷贝**:`IntentNotificationReconciler.notificationRequest`(`App/Intents/IntentNotificationReconciler.swift:23`)与 `LocalNotificationScheduler.reconcile` 内联构造(`App/LocalNotificationScheduler.swift:42-57`)是两份手工同步的同构代码,注释已自认「按约定不动」——改一处漏一处的漂移风险长期存在,建议提取共用工厂。
2. **`TodoStore.addBatch` 查重的跨进程盲区**:`existingTodoItem` 只查当前 context(`Store/TodoStore.swift:1123-1126` 注释自认);现有入口 id 均新生成,实际不可达,但若未来出现「固定 id 重放」入口会重复。
3. **App 进程内 reload 策略不一致**:`AddTodoIntent`/`DeleteTodoIntent` 直调 `WidgetCenter.reloadAllTimelines`,而 App 内主流程走 `WidgetReloadCoalescer` 去抖;intent 直调有依据(一次性调用),但同进程多次直调绕过 coalescer 的预算保护,量级低。
4. **planner 限额 60 与系统 64 的 4 条 headroom 无注释**:若是有意给就地 reconcile 留量,建议补一行注释说明,避免后人「顺手改满 64」。
5. **Siri 就地 reconcile 可把 pending 推过 64**:主 App 排满 60 后扩展单条对账再补变体,系统对超限的丢弃策略(丢最旧/丢新增)文档未明,真机观察即可,无代码动作。

---

## 5. 本次改动清单(全部在本分支,未合 main)

| 文件 | 改动 |
|---|---|
| `docs/review-plan-unreviewed-modules.md` | §0 评审意见(5 问逐条,`> 评审:` 块) |
| `App/CalendarSyncService.swift` | #1:replace 在副本上清旧标识再写新 |
| `App/Intents/AddTodoIntent.swift` | #2:落库后逐条就地排提醒 |
| `App/Intents/IntentNotificationReconciler.swift` | #3:新增 `removeNotifications(todoID:port:)` |
| `App/Intents/DeleteTodoIntent.swift` | #3:删除落库后撤提醒;review 修复:头部注释纠偏(#8 指出的「与主流程一致」失实表述与漂移行号) |
| `Store/TodoStore.swift` | #4:`refreshTodos(syncedExternalChangeVersion:)` + `refreshIfStale` 进门快照;review 修复:无参 `refreshTodos()` 同样进门快照(8 个进程内调用点的同型吸收窗口一并关闭),参数收成非 Optional |
| `VoiceTodoTests/Integration/CalendarSyncServiceTests.swift` | mock 忠实化(复刻真实过滤)+ 回归注释 |
| `VoiceTodoTests/Intents/IntentNotificationReconcilerTests.swift` | `removeNotifications` 2 条 spy 测试 |
| `VoiceTodoTests/Store/StoreTests.swift` | #4 快照落账红绿测试(review 补:回退成 fetch 后回读语义时变红) |

测试:`CalendarSyncServiceTests`(8)+ `IntentNotificationReconcilerTests`(10)+
`StoreTests`(68,含 #4 快照落账测试)全绿;
#1 回归测试已做红绿验证(还原修复后 3 断言失败,形态与线上 bug 一致:status=skipped、
receivedTodos 空、identifier 停留 event-old);#4 快照落账测试同样红绿验证
(回退成 fetch 后回读语义时 1 断言失败)。全量单测(iPhone 17 Pro 模拟器)47 套件,
45 通过、2 失败均为**既有环境红灯**,与本次改动无关:`TodoDueDateShifterTests`
DST 用例(worktree 环境已知问题)、`ProductsStorekitGuardTests`(xcodebuild CLI
注入不了 StoreKit 配置,已知限制)。本次触及模块对应的套件(Store / Calendar /
Reconciler / PendingRecovery / SystemCalendarWriter / WidgetFilter)全部通过。
