# 本地化占位符审计 —— 纯数据插值被误登记为可翻译字符串

> 状态：待实施
> 目标分支：`claude/recording-button-overlay-issue-t1sfxq`
> 本文档自包含，可直接按「三」「四」「五」三节执行。

## 一、如何复现

Xcode → Product → Scheme → Edit Scheme → Run → Options → App Language → **Double-Length Pseudolanguage** → 直接运行。

观察到的现象：

- 月历网格的日期数字渲染成 `lld 29`、`lld 4`、`lld 18`
- 月历网格的待办事件条全部渲染成彩色的 `@`
- 顶部渲染成 `今天 今天 lld/lld 0/6`、`今日 今日`、`日历 日历`，星期栏 `三 三`、`四 四`

**最后一组是伪本地化正常工作的样子**（把文案复制一遍）。前两组是同一机制作用在**含格式化占位符的字符串**上时的崩坏。

## 二、根因，以及「这算不算 bug」

SwiftUI 的 `Text(_:)` 接收的是 **`LocalizedStringKey`，不是 `String`**。因此 `Text("\(整数)")` 会被 Xcode 当作一条需要翻译的字符串抽取出来，key 就是字面的 `%lld`；三段 `Text` 拼接抽出的 key 就是 `%@%@%@`。

伪本地化对这条 key 的值做了复制变换，结果是屏幕上出现了本应是占位符的字面文本。

**这里必须说清楚哪些是确定的、哪些不是** —— 因为定位这个 bug 并不需要知道确切的变换规则，而写死一个未经验证的机制反而会误导后续排查：

- **确定**：这些字符串本不该进入本地化管线。根因是 `Text("\(...)")` 走了 `LocalizedStringKey` 重载。
- **确定**：默认语言（en / zh-Hans）下不会出现该现象，因为这些 key 的值恰好等于 key 本身，占位符数量与实参数量一致。
- **未确定**：Apple 的 Double-Length Pseudolanguage 对格式化占位符具体做了什么变换。

需要排除一个常见的错误解释：「多出的占位符没有实参可填，`%` 被吃掉、剩下 `lld`」。这不成立。C/ObjC 变参语义下缺实参是未定义行为，读到的是寄存器/栈上的残留值，不会把 `%` 消费掉：

```c
printf("%lld %lld", 29LL);    // → "29 0"     ← 不是 "lld 29"
printf("%%lld %lld", 29LL);   // → "%lld 29"  ← 与观察到的现象吻合
```

第二行提示了一个更合理的假设：伪本地化把复制出的那一份占位符**转义**为 `%%`，以保证字符串在实参数量不变的前提下仍然是合法的格式化串。这与截图吻合（低分辨率斜拍下，前导的 `%` 容易被漏读成 `lld`）。

但这仍只是假设，**且 printf 语义未必适用**：SwiftUI 的 `Text(LocalizedStringKey)` 并不经过 `String(format:)`，它用自己的插值实参数组按位置替换。printf 语义只适用于代码中显式调用 `String(format:)` 的位置（如 `HomeMonthGridButton.swift:246`），而月历网格的渲染是纯 SwiftUI 路径。

**若需坐实机制**（对修复非必需）：在伪本地化下于 `HomeMonthGridButton.swift:98` 前打印 `String(localized: "%lld")` 的解析结果，即可直接看到变换后的值。

**判定原则**：把伪本地化工具拿掉之后，是否还有真实路径能触达同一个缺陷？

| 发现 | 无工具时的真实触发路径 | 判定 |
|---|---|---|
| `@` / `lld` 渲染错乱 | 翻译流程 —— 任何人编辑这批 key | **真 bug** |
| 数字走本地化数字格式化器（阿拉伯-印度数字渲染成 `٢٩`） | 阿拉伯语系统用户，当前版本即可触发 | **真 bug，无条件** |
| 语序硬拼接（B 类，2+1 处） | 一旦翻译必错，与工具无关 | **真 bug，无条件** |
| 双倍长度导致文字截断 | 无 —— 没有任何真实语言是英文的均匀 2 倍 | **工具产物，仅作提示，需人工 triage** |

**第一条已非假设。** `Resources/Localizable.xcstrings` 中这批 key 已经开始分叉：

```
'%@ %@'        en → "%@ %@"             state: translated
               zh-Hans → "%1$@ %2$@"    state: new
'%lld / %lld'  en → "%lld / %lld"       state: translated
               zh-Hans → "%1$lld / %2$lld"  state: new
```

同一 key 在两种语言下已是不同写法，且英文那条被标记为 `translated`。这正是失效路径本身，只是尚未造成可见后果。

**代码库已知正确写法**：`UI/Home/HomeMonthGridButton.swift` 的 147、152、159 行已经全部使用 `Text(verbatim:)`（小时前缀、标题、`+N` 尾标）。同一文件的 98、166 行漏了。全仓库 19 处漏、3 处对 —— 这是一致性欠账，不是设计问题。

