# Onboarding 首次语音试用引导（First Voice Trial）+ 付费墙后置

> 状态：**待实现，两轮评审已全部闭环，可动工**——但须先看 §3.10 的跨分支合并顺序
> 分支：v1–v2 走 `claude/todo-voice-transcription-onboarding-qhuyx3`；v3 起直接落 `main`
> 版本：v3（2026-08-18）。历史：v1 评审 8 项 → §6；v2 评审 4 项 → §7。
> 本文档是可直接执行的实施说明，行号基于代码状态 `3a7e225`。
> 实施前请先核对行号是否漂移；文件路径和逻辑描述以实际代码为准。

**v3 相对 v2 的变化**（全部来自第二轮评审 §7 的闭环，正文即最终规格）：

1. **§1.5 新增「与 `:33` 的偏差承认」** —— 弹点选 A（wow 后立即弹），
   与 `PROMOTION_PLAN.md:33` 写的「第 2 次撞墙后弹」不一致，理由写明。
2. **§3.5c 新增 paywall 曝光遥测**，四来源可区分。评审提三种，实际代码有
   **四个** `showPaywall = true` 站点，逐一列出。
3. **§3.5d 延迟改为从 `UIConfig.toastDuration` 推导**，不再硬编码 2.0s——
   带 action 的庆祝 toast 时长会翻倍到 4.0s，硬编码会拦腰截断「去看看」。
4. **§3.2d 文本布局规则改双出处**（父仓库 CLAUDE.md + 代码注释）。
5. **新增 §3.10 跨分支合并顺序**——`subscribe-button` 分支是本方案的**前置依赖**，
   不只是「改同一个文件需要定顺序」。

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

### 1.4 已拍板的三个引导层决策

| 决策点 | 选择 | 理由 |
|---|---|---|
| 触发方式 | 高亮 `VoiceFAB`，等用户自己点 | 真正教会「以后从哪里录」。且用户有心理准备再开口，不会被 1.5s 静音自动提交（`Voice/VoiceInputManager.swift:704`）截成空转写 |
| 提示持久性 | 一直提醒到首次成功录一条，同时给显式「知道了」关闭入口 | 比 `ExpandMonthHintView` 的「一次性 4.5s 后永久落盘」语义更强——这是激活的关键动作，没看懂的用户应该还有机会 |
| 跨日兜底 | 庆祝 toast 改文案 + 带「去看看」跳转 | `revealConfirmedTodos` 已经算出了 `elsewhere`；toast modifier 已支持 `actionTitle` / `action`（`UI/Shared/ToastView.swift:237-256`） |

**明确不做**：自动展开面板、自动开始录音。也不复用 Action Button 的
`coordinator.pendingIntentRecordingLaunch` 通路。

### 1.5 顺带解决：付费墙前置这个战略 bug

`PROMOTION_PLAN.md` 已经就这件事拍过板，而且措辞很重：

- `:33` —「**Onboarding 改造**：现状「权限 → 语言 → 付费页」必须改为「权限 → 语言 →
  **首次录音 demo → wow** → 第 2 次撞墙 → trial → paywall」。**付费页前置是战略 bug，不是优化项**」
  （至今是未打勾的 checkbox）
- `:167` —「**Wow 必须在 paywall 之前** — onboarding 任何改动不得把付费页提前到首次录音 demo 之前」
- `:22` —「wow 必须在 paywall 之前，否则测的是『为未知价值付费』」

准确判定：v1 方案**没有违反 `:167` 的禁令**——它没有把 paywall 提前，paywall 本来就在前面。
但 v1 把 `completion` 从终点变成了「再走一步」的漏斗，**首次录音 demo 第一次被实现出来了**，
而它落在 paywall 之后。这意味着：如果这次不顺手把 `proPaywall` 挪到 wow 之后，
`:33` 以后还得再改一次 onboarding，改的是同一批代码（`visibleSteps` 索引、`showsProStep`
快照、`contentFits` 预算、同一组 UI 测试）。

**已拍板：顺手改。** 新顺序：

```
权限 → 语言 → 日历 → Action Button → completion「去试一句」
  →（关 sheet）→ hint → 首次录音 → wow → paywall
```

paywall 不再内嵌在 onboarding，改为首次 wow 成功后弹 app 级 sheet
（`coordinator.showPaywall`，`VoiceTodoApp.swift:221` 已存在）。

#### 1.5.1 与 `:33` 目标序列的偏差（必须承认，不能装作一致）

`:33` 写的完整序列是「首次录音 demo → wow → **第 2 次撞墙** → trial → paywall」。
本方案实现的是「wow → 等庆祝 toast 播完 → paywall」，**跳过了「第 2 次撞墙」这一层**。
`:57` 的漏斗事件清单（`install → first_record → wow_shown → quota_hit → trial_start → …`）
也把 paywall 曝光绑在 `quota_hit` 上。所以本方案自称是 `:33` 的载体，但落点不一致——
这个偏差是**有意选择**，理由如下。

| 方案 | 漏斗位置 | 得 | 失 |
|---|---|---|---|
| **A（本方案）** | wow → toast 播完 → paywall | day-1 必然曝光；情绪峰值转化；`:167` 硬约束满足 | 用户尚未感知配额稀缺，付费理由纯靠一次 wow 的情绪；首会话打断感最强 |
| B（`:33` 原文） | wow → 第 2 次撞墙 → paywall | 价值给足 + 动机具体（额度不够用） | **「第 2 次撞墙才弹」这个特定触发点不存在**——现状三条路是 5 次阈值（`handleRecordingSuccess`）、配额耗尽**首撞即弹**（`AppCoordinator:1121/:1225`，不是「第 2 次」）和设置页手动；实现 B 需要新写「计数到第 2 次配额耗尽才弹」的状态；且 free 3/day 下首日根本撞不到墙，day-1 曝光≈0，软启动 4 周 ≥5% 的度量窗口内曝光量显著缩水 |

