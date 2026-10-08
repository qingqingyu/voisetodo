# 上线前补审方案:小组件 / Siri / 本地提醒 / 系统日历

> 2026-10-08 起草。本文档是**审查方案**,不是审查结果。
> 读者:执行审查的人或 AI;以及先审本方案本身的人(见 §0)。

---

## 0. 给方案评审者:请先检查这几点

本方案交给执行者之前,先请你挑它的毛病。重点看:

1. **范围对不对**:§2 的覆盖率是从 commit message 推出来的(方法与局限见 §2.1)。有没有覆盖率低、但风险更高、却被漏掉的模块?
2. **优先级对不对**:§3 的排序依据是「跨进程写数据 > 静默失效 > 写用户外部数据」。你同意吗?
3. **检查点够不够具体**:§4 的每条问题,执行者能不能直接对着代码回答「是/否 + 证据」?有没有含糊到没法验证的?
4. **约束是否合理**:§5 要求「运行时代码不经真机验证不改」。会不会因此漏修本该当场修的东西?
5. **有没有更便宜的手段**:某些检查点能不能用单元测试代替人工推演?

意见直接写在对应段落后面,用 `> 评审:` 开头。

---

## 1. 背景

- App:VoiceTodo(iOS 26,SwiftUI + SwiftData,主 App + Widget 扩展 + App Intents),即将首次上架。
- 服务端(`AIProxy/`)、付费链路、复盘(`UI/Review`)、确认页已多轮审查,**不在本次范围**。
- 录音模块(`Voice/`)刚完成一轮审查,修复在分支 `claude/pre-launch-review-jy86zk` 的 `fafb085`,**不在本次范围**。

---

## 2. 为什么审这几块:历史审查覆盖率

### 2.1 统计方法

- 统计对象:全部 818 个提交,只看业务代码(排除测试、文档)。
- 「已审」的判定:提交经由的 merge 或提交本身的 message 含「双 review / dual review / 双审 / 复核 / 走查 / 核实 / 收敛 / 第 N 轮 review」。
- 已排除复盘功能的同名干扰:scope `(review)`、`ReviewView` 等。
- **局限**:写在 `docs/` 里、没进 commit message 的审查统计不到。例如 AIProxy 实际审了 4 轮,统计只显示 27%。所以低覆盖只是**线索**,不是结论。

### 2.2 结果(按行数加权的已审比例)

| 模块 | 变更行数 | 已审比例 |
|---|---|---|
| `App/Intents`(Siri / 快捷指令 / 小组件按钮) | 1622 | **14%**(`ToggleTodoIntent` 3%,`DeleteTodoIntent` 0%) |
| `UI/Widget` | 3121 | **13%**(`TodoWidgetComponents` 0%) |
| `App/LocalNotificationScheduler.swift` | 153 | **0%**(3 个提交全部未审) |
| `App/SystemCalendarWriter.swift` | 301 | **0%** |
| `App/CalendarSyncService.swift` | 254 | **1%** |
| 对照:`UI/Review` | 9097 | 88% |
| 对照:`Store/TodoQueryActor.swift` | 429 | 79% |

---

## 3. 范围与优先级

| 优先级 | 模块 | 为什么排在这里 |
|---|---|---|
| **P0** | 跨进程写库:`App/Intents/*` + `UI/Widget/*` + `Store/AppGroupModelContainerProvider.swift` | 主 App 之外的进程写**同一个** SwiftData 库。并发与可见性问题测试难覆盖,出事表现为数据错乱或丢失 |
| **P1** | 本地提醒:`Protocols/Domain/NotificationPlanner.swift` → `App/TodoNotificationSync.swift` → `App/LocalNotificationScheduler.swift`,以及 `App/Intents/IntentNotificationReconciler.swift` | 待办 App 的核心承诺。失效是**静默**的:提醒没响,用户事后才发现 |
| **P2** | 系统日历:`App/CalendarSyncService.swift` + `App/SystemCalendarWriter.swift` | 改的是用户自己的数据,出错不可撤销;但只有用户开启日历同步才会触达 |

