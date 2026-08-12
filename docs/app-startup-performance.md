# 首次安装后冷启动 3–5 秒：根因分析与优化指引

> 状态：**待实施**。本文档是 code review 结论 + 实施指引，供接手者独立执行。
> 所有 `文件:行号` 引用基于 commit `a64f3f8`（"fix: 清理 Xcode 26 升级后的编译错误与警告"）。
> 实施前请先 `git log` 确认代码未大幅漂移；若行号对不上，以引用的**符号名**为准。
> 主要落点：`App/VoiceTodoApp.swift`、`App/AppCoordinator.swift`、`App/PermissionManager.swift`、
> `Voice/VoiceInputManager.swift`、`App/OnboardingView.swift`、`Store/TodoStore.swift`

---

## 1. 现象与度量口径

### 现象

App 每次**重新安装后的第一次**启动约 3–5 秒；同类 todo App 约 1 秒。第二次及以后启动不明显。

「只有首启慢」这个特征本身就是最重要的线索：它把嫌疑人限定在**只在首装发生一次**的开销上
（建库、建索引、首次 migration、首次跨进程握手、onboarding 路径），而不是每次都跑的代码。

### 先量，再改（第 0 步，不可跳过）

代码里**已经有现成埋点**，不需要新加：

| 埋点 | 位置 | 含义 |
|---|---|---|
| `app.init.finished durationMS=` | `App/VoiceTodoApp.swift:207` | `App.init()` 整段同步耗时 |
| `store.init.finished todoCount=` | `Store/TodoStore.swift:80` | `TodoStore` 建好（含 migration + 首次 fetch） |
| `app.storage.container_created` | `App/VoiceTodoApp.swift:110` | `ModelContainer` 建好 |
| `store.init.start previousMigration=` | `Store/TodoStore.swift:71` | 能看出首装是否真的跑了 migration |

**做法**：删 App → 重装 → 启动 → Console.app 按 subsystem 过滤上述日志。
拿到 `app.init.finished durationMS` 后，就能把总时长拆成两段：

- **`App.init()` 内的同步阻塞**（第 2.1 节）
- **首帧之后的动画等待**（第 2.3 节）——这段不体现在 `durationMS` 里，但用户全程在看

这一步决定第 3 节里 P0 各项的实际排序。**不要跳过它直接照着 P0 改**，否则无法验证收益。

### 两个必须遵守的测量纪律

1. **必须用 Release 或 TestFlight 构建**。当前 scheme（`project.yml` → `schemes.VoiceTodo.run`）是
   Debug 配置，`SWIFT_OPTIMIZATION_LEVEL: -Onone`，并且挂了 `storeKitConfiguration: VoiceTodo/Products.storekit`。
   从 Xcode 直接 Run 出来的启动时间本身就明显偏慢，**不能当基线**，更不能拿它跟别家 App Store 下载的
   Release 包对比。
2. **每次测前删 App 重装**。首装成本（建库、首次 migration、生成设备标识）只出现一次，
   第二次启动测不出来。

---

## 2. 根因：三层叠加

不是单点问题。三层里前两层是真实的主线程阻塞，第三层是纯粹的动画等待——第三层最容易被
误判成「App 卡住了」，而它恰恰是首启独有的。

### 2.1 第一层：`App.init()` 把十几个系统服务的初始化同步塞在首帧之前

`App/VoiceTodoApp.swift:33-210`。

关键背景：SwiftUI 的 `App.init()` 跑在 `UIApplicationMain` 内部、scene 连接**之前**。
这段时间屏幕上只有 `project.yml` 里配的那张纯色 LaunchScreen（`UILaunchScreen: UIColorName: AccentColor`）。
`init()` 每多花一毫秒，用户就多盯一毫秒的纯色屏。

按 `init()` 内的执行顺序：