**已拍板：选 A**（2026-08-18，需求方）。决定性理由是 **day-1 曝光**：
free 3/day 的配额下，新用户第一天通常只录 1–2 条，「第 2 次撞墙」在 day-1 不可达，
而软启动只有 4 周度量窗口。wow 后立即弹是当前唯一的 day-1 曝光点，
且 `:167` 的硬禁令（paywall 不得早于首次 demo）完全满足。

**A 不是终局，是可度量的起点**——所以 §3.5c 的四来源遥测是这个决定的配套条件，
不是可选项：没有它，A 与 B 孰优永远测不出来，这个偏差就只是个未经检验的赌注。

> ⚠️ **不要退回被删掉的老实现。** `docs/onboarding-paywall-merge.md` 记录了一次历史：
> 早期版本用 `pendingPaywallAfterOnboarding` 标志 + 600ms 盲延迟弹 paywall sheet，
> 这个方案已被判定为「被卖了两次，第一次是假的」并删除，残留 key 也在
> `VoiceTodoApp.swift:49` 被清理。本次是**按 wow 事件触发**，不是按时间盲弹，
> **不得重新引入 `pendingPaywallAfterOnboarding` 或任何跨 modal 的延迟标志**。

---

## 2. 总体流程

```
onboarding（6 步，proPaywall 已移除）
  … → completion 页，按钮「去试一句」
  ↓  hasCompletedOnboarding = true
  ↓  firstVoiceTrialState = armedState(权限齐?) → .pending / .dismissed
  ↓
sheet 关闭 → HomeView 挂载
  ↓  onAppear + 0.4s（可取消 Task）
FAB 上方浮出 FirstVoiceTrialHintView
  「试着说：今晚八点给妈妈打电话」  [知道了]
  ↓  用户点 RecordFAB（走完全现有路径 openVoiceInputPanel）
录音 → 转写 → AI 抽取 → ConfirmSheet 确认
  ↓  onDismiss → revealConfirmedTodos()
  ↓  firstVoiceTrialState → .completed，hint 消失
【wow】待办错峰入场 + 庆祝 toast（三分类，见 3.4g）
  ↓  等 toast 播完(2.0s 或 4.0s,见 3.5d)+0.3s
paywall sheet（非 Pro 用户；写入同一份 14 天冷却簿记）
```

**中途放弃的分支**：用户点「知道了」→ `.dismissed` 终态，hint 不再出现，
**paywall 也不会弹**（wow 没发生，弹了就又回到「为未知价值付费」）。
这类用户由现有的 `handleRecordingSuccess()` 5 次阈值路径兜底。

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
    /// 首次语音待办已落库。终态。触发 wow 后置 paywall 的唯一入口。
    case completed

    static let storageKey = "firstVoiceTrialState"

    /// onboarding 结束时决定初始状态。
    ///
    /// 权限没拿齐时直接给 `.dismissed` 而非 `.pending`：**不叠加两层引导**——
    /// 跳过权限的用户已经由 `UI/Shared/VoicePermissionRepromptSheet.swift` 在点 FAB
    /// 时接管（触发条件见 `HomeView.startRecordingForInputPanel():1864` 的
    /// `hasSkippedInOnboarding && !allPermissionsGranted` 分支）。两个引导同屏会互相打架。
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

**d) 文本布局硬规则（整个 3.2 与 3.3 都适用）**

新增/改写的**每一个 `Text`** 必须带 `lineLimit(...)` + `minimumScaleFactor(≥0.7)`，
并按 `isCompact` 分支给紧凑规格。

> **出处有两处，取决于你在哪个目录树下工作：**
> 1. 父仓库 `doflow/CLAUDE.md` 的「文本布局规则」一节——在 doflow 目录树下用
>    Claude Code 工作时会自动加载。
> 2. 本仓库内的代码证据：`OnboardingView.swift:1106` 的注释
>    「用最小缩放换行数，符合项目「lineLimit + minimumScaleFactor ≥0.7」规则」，
>    以及 `HomeSelectedDayListView.swift:320` 的同款做法。
>
> ⚠️ **`voisetodo/` 根目录下没有 `CLAUDE.md`**（v2 据此误判「该规则无成文出处」）。
> 如果你的工作目录是单独 clone 出来的 `voisetodo`（非 doflow 子树），
> 找不到那个文件是正常的——照第 2 条的代码证据写即可，不要以为规则不存在。

> ⚠️ **小屏高度预算是硬约束。** 该文件有一整套 `contentFits` 机制
> （`OnboardingView.swift:98-111`）和 DEBUG 下暴露给 UI 测试的 a11y 钩子
> `OnboardingContentFits`，test_S17 会断言 iPhone SE 上每一步一屏装得下。改完必须重跑。
> 好消息：§3.5 删掉 `proPaywall` 步后，`minContentHeight`（`:89`）里那条
> `currentStep != .proPaywall` 的例外没了，test_S17 里「proPaywall 长内容允许滚动、
> 不做 fits 断言」的特例（`ScenarioTests.swift:676`）也可以一并删掉，判定反而更严格统一。

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
（`UI/Shared/DesignSystem.swift`）。所有 `Text` 遵守 §3.2d 的硬规则。

**遮挡预算**：本 hint 是两行文本 + 一个按钮，比先例（纯 icon 动画）大得多，
挂在 FAB 上方会盖住列表末行的可操作区。必须在 SE 上实测，见 §5.2。

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
/// hint_shown 遥测的会话内去重闸门。见 3.6 口径说明。
@State private var didRecordHintShownThisSession = false
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

**d) 调度触发点——必须自己列全，不能只写「沿用 `evaluateExpandHintTrigger`」**

这是 v1 最严重的规格缺口。`evaluateExpandHintTrigger()` 的调用点只有两处：
`.onChange(collapseProgress)`（`:1470`）和 `.onChange(selectedBottomTab)`（`:1473`），
**没有 `.onAppear`**。ExpandHint 无妨——它要 calendar tab + 折叠态才 eligible，
必然经由某次 onChange 进入；而 FirstTrial hint 在 `HomeView` 挂载那一刻 eligible 就已为真
（today tab / 无面板 / 无 confirm sheet），照搬写法**挂载后没有任何事件会触发它，hint 永不出现**。

