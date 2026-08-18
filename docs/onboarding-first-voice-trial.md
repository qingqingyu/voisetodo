# Onboarding 首次语音试用引导（First Voice Trial）

> 状态：待实现（**动工前须先按 §6.1 / §6.2 修订 3.4d / 3.4g**）
> 分支：`claude/todo-voice-transcription-onboarding-qhuyx3`
> 评审：2026-08-18 完成，质疑与判定见 §6
> 本文档是可直接执行的实施说明，行号基于本文档写作时的代码状态（`3a7e225`）。
> 实施前请先核对行号是否漂移；文件路径和逻辑描述以实际代码为准。

---

## 1. 背景与问题

### 1.1 用户拿到了权限，却从没用过一次

现有 onboarding（`App/OnboardingView.swift`）共 7 步：

```
welcome → voicePermissions → speechLanguage → calendarSync → actionButton → proPaywall → completion
```

`voicePermissions` 那一步（`OnboardingView.swift:515`）把麦克风和语音识别两个权限都拿到了，
`completion` 那一步（`:1288`）放三条静态 tip，然后按钮文案是 `onboarding.button.start`（「开始使用」），
点完 `hasCompletedOnboarding = true`，sheet 关闭，用户被丢进主页。

问题就在这里：**用户授权了，但从没实际录过一次**。他不知道右下角那个悬浮麦克风按钮是干什么的，
也没体验过「说一句话 → 变成待办 → 出现在今天清单里」这个核心闭环。
首次留存靠的就是这一下，而现在这一下完全交给用户自己去撞。

### 1.2 好消息：闭环已经完整存在，不需要重造

「转写成功后自然而然出现在当天清单里」这条链路**已经全部实现了**：

`ConfirmSheet` 确认 → `AppCoordinator.confirmTodos()`（`App/AppCoordinator.swift:600`）写
`pendingRevealTodoIDs` → `HomeView` 的 `.sheet(onDismiss: revealConfirmedTodos)`（`UI/Home/HomeView.swift:441`）
→ `revealConfirmedTodos()`（`:911`）做了：

- 按 rank 错峰 0.06s 的卡片入场动画（封顶 rank 8）
- 底部 toast（`presentAddedToast`，`:973`）
- 今日进度条数字 pop（`confirmPopToken`）
- 而且**已经区分了三类落点**：`onDayIds` / `unscheduledIds` / `elsewhere`

所以本次改动**不碰录音、转写、AI 抽取、确认、落库任何一条链路**。
只新增「把用户推到那一下点击」的引导层，外加一个成功时刻的庆祝反馈。

### 1.3 为什么不把录音器嵌进 onboarding sheet

`App/VoiceTodoApp.swift:270-290` 的 `mainView`：

```swift
if let startupStorageError { StartupStorageErrorView(...) }
else if hasCompletedOnboarding { HomeView(store: todoStore) }
else { Color.clear.onAppear { showOnboarding = true } }
```

onboarding 是挂在 `Color.clear` 之上的 sheet（`VoiceTodoApp.swift:248`），
**`hasCompletedOnboarding == false` 时 `HomeView` 根本没被渲染**。

要在 sheet 内跑一次真实录音，得把 `AppCoordinator` / `TodoStore` / `ConfirmSheet` / reveal 动画
整套搬进 onboarding；而需求里「展现在他当天**实际的** To Do List 那一项里面」这句话，
最终仍然必须关掉 sheet 才看得到。

结论：**交棒到真实主页**，在主页上做教练提示（coach mark），复用全部现有链路。

### 1.4 已拍板的三个产品决策

