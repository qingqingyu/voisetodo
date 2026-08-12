# Onboarding 提前两个关键设置：语音识别语言 + 系统日历同步

> 状态：待实现
> 分支：`claude/onboarding-settings-earlier-um9y1x`
> 本文档是可直接执行的实施说明，行号基于本文档写作时的代码状态（`974edaa`）。
> 实施前请先核对行号是否漂移；文件路径和逻辑描述以实际代码为准。

---

## 1. 背景与问题

两个直接决定第一印象的设置目前都埋在设置页里，新用户发现不了。

### 1.1 语音识别语言：新用户第一次录音就可能是错的

`UI/Home/HomeSettingsSheet.swift:105-114` 的「识别语言」Picker 默认 `.auto`（跟随系统）：

```swift
Section(String(localized: "settings.speech_language.title")) {
    Picker(String(localized: "settings.speech_language.title"), selection: $speechRecognitionLanguage) {
        ForEach(SpeechRecognitionLanguage.allCases) { lang in
            Text(lang.displayName).tag(lang.rawValue)
        }
    }
    .pickerStyle(.inline)
    .accessibilityIdentifier("SpeechLanguagePicker")
}
```

`SpeechRecognitionLanguage.swift:5-7` 的注释本身就点明了这个设置存在的理由——
「系统是英文但常用中文说」的场景。但这类用户恰恰**不会**去翻设置页第 4 个 Section
找「识别语言」，他们只会觉得这个 App 识别不准，然后卸载。

设置项本身没问题，**问题是它出现得太晚**。

### 1.2 系统日历同步：默认关闭 + 从不主动介绍 = 事实上不存在

`Protocols/CalendarWriteMode.swift` 默认 `.appOnly`，也就是同步默认关。
入口在 `HomeSettingsSheet.swift:60-77` 的「写入位置」Picker 里。
绝大多数用户从不知道这个能力存在。

### 1.3 日历权限是懒请求，且没有可复用的 seam

EventKit 授权在两个文件里各私有实现了一份，签名完全一样：

- `App/SystemCalendarWriter.swift:172-184` — `private func requestCalendarAccess()`
- `App/SystemCalendarReader.swift:117-127` — 同名同体

writer 的调用点在 `SystemCalendarWriter.swift:96`，**位于「可写 todo 过滤」之后**：

```swift
let writableTodos = todos.filter { ... }          // :83-89
guard !writableTodos.isEmpty else { return [] }   // :91-94
guard try await requestCalendarAccess() else {    // :96 ← 权限在这里才请求
    throw VoiceTodoError.storageWriteFailed("System calendar access denied")
}
```

含义：**切换「写入位置」Picker 本身不弹任何权限窗**，直到用户第一次确认一条
带时间的语音待办才弹。而 `PermissionManager` 只管麦克风和语音识别
（`App/PermissionManager.swift:77-78`），**没有日历的对应物**，
onboarding 现在够不到日历授权。这是本次要新建的基础设施。

### 1.4 拒绝路径目前只有一个 toast

用户拒绝日历权限时，`SystemCalendarWriter.swift:98` 抛错 →
`CalendarSyncService.write` 返回 `.failed` → `AppCoordinator.observeCalendarSync`
（`:841-858`）弹一个警告 toast「已保存到 App，但未能写入系统日历」。
**设置不会回退，也没有「去设置开启」的入口**，用户会停在一个「开着但不工作」的状态。
新的 onboarding 步骤不能重蹈这个覆辙。

---

## 2. 目标流程

```
当前：welcome → voicePermissions → [actionButton] → proPaywall → completion

改后：welcome → voicePermissions → speechLanguage → calendarSync → [actionButton] → proPaywall → completion
                                       ↑ 新增           ↑ 新增
```

已确认的产品决策：

| 决策点 | 结论 |
|---|---|
| 设置页是否保留 | **两边都保留**，`HomeSettingsSheet` 一行都不改 |
| 插入位置 | 语音权限之后、Action Button / 付费墙之前 |
| 日历权限时机 | **当场请求**；拒绝则开关回退关闭 + 提供「去设置开启」 |
| 语言默认值 | 按系统语言预选（保持 `.auto`，但把它解析出的具体语言显示出来） |

### 2.1 需要留意的代价（实施时不用处理，上线后观察）

引导从 4–5 屏涨到 6–7 屏。onboarding 每多一屏都会掉转化，而被稀释的正是
第 6 屏付费墙的到达率。建议上线后盯 onboarding 完成率与 `proPaywall` 到达率；
若明显下滑，把两屏合并成一个「个性化设置」页——本方案的两个 step view
是独立的计算属性，并到同一个 `VStack` 改动很小。

---

## 3. 实施步骤

### 3.1 `Voice/SpeechRecognitionLanguage.swift` — 暴露「auto 当前解析到哪个语言」

新用户看到「跟随系统」四个字并不知道那是中文还是英文。onboarding 需要把它展开成
「跟随系统 · 中文」。解析规则目前私藏在 `VoiceInputManager.resolveSystemLocale()`
（`Voice/VoiceInputManager.swift:647-661`），把它上提到枚举本身，让两处共用一份：