## 三、A 类：15 处纯数据插值 → 改用 `Text(verbatim:)`

这些插值的内容是**数据**（计数、日期数字、标题、emoji），永远不需要翻译。

| # | 文件:行 | 当前写法 | 抽出的垃圾 key |
|---|---|---|---|
| 1 | `UI/Home/HomeMonthGridButton.swift:98` | `Text("\(dayState.dayNumber)")` | `%lld` |
| 2 | `UI/Home/HomeMonthGridButton.swift:166` | `Text("\(hourText)\(titleText)\(overflowText)")` | `%@%@%@` |
| 3 | `UI/Home/HomeMonthHeaderView.swift:532` | `Text("\(dayState.dayNumber)")` | `%lld` |
| 4 | `UI/Home/HomeSelectedDayListView.swift:274` | `Text("\(count)")` | `%lld` |
| 5 | `UI/Home/HomeView.swift:795` | `Text("\(completed)/\(total)")` | `%lld/%lld` |
| 6 | `UI/Home/UnscheduledDrawer.swift:195` | `Text("\(todos.count)")` | `%lld` |
| 7 | `UI/ConfirmSheet/ConfirmSheetAnimations.swift:64` | `Text("\(count)")` | `%lld` |
| 8 | `UI/Review/ReviewView.swift:409` | `Text("\(entry.count)")` | `%lld` |
| 9 | `UI/Widget/TodoWidgetComponents.swift:203` | `Text("\(todos.count)")` | `%lld` |
| 10 | `UI/Widget/TodoWidgetComponents.swift:236` | `Text("\(firstTodo.category.emoji) \(firstTodo.title)")` | `%@ %@` |
| 11 | `UI/Detail/TodoDetailView.swift:603` | `ForEach(1...31) { Text("\($0)") }` | `%lld` |
| 12 | `App/OnboardingView.swift:679` | `Text("\(number)")` | `%lld` |
| 13 | `UI/UIDemoView.swift:118` | `Text("\(store.todos.count)")` | `%lld` |
| 14 | `UI/UIDemoView.swift:125` | `Text("\(...filter{...}.count)")` | `%lld` |
| 15 | `UI/UIDemoView.swift:132` | `Text("\(...filter{...}.count)")` | `%lld` |

### 改法

绝大多数直接加 `verbatim:` 即可，例如 #1：

```swift
Text(verbatim: "\(dayState.dayNumber)")
```

**#2 是唯一的特例，不能简单加 `verbatim:`。** `hourText` / `titleText` / `overflowText` 是三个 **`Text` 实例**（构造于 `HomeMonthGridButton.swift:145-163`），不是 String；`Text(verbatim:)` 只接受 String。必须改用 `Text` 的 `+` 拼接运算符，它保留每段各自的字体：

```swift
let combined = (hourText + titleText + overflowText)
    .strikethrough(occurrence.isCompleted, color: WarmTheme.textMuted)
```

这与该函数文档注释（第 132-135 行）描述的「通过 `Text` 插值合并，保留每段的字体」意图一致，`+` 同样满足该契约。

**注意 #6**：`UnscheduledDrawer` 全仓库无实例化点，是死代码。仍建议一并改，保持全局一致；不要因此顺手删除该文件（超出本次范围）。

**注意 #13-15**：`UIDemoView` 是开发预览用途，优先级最低，但同样会污染 catalog，一并改。

## 四、B 类：3 处语序硬拼接 → 必须改成完整语义 key

这几处把本地化文案与数据用**硬编码的空格 / 斜杠**拼接。语序在不同语言下会变（日语需后置助词，法语数字与单位间规则不同），当前写法在翻译后必然出错。**这三处与伪本地化无关，是无条件的真 bug。**

| # | 文件:行 | 当前写法 | 问题 |
|---|---|---|---|
| B1 | `UI/Detail/TodoDetailView.swift:294` | `Text("\(String(localized: "detail.created_at")) \(formattedDetailDate(todo.createdAt))")` | 本地化标签 + 硬编码空格 + 日期 |
| B2 | `UI/Paywall/PaywallView.swift:120` | `Text("\(quotaUsage.limit) / \(String(localized: "paywall.comparison.per_day"))")` | 数字 + 硬编码 ` / ` + 本地化单位；抽出垃圾 key `%lld / %@` |
| B3 | `UI/Paywall/PaywallView.swift:425` | `Text("/ \(periodUnit)")` | 硬编码前导 `/`；抽出垃圾 key `/ %@` |

### 改法

各新建一条**带语义名的** key，把整句交给译者，让语序由译文决定：