| # | 位置 | 做了什么 | 为什么贵 |
|---|---|---|---|
| ① | `VoiceTodoApp.swift:59-135` | 创建 SwiftData `ModelContainer` | 首装要建 SQLite 文件、建表，并建 `Store/SwiftDataModels.swift:73` 声明的 5 个 `#Index`（`sortOrder` / `isCompleted` / `completedAt` / `dueDate` / `needsAIProcessing`） |
| ② | `VoiceTodoApp.swift:138` → `Store/TodoStore.swift:66-81` | `TodoStore` 初始化 | 首装时 `previousMigrationVersion`（`:70`）为 0 < `currentMigrationVersion` 1，**3 个 migration 全跑**：`purgeLegacyVoiceCaptureRecords`（`:792`）、`migrateOldSortOrder`（`:809`）、`migrateDueDatesFromHints`（`:833`），各一次全表 fetch；随后 `refreshTodos()`（`:79` → `:674`）再两次 fetch。**共 5 次主线程 SwiftData fetch**，且这是全进程第一次真正打开库 |
| ③ | `VoiceTodoApp.swift:156` → `App/EntitlementManager.swift:60-62` | `EntitlementManager()` 启动 `Transaction.updates` 常驻监听 | StoreKit 子系统初始化 |
| ④ | `VoiceTodoApp.swift:158` → `Voice/VoiceInputManager.swift:88-93` | 整套音频 / 语音栈：`AVAudioEngine()`（存储属性 `:63`）、`AudioSessionHelper()`（`:64` → `Voice/AudioSessionHelper.swift:14` 的 `AVAudioSession.sharedInstance()`）、`SFSpeechRecognizer(locale:)`（`:92`） | 三次跨进程握手（mediaserverd、语音守护进程），首启还要枚举本地识别资源。**而用户此刻根本还没按录音键** |
| ⑤ | `VoiceTodoApp.swift:164` → `Protocols/Constants.swift:56` | `NetworkClient` 默认参数触发 `proxyDeviceIdentifier` | 首装生成 UUID 并**同步**写 `UserDefaults`（plist 落盘） |
| ⑥ | `VoiceTodoApp.swift:177-183` → `App/AppCoordinator.swift:122-123` | 默认参数 `SystemCalendarWriter()` + `SystemCalendarReader()`，**各自建一个 `EKEventStore()`**（`App/SystemCalendarWriter.swift:75` / `App/SystemCalendarReader.swift:21`） | `EKEventStore` 初始化要连 calaccessd，是本表里单项最贵的之一，这里一次建了**两个** |
| ⑦ | `VoiceTodoApp.swift:191-201` → `App/LocalNotificationScheduler.swift:18` | `UNUserNotificationCenter.current()`，并在 `:199` 设 delegate | usernoted 跨进程 |
| ⑧ | `VoiceTodoApp.swift:205-206` | `BGTaskScheduler.register` + `submit` | 两次 duetd 跨进程调用 |
| ⑨ | `VoiceTodoApp.swift:209` → `Protocols/TelemetryQueue.swift:43` | `Telemetry.record(.appLaunch(...))` 入队 | `lock.sync` 内：读 App Group `UserDefaults` → JSON 解码 → trim → 编码 → 写回。同步磁盘往返 |

**还有一个不在 `init()` 里、但同样卡在首帧前的**：`VoiceTodoApp.swift:17` 的
`@StateObject private var permissionManager = PermissionManager()`。它的默认值在 body 首次求值时创建，
仍在首帧之前。`App/PermissionManager.swift:148-164` 的 init 里：

- `calendarPermissionClient: .live` → `App/PermissionManager.swift:86` 建**第 3 个 `EKEventStore()`**
- `checkCurrentStatus()`（`:164`）同步查 `AVAudioApplication.shared.recordPermission`、
  `SFSpeechRecognizer.authorizationStatus()`、`EKEventStore.authorizationStatus(for:)`

> **值得单独点出**：`CalendarPermissionClient.live`（`PermissionManager.swift:80-117`）里闭包捕获的那个
> `EKEventStore` 实例**只被 `requestAccess` 用到**。`status()`（`:88`）走的是静态方法
> `EKEventStore.authorizationStatus(for: .event)`，根本不需要实例存在。
> 也就是说这第 3 个 `EKEventStore` 在「用户从没点过日历开关」的首启路径上是纯浪费。

小结：**冷启动期一共建了 3 个 `EKEventStore`、1 套音频栈、1 个语音识别器，全都是用户在
onboarding 阶段一个都用不到的东西。**

### 2.2 第二层：首装专属的一次性成本

这层解释了「为什么只有第一次慢」：

- `ModelContainer` 建 SQLite 库 + 建 5 个 `#Index`（第 2.1 节 ①）——第二次启动是打开已存在的库
- 3 个 migration 全跑（②）——第二次启动 `previousMigrationVersion` 已是 1，整段跳过
- `proxyDeviceIdentifier` 生成 UUID 并写盘（⑤）——第二次启动直接命中 `UserDefaults` 缓存
- 系统首次为本 App 建立各守护进程连接、首次构建 dyld launch closure——第二次启动有缓存

第二次启动这些全部消失，剩下的只有 2.1 里那些「每次都跑」的项，所以感觉正常了。
**这不代表 2.1 不是问题**——它只是被首装成本盖过了，改掉它二次启动也会更快。

### 2.3 第三层：首启感知延迟约 1.2–1.5 秒，且全发生在进程已就绪之后