| 决策点 | 选择 | 理由 |
|---|---|---|
| 触发方式 | 高亮 `VoiceFAB`，等用户自己点 | 真正教会「以后从哪里录」。且用户有心理准备再开口，不会被 1.5s 静音自动提交（`Voice/VoiceInputManager.swift:704`）截成空转写 |
| 提示持久性 | 一直提醒到首次成功录一条，同时给显式「知道了」关闭入口 | 比 `ExpandMonthHintView` 的「一次性 4.5s 后永久落盘」语义更强——这是激活的关键动作，没看懂的用户应该还有机会 |
| 跨日兜底 | 庆祝 toast 改文案 + 带「去看看」跳转 | `revealConfirmedTodos` 已经算出了 `elsewhere`；toast modifier 已支持 `actionTitle` / `action`（`UI/Shared/ToastView.swift:237-256`） |

**明确不做**：自动展开面板、自动开始录音。也不复用 Action Button 的
`coordinator.pendingIntentRecordingLaunch` 通路。

---

## 2. 总体流程

```
onboarding completion 页
  按钮「去试一句」
  ↓  hasCompletedOnboarding = true
  ↓  firstVoiceTrialState = armedState(权限齐?) → .pending / .dismissed
  ↓
sheet 关闭 → HomeView 挂载
  ↓  0.4s 后（可取消 Task）
FAB 上方浮出 FirstVoiceTrialHintView
  「试着说：今晚八点给妈妈打电话」  [知道了]
  ↓  用户点 RecordFAB（走完全现有路径 openVoiceInputPanel）
录音 → 转写 → AI 抽取 → ConfirmSheet 确认
  ↓  onDismiss → revealConfirmedTodos()
  ↓  firstVoiceTrialState → .completed，hint 消失
待办错峰入场到今天分组 + 庆祝 toast
  落今天 → 「太棒了！已经记在你今天的清单里」
  落别日 → 「已记到 X 月 X 日」 [去看看] → 切 calendar tab + selectDay
```

---

## 3. 实施步骤

### 3.1 新增状态机 `Protocols/Domain/FirstVoiceTrial.swift`（新文件）

按项目惯例（对照 `Protocols/CalendarWriteMode.swift`、`Voice/SpeechRecognitionLanguage.swift`）
做成 `String` enum + `storageKey`；判定逻辑做成**静态纯函数**以便单测
（对照 `App/VoiceTodoApp.swift:419` 的 `ModelContainerStartupPolicy`、
`Protocols/Domain/WidgetTodoFilter.swift` 的同款模式）。

```swift
/// 首次语音试用引导的状态。onboarding 结束时 arm，用户完成第一条语音待办后终结。
///
/// 存 UserDefaults（key: `firstVoiceTrialState`），跟随
/// `@AppStorage("hasCompletedOnboarding")` / `@AppStorage("hasShownExpandMonthHint")`
/// 的既有模式，不引入新命名空间。
enum FirstVoiceTrial: String {
    /// 默认值：onboarding 还没走完（或老用户升级上来）。
    case notArmed
    /// 已 arm，等用户完成第一条语音待办。仅此状态显示 hint。
    case pending
    /// 用户点了「知道了」主动关闭。终态。
    case dismissed
    /// 首次语音待办已落库。终态。
    case completed

    static let storageKey = "firstVoiceTrialState"

    /// onboarding 结束时决定初始状态。
    ///
    /// 权限没拿齐时直接给 `.dismissed` 而非 `.pending`：**不叠加两层引导**——
    /// 跳过权限的用户已经由 `UI/Shared/VoicePermissionRepromptSheet.swift` 在点 FAB
    /// 时接管（触发条件见 `HomeView.startRecordingForInputPanel()` 的
    /// `permissionManager.hasSkippedInOnboarding` 分支）。两个引导同屏会互相打架。
    static func armedState(allPermissionsGranted: Bool) -> FirstVoiceTrial {
        allPermissionsGranted ? .pending : .dismissed
    }

    /// 是否应该显示 hint。终态和未 arm 都不显示。
    var showsHint: Bool { self == .pending }

    /// 确认了一批待办之后的状态推进。幂等：终态和空批次原样返回。
    static func nextState(current: FirstVoiceTrial, didConfirmTodos: Bool) -> FirstVoiceTrial {
        guard current == .pending, didConfirmTodos else { return current }
        return .completed
    }
}
```