- B1 → 新增 `detail.created_at_value %@`，英文值 `Created %@`，中文值 `创建于 %@`；调用处改为 `Text("detail.created_at_value \(formattedDetailDate(todo.createdAt))")`。原 `detail.created_at` 若无其它引用方，一并从 catalog 移除。
- B2 → 新增 `paywall.comparison.quota_per_day %lld`，英文 `%lld / day`，中文 `%lld / 天`。原 `paywall.comparison.per_day` 若无其它引用方，一并移除。
- B3 → 新增 `paywall.price.per_period %@`，英文 `/ %@`，中文 `/%@`（中文习惯不加空格 —— 这正是必须交给译者决定的原因）。

**B2、B3 在付费页**，优先级高于 A 类。

## 五、D 类：1 处 accessibility 修饰符同样走 `LocalizedStringKey`

`App/OnboardingView.swift:165`：

```swift
.accessibilityValue("\(currentStep + 1) / \(totalSteps)")
```

`accessibilityValue` / `accessibilityLabel` / `accessibilityHint` 的 String 字面量重载同样接收 `LocalizedStringKey`，会被抽取成 `%lld / %lld`。

改法：要么用显式 String 变量传入（走 `StringProtocol` 重载，不被抽取），要么新增语义 key `a11y.onboarding.progress %lld %lld`。**推荐后者** —— VoiceOver 朗读「1 / 5」在各语言下并不自然，本就该本地化成「第 1 步，共 5 步」。

## 六、Catalog 清理

改完 A/B/D 后，从 `Resources/Localizable.xcstrings` 删除以下 9 条垃圾 key。它们无法被任何人翻译，且已开始在语言间分叉：

```
'%@'   '%lld'   '%@ %@'   '%@%@%@'   '%lld/%lld'   '%lld / %@'   '%lld / %lld'   '+%lld'   '/ %@'
```

其中 `%@`、`%lld`、`+%lld`、`/ %@` 目前 `localizations` 为空；`%@ %@`、`%lld / %lld` 已有 en + zh-Hans 两份且写法不一致；`%@%@%@`、`%lld / %@`、`%lld/%lld` 只有 en。

`+%lld` 在当前代码中已无产生方（`HomeMonthGridButton.swift:159` 早已是 `Text(verbatim: " +\(overflow)")`），属历史遗留孤儿 key，可直接删。

**不要动**这些带语义名的合法 key（它们本来就该有占位符）：`confirm.add %lld`、`home.stats %lld %lld`、`review.hero.count_%lld`、`recurrence.weekly_interval %lld %@`、`siri.query.result %lld` 等。

## 七、不要做的事

- **不要**为了消除 A 类而把数字改成 `String(describing:)` 再传入 `Text(_:)` —— 那仍然走 `LocalizedStringKey` 重载。必须用 `Text(verbatim:)`。
- **不要**在这一轮顺手修「双倍长度下文字被截断」的问题。那属于工具产物，需要在 A/B/D 修完、屏幕上不再有 `@` / `lld` 噪音之后，重跑一次伪本地化再单独 triage。
- **不要**删除 `UnscheduledDrawer.swift`，尽管它是死代码。

## 八、验证

1. `./prepare_xcode_project.sh` 后 Xcode 编译。
2. **默认语言（en / zh-Hans）跑一遍**：月历网格日期数字、事件条、`0/3` 计数、Widget、详情页创建时间、Paywall 价格行，显示应与改动前**完全一致**。这是本次改动的核心回归点 —— A 类改动不应有任何可见变化。
3. **重跑 Double-Length Pseudolanguage**：屏幕上应不再出现任何 `@` 或 `lld`。所有文案变成两倍长是预期行为。
4. 此时截图存档，作为后续排版 triage 的基线。预判 `HomeMonthGridButton.swift:171` 的 `lineLimit(2)` + 9pt 字号在月历格约 52pt 宽度下会截断 —— 那是需要设计取舍的地方，不在本次范围。
5. 用 Xcode 的 String Catalog 编辑器确认 9 条垃圾 key 已消失，且总 key 数下降 9 条（改前 493）。
6. VoiceOver 打开，走一遍 Onboarding，确认进度朗读正常（D 类）。
7. 跑 `VoiceTodoUITests` —— A 类不改 accessibility identifier，应全绿。

## 九、Review 关注点

- `HomeMonthGridButton.swift:166` 是否用了 `+` 拼接而**不是**错误地包成 `Text(verbatim:)`（后者编译不过或丢失分段字体）。
- B 类三处是否真的新建了语义 key，而不是简单加 `verbatim:` 了事 —— 加 `verbatim:` 能让伪本地化画面变干净，但**语序 bug 依然存在**，属于把问题藏起来。
- 默认语言下的视觉零变化（验证第 2 条）。
- 垃圾 key 是否连同 `localizations` 一起删干净，没有留下空壳条目。
