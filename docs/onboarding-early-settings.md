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

注意：`allCases` 中非 `auto` 的顺序是 `.zhHans / .jaJP / .enUS`（第 15-19 行），
与 `Voice/VoiceConstants.swift:27-31` 的 `supportedLocales` 同序同内容——
这是重构等价的前提，**不要改动枚举 case 的声明顺序**。

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
                // writeOnly 对写入场景已经够用，按 granted 处理
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

`buttonTitle`（:1004-1016）、`isPrimaryButtonDisabled`（:1020-1027）、
`shouldHideBottomBar`（:155-157）**都不用改**：两个新步骤都走 `default`——
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

@State private var isRequestingCalendarPermission = false
@State private var showCalendarDeniedNote = false
```

主体是一张卡（chrome 同 3.5.2），卡内一个 `Toggle`，`isOn` 用自定义 Binding：

```swift
private var calendarSyncBinding: Binding<Bool> {
    Binding(
        get: { calendarWriteModeRaw == CalendarWriteMode.appAndSystemCalendar.rawValue },
        set: { wantsOn in
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
                    // 保持 .appOnly —— 开关自然回弹到关，不出现「开着但不工作」的状态
                    calendarWriteModeRaw = CalendarWriteMode.appOnly.rawValue
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
- `showCalendarDeniedNote` 为真时，在卡片下方渲染拒绝提示——
  **复用 `permissionActionArea` 的 denied 分支样式**（:591-618）：
  `onboarding.calendar.denied` 说明文字 + `onboarding.open_settings` 胶囊按钮调
  `permissionManager.openAppSettings()`，accessibility id 沿用 `"OpenSettingsButton"`。
- 隐私说明用现成的 `privacyNote(_:)`（:649-665），文案 `onboarding.calendar.privacy`。
- accessibility id：step 外层 `"OnboardingCalendarSyncStep"`，开关 `"CalendarSyncToggle"`。

#### 3.5.4 从系统设置返回后刷新权限态

`OnboardingView.body` 的 `.onAppear`（:137-141）只在 sheet 首次出现时刷新权限。
用户点「去设置开启」授权完切回 App，开关不会自动变可用。加：

```swift
@Environment(\.scenePhase) private var scenePhase

// body 上
.onChange(of: scenePhase) { _, phase in
    guard phase == .active else { return }
    permissionManager.checkCurrentStatus()
}
```

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

新流程从权限页到付费墙恰好需要 4 次点击（语言 → 日历 → Action Button → 付费墙），
**刚好用满 1 + 3、毫无余量**。改法：

- 把上限提到 `attempts < 6`。
- 在循环之前显式断言两个新步骤依次出现
  （`OnboardingSpeechLanguageStep` → 点下一步 → `OnboardingCalendarSyncStep`），
  让失败信息直接指向具体哪一步，而不是笼统的「付费墙没出现」。

**新增用例 `test_S14_calendarPermissionDenied_revertsToggle`**（参考 :481 起的 S13 写法）：
以 `--calendar-permission-denied` 启动 → 走到 `OnboardingCalendarSyncStep` →
打开 `CalendarSyncToggle` → 断言：

- [ ] 开关回弹到关
- [ ] `OpenSettingsButton` 出现
- [ ] `NextButton` 仍可点
- [ ] 能继续走完引导进主界面（引导不被权限拒绝卡死）

`VoiceTodoUITests/AppLaunchHelper.swift` 需要补一个
`launchWithCalendarPermissionDenied()`，照 `launchWithMicPermissionDenied()` 写。

### 3.9 `VoiceTodoTests/Voice/VoiceInputTests.swift` — 守住 3.1/3.2 的重构等价性

现有 :62-64 已断言 `VoiceConstants.supportedLocales`。补一条：

```swift
// systemResolved 永不返回 auto，且必落在受支持的 locale 内 ——
// 守住 resolveSystemLocale() 委托重构后的行为等价。
let resolved = SpeechRecognitionLanguage.systemResolved
XCTAssertNotEqual(resolved, .auto)
XCTAssertTrue(VoiceConstants.supportedLocales.contains { $0.identifier == resolved.fixedLocale?.identifier })
```

---

## 4. 涉及文件一览

| 文件 | 改动 |
|---|---|
| `App/OnboardingView.swift` | 枚举 +2 case、switch +2 分支、两个 step view、`languageOptionRow` builder、scenePhase 刷新 |
| `App/PermissionManager.swift` | `CalendarPermissionClient` + 日历权限状态 / 请求 / 永久拒绝判断 |
| `Voice/SpeechRecognitionLanguage.swift` | `static var systemResolved` |
| `Voice/VoiceInputManager.swift` | `resolveSystemLocale()` 改为委托（保留日志字段） |
| `Protocols/UITestLaunchOptions.swift` | `--calendar-permission-denied` |
| `Resources/Localizable.xcstrings` | 新增 10 个 key（en + zh-Hans） |
| `VoiceTodoUITests/ScenarioTests.swift` | 修 S12 容错 + 新增 S14 |
| `VoiceTodoUITests/AppLaunchHelper.swift` | `launchWithCalendarPermissionDenied()` |
| `VoiceTodoTests/Voice/VoiceInputTests.swift` | `systemResolved` 断言 |

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

---

## 7. 实施前需确认的开放问题

以下 5 点在本方案起草时识别但未完全解决,实施前需逐一确认。

### 7.1 P1 — §3.5.3 Toggle setter 时序反模式(必须修)

§3.5.3 的 `calendarSyncBinding` setter 时序:

1. 用户拨 Toggle 到 on → setter 被调用,`wantsOn=true`
2. setter 进 `Task` 异步分支,**但 raw 值没改**(还是 `appOnly`)
3. SwiftUI 重读 getter → `calendarWriteModeRaw` 仍是 `appOnly` → 返回 `false`
4. Toggle 视觉**立即弹回 off**
5. 几百毫秒后授权成功 → 改 raw → Toggle 变 on

用户感知:「拨到 on → 弹回 off → 又变 on」,体验突兀。这是 iOS 设置类 Toggle 的反模式。

**实施约束**:改成「乐观更新 + 失败回滚」:

```swift
set: { wantsOn in
    guard wantsOn else {
        calendarWriteModeRaw = CalendarWriteMode.appOnly.rawValue
        showCalendarDeniedNote = false
        return
    }
    // 乐观更新:Toggle 立即显示 on,失败再回滚
    calendarWriteModeRaw = CalendarWriteMode.appAndSystemCalendar.rawValue
    if permissionManager.calendarGranted { return }
    isRequestingCalendarPermission = true
    Task {
        let granted = await permissionManager.requestCalendarPermission()
        isRequestingCalendarPermission = false
        if !granted {
            calendarWriteModeRaw = CalendarWriteMode.appOnly.rawValue  // 回滚
            showCalendarDeniedNote = true
        }
    }
}
```

回滚路径里 `showCalendarDeniedNote = true` 跟原方案语义一致(拒绝 → 显「去设置开启」),只是 Toggle 视觉走「先 on,失败再弹回」而不是「先弹回,成功再变 on」。

### 7.2 P2 — §3.9 测试不守护「匹配规则等价」(应补)

§3.1 把「匹配规则与原 `resolveSystemLocale()` 完全一致」作为重构等价的前提,但 §3.9 补的测试只守护两条不变量(`systemResolved ≠ .auto` + 返回值在 `supportedLocales` 内),**不守护优先级顺序**。

如果未来有人改了 `allCases` 顺序(比如把 `.enUS` 提到第一),中文/中英混说系统的匹配会变,§3.9 测试不会失败 —— 重构等价的前提静默失效。

**实施约束**:在 §3.9 补隐式顺序守护:

```swift
// CaseIterable 顺序决定 systemResolved 的匹配优先级。
// 改顺序会让中英混说系统的解析结果变化 —— 这是 §3.1 等价重构的隐含约束。
XCTEqual(SpeechRecognitionLanguage.allCases.first { $0 != .auto }, .zhHans)
XCTEqual(SpeechRecognitionLanguage.allCases.last, .enUS)
```

### 7.3 P2 — 繁中系统匹配到 `.zhHans`(既有 bug,标注为已知限制)

`"zh-Hant-TW".hasPrefix("zh")` = true → 返回 `.zhHans`(简体)。**原逻辑就有这个行为**,本方案作为等价重构没引入新问题,但应在文档里标注,避免下次有人排查「为什么繁中用户被识别成简体」时走弯路。

**实施约束**:MVP 不支持繁中,接受现状。后续若加繁中支持,匹配规则要细化(用 `languageCode + script` 区分 `zh-Hans` / `zh-Hant`,而不是仅 prefix `zh`)。本次实施保持原匹配逻辑。

### 7.4 P3 — `permissionClient` vs `calendarPermissionClient` 命名不对称

§3.3 加 `CalendarPermissionClient` 后,旧的 `permissionClient: VoicePermissionClient` 跟新命名不对称 —— 一个有 voice 前缀语义、一个没有。不是 bug,但读起来不一致。

**实施约束**:可选。要修就一起改:`permissionClient` → `voicePermissionClient`,并更新所有引用点(`init` 参数、`checkCurrentStatus` / `ensureVoicePermissionsBeforeRecording` / `requestMicPermission` / `requestSpeechPermission` 内的 `permissionClient.xxx` 调用)。不修不影响功能,但会让后续读者困惑一次。

### 7.5 P3 — §3.8 `attempts < 6` 缺论证

§3.8 说「上限提到 6」但没列实际需要几次点击,实施者无法判断 6 是不是真的够。

**实施约束**:在 §3.8 的注释里显式列出点击次数构成:

- 不支持 Action Button 的设备:`权限页→语言页→日历页→付费墙` = 3 次点击
- 支持 Action Button:`权限页→语言页→日历页→AB页→付费墙` = 4 次点击
- 加上 S12 现有的「先点一次」(`ScenarioTests.swift:440`)共 4 或 5 次
- `attempts < 6` 给 6 次循环,2 次余量应对动画时序抖动

### 7.6 小结

5 个开放问题归为 3 类:

| 类别 | 涉及 | 共同主题 |
|---|---|---|
| UX 时序 | §7.1 | Toggle 异步 setter 必须乐观更新,否则视觉抖动会被用户直接感知 |
| 测试守护 | §7.2、§7.3 | 「等价重构」的隐含约束(顺序、边界输入)必须转化为可执行测试,否则未来会静默失效 |
| 表达精度 | §7.4、§7.5 | 命名不对称、魔法数字缺注释 —— 不影响功能,但影响下一次接手者的判断速度 |

实施前的最小 checklist:

1. **§3.5.3 Toggle setter 改乐观更新 + 失败回滚**(覆盖 §7.1)—— 上线前必修
2. **§3.9 补 CaseIterable 顺序守护测试**(覆盖 §7.2)—— 上线前必修
3. **§3.1 注释里标注「繁中系统会落到简中,MVP 已知限制」**(覆盖 §7.3)
4. **§3.3 视精力同步改名 `voicePermissionClient`,或显式注明「保持现状,有意不对称」**(覆盖 §7.4)
5. **§3.8 注释里列出点击次数构成**(覆盖 §7.5)