> 注意：`@AppStorage` 直接绑 `String` raw value（项目现有做法，见
> `OnboardingView.swift:49-54` 的 `speechLanguageRaw` / `calendarWriteModeRaw`），
> 不要绑 enum 本身。

### 3.2 Onboarding 交棒 — `App/OnboardingView.swift`

**a) `completionStep`（`:1288`）文案改写**

从「都设置好了 + 三条 tip」改成「最后一步：试着说一句」+ 一条示例台词。
`celebrationIllustration` 保留。三条 `tipRow` 收敛成一条突出的示例台词卡片。

**b) `buttonTitle`（`:1469`）**

```swift
case .completion:
    return String(localized: "onboarding.button.try_voice")  // 原 onboarding.button.start
```

**c) `nextStep()`（`:1503`）落盘 arm 状态**

现有代码：

```swift
if currentStepIndex == totalSteps - 1 {
    hasCompletedOnboarding = true
}
```

改为在置位的同时写入 trial 状态。新增一个 `@AppStorage(FirstVoiceTrial.storageKey)`
属性到该 View，与 `speechLanguageRaw` / `calendarWriteModeRaw` 并列声明：

```swift
firstVoiceTrialRaw = FirstVoiceTrial
    .armedState(allPermissionsGranted: permissionManager.allPermissionsGranted)
    .rawValue
hasCompletedOnboarding = true
```

> ⚠️ **小屏高度预算是硬约束。** 该文件有一整套 `contentFits` 机制
> （`OnboardingView.swift:98-111`）和 DEBUG 下暴露给 UI 测试的 a11y 钩子
> `OnboardingContentFits`，test_S17 会断言 iPhone SE 上 completion 页一屏装得下。
> 新增/改写的每一个 `Text` 都必须沿用现有写法：`lineLimit(...)` +
> `minimumScaleFactor(≥0.7)` + `isCompact` 分支。改完必须重跑 test_S17。

### 3.3 新组件 `UI/Home/FirstVoiceTrialHintView.swift`（新文件）

直接对照 `UI/Home/ExpandMonthHintView.swift` 写——它是本仓库**唯一**的 coach-mark 先例，
结构照搬：

- `TimelineView(.animation)` 驱动无缝循环动画，`phase` 用 `truncatingRemainder`
- smoothstep 缓动 `phase * phase * (3 - 2 * phase)`
- 「早进晚出」淡出曲线
- 所有魔数收敛到同文件底部的 `FirstVoiceTrialHintMetrics` enum
- 顶部文档注释写清「纯视觉组件，触发条件与持久化由调用方 `HomeView` 决定」

**三处刻意的差异：**

1. **不自动超时。** `ExpandMonthHintView` 用 `.task { sleep; onDismiss() }` 做 4.5s 自动消失；
   本 hint 的生命周期由 `HomeView` 的 eligible 条件控制，**不要加自动 dismiss**
   （决策 1.4 第二行）。
2. **无障碍必须可达。** `ExpandMonthHintView` 是 `accessibilityHidden(true)`，
   因为 VoiceOver 用户有 `WeekStripCard.accessibilityAction(named: "a11y.action.expand_month")`
   这条替代路径。本 hint 承载真实信息 + 一个「知道了」按钮，**没有替代路径**，
   所以必须 `accessibilityElement(children: .contain)` + `accessibilityLabel`，
   「知道了」按钮独立可达。
3. **动画方向朝下**（指向下方的 FAB），而非 `ExpandMonthHintView` 的下拉手势示意。

**接口：**

```swift
struct FirstVoiceTrialHintView: View {
    let onDismiss: () -> Void   // 「知道了」
}
```

**内容**：一句引导语 + 一句示例台词（写死引向今天，如「试着说：今晚八点给妈妈打电话」）
+ 一个小号「知道了」文字按钮。视觉沿用 `WarmTheme` / `WarmFont` / `WarmSpacing`
（`UI/Shared/DesignSystem.swift`）。

**a11y id**：容器 `FirstVoiceTrialHint`，按钮 `FirstVoiceTrialGotItButton`。