同理，验收反例「录音后取消 → hint 仍在」依赖面板关闭时重新评估，
而现有 `.onChange(of: showInputPanel)`（`:505-515`）只清 `keyboardHeight`，不碰 hint。

**FirstTrial 自己的触发集（逐条实现，缺一条就有对应的失效场景）：**

| 触发点 | 覆盖场景 |
|---|---|
| `.onAppear` | onboarding sheet 关闭 → HomeView 首次挂载（**主路径**） |
| `.onChange(of: selectedBottomTab)` | 反例 6：切到 calendar 再切回 today |
| `.onChange(of: showInputPanel)` | 反例 4：打开面板后取消 |
| `.onChange(of: coordinator.showConfirmSheet)` | ConfirmSheet 关闭但用户没确认 |
| `.onChange(of: scenePhase)` | 退后台取消挂起 Task，回前台重新评估 |

**调度体**沿用 `evaluateExpandHintTrigger()`（`:1584`）的写法：可取消 `Task` +
sleep ~0.4s + 醒来后二次 `guard isFirstTrialHintEligible`。
**不要用 `DispatchQueue.main.asyncAfter`**——`:1575-1583` 有整段注释说明为什么必须可 cancel。
`.onDisappear`（`:548`）里 cancel 并置 nil，与现有 `hintTriggerTask` 并列。

`scenePhase` 分支仿 `:1476-1487`：非 `.active` 时 cancel 挂起任务并收起 hint。
**关键差异**：ExpandHint 是「展示即落盘、永久消失」，所以退后台等于永久失去；
本 hint **不在展示时落盘**，回前台重新评估即可重现，语义上安全。

**e)「知道了」**：写 `firstVoiceTrialRaw = FirstVoiceTrial.dismissed.rawValue`，
`withAnimation` 收起 hint。

**f) 完成钩子**：`revealConfirmedTodos()`（`:911`）在 `guard !ids.isEmpty`（`:913`）之后：

```swift
let wasFirstTrial = (firstVoiceTrialRaw == FirstVoiceTrial.pending.rawValue)
firstVoiceTrialRaw = FirstVoiceTrial.nextState(
    current: FirstVoiceTrial(rawValue: firstVoiceTrialRaw) ?? .notArmed,
    didConfirmTodos: !ids.isEmpty
).rawValue
```

`wasFirstTrial` 同时驱动两件事：庆祝 toast（3.4g）和后置 paywall（3.5c）。

> **口径说明 1（语音 vs 键盘）**：这里判定的是「确认了一批待办」，不区分语音还是键盘输入。
> 引导语明确指向语音，绝大多数情况就是语音；用键盘完成也算通过引导，
> 不值得为这个边界再拉一条 source 判定链路。**代价写在 3.6**：遥测侧不能直接拿
> `completed` 当语音激活数。
>
> **口径说明 2（离线恢复旁路）**：`App/PendingRecoveryFlow.swift` 会在回前台时认领
> 离线残留转写并弹 ConfirmSheet（`AppCoordinator.swift:469-533` → `:533 showConfirmSheet = true`），
> 确认后同样走 `confirmTodos` → `pendingRevealTodoIDs` → `revealConfirmedTodos`。
> 也就是说 trial 可能由「上次离线录的那条」完成，而非本次引导下的录音。
> **判定：接受**——用户确实录过音、也确实看到了待办落进清单，wow 成立。不为此加判别逻辑。

**g) 庆祝 toast——在现有三分类之上叠加，不替换**

`presentAddedToast`（`:973`）现有逻辑对 mixed batch 有分流文案
「N 条 + M 条在其他日期」（`:987-997`）。v1 的写法（`celebrate && onSelectedDay > 0`
整段替换）会让「明早九点开会，下周三去银行」里落别日的那条**没有任何反馈**，
而新用户恰恰最不懂「落别日」是什么。

另有一处口径瑕疵：`onSelectedDay = ids.count - elsewhere`（`:985`），而 `elsewhere`
只统计**有 dueDate 且落别日**的条目——所以无 dueDate 的「稍后」条目被算进了 `onSelectedDay`。
现有通用文案「已添加 N 条」是中性的，不冲突；但庆祝文案一旦点名「今天」就说错了。

**给 `presentAddedToast` 加 `celebrate: Bool` 参数，分支如下：**

| 条件 | 文案 | action |
|---|---|---|
| `!celebrate` | **完全维持现状**（`home.added_toast %lld` / `home.added_toast.elsewhere %lld %lld`），两个新 state 置 nil | 无 |
| `celebrate`，全部落今天（`elsewhere == 0` 且无无日期条目） | `home.added_toast.first_trial`（「太棒了！已经记在你今天的清单里」） | 无 |
| `celebrate`，含无日期条目、无别日条目 | 庆祝但**不点名「今天」**：`home.added_toast.first_trial_generic`（「太棒了！已经记在你的清单里」） | 无 |
| `celebrate`，含别日条目（mixed 或全别日） | 庆祝语义 + **保留分流信息**：`home.added_toast.first_trial_elsewhere %lld %lld`，不吞掉「M 条在其他日期」 | `home.added_toast.go_look` |

「去看看」action：

```swift
selectedBottomTab = .calendar
selectDay(firstElsewhereDueDate)   // :1621
```

必须切到 calendar tab——today tab 的 `.onChange` 会 `jumpToToday()` 把日期拽回今天
（`:496-500`）。

最后把两个新 state 传进现有 `.toast(...)` 调用（`:447-456`）——modifier 已支持
`actionTitle` / `action`（`UI/Shared/ToastView.swift:246-247`），**不需要改 `ToastView`**。

### 3.5 付费墙后置

