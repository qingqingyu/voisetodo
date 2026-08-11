# 修复：日语/德语下 UI 显示本地化 key 原文 + 日历被撑出屏幕

> 文档创建于 2026-08-11。状态：**待执行**。
> 分支：`claude/japanese-german-display-bug-kymdk0`
> 本文是**自包含实施方案**——接手的人/AI 不需要看任何其他上下文即可开工。
> 所有"已验证事实"都标了出处（文件:行号 / 可复跑的命令）；所有"待验证假设"都单独标注。

---

## 目录

1. [现象](#1-现象)
2. [根因分析](#2-根因分析)
3. [现状数据（已验证事实）](#3-现状数据已验证事实)
4. [待验证假设](#4-待验证假设)
5. [实施方案](#5-实施方案)
6. [日文翻译规范（内联全文）](#6-日文翻译规范内联全文)
7. [验证清单](#7-验证清单)
8. [不在本次范围内](#8-不在本次范围内)
9. [附录：可复跑的取证命令](#9-附录可复跑的取证命令)

---

## 1. 现象

真机（iPhone，iOS 26）把系统语言切到**日语**或**德语**后：

1. **界面大面积显示本地化 key 原文**，而不是翻译文本。实测截图里出现的原文包括：
   `tab.today`、`tab.calendar`、`home.week.mon`、`home.week.tue`、`home.week.wed`、
   `home.tier.all_day`、`category.work`、`recurrence.biweekly_short`、`recurrence.triweekly_short`。
2. **日历被撑出屏幕**：月视图 7 列的总宽度远超屏宽（截图里列间距约 114pt × 7 ≈ 800pt，
   而 iPhone 屏宽只有 393pt），折叠态周条卡片同样溢出右边缘。

**中文（zh-Hans）和英文（en）完全正常。**

另外可以观察到：标题栏的「8月」「火 8月11日」是**正确的日文/中文日期格式**——
因为那部分走 `DateFormatter` + `Locale.current`，与 String Catalog 无关，所以不受影响。
这条恰好反证了问题出在字符串表查找，而不是整个本地化系统没启动。

---

## 2. 根因分析

这是**两个独立问题叠加**，不是一个 bug。

### 2.1 原因 1（主因）：半成品的日语翻译反而杀死了英文兜底

项目用的是 Apple **String Catalog**（`.xcstrings`），不是 i18next / JSON 那一套，
所有语言是**同一个 JSON 文件里的并列列**，没有 per-locale 文件，仓库里也不存在任何 `.lproj` 目录。

`Resources/Localizable.xcstrings` 里共 559 个 key，但语言覆盖极不均衡：

| 语言 | 覆盖 key 数 | 覆盖率 |
|---|---|---|
| `en`（源语言） | 548 | 100%（基准） |
| `zh-Hans` | 547 | 99.8% |
| **`ja`** | **18** | **3.3%** |
| **`ja-JP`** | **1** | **0.2%** |

这 18 条 `ja` 是 `docs/mvp-japanese-launch/plan.md` 里 Layer 1.1（"给全部 530 个 key 加 ja 翻译"）
**尚未执行**、但在做 recurrence summary / confirm editor 功能时顺手漏进去的碎片。
第 19 条 `settings.speech_language.ja-JP` 更严重——它把日文值 `日本語` 填进了
**`ja-JP` 这个地区限定语言列**（其余 18 条用的是裸 `ja`），来源是 commit `c37d106`
（"feat(voice): 暴露 SpeechRecognitionLanguage.systemResolved"）加语音语言 enum 时的手误。

**关键机制（这是整个 bug 的核心）：**

> Xcode 的 `xcstringstool` 会为 String Catalog 里**出现过的每一种语言**生成对应的
> `<lang>.lproj/Localizable.strings`，这跟 `project.yml` 的 `knownRegions` 无关。

证据：`VoiceTodo.xcodeproj/project.pbxproj:956-959` 里 `knownRegions = (Base, en)`，
**连 `zh-Hans` 都没列**，但中文在真机上完全正常。所以 `knownRegions` 显然没有在门控 `.xcstrings` 的编译。

于是构建产物里多出了两个残缺的本地化包：`ja.lproj`（18 条）和 `ja-JP.lproj`（1 条）。

日语 iPhone 的 `Locale.preferredLanguages.first` 是 `"ja-JP"`。CFBundle 做本地化解析时
**精确匹配优先**，于是命中只有 1 条字符串的 `ja-JP.lproj`。而
`String(localized:)` 在解析出的 bundle 表里查不到 key 时，**直接返回 key 本身**——
Apple 不会为单个 key 跨 lproj 回退到源语言。

这就是满屏 `tab.today` 的完整成因：
**如果那 19 条日语碎片根本不存在，日语设备会干净地回退到 `en.lproj`，显示英文。
恰恰是"译了一点点"把英文兜底打掉了。**

### 2.2 原因 2：日历星期标签无法被压缩，撑破容器

即使没有原因 1，这也是一个真实存在的布局脆弱点，只是被超长的 key 原文提前引爆了。

**问题点 A —— `.fixedSize()` 是硬伤**

`UI/Home/HomeMonthHeaderView.swift:583-586`，`WeekStripCard.dayCell` 里的星期文字：

```swift
Text(state.weekdayTitle(for: day))
    .font(WarmFont.caption(9))
    .foregroundColor(dayState.isToday ? WarmTheme.primary : WarmTheme.textMuted)
    .fixedSize()          // ← 硬伤
```

`.fixedSize()` 让 Text 的**最小宽度 = 完整文本宽度**。外层是
`HStack(spacing: 4) { 7 × dayCell }`（:498-502），HStack 无论收到多小的宽度提议，
都压不下这 7 个最小宽度，只能溢出。文本是 `"一"` 时无所谓，
是 `"home.week.mon"` 时 7 格合计就轻松超过屏宽——这就是截图 1 的周条卡片溢出。

**问题点 B —— 月历表头兜底不足，并把整个网格带宽**

`UI/Home/HomeMonthHeaderView.swift:66-75`：

```swift
HStack(spacing: HomeLayoutMetrics.gridColumnSpacing) {
    ForEach(state.weekHeaderDays, id: \.self) { day in
        Text(state.weekdayTitle(for: day))
            .font(WarmFont.caption(9))
            .foregroundColor(WarmTheme.textSecondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)      // ← 最多只缩到 70%
            .frame(maxWidth: .infinity)
    }
}
```

`minimumScaleFactor(0.7)` 意味着 Text 的最小宽度 ≈ 完整宽度 × 0.7，仍然是一个**很大的下限**。
而这个表头行与下方 42 格日期网格**在同一个 `VStack`**（:61-98）里——
`VStack` 的宽度取所有子视图宽度的最大值，表头把 VStack 撑宽后，
下方 7 列网格就按撑宽后的宽度去排，于是**整个月历一起被顶出屏幕**（截图 2）。

**问题点 C —— 字号跟随 Dynamic Type，放大了前两个问题**

两处都用 `WarmFont.caption(9)`。看 `UI/Shared/DesignSystem.swift:334-337`：

```swift
static func caption(_ size: CGFloat) -> Font {
    .custom("Avenir Next", size: size, relativeTo: relativeTextStyle(for: size)).weight(.regular)
}
```

带了 `relativeTo:`，即**跟随 Dynamic Type 缩放**（9pt 走 `.caption2`，见 :264-276）。
用户开大字号时，9pt 会被放大到 20pt 以上，`home.week.mon` 这种 13 字符串宽度直接翻倍。

而 DesignSystem 里**已经有**专门为这种场景准备的不缩放版本 `captionFixed`（:359-361），
它的文档注释（:339-341）写得很明确：

> 用于"预览类 UI 容器"内的小字文本(如月历格事件条标题)：这些文本是点开看详情的概览,
> 不是用户主读内容,字号跟随系统缩放会**撑爆容器或触发伪截断**。

日历表头和周条星期标签正是这类"容器内装饰性小字"，却用了会缩放的 `caption`。

**注意：`UI/Shared/FlowLayout.swift` 不是元凶。**
它的 `sizeThatFits`（:66-77）无条件返回 `CGSize(width: proposal.width ?? 0, ...)`，
永远不会把父容器撑宽。图例行和圆点行不需要改。

---

## 3. 现状数据（已验证事实）

以下全部由读取仓库文件得出，可用第 9 节的命令复跑验证。

### 3.1 三个 String Catalog 的语言覆盖

| 文件 | key 总数 | `en` | `zh-Hans` | `ja` | `ja-JP` |
|---|---|---|---|---|---|
| `Resources/Localizable.xcstrings` | 559 | 548 | 547 | 18 | 1 |
| `VoiceTodo/InfoPlist.xcstrings` | 6 | 6 | 6 | 0 | 0 |
| `VoiceTodoWidget/InfoPlist.xcstrings` | 2 | 2 | 2 | 0 | 0 |

catalog 里**不存在 `de`**（德语从来没开始做，`docs/mvp-japanese-launch/plan.md` §1.3
明确写了"法德推迟，等数据"）。

### 3.2 结构复杂度：低（好消息）

- **0 个 key 带 `substitutions`**
- **0 个 localization 带 `variations`**（无复数变体、无设备变体）
- 全部是扁平的 `{"stringUnit": {"state": ..., "value": ...}}`
- `sourceLanguage` = `"en"`，`version` = `"1.0"`

所以工具脚本不需要处理 plural rules / device variants 这类复杂情况。

### 3.3 唯一需要小心的：70 个含格式化符的 key

译文里的格式符必须与 `en` **逐个一致**，否则运行时 `String(format:)` 会崩或错位。举例：

| key | en 值 |
|---|---|
| `%lld / %lld` | `%1$lld / %2$lld` |
| `a11y.drop_strip` | `%1$@, %2$d task(s)` |
| `a11y.day.open_todo` | `Open %@` |
| `a11y.recording_duration` | `Recording duration: %lld seconds` |
| `confirm.add_count %lld` | `Add %lld` |
| `calendar_import.success_count` | `Imported %d todos` |

**注意带位置参数的 `%1$@` / `%2$d`**——日文语序与英文不同，译者很可能想调换顺序，
这时**必须保留位置索引**（`%2$d` 件の「%1$@」），不能改成裸 `%@`/`%d`。
工具脚本的 merge 步骤要强制校验"格式符**集合**一致"（允许顺序变化，不允许增删或改类型）。

### 3.4 现存 18 条 `ja` 的完整清单

补全时**这 18 条也要一起复核文体**，不豁免（它们是分散多次加进来的，文体大概率不统一）：

```
a11y.clear_inferred_date
confirm.editor.inferred
confirm.editor.section.category
confirm.editor.section.priority
confirm.editor.section.time
detail.clock_time
home.pending_date.section.hint
home.undated.section.hint
recurrence.summary.daily
recurrence.summary.invalid
recurrence.summary.monthly
recurrence.summary.none
recurrence.summary.weekday_separator
recurrence.summary.weekly
recurrence.summary.weekly_interval_bi
recurrence.summary.weekly_interval_single
recurrence.summary.weekly_interval_tri
recurrence.summary.weekly_no_weekday
```

第 19 条（问题源头）：`settings.speech_language.ja-JP`，其 `localizations` 现状为
`{"en": "Japanese", "zh-Hans": "日语", "ja-JP": "日本語"}`。

### 3.5 11 个连 `en` 都没有的 key —— 不译，写进白名单

这些是 AppIntents / Siri 自动生成的占位符和品牌名，`zh-Hans` 同样没译：

```
""                              (空串)
"%@"
"%lld / %lld"                   ← 有 en，但缺 zh-Hans，一并白名单
review.chart.mark
siri.complete.summary ${todo}
siri.delete.summary ${todo}
siri.query.summary ${status}
siri.summary ${transcript}
Todo ID
Toggle Todo
VoiceTodo                       ← 品牌名
VT                              ← 品牌名
```

### 3.6 命名空间分布（用于分批翻译）

| namespace | key 数 | | namespace | key 数 |
|---|---|---|---|---|
| home | 68 | | glossary | 16 |
| onboarding | 62 | | empty | 15 |
| siri | 49 | | calendar_import | 14 |
| a11y | 46 | | panel | 10 |
| detail | 36 | | ui | 8 |
| recurrence | 31 | | category | 7 |
| settings | 29 | | widget | 7 |
| paywall | 28 | | quota / reprompt | 6 each |
| error | 27 | | live_activity / suggestion / time_bucket | 5 each |
| review | 24 | | common | 4 |
| confirm | 21 | | date / demo / due / tab | 3 each |

### 3.7 相关代码位置速查

| 用途 | 位置 |
|---|---|
| 主字符串目录 | `Resources/Localizable.xcstrings` |
| 主 App Info.plist 目录 | `VoiceTodo/InfoPlist.xcstrings` |
| Widget Info.plist 目录 | `VoiceTodoWidget/InfoPlist.xcstrings` |
| `knownRegions` 配置 | `project.yml:7-11` |
| 生成的工程（陈旧） | `VoiceTodo.xcodeproj/project.pbxproj:954-959` |
| 星期标题取字符串 | `UI/Home/HomeCalendarState.swift:134-142` |
| 月历表头行（问题点 B） | `UI/Home/HomeMonthHeaderView.swift:66-75` |
| 周条 dayCell（问题点 A） | `UI/Home/HomeMonthHeaderView.swift:583-586` |
| 字体定义 caption / captionFixed | `UI/Shared/DesignSystem.swift:334-337 / 359-361` |
| 语音语言 enum（引用出问题的 key） | `Voice/SpeechRecognitionLanguage.swift:29` |
| FlowLayout（已排除嫌疑） | `UI/Shared/FlowLayout.swift:66-77` |

---

## 4. 待验证假设

**接手的人请勿把下面两条当成已确认结论。**

### 假设 A：德语症状的传导路径

catalog 里没有 `de`，所以**纯德语设备理论上应当回退到 development region `en`，显示英文**，
而不是显示 key 原文。用户报告德语也坏掉，最可能的解释是：

> 测试机的"首选语言顺序"里，德语下面还挂着之前测日语时加的日语。
> CFBundle 跳过不存在的 `de`，往下命中残缺的 `ja` / `ja-JP`。

**验证方式**：iPhone → 设置 → 通用 → 语言与地区 → 看"首选语言顺序"列表。

无论假设是否成立，**修复方案都覆盖德语**：删掉 `ja-JP` 列、补全 `ja` 之后，
德语设备要么回退英文（列表里没日语），要么显示完整日文（列表里有日语）——两种都不是 key 原文。

### 假设 B：月历表头撑宽整个网格的精确传导链

第 2.2 节问题点 B 的推理（表头行经由共享 `VStack` 把宽度传给网格）是**根据代码结构推断**的，
没有在设备上用 Instruments / View Debugger 逐层确认。

已确认的部分：`.fixedSize()`（问题点 A）**必然**导致周条卡片溢出，这条无需再验。
未确认的部分：月历网格溢出的最终传导层。

**验证方式**：实施阶段 3 之前，先用 Xcode 的 **Double-Length Pseudolanguage**
（Scheme → Run → Options → App Language）跑一次，再用 View Debugger 看 `VStack` 的实际 frame 宽度。
如果加固后仍溢出，说明还有第三个撑宽点，需要继续排查（`HomeMonthGridButton` 是下一个怀疑对象）。

---

## 5. 实施方案

四个阶段按顺序做。每个阶段有明确的完成判据（DoD）。

### 阶段 0：翻译工具脚本

**新建 `Scripts/xcstrings_tool.py`**（Python 3，只用标准库，不引第三方依赖）。

三个子命令：

#### `extract`

```
python3 Scripts/xcstrings_tool.py extract <catalog.xcstrings> --lang ja [--out untranslated.json]
```

输出：该语言**缺失**的条目，带 en 原文和 zh-Hans 译文作参考上下文。

```json
{
  "catalog": "Resources/Localizable.xcstrings",
  "lang": "ja",
  "count": 548,
  "entries": [
    {
      "key": "tab.today",
      "en": "Today",
      "zh-Hans": "今日",
      "format_specifiers": []
    },
    {
      "key": "a11y.drop_strip",
      "en": "%1$@, %2$d task(s)",
      "zh-Hans": "%1$@，%2$d 项任务",
      "format_specifiers": ["%1$@", "%2$d"]
    }
  ]
}
```

`--include-existing` 可选参数：连已有译文的条目一起导出（用于复核那 18 条的文体）。

#### `merge`

```
python3 Scripts/xcstrings_tool.py merge <catalog.xcstrings> --lang ja --input translations.json
```

输入 JSON 结构（`{key: 译文}` 的扁平映射，或 extract 输出格式加 `"ja"` 字段，两种都支持）：

```json
{ "tab.today": "今日", "tab.calendar": "カレンダー" }
```

行为契约：
- 写入 `localizations.<lang>.stringUnit = {"state": "translated", "value": <译文>}`
- **保持原文件的 key 排序和 JSON 缩进风格**（`json.dump(..., indent=2, ensure_ascii=False, sort_keys=?)`
  —— 先读原文件确认实际风格再定，目标是 **diff 只出现新增行，不出现全文件重排**）
- **格式符校验**：译文中 `%` 格式符的多重集合必须与 en 完全一致（允许顺序变化）。
  不一致 → 打印 key + 两边的格式符 → **非零退出，不写文件**
- 幂等：重复跑同一份输入，文件内容不变

#### `check`

```
python3 Scripts/xcstrings_tool.py check <catalog1> [<catalog2> ...]
```

对每个 catalog 里**出现过的每一种语言**，断言：

```
该语言的 key 集合  ⊇  ( en 的 key 集合 − 白名单 )
```

白名单硬编码在脚本里（即第 3.5 节那 12 项，含 `%lld / %lld`），并留一个
`--allowlist <file>` 参数便于以后扩展。

任何语言覆盖不足 → 打印缺失 key 列表 → **退出码 1**。

**DoD（阶段 0）**：
- `check` 在**当前未修复的仓库**上运行时**必须失败**，并准确报出 `ja` 缺 530 条、`ja-JP` 缺 547 条。
  （先证明这道闸能抓到本次的 bug，再去修 bug。）

---

### 阶段 1：修数据 —— `Resources/Localizable.xcstrings`

#### 1.1 删除 `ja-JP` 这一列（止血，最关键的一步）

把 key `settings.speech_language.ja-JP` 下的：

```json
"ja-JP": { "stringUnit": { "state": "translated", "value": "日本語" } }
```

改成：

```json
"ja": { "stringUnit": { "state": "translated", "value": "日本語" } }
```

- ⚠️ **key 的名字 `settings.speech_language.ja-JP` 不要改**。它被
  `Voice/SpeechRecognitionLanguage.swift:29` 引用（`String(localized: "settings.speech_language.ja-JP")`），
  改名会造成新的 key 原文泄漏。这里 `ja-JP` 是 **key 名的一部分**，不是语言代码。
- ⚠️ 改完后，**全文件不能再出现任何 `"ja-JP"` 作为语言键**。留一条都会继续生成
  `ja-JP.lproj`，而它会在日语设备上**精确匹配抢赢** `ja.lproj`，bug 原样复现。
  自查：`grep -c '"ja-JP" *:' Resources/Localizable.xcstrings` 应为 0。

#### 1.2 补全 548 条 `ja`

流程：`extract` → 分批翻译（建议每批约 55 条，按第 3.6 节的 namespace 分组，
同一 namespace 的词汇上下文相关，一批内更容易保持文体一致）→ `merge` → `check`。

- 已有的 18 条（第 3.4 节）**一并复核**，文体不统一就改。
- 翻译规范见第 6 节，**必须逐条遵守**。
- 优先级顺序建议：先译截图里暴露的高可见度 namespace（`tab` / `home` / `category` /
  `recurrence` / `detail` / `confirm`），再译 `settings` / `onboarding` / `paywall` / `error`，
  最后译 `a11y`（VoiceOver 文案，可见度低但不能漏）。

#### 1.3 不译的 key

第 3.5 节那 11 项保持原样，写进 `check` 的白名单。

**DoD（阶段 1）**：
- `grep -c '"ja-JP" *:' Resources/Localizable.xcstrings` → `0`
- `python3 Scripts/xcstrings_tool.py check Resources/Localizable.xcstrings` → 退出码 0
- `git diff --stat` 显示的改动行数应接近"548 × 6 行新增"量级；
  如果出现几千行的删改，说明 merge 把文件重排了，回退重做

---

### 阶段 2：InfoPlist + 构建配置

#### 2.1 `VoiceTodo/InfoPlist.xcstrings` —— 6 个 key 加 `ja`

| key | en 现值 | ja 怎么处理 |
|---|---|---|
| `CFBundleDisplayName` | `VoiceTodo` | **保持 `VoiceTodo` 不译**（品牌名） |
| `CFBundleName` | `VoiceTodo` | **保持 `VoiceTodo` 不译** |
| `NSMicrophoneUsageDescription` | `VoiceTodo needs microphone access to record your voice.` | 认真译 |
| `NSSpeechRecognitionUsageDescription` | `VoiceTodo needs speech recognition access to understand your voice commands.` | 认真译 |
| `NSCalendarsUsageDescription` | `VoiceTodo needs calendar access to add your todos, read events, and detect scheduling conflicts.` | 认真译 |
| `NSCalendarsWriteOnlyAccessUsageDescription` | `VoiceTodo needs access to add your todos to the system calendar.` | 认真译 |

这 4 条权限说明是**日本用户看到的第一屏文字**，
`docs/mvp-japanese-launch/plan.md` §3.3 专门强调"文案如果半通不通会显著降低授权率"。
权限说明用「です/ます」敬体，句式参考 Apple 官方日文权限文案。

#### 2.2 `VoiceTodoWidget/InfoPlist.xcstrings` —— 2 个 key

| key | en 现值 | zh-Hans 现值 |
|---|---|---|
| `CFBundleDisplayName` | `VoiceTodo Widget` | `VoiceTodo 小组件` |
| `CFBundleName` | `VoiceTodoWidget` | `VoiceTodoWidget` |

`CFBundleName` 保持不译；`CFBundleDisplayName` 译成「VoiceTodo ウィジェット」。

#### 2.3 `project.yml` —— `knownRegions` 加 `ja`

`project.yml:7-11` 现状：

```yaml
  knownRegions:
    - Base
    - zh-Hans
    - en
```

改成：

```yaml
  knownRegions:
    - Base
    - zh-Hans
    - en
    - ja
```

> ⚠️ **这一步只是账面一致性，不是功能修复。**
> 已提交的 `VoiceTodo.xcodeproj/project.pbxproj:956-959` 里 `knownRegions = (Base, en)`
> 连 `zh-Hans` 都没有，中文照样工作——`.xcstrings` 的编译不看 `knownRegions`。
> 仓库里没有任何地方调用 XcodeGen（`prepare_xcode_project.sh` 不跑 `xcodegen`），
> `.xcodeproj` 是手工维护并提交的。**不要顺手重新生成整个工程**，那会产生巨大且高风险的 diff。

**DoD（阶段 2）**：
- `python3 Scripts/xcstrings_tool.py check Resources/Localizable.xcstrings VoiceTodo/InfoPlist.xcstrings VoiceTodoWidget/InfoPlist.xcstrings` → 退出码 0
- `project.yml` 的 diff 只有 1 行新增
- `VoiceTodo.xcodeproj/` 下**没有任何改动**

---

### 阶段 3：布局加固 —— `UI/Home/HomeMonthHeaderView.swift`

目标：**任何语言、任何 Dynamic Type 档位下，日历都不会超出屏幕宽度。**

#### 3.1 周条卡片的星期标签（:583-586）

改前：

```swift
Text(state.weekdayTitle(for: day))
    .font(WarmFont.caption(9))
    .foregroundColor(dayState.isToday ? WarmTheme.primary : WarmTheme.textMuted)
    .fixedSize()
```

改后：

```swift
Text(state.weekdayTitle(for: day))
    .font(WarmFont.captionFixed(9))
    .foregroundColor(dayState.isToday ? WarmTheme.primary : WarmTheme.textMuted)
    .lineLimit(1)
    .minimumScaleFactor(0.5)
    .allowsTightening(true)
    .frame(maxWidth: .infinity)
```

- **去掉 `.fixedSize()` 是这一步的核心**。
- `caption` → `captionFixed`：这是容器内的装饰性小字，符合
  `UI/Shared/DesignSystem.swift:339-341` 给出的判定标准。
- ⚠️ **同一个 `dayCell` 里日期数字的 `.fixedSize()`（:600）要保留**——
  它在固定 28pt 的圆形里，是 `DesignSystem.swift:365` 的 `mono` 文档注释明确要求的写法，
  去掉反而会出问题。

#### 3.2 月历表头行（:66-75）

改前：

```swift
Text(state.weekdayTitle(for: day))
    .font(WarmFont.caption(9))
    .foregroundColor(WarmTheme.textSecondary)
    .lineLimit(1)
    .minimumScaleFactor(0.7)
    .frame(maxWidth: .infinity)
```

改后：

```swift
Text(state.weekdayTitle(for: day))
    .font(WarmFont.captionFixed(9))
    .foregroundColor(WarmTheme.textSecondary)
    .lineLimit(1)
    .minimumScaleFactor(0.5)
    .allowsTightening(true)
    .frame(maxWidth: .infinity)
```

#### 3.3 最外层加第二道防线

`HomeMonthHeaderView.body` 的最外层（现有修饰符链在 :99-119，
`.padding(.horizontal, ...)` 那一串）补上：

```swift
.frame(maxWidth: .infinity)
.clipped()
```

即使将来某个子视图再次报出过大的最小宽度，也只会在内部截断，不会把网格顶出屏幕。

#### 3.4 不需要改的地方

- `UI/Shared/FlowLayout.swift` —— `sizeThatFits` 无条件回填 `proposal.width`，
  不会撑宽父容器。图例行和圆点行保持原样。
- `UI/Home/HomeMonthGridButton.swift` —— 唯一的 `.fixedSize()`（:127）作用在日期数字上，
  宽度极小；事件条文字已有 `.lineLimit(2)`（:233）。**除非假设 B 验证后发现仍溢出，
  否则不动这个文件。**

**DoD（阶段 3）**：
- Double-Length Pseudolanguage + AX5 下，月历表头和周条都不超出屏幕
- 中文 / 英文 / 日文默认字号下，星期标签**没有出现「…」伪截断**
  （`captionFixed` + 短译文本就够宽，不该触发缩放）

---

### 阶段 4：防复发校验

本次 bug 之所以能上真机，就是因为**没有任何一道闸在检查"某语言只译了一半"**。补两层：

#### 4.1 源文件层：`Scripts/xcstrings_tool.py check`

阶段 0 已经实现。把它挂到日常流程里（README 或 `docs/` 里写明改完翻译必须跑一次）。
仓库当前没有 CI 配置（无 `.github/`），所以先保证是**一条能手跑的命令**，
将来接 CI 时直接引用。

#### 4.2 构建产物层：`VoiceTodoTests/Protocols/LocalizationCoverageTests.swift`

新建单元测试，断言**构建出来的 app bundle** 里每种语言都能正常解析哨兵 key：

```swift
import XCTest
@testable import VoiceTodo

final class LocalizationCoverageTests: XCTestCase {
    /// 覆盖截图里实际暴露过的 key，每个 namespace 取一个代表。
    private let sentinelKeys = [
        "tab.today",
        "home.week.mon",
        "home.tier.all_day",
        "category.work",
        "recurrence.biweekly_short",
    ]

    /// bundle 里出现的每一种本地化，哨兵 key 都必须解析出 ≠ key 本身的值。
    /// 这道断言正是本次 bug 漏掉的闸：ja.lproj 只有 18 条时，这里会红。
    func testEveryShippedLocalizationResolvesSentinelKeys() throws {
        let bundle = Bundle(for: type(of: self))   // 视 test target 宿主配置调整
        for localization in bundle.localizations where localization != "Base" {
            guard let path = bundle.path(forResource: localization, ofType: "lproj"),
                  let localeBundle = Bundle(path: path) else {
                XCTFail("找不到 \(localization).lproj")
                continue
            }
            for key in sentinelKeys {
                let value = localeBundle.localizedString(forKey: key, value: nil, table: nil)
                XCTAssertNotEqual(
                    value, key,
                    "\(localization).lproj 缺 key「\(key)」——该语言是半成品翻译，会在真机上显示 key 原文"
                )
            }
        }
    }
}
```

> 实施注意：`Bundle(for:)` 在 unit test target 里拿到的是 test bundle。
> 需要按本项目 test target 的 host application 配置调整成拿宿主 app bundle
> （例如 `Bundle(for: TodoStore.self)`，或 `Bundle(identifier: "com.qingqingyu.VoiceTodo")`）。
> **写完后必须先人为制造一次失败**（临时删掉某个 ja 译文）确认这个测试真的会红，
> 否则等于没加。

新文件要同时登记到：
- `.xcode_unit_test_files.txt`
- `project.yml` 的 `VoiceTodoTests` target sources（若该 target 用的是目录整体引用则不需要）

**DoD（阶段 4）**：
- 临时删掉一条 ja 译文 → `check` 红、单元测试红
- 恢复后两者都绿

---

## 6. 日文翻译规范（内联全文）

摘自 `docs/mvp-japanese-launch/plan.md` §3.2 + §8 已锁定决策（D4=A、D5=A），此处内联以便自包含。
**这些是已锁定的决策，不要重新讨论。**

### 6.1 文体

- **全部用「です/ます」敬体**（消费者向 app 标配）。
  **禁止**出现「〜する」「〜である」常体，**禁止**敬体常体混用——
  混用是机翻的典型标志，母语用户一眼识破。
- **标题 / 按钮**用「体言止め」或动词辞书形：「保存」「キャンセル」「設定」「削除」。
  与 Apple HIG 日文版风格一致。不要写成「保存します」这种句子形式的按钮。

### 6.2 用词

- **不要直译**。例：`Today` → 「今日」（可以）；但 `Up Next` → 「次に」，
  **不要**直译成「次に上がる」这种不存在的日语。
- **枚举值保持英文不译**：`high` / `normal` / `low`、`work` / `study` / `life` 等，
  以及 `morning` / `afternoon` / `evening`。这些是数据层的值，不是 UI 文案。
  （如果 catalog 里某个 key 的 en 值就是这些枚举词本身、且它是**展示用**的分类名——
  如 `category.work` = `Work` —— 那要译成「仕事」。判断依据看 key 的用途，不看值长得像什么。）

### 6.3 数字与日期

- 数字用**半角**，与 Apple 系统惯例一致，全文统一。
- 日期用**西历**（`2026年`），不用和暦（`令和8年`）。这是 D5 已锁定的决策。

### 6.4 长度

- 译文不要比 en / zh-Hans 长很多。阶段 3 加固后不会溢出，
  但日历格、周条、chip 的空间本来就紧，短译文视觉更好。
- 星期标签（`home.week.mon` 等 7 条）**必须是单字**：「月」「火」「水」「木」「金」「土」「日」。
- `home.week.today` / `home.week.tomorrow` 译「今日」「明日」。

### 6.5 已知的 AI 日文翻译失败模式（复核时重点看）

1. **敬体/常体混用** —— 复核时**必须明确指定"检查所有字符串的 です/ます 一致性"**，
   否则 AI 自己也看不出来。
2. **「今度」歧义** —— 可以是"下次"/"最近"/"刚才"，UI 文案里尽量不用这个词。
3. **助词一字之差** —— 「水曜日**に**」（在周三）vs「水曜日**まで**」（到周三为止）
   意思完全不同，重复规则和截止日相关的文案要格外小心。
4. **计数词** —— 一個 / 一本 / 一枚 / 一件 / 一台 各有适用对象，待办用「件」。

### 6.6 复核机制

`docs/mvp-japanese-launch/plan.md` §5.3 要求**用两个不同的 AI 模型交叉检查**
（不要同一个模型自查，盲点一致等于没查）。复核只查三项：

1. 日文的自然度
2. **文体一致性**（全文是否统一 です/ます）
3. 是否有漏译 / 过度意译

---

## 7. 验证清单

### 7.1 改动前（先取基线 + 验假设 A）

1. iPhone → 设置 → 通用 → 语言与地区 → 看**"首选语言顺序"里德语下面有没有挂日语**。
   记录结果——这决定假设 A 是否成立。
2. Xcode → Scheme → Run → Options → App Language 分别设成 **Japanese** 和 **German**，
   各跑一次，截图记录修复前的表现。模拟器即可（这一步不涉及语音）。
3. 跑一次 `python3 Scripts/xcstrings_tool.py check ...`，**确认它在未修复的代码上是红的**
   且报出的缺失数量与第 3.1 节的表格对得上。

### 7.2 改动后

4. `python3 Scripts/xcstrings_tool.py check Resources/Localizable.xcstrings VoiceTodo/InfoPlist.xcstrings VoiceTodoWidget/InfoPlist.xcstrings` → 退出码 0。
5. 构建后确认产物里**有 `ja.lproj`、没有 `ja-JP.lproj`**：
   ```bash
   find ~/Library/Developer/Xcode/DerivedData -path "*VoiceTodo.app*" -name "*.lproj"
   ```
   期望看到 `en.lproj`、`zh-Hans.lproj`、`ja.lproj`（可能还有 `Base.lproj`），**不能有 `ja-JP.lproj`**。
6. Xcode 跑 `VoiceTodoTests`，`LocalizationCoverageTests` 通过。
7. **App Language = Japanese**：Today / Calendar 两个 tab、周条卡片、月历网格、
   任务详情页、设置页、确认面板全部日文，**无任何 key 原文**；周条 7 格不溢出。
8. **App Language = German**：全部回退**英文**（既不是 key 原文，也不是日文）。
   若设备首选语言列表里挂着日语，则显示日文也算通过——但不能是 key 原文。
9. **App Language = Double-Length Pseudolanguage**（Xcode 内置，专门用来测溢出）：
   月历表头 + 周条卡片不超出屏幕、不出现横向滚动、不出现内容被裁掉一半。
   **这是原因 2 的直接回归测试。**
10. 叠加 **设置 → 辅助功能 → 显示与文字大小 → 更大字体 = AX5**，重跑第 7 / 8 / 9 步。
    这是 `docs/mvp-japanese-launch/plan.md` §3.3「文本截断零容忍」的硬性要求。
11. 真机切日语跑一遍，复验第 7 步。
    （本次改动不碰语音链路，但 `plan.md` §4.3 提醒模拟器测不了 `SFSpeechRecognizer`，
    顺手在真机上确认语音入口没被本地化改动波及。）

---

## 8. 不在本次范围内

**`docs/mvp-japanese-launch/plan.md` 的 Layer 3（AIProxy 日文 prompt）不做。**

具体地：`AIProxy/worker.js:1566` 的 `normalizeLocale` 仍然会把 `ja-JP` 吞成 `en`：

```javascript
function normalizeLocale(locale) {
  const raw = String(locale || "en");
  return raw.toLowerCase().startsWith("zh") ? "zh" : "en";  // ← ja-JP 被吞成 en
}
```

所以日文语音的 AI 提取仍然走英文 system prompt（`AIProxy/src/adapters/base.js:95`）。

**影响评估**：本次只修 UI 显示层，AI 提取质量与今天**持平，不会变差**。
但如果日语 UI 要正式对日本用户上线，Layer 3 是 `plan.md` §7 里排在 **Day 1** 的更高优先级项
（因为"日文 UI + 英文 prompt"会让用户说日语后拿到英文标题），**建议单独开一轮做**。

同样不在本次范围：
- 德语（`de`）的完整翻译 —— `plan.md` §1.3 已锁定"法德推迟，等数据"
- Beta 标签 UI、反馈渠道（`plan.md` §6.1 / §6.2）
- App Store Connect 日文 metadata（`plan.md` §6.3）

---

## 9. 附录：可复跑的取证命令

在仓库根目录执行，可复现本文所有"已验证事实"。

```bash
# 各语言覆盖数
python3 - <<'PY'
import json
from collections import Counter
d = json.load(open('Resources/Localizable.xcstrings'))
print('sourceLanguage:', d['sourceLanguage'], '| total keys:', len(d['strings']))
c = Counter()
for k, v in d['strings'].items():
    for lang in v.get('localizations', {}):
        c[lang] += 1
print(c)
PY

# 现存 ja / ja-JP 的 key 清单
python3 - <<'PY'
import json
s = json.load(open('Resources/Localizable.xcstrings'))['strings']
for lang in ('ja', 'ja-JP'):
    ks = sorted(k for k, v in s.items() if lang in v.get('localizations', {}))
    print(f'--- {lang} ({len(ks)}) ---')
    for k in ks:
        print(' ', k)
PY

# 结构复杂度：substitutions / variations 是否为 0
python3 - <<'PY'
import json
s = json.load(open('Resources/Localizable.xcstrings'))['strings']
print('substitutions:', [k for k, v in s.items() if 'substitutions' in v])
print('variations:', [k for k, v in s.items()
                      for loc in v.get('localizations', {}).values() if 'variations' in loc])
PY

# 含格式化符的 key 数量
python3 - <<'PY'
import json, re
s = json.load(open('Resources/Localizable.xcstrings'))['strings']
fmt = [k for k, v in s.items()
       if 'en' in v.get('localizations', {})
       and '%' in v['localizations']['en']['stringUnit']['value']]
print('keys with % format:', len(fmt))
PY

# knownRegions 现状（证明它没在门控 .xcstrings 编译：zh-Hans 不在列表里却能工作）
grep -n -A6 'knownRegions' VoiceTodo.xcodeproj/project.pbxproj | head
sed -n '7,11p' project.yml

# 两个问题布局点
sed -n '66,75p'   UI/Home/HomeMonthHeaderView.swift
sed -n '583,586p' UI/Home/HomeMonthHeaderView.swift

# caption vs captionFixed
sed -n '334,337p' UI/Shared/DesignSystem.swift
sed -n '359,361p' UI/Shared/DesignSystem.swift
```

---

## 变更记录

| 日期 | 变更 |
|---|---|
| 2026-08-11 | 初版。基于真机日语/德语截图的根因分析 + 四阶段修复方案 |