### 3.4 `UI/Home/HomeView.swift` 接线

**a) 新增状态**（加在 `hasShownExpandMonthHint` 那组附近，约 `:256-266`，
沿用同样的注释密度）：

```swift
// MARK: - 首次语音试用引导(FirstVoiceTrialHintView)
@AppStorage(FirstVoiceTrial.storageKey)
private var firstVoiceTrialRaw = FirstVoiceTrial.notArmed.rawValue
@State private var showFirstTrialHint = false
@State private var firstTrialHintTask: Task<Void, Never>?
```

toast 需要的两个新 state（加在 `addedToastToken` 旁，`:314-316`）：

```swift
@State private var addedToastActionTitle: String?
@State private var addedToastAction: (() -> Void)?
```

**b) 挂载**：在现有 FAB 的 `.overlay(alignment: .bottom)`（`:407-421`）内，
与 `VoiceFAB` 同一层，用 `offset` 把 hint 顶到 FAB 上方。

> 该处已有注释说明 overlay 挂载顺序：FAB 先挂、`inputPanelOverlay`（`:423`）后挂，
> 后挂的层级更高。所以面板打开时天然盖住 hint，**不需要额外处理**。

**c) 触发条件**（仿 `isExpandHintEligible`，`:1615`，集中成一个 computed property）：

```swift
private var isFirstTrialHintEligible: Bool {
    firstVoiceTrialRaw == FirstVoiceTrial.pending.rawValue
        && selectedBottomTab == .today
        && !showInputPanel
        && !coordinator.showConfirmSheet
        && !isInputEntryDisabled          // :273
}
```

**d) 调度**：沿用 `evaluateExpandHintTrigger()`（`:1584`）那套
「可取消 `Task` + sleep 后二次 `guard eligible`」的写法，延迟 ~0.4s 让主页先渲染完。

> **不要用 `DispatchQueue.main.asyncAfter`** —— `:1575-1583` 有整段注释说明为什么必须用
> 可 cancel 的 `Task`。同样要在 `.onDisappear`（`:548`）里 cancel 并置 nil，
> 与现有 `hintTriggerTask` 并列。

**与 `ExpandMonthHint` 的一个关键区别**：`evaluateExpandHintTrigger` 在**展示时**就
`hasShownExpandMonthHint = true` 落盘。本 hint **不在展示时落盘**——
落盘只发生在「完成」或「知道了」两个终点。

**e)「知道了」**：写 `firstVoiceTrialRaw = FirstVoiceTrial.dismissed.rawValue`，
`withAnimation` 收起 hint。

**f) 完成钩子**：在 `revealConfirmedTodos()`（`:911`）里，拿到非空 `ids` 之后：

```swift
let wasFirstTrial = (firstVoiceTrialRaw == FirstVoiceTrial.pending.rawValue)
firstVoiceTrialRaw = FirstVoiceTrial.nextState(
    current: FirstVoiceTrial(rawValue: firstVoiceTrialRaw) ?? .notArmed,
    didConfirmTodos: !ids.isEmpty
).rawValue
```

把 `wasFirstTrial` 传给下面的 `presentAddedToast`。

> 口径说明：这里判定的是「确认了一批待办」，不区分语音还是键盘输入。
> 引导语明确指向语音，绝大多数情况就是语音；用键盘完成也算通过引导，
> 不值得为这个边界再拉一条 source 判定链路。

**g) 庆祝 toast**：给 `presentAddedToast(for:todosById:dayStart:)`（`:973`）
加一个 `celebrate: Bool` 参数：

- `celebrate == false` → **完全维持现状**，走 `home.added_toast %lld` /
  `home.added_toast.elsewhere %lld %lld`，并把 `addedToastActionTitle` /
  `addedToastAction` 置 nil。
- `celebrate == true` 且 `onSelectedDay > 0` → `home.added_toast.first_trial`
  （「太棒了！已经记在你今天的清单里」），无 action。