不在范围:`HomeView.swift`(未审量最大,约 9000 行,但以 UI 布局为主,另起一轮)、`PromptTemplates`、`TelemetryUploader`(已抽查,转写已脱敏)。

---

## 4. 检查点

每条都要回答「成立 / 不成立 / 无法从代码判断」,并附 `文件:行号` 作为证据。

### 4.1 P0:跨进程写库

**已知的结构(审前已核实,用来定位,不是结论)**

- 写库的 intent 有 `AddTodoIntent`、`CompleteTodoIntent`、`DeleteTodoIntent`、`ToggleTodoIntent`,都走 `AppGroupModelContainerProvider.writable()` + 新建 `ModelContext`。
- `ToggleTodoIntent` 和 `IntentNotificationReconciler` **同时编进了 Widget 扩展 target**(`project.yml:171-172`)。小组件按钮执行时跑在 Widget 进程里。
- 写完后各自调 `AppGroupConfig.markExternalDataChanged()` + `WidgetCenter.shared.reloadAllTimelines()`。
- 主 App 靠 `TodoStore` 比对 `currentExternalChangeVersion()`(`Store/TodoStore.swift:938`)感知外部改动。
- `AppGroupModelContainerProvider` 用 `nonisolated(unsafe) static var` 缓存容器。

**检查点**

1. **并发写**:主 App 正在保存(例如确认页批量落库)时,小组件或 Siri 同时写同一条待办,结果是什么?SwiftData 跨进程有没有冲突检测?是后写覆盖,还是抛错?抛错时 intent 怎么处理?
2. **主 App 的陈旧内存**:主 App 前台常驻时,小组件把一条待办标记完成。主 App 什么时机重读?在它重读之前,用户在主 App 里编辑同一条待办并保存,会不会把「已完成」覆盖回「未完成」?
3. **外部版本号**:`markExternalDataChanged` 用时间戳当版本号。两个进程在同一毫秒内写,或者设备时钟回拨,会不会漏检?
4. **容器缓存**:`nonisolated(unsafe)` 的缓存在 intent 并发执行时(连点两次小组件按钮)有没有竞态?会不会建出两个容器?
5. **只读容器**:`QueryTodosIntent`、`TodoEntityQuery` 用 `readOnly()`。主 App 刚写完时它们能读到最新数据吗?缓存的只读容器会不会读到旧快照?
6. **失败反馈**:`recordWidgetInteractionError` 记录的错误,用户在哪里能看到?会不会一直残留?
7. **重复待办**:`ToggleTodoMutation` 对重复待办「今天这次」的完成,与主 App 的 `TodoOccurrenceCompletion` 口径一致吗?(`occurrenceKey` 的归一化是否用同一个 `Calendar`、同一个 `DayClock`?)
8. **删除**:`DeleteTodoIntent` 删除待办时,会不会连带删掉系统日历事件、撤销已排的提醒?还是要等主 App 回前台才收敛?

### 4.2 P1:本地提醒

**已知的结构**

- 纯函数 `NotificationPlanner.plannedNotifications` 算出「应存在的通知集合」,包括 64 条上限截断、提前量、重复规则展开。
- `TodoNotificationSync` 订阅 `TodoStore.$todos`,做对账式排程。生命周期钩子在 `VoiceTodoApp.swift:329`、`:355`。
- 扩展进程内由 `IntentNotificationReconciler` 就地对账单条。

**检查点**