这层不体现在任何 `durationMS` 埋点里，但用户全程在等。**只有首启（未完成 onboarding）会走这条路。**

链路在 `App/VoiceTodoApp.swift:282-288`：

```
hasCompletedOnboarding == false
  → 首帧渲染的是 Color.clear（:284）          ← 用户看到空白
  → 靠 .onAppear 才把 showOnboarding = true（:287）
  → OnboardingView 以 sheet 形式上滑（:248）  ← 约 0.4s 系统弹层动画
  → sheet appear 后触发 animateContentIn()（App/OnboardingView.swift:162-165）
  → animateContentIn（:1386-1414）:
       先把 contentOpacity 归 0、illustrationScale 归 0.8（:1396-1399）
       Task.sleep(100ms)（:1402）→ 0.6s spring 弹插图（:1403）
       Task.sleep(100ms)（:1408）→ springEntrance 淡入正文（:1409）
```

三段**串行**叠加：空白帧 → 弹层上滑 → 内容淡入。粗算 0.4s + 0.2s sleep + 0.6s spring ≈ 1.2s 起，
而这全部发生在进程和数据都已经准备好之后——纯粹是把已经能显示的东西按住不显示。

第二次启动走 `HomeView(store:)`（`VoiceTodoApp.swift:280`）直连，没有这一段，
所以用户只在首启感受到它。

---

## 3. 修复方案

按投入产出排序。**每改一项就按第 1 节的方法重测一次**，避免堆改动却说不清哪项有效。

### P0 — 改动小、收益最大

#### P0-1　干掉冷启动期的 3 个 `EKEventStore()`

- `App/AppCoordinator.swift:122-123`：把 `systemCalendarWriter` / `calendarReader` 的默认参数从
  `SystemCalendarWriter()` / `SystemCalendarReader()` 改为 `nil`，内部改成 `lazy var` 持有；
  或改为注入工厂闭包（如 `@escaping () -> any SystemCalendarWritingProtocol`）。
  日历只在「写 todo 到系统日历」和「查时间冲突」时用得到，冷启动一次都不碰。
- `App/PermissionManager.swift:80-117`：把 `CalendarPermissionClient.live` 里闭包捕获的 `eventStore`
  改成惰性创建（只有 `requestAccess` 分支需要它）。`status()` 保持用静态方法，不要动。

**注意**：`calendarReader` 当前类型是 `(any SystemCalendarReadingProtocol)?`，已经是 Optional，
但默认值是具体实例。改默认值为 `nil` 时要确认现有「显式传 nil 表示禁用 reader」的语义没有调用方依赖——
如果有，就改用工厂闭包方案而不是 `nil` 方案。

#### P0-2　音频 / 语音栈改懒加载

`Voice/VoiceInputManager.swift`：`audioEngine`（`:63`）、`audioSessionHelper`（`:64`）改 `lazy var`；
`speechRecognizer`（`:92`）从 init 移出，首次 `startRecording()`（`:97`）时才建。

**注意**：`:110-121` 已有的 locale 轮换逻辑（用户在设置里改了识别语言就重建 recognizer）
**保持原样不要动**——它本来就在 `startRecording` 入口，懒加载后天然衔接。

#### P0-3　遥测挪出 `init()`

`App/VoiceTodoApp.swift`：把 `:206` 的 `scheduleNextRun()` 和 `:209` 的
`Telemetry.record(.appLaunch(...))` 移到 `handleAppLaunch()`（`:295`）里的 `Task { }` 中。

**注意**：`:205` 的 `registerBackgroundTask()` **必须留在 `init()`**。
`BGTaskScheduler.register` 要求在 scene 连接前完成注册，挪走会导致后台上报失效。
只有 `submit`（`scheduleNextRun`）可以延后——`scenePhase` 进 `.background` 时（`:336`）本来也会再调一次。

#### P0-4　首启不要走 `Color.clear` + sheet

这一项不减 CPU，但直接砍掉约 1 秒的感知等待，是四项里用户体感最明显的。

- `App/VoiceTodoApp.swift:282-288`：`hasCompletedOnboarding == false` 时**直接把 `OnboardingView`
  当根视图渲染**，不再走「空白占位 + `.onAppear` 触发 sheet」。
  `:248-258` 的 sheet 修饰符与 `:260-263` 的 `onChange(of: hasCompletedOnboarding)` 相应简化。
  注意保留 `:254-256` 那两个 `environmentObject` 注入的等价物——根视图渲染时它们由外层
  `:217-220` 提供，但要逐个核对 `OnboardingView` 依赖的 `entitlementManager` / `quotaUsage` 确实拿得到。