- `celebrate == true` 且**全部落别日**（`onSelectedDay == 0`）→
  `home.added_toast.first_trial_elsewhere`（「已记到 X 月 X 日」，日期取第一条
  `elsewhere` 的 `dueDate`）+ `addedToastActionTitle = home.added_toast.go_look`，
  action 内：

  ```swift
  selectedBottomTab = .calendar
  selectDay(thatDueDate)      // :1621
  ```

  （today tab 的 `.onChange` 会 `jumpToToday()` 把日期拽回今天，`:496-500`，
  所以跨日跳转必须切到 calendar tab。）

最后把两个新 state 传进现有的 `.toast(...)` 调用（`:447-456`）——
modifier 已经支持 `actionTitle` / `action` 两个参数（`UI/Shared/ToastView.swift:237-256`），
不需要改 ToastView。

### 3.5 遥测 `Protocols/Telemetry.swift` + `TELEMETRY.md`

新增事件：

```swift
/// A6: 首次语音试用引导进度。onboarding→激活的转化漏斗，
/// 没有它这个功能的效果完全不可观测。
case firstVoiceTrial(stage: String)
```

- `name` → `"first_voice_trial"`
- `params` → `["stage": stage]`
- stage 取值：`armed` / `hint_shown` / `dismissed` / `completed`

埋点位置：`armed` 在 `OnboardingView.nextStep()`；其余三个在 `HomeView`
对应的状态迁移处。

按该文件的既有硬约定：**params 里不允许出现任何文本原文**（转写、标题、示例台词都不能带）。
同步补 `TELEMETRY.md` 的事件表。

### 3.6 本地化 `Resources/Localizable.xcstrings`

新增 key（zh-Hans + en 双语；`project.yml` 里 `developmentLanguage: en`，
`knownRegions: Base / zh-Hans / en`）：

| Key | 用途 |
|---|---|
| `onboarding.button.try_voice` | completion 页按钮「去试一句」 |
| `onboarding.done.trial_title` | completion 页标题 |
| `onboarding.done.trial_desc` | completion 页副文案 |
| `home.first_trial.hint` | hint 引导语 |
| `home.first_trial.example` | hint 示例台词 |
| `home.first_trial.got_it` | hint「知道了」 |
| `home.added_toast.first_trial` | 庆祝 toast（落今天） |
| `home.added_toast.first_trial_elsewhere` | 庆祝 toast（落别日，带日期占位符） |
| `home.added_toast.go_look` | toast action「去看看」 |
| `a11y.first_trial.hint` | hint 的 VoiceOver label |

若 `onboarding.button.start` 和被删掉的 tip key（`onboarding.tip1/2/3`）不再被任何地方引用，
**一并清掉**——本仓库刚做过一次「清理 xcstrings 死键」的提交（`3a7e225`），保持这个卫生习惯。

### 3.7 测试支持与测试

**a) `App/VoiceTodoApp.swift:44-53` 的 `resetUserData` 分支**
把 `firstVoiceTrialState` 加进 `removeObject` 列表，和 `hasCompletedOnboarding`、
`hasShownExpandMonthHint` 并列。否则 UI 测试重置后拿不到干净的首次状态。

**b) 单测**（`VoiceTodoTests/`）
`FirstVoiceTrial` 的纯函数：

- `armedState(allPermissionsGranted: true)` → `.pending`
- `armedState(allPermissionsGranted: false)` → `.dismissed`
- `nextState(current: .pending, didConfirmTodos: true)` → `.completed`
- `nextState(current: .pending, didConfirmTodos: false)` → `.pending`（空批次不推进）
- `nextState(current: .completed / .dismissed / .notArmed, didConfirmTodos: true)` → 原样（幂等）

**c) UI 测试**（`VoiceTodoUITests/`）
`--ui-testing --reset-user-data` 启动 →走完 onboarding（含授权）→
断言 `FirstVoiceTrialHint` 存在 → 点 `RecordFAB`
（`UITestVoiceInputManager` 提供 mock transcript，见 `App/UITestSupport.swift` +
`Protocols/UITestLaunchOptions.swift:57` 的 `mockTranscript`）→ 确认 ConfirmSheet →
断言 hint 消失、待办出现在今天分组。

