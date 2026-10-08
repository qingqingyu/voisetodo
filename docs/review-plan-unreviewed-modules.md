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

> **评审(2026-10-08,执行前)**:方案可执行,五问逐条回答见各节 `> 评审:` 块,汇总:
> ①范围成立,建议把「intent 写库入口 × 副作用收敛」当矩阵整体过(见 §3 后注);
> ②优先级依据同意,但模块优先级 ≠ 风险优先级(见 §3 后注);
> ③检查点三处需校准(见 §4 前注:时间戳同值不成立/一半答案在系统/一条是产品拍板题);
> ④「审查环境没有 Xcode」前提在本机不成立,约束已收紧执行(见 §5 后注);
> ⑤有两条更便宜的手段且已用上(忠实 mock / Port spy,见 §5 后注)。
> 本轮执行结果另见 `docs/review-findings-unreviewed-modules.md`。

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

> 评审:统计口径本身的局限(§2.1)已如实声明,认可。补充一条执行后回看的佐证:
> 覆盖率最低的 `DeleteTodoIntent`(0%)恰恰藏着真问题(删除不撤已排提醒,且其
> 「与主流程一致」的注释已过时——主 App 的 `AppCoordinator.deleteTodo:939` 实际
> 会清理日历事件)。低覆盖 = 线索的判断在本轮成立。

---

## 3. 范围与优先级

| 优先级 | 模块 | 为什么排在这里 |
|---|---|---|
| **P0** | 跨进程写库:`App/Intents/*` + `UI/Widget/*` + `Store/AppGroupModelContainerProvider.swift` | 主 App 之外的进程写**同一个** SwiftData 库。并发与可见性问题测试难覆盖,出事表现为数据错乱或丢失 |
| **P1** | 本地提醒:`Protocols/Domain/NotificationPlanner.swift` → `App/TodoNotificationSync.swift` → `App/LocalNotificationScheduler.swift`,以及 `App/Intents/IntentNotificationReconciler.swift` | 待办 App 的核心承诺。失效是**静默**的:提醒没响,用户事后才发现 |
| **P2** | 系统日历:`App/CalendarSyncService.swift` + `App/SystemCalendarWriter.swift` | 改的是用户自己的数据,出错不可撤销;但只有用户开启日历同步才会触达 |

不在范围:`HomeView.swift`(未审量最大,约 9000 行,但以 UI 布局为主,另起一轮)、`PromptTemplates`、`TelemetryUploader`(已抽查,转写已脱敏)。

> 评审(范围,§0-问1):范围判断成立——本轮三个可单测的实锤全部落在既定范围内
> (P2 replace 镜像丢失 / P1 Siri 新增不排提醒 / P1 Siri 删除不撤提醒)。
> 一处结构性建议:这三条本质是同一类问题——「intent 写库入口的副作用(通知/日历)
> 收敛」在方案里被拆到 4.1.8 / 4.2.8 / 4.3.6 三处,执行时容易只答其一。本轮按
> 矩阵补齐:4 个写库 intent(Add/Complete/Toggle/Delete)× 2 类副作用(通知/日历)。

> 评审(优先级,§0-问2):排序依据(跨进程不确定性最该先摸底)同意。但要给执行者
> 打个预防针:**模块优先级 ≠ 风险优先级**——P0 的 8 条检查点本轮多数落在
> 「需真机/不成立」,而 P1、P2 各挖出一条高危(静默失效)。别因为 P0 排最前就
> 预期问题也集中在 P0。

---

## 4. 检查点

每条都要回答「成立 / 不成立 / 无法从代码判断」,并附 `文件:行号` 作为证据。

> 评审(具体性,§0-问3):大部分检查点可对着代码回答,方案里引用的行号锚点
> (TodoStore.swift:938 / VoiceTodoApp.swift:329,355 / NotificationPlanner.swift:26 /
> SystemCalendarWriter.swift:152 / project.yml:171-172)经逐一核对**全部准确**。
> 三处需校准:
> (a) 4.1.3「同一毫秒写/时钟回拨」不成立——版本号是 Double 时间戳,亚微秒分辨率,
> 两进程取到同值概率可忽略;`!=` 比较对回拨也免疫。真正会漏检的是另一个窗口:
> `refreshTodos` 先 fetch 数据、后回读版本号(Store/TodoStore.swift:926),
> 外部写在 fetch 与回读之间提交会被「吸收」,主 App 漏看这次写直到下一次外部写。
> 本轮已按此修(进门快照版本号)。
> (b) 4.1.1 / 4.1.2 / 4.1.5 的答案一半在系统侧(SwiftData 跨进程可见性/合并语义),
> 代码层只能推到「无冲突检测、无行缓存、主 App 长生命周期 context 对已注册对象
> 的新鲜度未知」——这三条的正确产出是「需真机 + 复现步骤」,不要硬下结论。
> (c) 4.3.1「这是期望行为吗」是产品拍板题不是代码题,执行者只能给事实
> (删系列含用户改过的实例),不能替产品回答。

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

> 评审(约束,§0-问4):§5.2「审查环境里没有 Xcode」的前提**在本机不成立**
> (xcodebuild / swift 6.3.3 / xcodegen 齐备,单元测试可跑,本轮已跑通过)。
> 据此把约束收紧为三级:
> ①纯逻辑/组合问题 → 单测证明 + 修复(本轮 4 个修复全属此类);
> ②模拟器可验的(EventKit 写读逻辑)→ 可加模拟器冒烟;
> ③真机跨进程行为(Widget/Siri 进程调度、通知真实触发、SwiftData 多进程合并)→
> 维持「只出结论 + 复现步骤,不改代码」。
> 「不经真机验证不合 main」维持不变。

> 评审(更省手段,§0-问5):有两条,本轮均已用上:
> ①**忠实 mock**——P2 最高危的 replace 镜像丢失之所以测试全绿,是因为
> `CalendarSyncTestWriter` 没有复刻真实 writer 的 `systemCalendarEventIdentifier == nil`
> 过滤(SystemCalendarWriter.swift:87)。把 mock 改忠实后,现有 replace 测试
> 立刻变红、修复后复绿。建议沉淀为约定:**测真实实现的过滤/钳制时,mock 必须同步
> 复刻,否则测试在验证一个不存在的系统**。
> ②**Port spy**——`IntentNotificationReconciler` 已有可注入的 `UNNotificationPort`
> spy 测试模式,新增 intent 侧通知行为直接补 spy 测试即可,不必真机。

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