```swift
/// `.auto` 当前会解析到的具体语言。onboarding 用它把「跟随系统」展开成
/// 「跟随系统 · 中文」，让用户第一眼就知道 auto 意味着什么。
///
/// 匹配规则与原 `VoiceInputManager.resolveSystemLocale()` 完全一致
/// （后者已改为调用此处）：按 `Locale.preferredLanguages.first` 的 languageCode
/// 前缀依次匹配非 auto 的各 case，未命中回退 `.enUS`（非中日英系统走英文，国际通用）。
///
/// 返回值永不为 `.auto`。
static var systemResolved: SpeechRecognitionLanguage {
    let preferredLanguage = Locale.preferredLanguages.first ?? "en-US"
    for candidate in allCases where candidate != .auto {
        guard let code = candidate.fixedLocale?.language.languageCode?.identifier else { continue }
        if preferredLanguage.hasPrefix(code) { return candidate }
    }
    return .enUS
}
```

注意：`allCases` 中非 `auto` 的 case 必须与 `Voice/VoiceConstants.swift:27-31` 的
`supportedLocales` **保持集合一一对应**（当前都是 `zh-Hans / ja-JP / en-US`）。
两边任一侧单方面增删，auto 匹配和 Picker 选项就会漂出两套语言集——
§3.9 的测试守护的正是这条。

**顺序无关，不用管**：三个 languageCode 前缀 `"zh"` / `"ja"` / `"en"` 两两互不包含，
任一 `preferredLanguages.first` 最多命中其中一个，遍历顺序不影响结果。
`allCases` 的顺序只决定 Picker 的显示顺序，可以自由调整。

**繁中 / 粤语的已知限制（原逻辑既有，本次不修）**：`"zh-Hant-TW"` 和 `"zh-HK"`
都 `hasPrefix("zh")`，会落到 `.zhHans`。繁中普通话用户影响有限（识别引擎都是普通话，
只是输出简体字形），粤语用户会被塞进普通话识别器。MVP 不支持繁中/粤语，接受现状。
**请把这段作为注释写进 `systemResolved` 的文档注释里**——下次有人排查
「为什么繁中用户被识别成简体」时能直接看到答案。后续若要支持，匹配规则需细化到
`languageCode + script`（区分 `zh-Hans` / `zh-Hant`），而不是只比 `zh` 前缀。

### 3.2 `Voice/VoiceInputManager.swift:647-661` — 改为委托

```swift
/// `auto` 模式下的系统首选语言匹配。
/// 匹配规则统一由 `SpeechRecognitionLanguage.systemResolved` 持有——
/// onboarding 语言页要显示「auto 当前等于哪个语言」，两边必须同源，否则会漂出两套规则。
private static func resolveSystemLocale() -> Locale {
    let resolved = SpeechRecognitionLanguage.systemResolved
    let locale = resolved.fixedLocale ?? Locale(identifier: "en-US")
    VoiceTodoLog.voice.info("locale.system preferred=\(Locale.preferredLanguages.first ?? "nil", privacy: .public) selected=\(locale.identifier, privacy: .public)")
    return locale
}
```

**保留日志行**（线上排查在用）。原来分「命中」和「回退」两条日志，合并成一条即可，
但 `preferred` 和 `selected` 两个字段必须都还在。
`resolveCurrentLocale()`（:635-644）不动。

### 3.3 `App/PermissionManager.swift` — 补日历权限

照文件里现成的 `VoicePermissionClient`（:26-66）写一个对称的客户端，
保住可注入 seam（UI 测试必须能 mock，否则会被系统权限弹窗挂死）：

```swift
enum CalendarPermissionStatus {
    case notDetermined
    case denied
    case granted
}

struct CalendarPermissionClient {
    var status: @MainActor () -> CalendarPermissionStatus
    var requestAccess: @MainActor () async -> Bool

    static let live: CalendarPermissionClient = {
        // 单例 EKEventStore：授权状态挂在 store 实例上，每次新建会丢失刚拿到的授权。
        let eventStore = EKEventStore()
        return CalendarPermissionClient(
            status: {
                switch EKEventStore.authorizationStatus(for: .event) {
                case .notDetermined:            return .notDetermined
                // writeOnly 对写入场景已经够用，按 granted 处理。
                // ⚠️ 不要往这里加 .authorized —— 它与 .fullAccess rawValue 相同
                // （都是 3），但 Swift 里是独立 case，同列不会编译失败只会触发
                // deprecated warning。iOS 17+ 的 authorizationStatus(for: .event) 永远
                // 不返回 .authorized（已废弃），加上是死代码且制造混淆。
                case .fullAccess, .writeOnly:   return .granted
                case .denied, .restricted:      return .denied
                @unknown default:               return .denied
                }
            },
            requestAccess: {
                // 必须是 requestFullAccessToEvents —— 与 SystemCalendarWriter.requestCalendarAccess()
                // (SystemCalendarWriter.swift:174) 请求同一档权限，否则首次写日历时会二次弹窗。
                await withCheckedContinuation { continuation in
                    eventStore.requestFullAccessToEvents { granted, error in
                        if let error {
                            VoiceTodoLog.calendar.error("permissions.calendar.failed error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
                        }
                        continuation.resume(returning: granted)
                    }
                }
            }
        )
    }()
}
```