反例用例：`--mic-permission-denied` 走完 onboarding → 断言 `FirstVoiceTrialHint`
**不存在**（应走原有 `VoicePermissionRepromptSheet` 路径）。

**d) 回归**
重跑 onboarding 布局测试 test_S17（断言 `OnboardingContentFits`）。

### 3.8 无需改动

`project.yml` 不用动——两个新文件分别落在 `Protocols/Domain/` 和 `UI/Home/`，
两个目录都已在 `targets.VoiceTodo.sources` 的目录级条目里，XcodeGen 会自动收。

（`.xcode_main_app_files.txt` 是一份**已经过期**的说明清单——它里面还列着并不存在的
`App/ServiceContainer+VoiceTodo.swift`——不是构建输入，不用改。）

---

## 4. 改动文件清单

| 文件 | 类型 | 说明 |
|---|---|---|
| `Protocols/Domain/FirstVoiceTrial.swift` | 新增 | 状态机 + 纯函数判定 |
| `UI/Home/FirstVoiceTrialHintView.swift` | 新增 | coach-mark 视图 |
| `App/OnboardingView.swift` | 改 | completion 页文案 + 按钮 + `nextStep()` 落盘 arm |
| `UI/Home/HomeView.swift` | 改 | state / 挂载 / 触发条件 / 调度 / 完成钩子 / 庆祝 toast |
| `App/VoiceTodoApp.swift` | 改 | `resetUserData` 清新 key |
| `Protocols/Telemetry.swift` | 改 | `firstVoiceTrial(stage:)` 事件 |
| `Resources/Localizable.xcstrings` | 改 | 10 个新 key，清理死键 |
| `TELEMETRY.md` | 改 | 事件表补一行 |
| `VoiceTodoTests/...` | 新增 | 状态机单测 |
| `VoiceTodoUITests/...` | 新增 | 正例 + 权限被拒反例 |

**不改动**：`Voice/`、`Extractor/`、`Store/`、`App/AppCoordinator.swift`、
`App/TranscriptProcessingFlow.swift`、`UI/ConfirmSheet/`、`UI/Shared/ToastView.swift`。

---

## 5. 验收

### 5.1 构建与自动化

```bash
./prepare_xcode_project.sh      # 或 xcodegen
xcodebuild test -scheme VoiceTodo \
  -destination 'platform=iOS Simulator,name=iPhone SE (3rd generation)'
```

SE 是 onboarding 高度预算最紧的机型，test_S17 必须过。

### 5.2 手工冒烟

> 模拟器缺 Siri asset 时语音会 fallback 到键盘模式（`HomeView.swift:516`），
> 建议用真机验证正例。

**正例：**

1. 删除 App 重装 → 走完 onboarding 并授权 → 点「去试一句」
2. sheet 关闭后，主页 FAB 上方浮出 hint
3. 点 FAB → 说「今晚八点给妈妈打电话」→ 确认
4. 待办错峰入场到今天分组，庆祝 toast 弹出，hint 消失
5. 杀掉 App 重启 → hint 不再出现

**反例：**

| # | 场景 | 期望 |
|---|---|---|
| 1 | 重装 → onboarding 里跳过语音权限 | 主页**不出现** hint，点 FAB 走原有 `VoicePermissionRepromptSheet` |
| 2 | 重装 → 走完 onboarding → 直接点「知道了」→ 杀掉重启 | hint 不再出现 |
| 3 | 引导中说「下周三去银行」 | toast 显示「已记到 X 月 X 日」+「去看看」，点击跳到 calendar tab 的那一天 |
| 4 | 引导中开始录音后取消（不确认） | hint 仍在，状态仍是 `.pending` |
| 5 | 老用户（已 `hasCompletedOnboarding`）升级安装 | 状态是 `.notArmed`，**不出现** hint |
| 6 | 引导中切到 calendar tab | hint 隐藏；切回 today tab 后重新出现 |