1. **64 条上限**:截断排序是否保证「最近要响的」优先?重复项全保留,会不会挤掉一次性的近期提醒?待办很多的用户会不会出现「提醒静默不响」?
2. **重排时机**:截断掉的提醒什么时候补排?只在待办变化、冷启动、回前台时补?用户一周不开 App,第 65 条以后的提醒还会响吗?
3. **时区 / 夏令时**:一次性通知用的是绝对日期分量还是相对时间?用户跨时区出行后,「明早 9 点」按哪个时区响?夏令时切换当天呢?
4. **提前量的边界**:`NotificationPlanner.swift:26` 写明「每月 1 号提前跨到上月末」被钳到当天 00:00。还有没有其他类似的钳制?比如 weekly 跨日、全天待办。
5. **权限**:权限懒申请。用户拒绝后,App 里有没有提示「提醒不会响」?用户在系统设置里关掉通知后,App 内开关显示是否同步?
6. **对账竞态**:`reconcile` 先读 `pendingNotificationRequests` 再增删,两次对账并发(回前台 + 待办变化同时触发)会不会重复添加或误删?
7. **扩展与主 App 双写**:扩展里的 `IntentNotificationReconciler` 和主 App 的 `TodoNotificationSync` 用的通知 identifier 规则一致吗?会不会同一条提醒排两份?
8. **完成后撤销**:主 App、小组件、Siri 三个入口完成待办后,已排的提醒是否都被撤掉?重复待办「完成今天这次」后,明天的还在吗?

### 4.3 P2:系统日历

**已知的结构(上一轮抽查结论)**

- 导入的日历事件不持有 `systemCalendarEventIdentifier`,删除待办不会删用户原有的事件。
- `SystemCalendarWriter.removeEvents` 用 `span: .futureEvents`(`App/SystemCalendarWriter.swift:152`)。
- 所有写操作经 `CalendarSyncService` 串行队列。

**检查点**

1. **整组删除**:删除一个重复待办,会删掉整个系列,连同用户在系统日历里手动改过的单次实例。这是期望行为吗?
2. **ID 失效**:EventKit 文档说事件换了所属日历后,ID「很可能改变」。ID 失效后,删除和替换都会走 `event_missing` 分支,留下孤儿事件。有没有用 `calendarItemIdentifier` 或其他字段兜底?
3. **替换的原子性**:`replace` 先删旧事件再写新事件,还是反过来?中间失败会不会出现两个都没有,或者两个都在?
4. **持久化回写**:`persistSystemCalendarResults` 回写事件 ID 失败时,下次同步会不会重复创建事件?
5. **权限撤销**:用户在系统设置里撤销日历权限后再编辑待办,会怎样?会报错打扰用户,还是静默跳过?
6. **跨进程**:小组件或 Siri 删除、修改待办时,日历事件何时同步?(与 4.1 第 8 条联动)

---

## 5. 执行约束

1. **先读后判**。上一轮出过错:只读了 `VoiceInputManager`,就断言「来电中断会丢转写」,其实 `AppCoordinator.savePartialTranscriptIfAny` 已经兜底。**每个结论都要追到所有调用方和兜底路径之后再下。**
2. **运行时行为改动必须真机验证**。审查环境里没有 Xcode,编译不了 Swift。所以:
   - 能用单元测试证明的问题 → 写失败的测试 + 修复。
   - 依赖系统行为的问题(SwiftData 跨进程、EventKit、通知调度)→ **只出结论和真机复现步骤,不改代码**。
3. **不扩大范围**。发现范围外的问题,记进 §6「范围外发现」,不要顺手修。
4. 改动提交到 `claude/pre-launch-review-jy86zk`,**不合入 main**;等人工编译和真机验证后再合。

---

## 6. 输出格式

每条发现一行表格,按严重度排序:

| # | 严重度 | 模块 | `文件:行号` | 问题(一句话) | 触发场景(具体输入 / 时序) | 置信度 | 处置 |
|---|---|---|---|---|---|---|---|
| 1 | 高 / 中 / 低 | P0 / P1 / P2 | | | | 已证实 / 推断 / 需真机 | 已修(commit)/ 待真机 / 不修(理由) |

严重度定义:

- **高**:用户数据丢失、错乱,或核心承诺(提醒)静默失效。
- **中**:可见的错误状态,但数据可恢复;或需要特定时序才会触发。
- **低**:体验瑕疵、日志或遥测口径问题。

表格之后附两部分:

- **真机验证清单**:每条「需真机」的发现给出复现步骤和预期结果。
- **范围外发现**:只列不修。
- §4 的每个检查点都要有结论,包括「不成立」的,不能跳过。