`PermissionManager` 上新增（沿用文件里 mic/speech 的写法与日志风格）：

```swift
@Published private(set) var calendarGranted: Bool = false

func requestCalendarPermission() async -> Bool { ... }   // uiTestOptions.isUITesting 分支走 mock
var isCalendarPermanentlyDenied: Bool { ... }            // 同 isMicPermanentlyDenied (:255-261) 的写法
```

并在 `checkCurrentStatus()`（:110-121）里一并刷新 `calendarGranted`。
`init` 需要多接一个 `calendarPermissionClient: CalendarPermissionClient = .live` 参数。

**顺手把旧参数改名**：现有的 `permissionClient: VoicePermissionClient`（:73 声明、
:93 init 参数、:96 赋值，以及 :118/:119/:133/:147/:180/:198/:260/:269 的调用）
改为 `voicePermissionClient`——加了日历客户端之后，一个带 voice 语义、一个不带，
读起来会持续困惑。引用面很浅：`PermissionManager.swift` 内 9 处 +
`VoiceTodoTests/App/PermissionManagerTests.swift` 的 4 处带标签 init 调用
（:19 / :48 / :78 / :103）。一次改干净。

> ⚠️ **`allPermissionsGranted`（:250-252）保持 `micGranted && speechGranted` 不变。**
> 它是语音权限页 Continue 按钮的开关（`OnboardingView.swift:1022-1023`），
> 把日历算进去会让用户卡死在第二屏。

### 3.4 `Protocols/UITestLaunchOptions.swift` — 新增 `--calendar-permission-denied`

照 `micPermissionDenied` / `speechPermissionDenied`（:8-9 声明，:22-23 解析）
加一个 `calendarPermissionDenied`。

`PermissionManager` 在 `uiTestOptions.isUITesting` 时**必须**走 mock 分支
（`calendarGranted = !uiTestOptions.calendarPermissionDenied`），绝不能碰真的 EventKit。

### 3.5 `App/OnboardingView.swift` — 两个新步骤

#### 3.5.1 枚举与路由

`OnboardingStep`（:8-14）在 `.voicePermissions` 之后插入两个 case——
**顺序完全由 `CaseIterable` 的声明顺序决定**：

```swift
private enum OnboardingStep: CaseIterable {
    case welcome
    case voicePermissions
    case speechLanguage      // 新增
    case calendarSync        // 新增
    case actionButton
    case proPaywall
    case completion
}
```

`body` 的 switch（:110-123）加两个分支。`visibleSteps`（:67-78）**不用改**——
两个新步骤都走 `default: return true`，始终显示。
页码指示器（:190-222）遍历 `visibleSteps.indices`，自动适配新长度。

`buttonTitle`（:1004-1016）、`shouldHideBottomBar`（:155-157）**都不用改**：两个新步骤都走 `default`——
底栏显示「下一步」，始终可点。这是有意的：两项都是可选的个性化设置，
任何状态下都不能卡住引导。

#### 3.5.2 `speechLanguageStep`

存储绑定（与 `HomeSettingsSheet.swift:11-12` 同一个 key，设置页无需任何改动就能读到）：

```swift
@AppStorage(SpeechRecognitionLanguage.storageKey)
private var speechLanguageRaw: String = SpeechRecognitionLanguage.auto.rawValue
```

视图骨架沿用其他 step 的固定结构（参考 `voicePermissionsStep` :394-476）：

```
Spacer().frame(height: 30)
  → 插图（圆底 + SF Symbol，仿 voicePermissionsIllustration :478-500，用 globe.asia.australia + waveform）
  → 标题 WarmFont.title(28) / 说明 WarmFont.body(17)，带 .offset(y: contentOffset).opacity(contentOpacity)
  → ForEach(SpeechRecognitionLanguage.allCases) { languageOptionRow(...) }
  → Spacer()
```

新增私有 builder `languageOptionRow(_ lang:isSelected:)`：

- 卡片外观**复用 `permissionCard` 的 chrome**（:556-565）：
  `RoundedRectangle(cornerRadius: 20)` + `WarmTheme.cardBackground` + shadow +
  `sketchColor.opacity(0.15)` 描边。
- 选中态：描边换成 `highlightColor`（`WarmTheme.primary`）+ 右侧
  `checkmark.circle.fill`——与 `UI/Paywall/PaywallView.swift` 里 `ProductCard`
  的选中语义保持一致，全 App 一套选择视觉。
- 主标题**直接复用** `lang.displayName`（即已有的 `settings.speech_language.*`），不新增文案。
- `.auto` 那一行加一条副标题：`onboarding.speech_language.auto_resolved %@`，
  `%@` 填 `SpeechRecognitionLanguage.systemResolved.displayName`。
  这是 3.1 存在的唯一理由——让「跟随系统」不再是黑箱。