---

## 6. 评审质疑与判定（2026-08-18）

> 实施前评审记录。原文引用的行号/事实已逐一复核，全部属实：`revealConfirmedTodos`
> （HomeView.swift:911）、`presentAddedToast`（:973）、`isInputEntryDisabled`（:273）、
> `evaluateExpandHintTrigger`（:1584）、Toast `actionTitle/action`（ToastView.swift:246-247）、
> `resetUserData`（VoiceTodoApp.swift:44-53）、`mockTranscript`（UITestLaunchOptions.swift:55）、
> test_S17 / `OnboardingContentFits` 钩子均存在且语义一致。
>
> 分级：**P1 = 照原文实施必出问题，先修文档再动工**；P2 = 产品口径需拍板或补说明；
> P3 = 低成本补丁。§1-§5 原文保持不动，修订以本节「判定」为准。

### 6.1 [P1·必修] 3.4d 调度触发点不完整——hint 可能永远不出现

**质疑**：方案说「沿用 `evaluateExpandHintTrigger()` 那套写法」，但那套的 evaluate
只挂在 `.onChange(collapseProgress)` / `.onChange(selectedBottomTab)`
（HomeView.swift:1470-1475），**没有 `.onAppear`**。ExpandHint 无妨——它要
calendar tab + 折叠态才 eligible；而 FirstTrial hint 在 HomeView 挂载那一刻
eligible 即为真（today tab / 无面板 / 无 confirm sheet），照搬写法不补自己的调用点，
挂载后没有任何事件会触发它。且验收反例 4（「录音后取消 → hint 仍在」）依赖
`onChange(showInputPanel)` 重新评估，而现有该钩子（HomeView.swift:505-515）
只清 keyboardHeight，不碰任何 hint 状态。

**判定（修订 3.4d）**：必须明确列出 FirstTrial 自己的触发集，不能只写「沿用」：

- `.onAppear`（onboarding sheet 关闭 → HomeView 首次挂载）
- `.onChange(selectedBottomTab)`（反例 6：切回 today 重现）
- `.onChange(showInputPanel)`（反例 4：面板取消后重现）
- `.onChange(coordinator.showConfirmSheet)`（confirm sheet 关闭且未确认时重现）
- `scenePhase` 退后台仿 :1476-1487 取消挂起任务；本 hint **不在展示时落盘**，
  回前台重新评估即可重现，与 ExpandHint 的「展示即永久消失」语义不同。

### 6.2 [P1·必修] 3.4g 庆祝分支把三分类落点压扁成两类

**质疑**：`presentAddedToast` 现有逻辑（HomeView.swift:987-997）对 mixed batch 有
分流文案「N 条 + M 条在其他日期」。`celebrate == true && onSelectedDay > 0` 会整段
替换它——首次试用说「明早九点开会，下周三去银行」，落别日那条**没有任何反馈**，
而新用户恰恰最不懂「落别日」是什么。另有口径瑕疵：无 dueDate 的「稍后」条目计入
`onSelectedDay`（:985），toast 却说「记在你今天的清单里」，语义不符。

**判定（修订 3.4g）**：celebrate 分支不替换分流逻辑，而是在其上叠加：

- 落今天 + 无别日条目 → `home.added_toast.first_trial`（纯庆祝）
- 含别日条目 → 庆祝语义保留 + 分流信息保留（扩展 `first_trial_elsewhere`
  的占位符或追加第二行，不吞「M 条在其他日期」）
- 含「稍后」（无 dueDate）条目 → 庆祝文案不指认「今天」（「已经记在你的清单里」），
  或 celebrate 判定先排除无日期条目

### 6.3 [P2·待拍板] paywall 仍在 wow 之前