**a) `App/OnboardingView.swift` 删除 `proPaywall` 步**

牵动的点（逐一处理，别漏）：

| 位置 | 处理 |
|---|---|
| `OnboardingStep` 枚举 `:14` | 删 `case proPaywall` |
| `visibleSteps` 的 `.proPaywall` 分支 `:142` | 删 |
| `switch currentStep` 的 `:193-194` | 删 |
| `proPaywallStep` 视图 `:1270-1284` | 删 |
| `shouldHideBottomBar` `:266-268` | 恒为 false，连同 `:237` 的 `if` 一起删 |
| `minContentHeight` `:89-92` 的 `currentStep != .proPaywall` | 删该条件，只留 `viewportHeight.isFinite` |
| `showsProStep` 属性 + `init` 的 `entitlement` 参数 `:36-39, :119-127` | 删。**注意同步改调用点** `VoiceTodoApp.swift:249-253` 和文件底部 `#Preview` |
| `.onChange(of: entitlement.isPro)` 自动前进 `:258-261` | 删（没有 proPaywall 步了，这个 handler 是死代码） |
| `@EnvironmentObject entitlement` `:65` | **保留**——`completionStep:1312` 仍用 `entitlement.isPro` 显示已订阅用户的感谢文案 |

**b) `UI/Paywall/PaywallView.swift`**

`PaywallPresentationContext.onboarding`（`:10`）失去唯一调用方。
该 context 在 `PaywallContent` 里**只影响一处间距**（`:144`
`context == .sheet ? WarmSpacing.sm : WarmSpacing.xs`）。
删掉 `case onboarding` 并把 `:144` 简化为常量；同步清理 `:32` / `:74` 两处
提到「Onboarding 第三屏内嵌」的过期注释。

> `onboarding.pro.bullet.*` 系列文案**不要删**——`PaywallView.swift:296-315` 仍在用
> （key 名带 `onboarding` 前缀只是历史包袱，不是死键）。
> 会变成死键的是 `onboarding.pro.cta.later`（「以后再说」，仅 `proPaywallStep` 用）。

**c) `App/AppCoordinator.swift` 新增 wow 后置触发**

paywall 的触发策略目前集中在 `handleRecordingSuccess()`（`:214-240`），
新入口必须**复用同一份簿记**，否则用户会先在 wow 后被弹一次、再在第 5 次录音后被弹一次。

把 `handleRecordingSuccess` 里的公共守卫抽成私有方法（`!entitlement.isPro`、
`!showPaywall`、14 天冷却读写 `lastPaywallAutoShownAtKey`），新增：

```swift
/// 首次 wow(引导下第一条待办落进清单)之后引导升级。
/// 与 handleRecordingSuccess 的 5 次阈值路径共用冷却簿记 —— 弹过一次后
/// 14 天内不再弹，避免新用户前两天被连弹两次。
func showPaywallAfterFirstWow() { … }
```

日志沿用现有格式但换 reason：`coordinator.paywall.auto_trigger reason=first_wow`
（对照现有 `reason=recording_count`，`:238`）。

**但只有 OSLog 不够——paywall 曝光必须进遥测，且四来源可区分。**
这是 §1.5.1 选 A 的配套条件。现状代码有**四个** `showPaywall = true` 站点：

| 站点 | 来源 | 语义 |
|---|---|---|
| `AppCoordinator:236` | `recording_count` | 累计 5 次录音成功阈值 |
| `AppCoordinator:1121` | `quota_exhausted` | 配额耗尽 + 离线兜底后 |
| `AppCoordinator:1225` | `quota_exhausted` | `handleError` 里的配额耗尽分支 |
| `HomeView:431` | `manual` | 设置页「升级 Pro」 |
| **新增** | `first_wow` | 本方案 |

> 评审只提了三种来源，实际是四种。`quota_exhausted` 尤其不能漏——
> **它正是选项 B 说的「撞墙」**。不把它单独记出来，A vs B 的对比就没有对照组。

**实现方式**：把这四处 + 新增的一处全部收口到一个方法，避免以后新增入口漏埋点：

```swift
/// 所有 paywall 曝光的唯一入口。四来源统一埋点，便于分析 A/B 弹点效果。
/// showPaywall 保持可写 —— VoiceTodoApp.swift:221 的 sheet binding 需要写 false 关闭。
func presentPaywall(source: PaywallSource) {
    Telemetry.record(.paywallShown(source: source.rawValue))
    showPaywall = true
}
```

`PaywallSource: String` 放 `Protocols/Telemetry.swift`，与既有的 `RecordingSource` /
`SaveSource` 并列（`Telemetry.swift:152-186` 的同款模式）。
`showPaywallAfterFirstWow()` 内部走 `presentPaywall(source: .firstWow)`。

**d) `UI/Home/HomeView.swift` 触发时机**

在 `revealConfirmedTodos()` 里 `wasFirstTrial == true` 时，起一个可取消 Task，
**等 wow 播完再弹**。醒来后二次守卫：`!showInputPanel && !coordinator.showConfirmSheet
&& selectedTodo == nil`（用户可能已经点进详情页），再调 `coordinator.showPaywallAfterFirstWow()`。
Task 存 `@State` 并在 `.onDisappear` cancel，与本文档其它 Task 一致。

**延迟必须从 `UIConfig.toastDuration` 推导，不要硬编码 2.0s。**
v2 写死 2.0s 是个真 bug：`ToastView.swift:150` 是

```swift
let duration = action != nil ? UIConfig.toastDuration * 2 : UIConfig.toastDuration
```

而 `UIConfig.toastDuration = 2.0`（`Protocols/Constants.swift:149`）。所以：

| 庆祝 toast 分支（见 3.4g） | 有无 action | toast 实际时长 | 硬编码 2.0s 的后果 |
|---|---|---|---|
| 全落今天 / 含无日期条目 | 无 | 2.0s | 勉强踩点，paywall 恰在 toast 消失时弹 |
| **含别日条目** | 有「去看看」 | **4.0s** | **paywall 在第 2s 盖住 toast，用户根本来不及点「去看看」** |