- 点击 action：`speechLanguageRaw = lang.rawValue`（只选中，不前进；前进交给底栏「下一步」）。
- accessibility id：`"SpeechLanguageOption_\(lang.rawValue)"`；
  整个 step 外层挂 `"OnboardingSpeechLanguageStep"`。

**默认值**：`.auto` 已经是「跟随系统」，无需任何额外预选逻辑；
配合上面的副标题，就满足了「按系统语言预选、用户可改」。

#### 3.5.3 `calendarSyncStep`

存储绑定（与 `UI/Home/HomeView.swift:243` 同一个 key）：

```swift
@AppStorage(CalendarWriteMode.storageKey)
private var calendarWriteModeRaw: String = CalendarWriteMode.appOnly.rawValue

/// Toggle 的视觉状态，与持久化状态刻意分开。
///
/// 不直接绑 @AppStorage：授权是异步的，setter 里不立刻改 getter 读的值，
/// SwiftUI 重绘时开关会先弹回 off、拿到授权后再跳回 on，用户能直接看到抖动。
///
/// 也不能「乐观地先写 @AppStorage 再失败回滚」：系统弹窗期间 App 若被杀
/// （用户上划、系统回收），持久化的值会停在 .appAndSystemCalendar 而权限从未拿到——
/// 正是 §1.4 那个「开着但不工作」的状态换条路径重现。
///
/// 不变量：**持久化为 .appAndSystemCalendar ⟹ 权限确实拿到过。**
@State private var calendarSyncOn = false

@State private var isRequestingCalendarPermission = false
@State private var showCalendarDeniedNote = false
```

step 的 `.onAppear` 里做一次初始化（重装用户可能已是开启状态）：

```swift
calendarSyncOn = (calendarWriteModeRaw == CalendarWriteMode.appAndSystemCalendar.rawValue)
```

主体是一张卡（chrome 同 3.5.2），卡内一个 `Toggle`，`isOn` 用自定义 Binding：

```swift
private var calendarSyncBinding: Binding<Bool> {
    Binding(
        get: { calendarSyncOn },
        set: { wantsOn in
            calendarSyncOn = wantsOn          // 视觉立即跟手，不弹回
            guard wantsOn else {
                calendarWriteModeRaw = CalendarWriteMode.appOnly.rawValue
                showCalendarDeniedNote = false
                return
            }
            // 已授权（比如重装用户）直接开，不再多弹一次系统窗
            if permissionManager.calendarGranted {
                calendarWriteModeRaw = CalendarWriteMode.appAndSystemCalendar.rawValue
                return
            }
            isRequestingCalendarPermission = true
            Task {
                let granted = await permissionManager.requestCalendarPermission()
                isRequestingCalendarPermission = false
                if granted {
                    calendarWriteModeRaw = CalendarWriteMode.appAndSystemCalendar.rawValue
                } else {
                    // 只回滚视觉；calendarWriteModeRaw 全程没被写过，不存在写脏的窗口
                    calendarSyncOn = false
                    showCalendarDeniedNote = true
                }
            }
        }
    )
}
```

其余要点：

- `isRequestingCalendarPermission` 期间给 `Toggle` 加 `.disabled(true)`，
  避免系统弹窗出现前的几百毫秒里被反复切换。
- 失败回滚那次 `calendarSyncOn = false` 包一层 `withAnimation`，让开关滑回去
  而不是硬跳。
- `showCalendarDeniedNote` 为真时，在卡片下方渲染拒绝提示——
  **复用 `permissionActionArea` 的 denied 分支样式**（:591-618）：
  `onboarding.calendar.denied` 说明文字 + `onboarding.open_settings` 胶囊按钮调
  `permissionManager.openAppSettings()`。
  accessibility id 用独立的 `"OnboardingCalendarOpenSettingsButton"`，
  不要沿用权限页的 `"OpenSettingsButton"`——onboarding 期间两页可能前后出现，
  UI 测试若按 id 查找会跨页匹配到歧义节点。
- 隐私说明用现成的 `privacyNote(_:)`（:649-665），文案 `onboarding.calendar.privacy`。
- accessibility id：step 外层 `"OnboardingCalendarSyncStep"`，开关 `"CalendarSyncToggle"`。

#### 3.5.4 从系统设置返回后刷新权限态

`OnboardingView.body` 的 `.onAppear`（:137-141）只在 sheet 首次出现时刷新权限。
用户点「去设置开启」授权完切回 App，开关不会自动变可用。**在 `.onAppear` 之外另加**
（不是替换）：

```swift
@Environment(\.scenePhase) private var scenePhase

// body 上
.onChange(of: scenePhase) { _, phase in
    guard phase == .active else { return }
    permissionManager.checkCurrentStatus()
}
```

`.onAppear` 管 sheet 首次出现,`.onChange(of: scenePhase)` 管后续从系统设置切回来。
**两者是互补关系,都要保留**——删掉 `.onAppear` 会让首次进入 onboarding 时不刷新权限态。