- `App/OnboardingView.swift:1396-1413`：`animateContentIn()` 的**首屏那次**直接给终态
  （和 `:1388-1394` 的 `reduceMotion` 分支一样），入场动画只保留给后续 `currentStepIndex`
  切换（`:174` 的 `onChange`）。

  实现上加一个 `@State private var hasAnimatedFirstStep = false` 门闩即可，
  别把 `reduceMotion` 分支改坏——那条是无障碍要求，必须继续生效。

### P1 — 收益次之，改动略大

#### P1-5　首装跳过 migration

`Store/TodoStore.swift:70-77`。全新库无数据可迁，3 次全表 fetch 纯属空转。
在 `ModelContainer` 建好后判断是否是全新库（例如 `AppGroupConfig.currentStoreMigrationVersion() == 0`
且库文件此前不存在），直接调 `AppGroupConfig.markStoreMigrationCompleted(version:)` 并跳过三个 migration。

**注意**：`init` 的 `forceMigration` 参数（`:65`，见 `:59-61` 的文档注释）是测试 seam——
in-memory DB 是新的但 `AppGroupConfig` 的 `UserDefaults` 跨测试持久，测试要靠它强制跑 migration。
新增的「全新库」判断**必须排在 `forceMigration` 之后**，不能把这个 seam short-circuit 掉。

> 相关背景：`docs/completed-todos-performance.md` §2 的 ⑤ 条目最早提出「三个 migration 无已执行标记」，
> 现在的 `currentMigrationVersion` 门闩就是那次的产物。本条是它的补充——门闩解决了「第二次以后」，
> 没解决「第一次」。

#### P1-6　`refreshTodos()` 挪出 `init()`

`Store/TodoStore.swift:79`。首帧不需要等数据——空列表先渲染、数据随后补入，比阻塞首帧划算。
交给 `UI/Home/HomeView.swift` 的 `.task` 触发，或复用已有的 `Store/TodoQueryActor.swift`
（`@ModelActor`，专为把重查询下沉到后台上下文而建，见其文件头注释）在后台装载。

**注意**：`refreshTodos()`（`:674-704`）内会同步 `lastSyncedExternalChangeVersion`（`:699`），
这是 `refreshIfStale`（`:710`）门闩的依据。挪动时保证首次装载仍会推进这个版本号，
否则回前台会多一次无谓全量 fetch。

#### P1-7　StoreKit 监听延后

`App/EntitlementManager.swift:60-62` 的 `Transaction.updates` 常驻监听改为首帧后再起。
`handleAppLaunch()`（`VoiceTodoApp.swift:301`）已经有 `Task { await entitlementManager.refresh() }`，
可以在那里一并启动监听。

---

## 4. 验证

### 基线与回归

删 App 重装 → Release 构建 → 跑 5 次 → 取 `app.init.finished durationMS` 的**中位数**（不是平均值，
首次启动方差大）。改动前后各测一轮。

### 端到端启动时长

```
xcrun xctrace record --template 'App Launch' \
  --device <udid> --launch -- com.qingqingyu.voicetodo
```

对比改动前后的 Total Launch Time。这个数才是用户真实感受的口径，
它把第 2.3 节那段「埋点里看不见的动画等待」也算进去了。

### 回归测试

跑 `VoiceTodoTests` + `VoiceTodoUITests`。懒加载类改动（P0-1 / P0-2）重点确认：

- UI 测试的 mock 注入路径仍生效：`UITestVoiceInputManager`（`VoiceTodoApp.swift:158` 分支）、
  `NoopNotificationScheduler`（`:189`）
- S16 日历权限拒绝路径（见 commit `0d475f3` "test(ui): 修 S12 容错边界 + 新增 S16 日历权限拒绝路径"）
  覆盖了 `EKEventStore` 懒加载后的行为，务必确认它仍通过

### 手工验证

1. 删 App 重装 → 完整走完 onboarding → 确认 P0-4 之后首屏内容立刻可见，没有空白帧
2. 进主界面 → 录音一次 → 确认懒加载的音频 / 语音栈能正常起来，**不丢首个音频帧**
   （这是 P0-2 唯一的真实风险：原本在 init 就预热好的东西改成首次录音时才建，
   要确认 `startRecording()` 里 `configureSession()` → `audioEngine.start()` 的顺序仍能拿到完整音频）
3. 打开设置改识别语言 → 再录一次 → 确认 locale 轮换（`VoiceInputManager.swift:110-121`）没被改坏
4. 添加一条带时间的 todo 并打开日历同步 → 确认 P0-1 之后 `EKEventStore` 能按需建起来、写入成功