正确做法：延迟 = 该次 toast 的实际时长 + 一点余量。卡片 stagger 最长
8×0.06 ≈ 0.48s，被 toast 时长覆盖，不用另算。

```swift
let toastDuration = UIConfig.toastDuration * (addedToastAction != nil ? 2 : 1)
let paywallDelay = toastDuration + 0.3
```

> **绝不要**在 `revealConfirmedTodos` 里同步弹 paywall——那会让 paywall sheet 盖住
> 正在播的入场动画，wow 直接归零，等于白改。

**e) `PROMOTION_PLAN.md`**

实施完成后：

1. 勾掉 `:33` 的「Onboarding 改造」checkbox；
2. **同步改写 `:33` 的目标序列表述**，把「wow → 第 2 次撞墙 → trial → paywall」
   改成实际实现的「wow → paywall」，并注明选 A 的理由与 `:57` 漏斗的对应关系。
   别让战略文档和实现长期互相矛盾——下一个读 `:33` 的人会以为还有一层没做。
3. `:57` 漏斗事件清单里的 `wow_shown` 对应到 `first_voice_trial(stage=completed)`；
   `quota_hit` 之后的 paywall 曝光对应到 `paywall_shown(source=quota_exhausted)`。

### 3.6 遥测 `Protocols/Telemetry.swift` + `TELEMETRY.md`

新增事件：

```swift
/// A6: 首次语音试用引导进度。onboarding→激活的转化漏斗，
/// 也是 PROMOTION_PLAN.md 漏斗里 wow_shown 的数据来源。
case firstVoiceTrial(stage: String)
```

- `name` → `"first_voice_trial"`
- `params` → `["stage": stage]`
- stage 取值：`armed` / `hint_shown` / `dismissed` / `completed`

埋点位置：`armed` 在 `OnboardingView.nextStep()`；其余三个在 `HomeView` 对应状态迁移处。

**三条必须写进 `TELEMETRY.md` 的口径限制：**

1. **`hint_shown` 会重复触发，必须会话内去重。** §3.4d 把触发集扩到了 5 个入口
   （挂载 / 切 tab / 关面板 / 关 confirm sheet / 回前台），同一用户一次会话内可能
   展示 hint 很多次。若每次都发事件，漏斗分母直接失真。
   用 `@State didRecordHintShownThisSession`（3.4a）做**每会话一次**的闸门；
   `Telemetry.sessionID` 本身就是每次启动新建不持久化的（`Telemetry.swift:12`），
   语义天然对齐。分析侧口径写明：`hint_shown` = 会话级曝光，不是展示次数。
2. **`completed` 混入键盘输入**（口径说明 1）。`todoSaved(source:)` 有 source 维度，
   本事件没有。分析侧必须靠 `todo_saved(source:)` 与
   `first_voice_trial(stage=completed)` 的时序关联还原真实语音激活率，
   **不能直接拿 `completed` 当语音激活数**。
3. **`dismissed` 率是本功能的必盯指标。**「知道了」是终态，一点即永不重提。
   若 `dismissed / armed` 偏高，说明这个显式出口在吞激活，需要二次 arm 策略
   （如 N 天后重新 `pending`）。本期不实现二次 arm，但指标必须先埋上。

按该文件既有硬约定：**params 里不允许出现任何文本原文**（转写、标题、示例台词都不能带）。

### 3.7 本地化 `Resources/Localizable.xcstrings`

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
| `home.added_toast.first_trial` | 庆祝 toast（全落今天） |
| `home.added_toast.first_trial_generic` | 庆祝 toast（含无日期条目，不点名「今天」） |
| `home.added_toast.first_trial_elsewhere %lld %lld` | 庆祝 toast（含别日条目，保留分流） |
| `home.added_toast.go_look` | toast action「去看看」 |
| `a11y.first_trial.hint` | hint 的 VoiceOver label |

**待清理的死键**（确认无引用后删）：`onboarding.button.start`、`onboarding.tip1/2/3`、
`onboarding.pro.cta.later`。本仓库刚做过一次「清理 xcstrings 死键」的提交（`3a7e225`），
保持这个卫生习惯。

**ja 挂账**：xcstrings 现状 en 592 / zh-Hans 591 / **ja 仅 48** 键（共 603 键）。
本方案维持 zh+en，与全库现状一致，不单独拔高。但这 11 个 key 是**首启体验文案**，
ja 上线时是最显眼的英文 fallback 区——在 `docs/mvp-japanese-launch/plan.md` 挂账：
本批 key 必须补 ja。

### 3.8 测试支持与测试

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

**c) UI 测试**（`VoiceTodoUITests/ScenarioTests.swift`）

*必须先修的既有测试*：`ProIntroLaterButton` 在 `:455` / `:630` / `:689` 三处被引用，
`proPaywall` 步删除后这三处的 onboarding 走查会挂。同时 `:676` 那条
「proPaywall 长内容允许滚动，不做 fits 断言」的特例可以删掉（见 §3.2d）。

*新增正例*：`--ui-testing --reset-user-data` 启动 → 走完 onboarding（含授权）→
断言 `FirstVoiceTrialHint` 存在 → 点 `RecordFAB`（`UITestVoiceInputManager` 提供
mock transcript，见 `App/UITestSupport.swift` + `Protocols/UITestLaunchOptions.swift:55`）
→ 确认 ConfirmSheet → 断言 hint 消失、待办出现在今天分组、paywall 在延迟后弹出。

*新增反例*：`--mic-permission-denied` 走完 onboarding → 断言 `FirstVoiceTrialHint`
**不存在**（应走原有 `VoicePermissionRepromptSheet` 路径）。

**d) 回归**
onboarding 布局测试 test_S17（断言 `OnboardingContentFits`）——步骤数从 7 变 6，
断言循环要跟着改。

### 3.9 无需改动