麦克风 / 语音识别页同样受益于这个修复（当前也有同样的空档）。

### 3.6 不需要 backfill

`CalendarWriteMode` 只在 confirm / 编辑 / 删除三条路径被读取
（`App/AppCoordinator.swift:611-621`、`:761-772`、`:808-817`），
切换模式从不回填历史 todo。onboarding 阶段本来就一条 todo 都没有，
语义天然正确，**不要新增任何回填逻辑**。

### 3.7 `Resources/Localizable.xcstrings` — 新增 key

只补 **`en` + `zh-Hans`** 两种语言（`project.yml:8-11` 的 `knownRegions` 只有
`Base / zh-Hans / en`；文件里零散的 `ja` 条目不是发布语言，不跟）。

| key | en | zh-Hans |
|---|---|---|
| `onboarding.speech_language.title` | How will you speak? | 你习惯用什么语言说？ |
| `onboarding.speech_language.desc` | Pick the language you'll record todos in. You can change it anytime in Settings. | 选择你录入待办时说的语言，之后可随时在设置里修改。 |
| `onboarding.speech_language.auto_resolved %@` | Currently: %@ | 当前为 %@ |
| `onboarding.calendar.title` | Sync to your Calendar? | 要同步到系统日历吗？ |
| `onboarding.calendar.desc` | Todos with a date can also appear in the iOS Calendar app, alongside your other events. | 带日期的待办可以同时出现在 iOS 日历里，和其他日程排在一起。 |
| `onboarding.calendar.toggle` | Write to iOS Calendar | 写入 iOS 日历 |
| `onboarding.calendar.privacy` | Events are written to your default calendar on this device only. | 事件只写入本机的默认日历，不上传。 |
| `onboarding.calendar.denied` | Calendar access was declined, so todos will stay in the app. You can turn it on later in Settings. | 未获得日历权限，待办将只保存在 App 内。你可以稍后在系统设置里开启。 |
| `a11y.onboarding.speech_language` | Recognition language selection | 识别语言选择 |
| `a11y.onboarding.calendar` | Calendar sync setting | 日历同步设置 |

（英文/中文文案为建议值，实施时按视觉效果微调；关键是 key 名与数量。）

**复用不新增**：`settings.speech_language.*`（4 个选项名）、`onboarding.open_settings`、
`onboarding.button.next`。

新文案一律按项目惯例配 `lineLimit` + `minimumScaleFactor`（零截断容忍度，
参考 `UI/Shared/ValuePropCard.swift:34-35`）。

### 3.8 `VoiceTodoUITests/ScenarioTests.swift` — 修 S12 + 新增拒绝路径用例

**S12 会踩在容错边界上。** `test_S12_firstLaunch_onboarding`（:424-475）在
第 440 行先点一次「下一步」，随后：

```swift
var attempts = 0
while !laterButton.exists && attempts < 3 {   // :443-449
    if appHelper.nextButton.exists { appHelper.nextButton.tap() }
    _ = laterButton.waitForExistence(timeout: 1.5)
    attempts += 1
}
```

点击次数构成（改后，从权限页数起）：

| 机型 | 路径 | 总点击 | 第 440 行占 1 次后，循环还需 |
|---|---|---|---|
| 无 Action Button | 权限页 → 语言页 → 日历页 → 付费墙 | 3 | **2** |
| 有 Action Button | 权限页 → 语言页 → 日历页 → AB 页 → 付费墙 | 4 | **3** |

现有的 `attempts < 3` 恰好等于有 AB 机型的需求量——**零余量**，动画时序稍有抖动
就会红。（注意别把第 440 行那次当成额外的一次：它就是上表 3-4 次里的第一次。）

改法：

- 把上限提到 `attempts < 6`，留 3 次余量。**把上表的次数构成写进注释**，
  下次再插步骤的人才知道 6 是怎么来的、还剩多少额度。
- 在循环之前显式断言两个新步骤依次出现
  （`OnboardingSpeechLanguageStep` → 点下一步 → `OnboardingCalendarSyncStep`），
  让失败信息直接指向具体哪一步，而不是笼统的「付费墙没出现」。

**新增用例 `test_S14_calendarPermissionDenied_revertsToggle`**（参考 :481 起的 S13 写法）：
以 `--calendar-permission-denied` 启动 → 走到 `OnboardingCalendarSyncStep` →
打开 `CalendarSyncToggle` → 断言：

- [ ] 开关回弹到关
- [ ] `OnboardingCalendarOpenSettingsButton` 出现
- [ ] `NextButton` 仍可点
- [ ] 能继续走完引导进主界面（引导不被权限拒绝卡死）

`VoiceTodoUITests/AppLaunchHelper.swift` 需要补一个
`launchWithCalendarPermissionDenied()`，照 `launchWithMicPermissionDenied()` 写。

### 3.9 `VoiceTodoTests/Voice/VoiceInputTests.swift` — 守住 3.1/3.2 的重构等价性