**质疑**：onboarding 顺序 `… → proPaywall → completion →（关 sheet）→ 首次语音`，
付费墙在用户第一次体验「说一句话变待办」之前，与 GTM 软启动「wow 必须在
paywall 前」的既定原则相悖。本方案未触碰该结构，还把 completion 页从终点变成
「再走一步」的漏斗，paywall 转化更依赖文案而非体验。

**判定（建议）**：结构性重排（试用提前到 paywall 步之前）牵动 HomeView 挂载时序，
超出本方案「不碰链路」的边界，**本期不做**；但 A6 遥测必须可与 paywall 步转化
交叉分析——`firstVoiceTrial` 各 stage 的时间戳要能对上 paywall 步的展示/跳过行为，
否则无法评估「paywall 提前造成的流失」。是否重排留待软启动数据决策。

### 6.4 [P2·补观察项] `dismissed` 终态的吞激活风险

**质疑**：「知道了」一点即永不重提（终态）。若 dismissed 率高，说明显式出口
在吞激活，需要二次 arm 策略（如 N 天后重新 pending）。

**判定**：不改终态语义（已拍板），但把 dismissed 率列为本功能上线后的**必盯指标**
（`first_voice_trial(stage=dismissed)` / `stage=armed` 的比值），写入 5.2 验收
与 TELEMETRY.md 的观察项。

### 6.5 [P2·补口径] `completed` 混入键盘输入，遥测口径没写破

**质疑**：完成钩子不区分语音/键盘（3.4f 口径说明），而 `todoSaved(source:)` 已有
source 维度，`firstVoiceTrial(stage: completed)` 不带——漏斗会高估「语音激活」。

**判定**：接受不为边界拉 source 判定链路的拍板，但 TELEMETRY.md 事件表须写明
口径限制：分析侧靠 `todo_saved(source:)` 与 `first_voice_trial(stage=completed)`
的时序关联还原真实语音激活率，不能直接拿 completed 当语音激活数。

### 6.6 [P3·补反例] eligible 不查当前权限

**质疑**：arm 后用户去系统设置关掉麦克风，hint 照弹；点 FAB 走
`performRecordingWithPermissionCheck()`——reprompt 分支的条件是
`hasSkippedInOnboarding && !allPermissionsGranted`
（HomeView.swift:1864，startRecordingForInputPanel），此场景 `hasSkippedInOnboarding`
为 false，不会弹二次引导。反例清单未覆盖。

**判定**：不加 eligible 权限检查（低频场景，reprompt 语义是「onboarding 跳过者」
专属，不扩大），但 5.2 反例表补一行：「arm 后到系统设置关闭麦克风 → 重启 app →
hint 仍出现，点 FAB 走系统权限失败路径，行为与无引导时一致、不引入新状态」。

### 6.7 [P3·补规格] 小屏遮挡无验收项；3.3 缺文本布局硬规则

**质疑**：hint（两行文本 + 按钮）比先例 ExpandMonthHint（纯 icon 动画）遮挡大，
挂在 FAB 上方会盖住列表末行操作区。3.3 没像 3.2 那样显式要求 `lineLimit` +
`minimumScaleFactor(≥0.7)`——这是仓库级文本布局硬规则（见根 CLAUDE.md）；
手工冒烟无 SE 检查项。

**判定**：3.3 补硬规则——hint 内所有 `Text` 必须 `lineLimit` +
`minimumScaleFactor(≥0.7)`，按 AX 大字号 + 中英长文本双验证；5.2 手工冒烟补
「SE 上 hint 不遮列表末行可操作区、长文本不截断不意外换行」。

### 6.8 [P3·挂账] 新 key 无 ja 本地化

**质疑**：xcstrings 现状 en 592 / zh-Hans 591 / ja 仅 48 键。新 10 个 key 只做
zh+en 与全库现状一致，但 MVP 语言范围拍板是 zh+en+ja——这批 key 是首启体验
文案，ja 上线时是最显眼的英文 fallback 区。

**判定**：本方案维持 zh+en（与全库现状一致，不单独拔高），在 MVP 日文上线
checklist 挂账：`onboarding.button.try_voice` 等 10 个新 key 必须补 ja。