`project.yml` 不用动——两个新文件分别落在 `Protocols/Domain/` 和 `UI/Home/`，
两个目录都已在 `targets.VoiceTodo.sources` 的目录级条目里，XcodeGen 会自动收。

（`.xcode_main_app_files.txt` 是一份**已经过期**的说明清单——它里面还列着并不存在的
`App/ServiceContainer+VoiceTodo.swift`——不是构建输入，不用改。）

### 3.10 跨分支合并顺序（动工前必读）

`claude/onboarding-screen-3-subscribe-button-06o1za`（`ed47088`，文档
`docs/onboarding-paywall-products-empty.md`）与本方案都改
`UI/Paywall/PaywallView.swift`。第二轮评审把这件事定性为「需要定合并顺序」，
**但实际关系更强：那支是本方案的前置依赖。**

**为什么是依赖而不只是冲突：**

1. 本方案把 paywall 从 onboarding 内嵌改成 wow 之后弹的 sheet。
   商品加载不出来时，**wow 的结尾就是一张「无法加载订阅方案」错误卡**——
   比原来在 onboarding 第三屏出错更糟，因为它紧跟在情绪峰值后面。
2. `Products.storekit` 只是本地 StoreKit 测试文件（不影响生产），
   但 §5.2 正例第 5 步「wow 播完后付费墙弹出」**正是靠它验证的**。
   不先修，验收时只能看到错误卡，测不出本方案对不对。

**合并顺序：subscribe-button 先，本方案后。**

- 前者是在现有结构上修 bug（`PaywallContent` 自己负责商品加载 + 重写
  `Products.storekit`）；后者只是删掉一个调用点（`PaywallPresentationContext.onboarding`）。
  本方案 rebase 到前者之上，成本几乎为零。
- 反过来则是给一个**已被删除的「第三屏」**修 bug，那份文档的叙述得整个重写。

**反向中继给 subscribe-button 分支的两件事：**

1. 那份文档通篇以「onboarding 第三屏」为叙事主体，而本方案会**删掉第三屏**。
   需要在其头部加一行说明：修复对象已改为「wow 之后弹出的 paywall sheet」，
   根因与改法不变（`PaywallContent` 是同一个）。
2. 该文档 §3.1 的三处过期（`P3D` / 价格 12·98 / 「现状文件这一处本来就是对的」），
   见 §7 表中 7.4 行及其下方验证表——我已逐条比对现状文件确认属实，**修正在那支分支做，本方案不动它**。

---

## 4. 改动文件清单

| 文件 | 类型 | 说明 |
|---|---|---|
| `Protocols/Domain/FirstVoiceTrial.swift` | 新增 | 状态机 + 纯函数判定 |
| `UI/Home/FirstVoiceTrialHintView.swift` | 新增 | coach-mark 视图 |
| `App/OnboardingView.swift` | 改 | completion 页文案/按钮/落盘 arm；**删除 `proPaywall` 步及其 7 处牵连** |
| `UI/Home/HomeView.swift` | 改 | state / 挂载 / 触发集(5 入口) / 完成钩子 / 三分类庆祝 toast / wow 后置 paywall 触发；`:431` 改走 `presentPaywall(source: .manual)` |
| `App/AppCoordinator.swift` | 改 | `showPaywallAfterFirstWow()` + 抽出共用冷却簿记；**新增 `presentPaywall(source:)` 并把现有三处 `showPaywall = true`（`:236` / `:1121` / `:1225`）收口进去** |
| `UI/Paywall/PaywallView.swift` | 改 | 删 `PaywallPresentationContext.onboarding` + 过期注释。**注意 §3.10 的合并顺序** |
| `App/VoiceTodoApp.swift` | 改 | `resetUserData` 清新 key；`OnboardingView` 调用点去掉 `entitlement` 参数 |
| `Protocols/Telemetry.swift` | 改 | `firstVoiceTrial(stage:)` + `paywallShown(source:)` 两个事件 + `PaywallSource` enum |
| `Resources/Localizable.xcstrings` | 改 | 11 个新 key，清理 5 个死键 |
| `TELEMETRY.md` | 改 | 事件表 + 三条口径限制 |
| `PROMOTION_PLAN.md` | 改 | 勾掉 `:33` 的 onboarding 改造项；`wow_shown` 对应到新事件 |
| `docs/mvp-japanese-launch/plan.md` | 改 | 挂账 11 个新 key 的 ja 补齐 |
| `docs/onboarding-paywall-merge.md` | 改 | 头部加一行：内嵌 paywall 步已被本方案移出，该文档的 §3 结论部分作废 |
| `VoiceTodoUITests/ScenarioTests.swift` | 改 | 修 `ProIntroLaterButton` ×3 + test_S17 步数/特例；新增正例 + 反例 |
| `VoiceTodoTests/...` | 新增 | 状态机单测 |
| *（跨分支）* `docs/onboarding-paywall-products-empty.md` | **不在本方案改** | 前置依赖 + 反向中继两件事，见 §3.10 与 §7 的 7.4 行 |

**不改动**：`Voice/`、`Extractor/`、`Store/`、`App/TranscriptProcessingFlow.swift`、
`UI/ConfirmSheet/`、`UI/Shared/ToastView.swift`。

> `ToastView.swift` 仍然不改——§3.5d 只是**读** `UIConfig.toastDuration` 来推导延迟，
> 没有改 toast 的任何行为。

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

1. 删除 App 重装 → 走完 onboarding 并授权 →**中途不应出现付费墙** → 点「去试一句」
2. sheet 关闭后，主页 FAB 上方浮出 hint
3. 点 FAB → 说「今晚八点给妈妈打电话」→ 确认
4. 待办错峰入场到今天分组，庆祝 toast 弹出，hint 消失
5. wow 播完后（**2.0s 或 4.0s，取决于 toast 有没有「去看看」**，见 §3.5d）
   付费墙 sheet 弹出，且商品卡正常渲染
