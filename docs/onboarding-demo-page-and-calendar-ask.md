# Onboarding 改版：演示页 + 日历延后询问 + 文案纠错

> 状态：已实现（2026-08-23 拍板，同日落地）
> 前置文档：`docs/onboarding-first-voice-trial.md`（v3，首次语音试用引导，本文不改动其流程）

## 0. 拍板记录（2026-08-23）

用户对 onboarding 五页逐页审查后拍板四项：

| # | 决定 | 落点 |
|---|------|------|
| 1 | 删日历同步页，改为首次确认带日期待办后一次性询问 | §2 |
| 2 | 新增「一句话 → 两条待办」演示页（welcome 三卡保留） | §3 |
| 3 | completion 页结构不动，只修三处事实性文案错误 | §4 |
| 4 | 隐私文案改讲真话（原「设备本地完成」与实际技术不符） | §5 |

另含审查确认的小修：按钮统一「下一步」、权限全开后隐藏「先跳过」、
feature1「按下按钮」改为明确的「点一下麦克风」、feature3 不再承诺「随时提醒」、
auto 副标题「当前为 %@」改「当前:%@」。

审查中**不成立**的两条（留档防重提）：
- 「语言页默认选中的是中文」——代码默认 `.auto`（OnboardingView 的
  `speechLanguageRaw` 初值），截图上的「中文（支持中英混说）」是 auto 行的副标题。
- 「Action Button 完全没提到」——有整页设置引导，仅按机型过滤
  （`ActionButtonCapability`：iPhone 15 Pro / 16+）；审查设备不支持所以没看到。

## 1. 页面结构变化

```
旧: welcome → voicePermissions → speechLanguage → calendarSync → (actionButton) → completion
新: welcome → demo → voicePermissions → speechLanguage → (actionButton) → completion
```

（`actionButton` 仅在支持机型出现；页数在无 Action Button 机型上不变，5 → 5。）

## 2. 日历同步：从 onboarding 整页 → 首次带日期待办后一次性询问

动机：onboarding 里凭空推荐功能、开关却默认关，大多数人直接「下一步」，
整页白占。延后到用户刚看到「今晚八点」被识别成带时间待办的那一刻请求价值
（iOS 权限请求的标准时机：用户理解价值的那一刻）。

实现（`UI/Shared/CalendarSyncAskSheet.swift` + `HomeView.maybePresentCalendarSyncAsk`）：

- 触发点：`revealConfirmedTodos()`（ConfirmSheet 关闭、待办已落库）末尾。
- 触发条件（全满足才弹）：
  1. 从未弹过（`CalendarWriteMode.deferredAskShownKey`，弹过一次永不复弹，含下滑关闭）
  2. 本次确认批次里有 `dueDate != nil` 的待办
  3. 写模式仍是 `.appOnly`（设置里主动配置过的用户不打扰）
  4. 不是首次语音 wow（wow 时刻 paywall 已排队，不叠第二层打断）
  5. UI 测试默认抑制，`--calendar-ask` 显式开启（防既有场景断言被弹层打断）

已被拒的用户**不排除**：sheet 的被拒分支自带「去设置开启」出口，
「不再打扰」由一次性 flag 保证。
- 持久化不变量沿用原 onboarding 页：`.appAndSystemCalendar ⟹ 权限确实拿到过`
  ——持久化只在 `requestCalendarPermission()` 返回 true（或已授权）后写入，被拒只回滚视觉。
- **已知取舍**：触发的这批待办在询问**之前**已落库，不回填进系统日历；
  开启后从下一条带日期待办开始同步。文案按此事实表述，不承诺回填。

## 3. 演示页（welcome 之后新增）

静态 before/after：口语「明天下午三点跟张总开会，顺便买点牛奶」→
两条待办行（带时间胶囊 / 不带）。动机：三张 feature 卡是「声明」，
产品的说服力在「乱糟糟的口语变成整齐待办」这个瞬间，把它前置演示。

示例台词与 completion 页 / 主页 hint 的 `home.first_trial.example`
（「今晚八点给妈妈打电话」）**刻意不同**——那是用户接下来要照着说的句子，
这里是演示，避免同一句话在 onboarding 里出现三遍。

## 4. completion 页文案纠错（结构不动）

| 错误 | 根因 | 修正 |
|------|------|------|
| 「点**右下角**的麦克风」 | 2026-07-12 设计改版把 FAB 移到底部**中央**（`BottomTabBar.swift`「独占底部中央」），文案没跟上 | 改用颜色描述：「点亮那个橙色的麦克风按钮」 |
| 「**回到**清单」 | onboarding 是首启 sheet，用户从没见过清单 | 删除 |
| 卡片「点**下面的**麦克风按钮」 | completion 页下面是「去试一句」按钮，没有麦克风 | 该 key 与主页 hint 共用（有意同源、认知连续），去掉「下面的」后两处都成立 |

## 5. 隐私文案：从失实到讲真话

原 zh「语音转文字在设备本地完成；任务解析会把文字发到服务器处理」——前半句失实：
`VoiceInputManager.makeRecognitionRequest` 未设 `requiresOnDeviceRecognition`
（全仓库 0 处），SFSpeechRecognizer 默认会把**音频**发给 Apple 服务器识别。

新口径（zh）：「语音由 Apple 转成文字，只有文字会发到服务器解析成待办」。
真实链路：音频 → Apple（转录）、文字 → 我们的代理（解析）。

- `PrivacyInfo.xcprivacy` 无需改：标签声明的是到达**我们**基础设施的数据
  （转写文本 = Other User Content），音频由 Apple 按系统框架处理、从不落到我们服务器。
- 顺手删除两个未引用且含失实文案的 stale key：`onboarding.mic.privacy`
  （「不会保存或上传」）与 `onboarding.speech.privacy`。
- 若未来想让「本地完成」变真，需设 `requiresOnDeviceRecognition = true`，
  代价是识别质量 / 机型兼容 / 中英混说效果需真机重验——本次拍板选改文案不改技术。