现有 :62-64 已断言 `VoiceConstants.supportedLocales`。补两条：

```swift
// ① systemResolved 永不返回 auto，且必落在受支持的 locale 内 ——
//    守住 resolveSystemLocale() 委托重构后的行为等价。
let resolved = SpeechRecognitionLanguage.systemResolved
XCTAssertNotEqual(resolved, .auto)
XCTAssertTrue(VoiceConstants.supportedLocales.contains { $0.identifier == resolved.fixedLocale?.identifier })

// ② 非 auto 的 case 必须与 supportedLocales 集合一一对应。
//    两边任一侧单方面增删（比如加了 .koKR 却忘了 supportedLocales），
//    auto 匹配和 Picker 选项就会漂出两套语言集 —— 这是真正的漂移风险。
XCTAssertEqual(
    Set(SpeechRecognitionLanguage.allCases.compactMap { $0.fixedLocale?.identifier }),
    Set(VoiceConstants.supportedLocales.map(\.identifier))
)
```

> **不要加「顺序守护」断言**（如 `allCases.last == .enUS`）。前缀 `"zh"` / `"ja"` / `"en"`
> 两两互不包含，遍历顺序对匹配结果没有影响；而 `allCases` 的顺序同时决定设置页和
> 引导页 Picker 的**显示顺序**。钉死它会让「把 English 挪到前面」这类纯 UI 调整
> 撞在一个声称守护匹配规则的测试上——测试钉错了对象。

---

## 4. 涉及文件一览

| 文件 | 改动 |
|---|---|
| `App/OnboardingView.swift` | 枚举 +2 case、switch +2 分支、两个 step view、`languageOptionRow` builder、scenePhase 刷新 |
| `App/PermissionManager.swift` | `CalendarPermissionClient` + 日历权限状态 / 请求 / 永久拒绝判断；`permissionClient` → `voicePermissionClient` |
| `Voice/SpeechRecognitionLanguage.swift` | `static var systemResolved` |
| `Voice/VoiceInputManager.swift` | `resolveSystemLocale()` 改为委托（保留日志字段） |
| `Protocols/UITestLaunchOptions.swift` | `--calendar-permission-denied` |
| `Resources/Localizable.xcstrings` | 新增 10 个 key（en + zh-Hans） |
| `VoiceTodoUITests/ScenarioTests.swift` | 修 S12 容错 + 新增 S14 |
| `VoiceTodoUITests/AppLaunchHelper.swift` | `launchWithCalendarPermissionDenied()` |
| `VoiceTodoTests/Voice/VoiceInputTests.swift` | `systemResolved` + 语言集合相等断言 |
| `VoiceTodoTests/App/PermissionManagerTests.swift` | 跟随 `voicePermissionClient` 改名（4 处 init 调用） |

**明确不改**：

- `UI/Home/HomeSettingsSheet.swift` / `UI/Home/HomeView.swift`——设置页两项**保留原样**
- `Protocols/CalendarWriteMode.swift`
- `App/AppCoordinator.swift` / `App/CalendarSyncService.swift` / `App/SystemCalendarWriter.swift`

两个设置沿用同一批 `UserDefaults` key，onboarding 写进去，现有消费方
（`VoiceInputManager.resolveCurrentLocale()`、`AppCoordinator.calendarWriteModeProvider`）
自动生效，**不需要任何新的同步逻辑**。

无新增源文件；即便新增，`project.yml:29-72` 用目录 glob，也不需要改工程配置
（`.xcode_main_app_files.txt` 是过期的遗留清单，不用动）。

---

## 5. 验证

1. **构建**
   ```
   xcodebuild -project VoiceTodo.xcodeproj -scheme VoiceTodo \
     -destination 'platform=iOS Simulator,name=iPhone 17' build
   ```
   若 `project.yml` 有变动，先跑 `./prepare_xcode_project.sh`。

2. **单元测试**
   ```
   xcodebuild test -scheme VoiceTodo -destination '...' -only-testing:VoiceTodoTests
   ```

3. **UI 测试**
   ```
   xcodebuild test -scheme VoiceTodo -destination '...' \
     -only-testing:VoiceTodoUITests/ScenarioTests/test_S12_firstLaunch_onboarding \
     -only-testing:VoiceTodoUITests/ScenarioTests/test_S14_calendarPermissionDenied_revertsToggle
   ```

4. **模拟器手动走查**（全新安装；删 App 重装以清 UserDefaults）

   - [ ] 顺序为 欢迎 → 语音权限 → 语言 → 日历 → [Action Button] → 付费墙 → 完成，
         顶部页码圆点数量与实际步数一致
   - [ ] 语言页默认选中「跟随系统」，副标题显示当前解析到的语言
   - [ ] 系统语言切成英文后重进引导，副标题跟着变成 English（验证 3.1）
   - [ ] 选「中文」→ 完成引导 → 设置页「识别语言」显示中文（同 key 打通）
   - [ ] 日历页打开开关 → **弹出系统日历授权弹窗**（本次核心验收点）
   - [ ] 授权 → 开关保持开 → 完成引导 → 设置页「写入位置」为「App + 系统日历」
   - [ ] 录一条带时间的待办并确认 → 事件出现在系统日历，**且不再二次弹权限**
         （验证 onboarding 请求的是 full access，与 writer 同档）
   - [ ] 拒绝授权 → 开关回弹到关、出现「去设置开启」、`NextButton` 仍可点
   - [ ] 点「去设置开启」授权后切回 App → 开关变为可开（验证 3.5.4）
   - [ ] 两页都不做任何操作直接点「下一步」→ 走得完，落到默认值 `.auto` / `.appOnly`
   - [ ] 已订阅用户（`isPro`）重装：跳过付费墙，但两个新步骤仍然出现