6. 杀掉 App 重启 → hint 不再出现、付费墙不再自动弹（14 天冷却）

> ⚠️ **第 5 步依赖 `claude/onboarding-screen-3-subscribe-button-06o1za` 的
> `Products.storekit` 修复先合入**（见 §3.10）。否则本地 StoreKit 环境下商品加载
> 不出来，这一步只能看到「无法加载订阅方案」错误卡，验证不了本方案。

**反例：**

| # | 场景 | 期望 |
|---|---|---|
| 1 | 重装 → onboarding 里跳过语音权限 | 主页**不出现** hint，点 FAB 走原有 `VoicePermissionRepromptSheet` |
| 2 | 重装 → 走完 onboarding → 直接点「知道了」→ 杀掉重启 | hint 不再出现；**付费墙也不弹**（wow 没发生） |
| 3 | 引导中说「下周三去银行」 | toast 显示庆祝 + 「在其他日期」分流 + 「去看看」，点击跳到 calendar tab 的那一天 |
| 4 | 引导中说「明早九点开会，下周三去银行」（mixed） | toast **同时**保留庆祝语义和「M 条在其他日期」，别日那条不被吞 |
| 5 | 引导中说一句无日期的话（如「买牛奶」） | 庆祝文案**不点名「今天」**（条目进「稍后」分区） |
| 6 | 引导中开始录音后取消（不确认） | hint 仍在，状态仍是 `.pending`（验证 3.4d 的 `showInputPanel` 触发点） |
| 7 | 老用户（已 `hasCompletedOnboarding`）升级安装 | 状态 `.notArmed`，**不出现** hint，不弹付费墙 |
| 8 | 引导中切到 calendar tab | hint 隐藏；切回 today tab 后重新出现（验证 `selectedBottomTab` 触发点） |
| 9 | 引导中退后台再回前台 | hint 重现（本 hint 不在展示时落盘，与 ExpandHint 不同） |
| 10 | arm 后到系统设置关掉麦克风 → 重启 app | hint 仍出现；点 FAB 走系统权限失败路径，行为与无引导时一致、**不引入新状态**（见 §6 第 6.6 条） |
| 11 | 已是 Pro 的用户完成首次 wow | 庆祝 toast 正常，**不弹付费墙** |
| 12 | 引导中说「下周三去银行」（庆祝 toast 带「去看看」） | **付费墙必须等满 4.0s**，用户来得及点到「去看看」；不得在第 2s 把 toast 盖掉（验证 §3.5d 的延迟推导，这是 v2 硬编码 2.0s 的原始 bug） |
| 13 | 四条 paywall 路径各走一次（wow / 第 5 次录音 / 配额耗尽 / 设置页升级） | 各自发出 `paywall_shown` 且 `source` 互不相同（验证 §3.5c 的收口没漏站点） |

**布局专项（SE + AX 大字号）：**

- hint 不遮挡今天列表末行的可操作区（滑动删除/打勾）
- hint 内中英长文本都不截断、不意外换行（验证 §3.2d 的硬规则落实到位）
- onboarding 每一步 `OnboardingContentFits` 为 1

---

## 6. v1 评审 8 项的处理记录

> v1（`2792a09`）的 §6 评审记录（`6cfaec7`）。原文的行号与事实我已逐条复核，
> 结论：**6 条属实且已并入正文，1 条证据引错已更正，1 条判定我不同意并已升级**。
> 本节只保留追溯用的对照表，正文以 §1–§5 为准。

| # | 原评审 | 我的复核 | 落点 |
|---|---|---|---|
| 6.1 | P1 调度触发点不全，hint 可能永不出现 | **属实，且是最严重的一处。**已核：`evaluateExpandHintTrigger` 只在 `:1471` / `:1474` 被调，确无 `.onAppear`；`.onChange(showInputPanel)`（`:505`）确实只清 `keyboardHeight` | 并入 **§3.4d**，改为自列 5 个触发点的表格，并逐条标注对应的失效场景 |
| 6.2 | P1 庆祝 toast 压扁三分类 | **属实。**已核 `:985` 的 `onSelectedDay = ids.count - elsewhere` 确实把无 dueDate 条目算进「今天」 | 并入 **§3.4g**，改成四分支叠加表；新增反例 4/5 专测 mixed batch 与无日期条目 |
| 6.3 | P2 paywall 仍在 wow 之前，判「本期不做」 | **判定不同意，已升级为本期做。**评审说「与既定原则相悖」不够准确——`PROMOTION_PLAN.md:167` 禁的是「把付费页**提前**」，本方案没提前；真正的问题是 `:33` 那个未打勾的待办项，而本方案是它的天然载体，不顺手做就要再改一次同一批代码 | 升级为正式范围，见 **§1.5 + §3.5**（已与需求方确认） |
| 6.4 | P2 `dismissed` 率需列必盯指标 | 属实，采纳 | 并入 **§3.6** 口径限制第 3 条 |
| 6.5 | P2 `completed` 混键盘，遥测口径需写破 | 属实，采纳 | 并入 **§3.6** 口径限制第 2 条 + §3.4f 口径说明 1 |
| 6.6 | P3 eligible 不查当前权限 | **属实。**已核 `:1864` 的 reprompt 条件是 `hasSkippedInOnboarding && !allPermissionsGranted`，「授权后又去设置里关掉」的用户确实进不了 reprompt 分支。同意不加 eligible 权限检查（低频，且 reprompt 语义是「onboarding 跳过者」专属） | 并入 **§5.2 反例 10** |
| 6.7 | P3 SE 遮挡无验收项 + §3.3 缺文本布局硬规则 | 问题属实。~~证据引错~~ **我的这条反驳只对了一半，已被 §7 表中 7.2 行更正**：`voisetodo/` 根目录确实没有 CLAUDE.md，但规则在**父仓库 `doflow/CLAUDE.md`** 里是成文的 | 并入 **§3.2d**（升格为 3.2/3.3 共用的规则，v3 已改为**双出处**）+ §3.3 遮挡预算 + §5.2 布局专项 |
| 6.8 | P3 新 key 无 ja | 属实。已核：共 603 键，en 592 / zh-Hans 591 / ja 48 | 并入 **§3.7** ja 挂账段 |

**评审未覆盖、本次补上的三项：**

- **`hint_shown` 遥测重复触发**（§3.6 口径限制第 1 条）。这是 6.1 修订的直接后果：
  触发集从 0 个扩到 5 个入口后，同一用户一次会话内会多次展示 hint，
  每次都发事件会让漏斗分母失真。需要会话内去重闸门。
- **离线恢复旁路**（§3.4f 口径说明 2）。`PendingRecoveryFlow` 认领的离线转写
  同样会走到 `revealConfirmedTodos`，可能替用户「完成」trial。判定为可接受，但要写明。
- **paywall 后置的时序陷阱**（§3.5d）。同步弹 sheet 会盖住正在播的入场动画，
  wow 归零、整个改动白做。必须延迟到 wow 播完（~2.0s）并二次守卫。

---

## 7. 第二轮评审 4 项的处理记录

> 第二轮评审（`2b39a69`）针对 v2 `bcd1da9`，需求方随后就 7.1 拍板选 A（`e2d0174`）。
> 该轮先给出了核验结论：v2 引用的代码事实（`handleRecordingSuccess` 阈值 5 +
> 14 天冷却簿记、`VoiceTodoApp.swift:221` app 级 sheet、删 `proPaywall` 的 7 处牵连、
> PaywallView 的 context/注释/bullet keys、ScenarioTests `:455/:630/:689`、
> `PendingRecoveryFlow`、`sessionID` 会话语义）**逐项复核全部属实**。
>
> 本节记录 v3 对这 4 项的处置。正文以 §1–§5 为准。

| # | 评审意见 | 我的复核 | 落点 |
|---|---|---|---|
| 7.1 | 弹点偏离 `:33` 的目标序列，且文档没承认偏差 | **属实。**`:33` 写的是「wow → 第 2 次撞墙 → trial → paywall」，本方案是「wow → 立即弹」，确实不一致；v2 自称 `:33` 载体却没说破 | 需求方拍板**选 A**。四条必办全部落地：偏差承认 → **§1.5.1**；四来源遥测 → **§3.5c**；延迟校准 → **§3.5d**；改写 `:33` 表述 → **§3.5e** |
| 7.2 | v2 说「无成文出处」只对一半，父仓库 `doflow/CLAUDE.md` 有 | **评审对，我 v2 错了。**但需说明：本容器里 `find / -name CLAUDE.md` 无结果、无 `.gitmodules`，voisetodo 是独立 clone，**我无法亲自验证父仓库那份文件**，按评审所述采信 | **§3.2d** 改为双出处并列，并写明「独立 clone 场景下找不到是正常的」——对两种工作目录都成立。§6 的 6.7 行已标注被本条更正 |
| 7.3 | 两支分支都改 `PaywallView.swift`，需定合并顺序 | **属实，但定性偏轻**——见下方「本轮我的加码」 | **§3.10**（新增），升级为前置依赖 + 明确顺序 + 反向中继 |
| 7.4 | 中继：paywall-products-empty 文档三处过期 | **三处全部属实，已逐条比对现状文件**（详见下表） | 转 `subscribe-button` 分支处理，**本方案不改那份文档**；§3.10 反向中继第 2 条已记录 |

**7.4 三处过期的逐条验证**（我比对了 `VoiceTodo/Products.storekit` 现状）：

| 该文档写的 | 现状文件实际 | 结论 |
|---|---|---|
| 试用周期 `P3D` | `P7D`（`:66` / `:74` / `:118` / `:126`） | 过期属实。另 `a8c7914` 已拍板 trial 7 天口径 |
| 价格 12 / 98 | `4.99` / `39.99`（`:49` / `:57` / `:101` / `:109`） | 过期属实（`7ca89ca` 调过价） |
| 「现状文件这一处本来就是对的」 | 现状 `paymentMode: "free"`（`:65` / `:117`），而该文档论证的正确值是 `"freeTrial"` | **自相矛盾属实**——现状文件这处本来就是错的，重写时正是要改它。修正方向（`freeTrial`）是对的，错的是那句话 |

### 本轮我的加码

**1. 7.3 的定性要升级：那支分支是前置依赖，不只是「改了同一个文件」。**

理由写在 §3.10：本方案把 paywall 挪到 wow 之后，商品加载失败时
**wow 的结尾就是一张错误卡**；而 §5.2 正例第 5 步正是靠 `Products.storekit`
验证的，不先修就测不出本方案对错。顺序必须是 subscribe-button 先、本方案后。

**2. 评审说「三种来源」，实际是四种。**

现状代码有**四个** `showPaywall = true` 站点（`AppCoordinator:236` /
`:1121` / `:1225`，`HomeView:431`）。其中 `quota_exhausted`（`:1121` / `:1225`）
**正是选项 B 说的「撞墙」**——不把它单独记出来，A vs B 就没有对照组，
而「A 是可度量的起点」正是选 A 的立论基础。§3.5c 已按四来源写，
并收口到单一 `presentPaywall(source:)` 避免以后新增入口漏埋点。

**3. 「2.0s 延迟对着 toast 时长校一下」是个真 bug，不只是「要有意识」。**

评审只在 7.1 末尾附了一句提醒。实测：`UIConfig.toastDuration = 2.0`
（`Constants.swift:149`），而 `ToastView.swift:150` 对带 action 的 toast **时长翻倍**。
所以跨日分支的庆祝 toast 是 **4.0s**，硬编码 2.0s 会在第 2 秒用 paywall 盖掉它，
**用户根本点不到「去看看」**——而「去看看」正是 §1.4 第三条决策的全部意义。
§3.5d 已改为从 `UIConfig.toastDuration` 推导，§5.2 新增反例 12 专测这一条。