5. **回归**
   - [ ] 设置页两项仍可正常修改，改完下次录音 / 下次 confirm 生效
   - [ ] 设置页「从日历导入」不受影响（走的是 `SystemCalendarReader` 的独立授权路径）

---

## 6. 实施注意事项

- **不要动 `allPermissionsGranted`。** 它只管 mic && speech；把日历算进去会让
  语音权限页的 Continue 永久禁用。
- **日历权限必须用 `requestFullAccessToEvents`。** 与
  `SystemCalendarWriter.swift:174` 同档，否则用户会被弹两次权限窗。
- **`CalendarPermissionClient.live` 里的 `EKEventStore` 必须是长生命周期实例**，
  不能每次调用新建——授权状态挂在 store 实例上。
- **两个新步骤的「下一步」在任何状态下都必须可点。** 权限被拒、EventKit 不可用、
  语言一个都没选，用户都要能走完引导。这与 `proPaywall` 的「以后再说」是同一条原则
  （见 `docs/onboarding-paywall-merge.md` 第 5 节）。
- **不要为 onboarding 新建第二套设置存储。** 两项都直接 `@AppStorage` 复用
  `SpeechRecognitionLanguage.storageKey` / `CalendarWriteMode.storageKey`，
  设置页与引导页共享同一份真相。
- **UI 测试路径绝不能触发真的 EventKit 授权**，否则测试会被系统弹窗永久挂起。
  `PermissionManager` 的 `isUITesting` 分支要在**调用 client 之前**短路。
- **日历开关的视觉状态和持久化状态必须分开**（§3.5.3）。既不能直接绑
  `@AppStorage`（开关会抖），也不能乐观地先写 `@AppStorage` 再回滚
  （弹窗期间 App 被杀会留下「开着但没权限」的脏值）。不变量有两个来源：
  (a) `requestAccess` 成功路径,(b) 「`permissionManager.calendarGranted` 已为真」
  的快路径——后者依赖 `checkCurrentStatus()` 读的是
  `EKEventStore.authorizationStatus(for: .event)` 的真实系统状态,不是 `@AppStorage`。
  后续若有人把 `calendarGranted` 改为读 `@AppStorage`,这条不变量会被无声打破,
  必须加测试守护。
- **`EKAuthorizationStatus` 的 switch 里不要写 `.authorized`**，它与 `.fullAccess`
  rawValue 相同（都是 3），但 Swift 里是独立 case，同列不会 duplicate case
  编译失败，只会触发 deprecated warning。`authorizationStatus(for: .event)` 在
  iOS 17+ 永远不返回 `.authorized`（已废弃），加它是死代码。

---

## 7. 评审意见与处置记录

第一轮评审提了 5 条。**结论已全部合并进 §1–§6，实施时按正文执行即可**，
本节只保留处置理由，供后续接手者理解「为什么是这样」，不必再单独执行一遍。

| # | 评审意见 | 处置 | 已合并到 |
|---|---|---|---|
| 7.1 | Toggle setter 时序会导致开关抖动 | **认问题，换修法** | §3.5.3、§6 |
| 7.2 | 补 `allCases` 顺序守护测试 | **不采纳**，改为集合相等测试 | §3.1、§3.9 |
| 7.3 | 繁中系统落到 `.zhHans` | **采纳**，标注为已知限制 | §3.1 |
| 7.4 | `permissionClient` 命名不对称 | **采纳**，一并改名 | §3.3、§4 |
| 7.5 | `attempts < 6` 缺论证 | **采纳**，但原文数字算错，已修正 | §3.8 |
| 7.6 | （新）`.authorized` 是 `.fullAccess` 废弃别名 | 两轮都漏了，补上 | §3.3、§6 |

---

### 7.1 Toggle 时序：问题成立，但「乐观更新」是错误的修法

**问题描述是对的**：自定义 `Binding` 的 setter 里不改 getter 读的值，
SwiftUI 重绘时 Toggle 会先弹回 off、拿到授权后再跳回 on，用户能直接看到抖动。
原方案（§3.5.3 初版）确实有这个疏漏。

**但评审提的「乐观更新 + 失败回滚」不能用**：它把 `.appAndSystemCalendar`
写进了 UserDefaults，而权限还没拿到。系统弹窗期间 App 若被杀（用户上划、系统回收），
持久化的值就停在「开着」而权限从未给过——**正是 §1.4 说「不能重蹈覆辙」的
那个「开着但不工作」状态，只是换了条路径产生**。

正确的做法是让**视觉状态和持久化状态分开**：Toggle 绑本地 `@State`，
`@AppStorage` 只在授权成功后才写。失败路径的视觉表现与「乐观更新」完全一样，
但没有写脏持久化的窗口。

**不变量**：**持久化为 `.appAndSystemCalendar` ⟹ 权限确实拿到过。**
两条写持久化的路径都必须守护它：
- 主路径(`requestAccess` 成功 → 写 `@AppStorage`)：由 `requestFullAccessToEvents`
  的 granted 返回值守护。
- 快路径(`permissionManager.calendarGranted` 已为真 → 直接写 `@AppStorage`,
  覆盖重装用户)：由 `checkCurrentStatus()` 读
  `EKEventStore.authorizationStatus(for: .event)` 真实系统状态守护。
  **不要把 `calendarGranted` 改成读 `@AppStorage`**——会把不变量绕成自指。

→ 代码见 §3.5.3。

### 7.2 顺序守护测试：前提不成立，不加

评审称「改了 `allCases` 顺序，中文/中英混说系统的匹配会变」。**这个推断是错的。**

三个 case 的 languageCode 是 `"zh"` / `"ja"` / `"en"`，两两之间谁也不是谁的前缀。
对任意 `Locale.preferredLanguages.first`，`hasPrefix` 最多命中一个——命中哪个与
遍历顺序无关。把 `.enUS` 提到第一位，`"zh-Hans-CN"` 仍然只会匹配到 `.zhHans`。
**顺序在当前语言集下可证明无关。**

而且评审提议的 `allCases.last == .enUS` 会把枚举顺序钉死，
而这个顺序同时决定**设置页和引导页 Picker 的显示顺序**。将来想把 English
挪到前面这种纯 UI 调整，会撞在一个声称守护「匹配规则」的测试上——测试钉错了对象。
（另：那段代码里的 `XCTEqual` 不是 XCTest 的 API，照抄会编译失败。）

**真正值得守护的是集合相等**：非 `auto` 的 case 集合必须等于
`VoiceConstants.supportedLocales`。有人给枚举加了 `.koKR` 却忘了同步
`supportedLocales`（或反过来），auto 匹配和 Picker 就会各说各话——这才是真实的漂移风险。

→ 测试见 §3.9 的 ②。

**连带修正**：§3.1 初版写的「不要改动枚举 case 的声明顺序」是过度约束，
评审是顺着这句错误推下去的。该句已改为「集合一一对应，顺序无关」。

### 7.3 繁中 / 粤语落到 `.zhHans`：采纳，标注为已知限制

`"zh-Hant-TW".hasPrefix("zh")` 为 true，确实落到 `.zhHans`。原逻辑就是这样，
§3.2 的委托重构没引入新问题。

补一点评审没提的边界：受影响最明显的其实不是繁中普通话用户（识别引擎都是普通话，
只是输出简体字形），而是**粤语用户**——`zh-HK` 同样命中 `zh` 前缀，
会被塞进普通话识别器。

→ 已写入 §3.1，要求作为注释落到 `systemResolved` 的文档注释里。

### 7.4 `permissionClient` 改名：采纳

引用面很浅：`App/PermissionManager.swift` 内 9 处（:73 声明、:93 init 参数、
:96 赋值，以及 :118/:119/:133/:147/:180/:198/:260/:269 的调用）+
`VoiceTodoTests/App/PermissionManagerTests.swift` 的 4 处带标签 init 调用
（:19 / :48 / :78 / :103）。一次改干净比留个永久 papercut 划算。

→ 已写入 §3.3，`VoiceTodoTests/App/PermissionManagerTests.swift` 已补进 §4 文件表。

### 7.5 点击次数论证：采纳，但评审的数字算错了

要求补论证是对的。但评审列的「加上 S12 现有的『先点一次』共 4 或 5 次」
把同一次点击数了两遍——`ScenarioTests.swift:440` 那次点击**就是**
3-4 次总量里的第一次，不是额外一次。

正确构成：无 AB 机型 3 次、有 AB 机型 4 次；第 440 行占 1 次，
循环还需 2 次或 3 次。现有 `attempts < 3` 恰好等于有 AB 机型的需求量，零余量。

→ 修正后的次数表见 §3.8，并要求把它写进测试注释。

### 7.6 `.authorized` 是 `.fullAccess` 的废弃别名（两轮评审都漏了）

`EKAuthorizationStatus.authorized` 与 `.fullAccess` rawValue 相同（都是 3），
在同一个 `switch` 里一起列**不会** duplicate case 编译失败——Swift 视它们为
独立 case，只会触发 deprecated warning。但 `authorizationStatus(for: .event)` 在
iOS 17+ 永远不返回 `.authorized`（已废弃），加它是死代码且制造混淆。
实施者看到 `.authorized` 出现在补全列表里很容易顺手加上。

→ 已写入 §3.3 的代码注释与 §6。
