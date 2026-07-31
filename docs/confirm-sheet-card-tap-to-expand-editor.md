# 确认页卡片：点击就地展开成详情编辑面板

> 状态：**待实施**。本文档是设计决策 + 实施方案，实施后请对照「验证」一节逐项确认。
>
> **基线**：行号对齐 `9075039`（*Merge branch 'wendang' — month-grid 文档状态同步到已实施*）。
> 若实施时 main 又前进了，**先按符号名（函数名 / 属性名 / 注释原文）定位，行号仅作参考**。
> 本方案涉及的 `UI/ConfirmSheet/`、`UI/Detail/TodoDetailView.swift`、`Protocols/Models.swift`、
> `Store/SwiftDataModels.swift`、`Store/TodoStore.swift` 自 `54b8fde` 以来均未被改动。
>
> 主改动文件：`UI/ConfirmSheet/`、`UI/Detail/TodoDetailView.swift`、
> `UI/Shared/TodoFieldEditors.swift`（新建）
>
> 相关文件（只读参考）：`Protocols/Models.swift`、`Store/SwiftDataModels.swift`、
> `Store/TodoStore.swift`、`UI/Home/HomeView.swift`

---

## 需求

录音解析完成后弹出 `ConfirmSheetView`（`Cancel` / `Save to app…` / `Add 2` +
转录原文 + 分组卡片）。这是用户校对 AI 结果的唯一时机，但目前卡片上**只能改两样东西**：

- 标题——点卡片进 `TextField`（`TodoItemRow.swift:173-175`）
- 模糊时段——`Anytime` 那行 `Menu`（`TodoItemRow.swift:102-125`）

AI 最容易搞错的**日期、分类、优先级**都改不了。用户只有两条路：先 `Add` 存进库，
再去 `TodoDetailView` 改（绕一大圈）；或者点 ✕ 删掉重录。

**目标**：点卡片 → 卡片**在弹层内原地展开**成编辑面板，改完收起，
顶部 `Add N` 语义不变（随时提交全部 N 条）。不新增导航层级、不动 `TodoDetailView` 的持久化逻辑。

## 已确认的四个决策

| 决策点 | 选择 | 落选项及原因 |
|---|---|---|
| 展开形态 | **卡片就地展开**（accordion） | 弹层内 push 需加回被刻意去掉的 `NavigationStack`，且动态 detent 与新页高度打架；全屏复用详情页要动它的持久化层，回归面覆盖全 app 编辑入口 |
| `Add N` 语义 | **保持不变**：始终可见，提交全部 N 条并关闭 | 改「完成」多一次点击且要处理「未收起就点 Add」；「只添加这条」需 `confirmTodos` 支持部分提交，牵动学习/词汇/日历同步的批次语义 |
| 可编辑字段 | 标题、日期、钟点/时段、分类、优先级 | 备注与重复规则留给详情页——重复编辑器（`TodoDetailView.swift:762-947`）含周几网格、间隔、每月几号轮盘，面板会过长 |
| 编辑控件来源 | **从详情页抽成共享组件**，两边共用 | 确认页另写一套会产生第二份日期/时间选择器，样式必然漂移——仓库已有 `PendingDateTodoRow` 这个先例 |

## 现状：两条不相通的栈

| | 确认页（草稿） | 详情页（已保存） |
|---|---|---|
| 数据 | `ExtractedTodo`（`Protocols/Models.swift:126-228`），纯内存，字段全是 `var` | `TodoItemData`，必须已落库 |
| 编辑方式 | `@Binding` 一路传到 row，直接写 `coordinator.extractedTodos` | 改完 800ms 防抖自动写 SwiftData |
| 承载 | `.sheet` + 动态 detent，**故意没有 `NavigationStack`**（`HomeView.swift:396-398`） | `fullScreenCover` + 自带 `NavigationStack` |
| 提交 | 顶部 `Add N` → `coordinator.confirmTodos` | 无提交按钮，边改边存 |

好消息是**字段几乎一一对应**（标题/备注/分类/优先级/日期/时段/重复都有），
所以不是数据模型的问题，是「编辑控件没抽出来」+「保存语义不同」两件事。

`TodoDetailView`（1189 行）里所有编辑控件——日期 popover、钟点选择、时段 chip、分类格、
优先级、重复规则——**全是它自己的 `private` 成员，一个都没抽出来**。

---

## 实施方案

### 1. 抽共享编辑控件 → `UI/Shared/TodoFieldEditors.swift`（新文件）

把 `TodoDetailView` 里 5 组控件提出来，改成**只收 Binding 的纯 UI 组件**。
它们本来就没碰持久化，只在末尾调 `checkForChanges()`——换成 `onEdit: () -> Void` 回调即可。
原文件对应位置改为调用新组件。

| 新组件 | 从哪来 | API |
|---|---|---|
| `TodoDatePopoverTrigger` | `TodoDetailView.swift:553-632`（`datePopoverTrigger` + `datePopoverBinding` + `schedulePopoverDismiss`） | `init(date: Binding<Date?>, fallbackAnchor: Date?, onEdit: () -> Void)` |
| `TodoClockTimeRow` | `TodoDetailView.swift:640-733`（`timeSection`） | `init(dueDate: Binding<Date?>, hasDueTime: Binding<Bool>, timeBucket: Binding<TimeBucket?>, recurrenceFrequency: RecurrenceFrequency?, onEdit: () -> Void)` |
| `TodoTimeBucketChipRow` | `TodoDetailView.swift:735-758`（`timeBucketButton`） | `init(selection: Binding<TimeBucket?>, onEdit: () -> Void)` |
| `TodoCategoryGrid` | `TodoDetailView.swift:480-496`（`categoryChip`）+ `:206-224` 的 `LazyVGrid` | `init(selection: Binding<TodoCategory>, onEdit: () -> Void)` |
| `TodoPriorityPicker` | `TodoDetailView.swift:505-545`（`priorityButton` + `priorityButtonBackground`）+ `:226-238` 的 `HStack` | `init(selection: Binding<Priority>, onEdit: () -> Void)` |

约束：

- **视觉零变化**——原样搬运 padding / 圆角 / 颜色 / 动画 / a11y id。
  `DetailDatePopoverTrigger`、`DetailAddTimeButton`、`DetailStartDatePicker` 等标识符必须保留。
- `schedulePopoverDismiss` 的 `Task` 句柄和 `popoverFallbackAnchor` 随组件一起迁进去做 `@State`。
  注意 `TodoDetailView.swift:601-618` 注释记录的边界：点已选中的同一日期时 setter 不触发、
  popover 不收，这是有意行为，别在搬运中「修掉」。
- 复用现成 domain helper，别重写：`RecurrenceAnchorPolicy.canAddClockTime` / `.dateRowMode`、
  `TimeBucketResolver.effective`、`DayClock.startOfUserDay`、`TimeBucket.chronologicalOrder`、
  `WarmTheme` / `WarmSpacing` / `WarmRadius` / `WarmAnimation`。
- **机会点（不在本次范围）**：`UI/Home/PendingDateTodoRow.swift:123-153` 是第三份平行实现的
  日期 popover，可被 `TodoDatePopoverTrigger` 替掉。只在新文件顶部注释里标注，别顺手做。

### 2. 草稿侧时间字段适配器

唯一的模型阻抗差：

| | 日期 | 钟点 |
|---|---|---|
| 详情页 | `dueDate: Date?`（含时分） | `hasDueTime: Bool` |
| 草稿 | `dueDate: Date?`（仅 y-m-d，来自 ISO `yyyy-MM-dd`） | `dueTime: String?`（`"HH:mm"`） |

在草稿面板里用**计算 Binding** 桥接，两个方向都复用已有工具
（`Protocols/Domain/TodoDueTimeResolver.swift`）：

- 读：`TodoDueTimeResolver.combine(date: todo.dueDate, dueTime: todo.dueTime)` → `(date, hasTime)`
- 写：拆回 `todo.dueDate = 日期部分`、`todo.dueTime = String(format: "%02d:%02d", h, m)`
  （`nil` = 清掉钟点）

`ExtractedTodo.init` 已强制「`dueTime` 与 `timeBucket` 互斥」（`Models.swift:214`），
但面板里直接改字段**绕过了 init**，需在写入路径显式维持该不变式：
设钟点时清 `timeBucket`，清钟点后才允许选时段。

### 3. ⚠️ 必修：手动改的日期会被 `TodoItem.from` 静默清掉

这是本需求的**头号坑**，不处理会做出一个「改了日期但存不下」的功能。

`Store/SwiftDataModels.swift:304-331` 的 `applyDueDateBasisFilter` 在保存时按
`dueDateBasis`（AI 自报的 due_date 来源）过滤 `dueDate`：

```
.userExplicit              + rawTranscript 非空且无时间状语 → 清空
.titleMention/.inferred/nil + rawTranscript == nil          → 清空
```

而在线主路径 `TodoStore.addBatch`（`TodoStore.swift:95`）调 `TodoItem.from(item)`
**不传 rawTranscript**。

结论：用户在面板里手动选的日期，只要 AI 原本给的 `dueDateBasis` 是 `nil` / `.inferred` /
`.titleMention`，**保存时会被无声丢弃**。这个过滤器本身是对的（它拦的是
"prepare for Sunday" 被误识别成截止日），只是它没有「用户手动指定」这个概念。

修法（最小、语义正确）：

1. `ExtractedTodo` 新增 `var dueDateUserEdited: Bool = false`——本地字段，
   **不写进 `CodingKeys`、不参与 `encode(to:)`**（与 `localeIdentifier` 同待遇，
   见 `Models.swift:187-188` 的注释）。
2. 面板里任何写 `todo.dueDate` 的路径把它置 `true`。
3. `applyDueDateBasisFilter` 开头加：

   ```swift
   // 用户在确认页手动指定的日期是最终判决，不再经 AI basis 白名单过滤——
   // 该过滤器拦的是「AI 把标题里偶然出现的日期词误识别为 due_date」，
   // 与「用户自己点了日历」无关。
   guard !extracted.dueDateUserEdited else { return false }
   ```

已核实**无需处理**的字段：`dueTime` / `timeBucket` / `priority` / `categoryHint`
在 `TodoItem.from`（`SwiftDataModels.swift:233-281`）里不经任何过滤，直接透传。

### 4. 新面板 → `UI/ConfirmSheet/TodoDraftEditorPanel.swift`（新文件）

```swift
struct TodoDraftEditorPanel: View {
    @Binding var todo: ExtractedTodo
    let index: Int
    let onCollapse: () -> Void
}
```

自上而下：

1. 标题 `TextField`——进入时自动聚焦，承接原来「点卡片一步改名」的效率
2. 日期行——`TodoDatePopoverTrigger` + ✕ 清除 / 「添加日期」（对齐 `TodoDetailView.swift:259-289`）
3. `Divider`
4. `TodoClockTimeRow`
5. 分类 `TodoCategoryGrid`
6. 优先级 `TodoPriorityPicker`
7. 底部「收起」

所有 Binding 直写 `todo`，**无保存动作**——点 `Add N` 时随 `coordinator.extractedTodos` 一并提交。

**不复用** `TodoDetailView.detailCard`（`:467-476`）的卡片外观：那是白底大卡，
而确认页卡片已有自己的圆角 + 左侧分类色条，面板应长在现有卡片内部，共用 `TodoItemRow` 的背景。

### 5. 展开状态接线

`ConfirmSheetView` 新增 `@State private var expandedTodoID: UUID?`，以 `Binding` 逐层下传：
`ConfirmGroupedList` → `ConfirmGroupSection` → `TodoItemRowWithDelete` → `TodoItemRow`。

`TodoItemRow` 改动：

- 删掉 `isEditing` / `editedTitle` / `isTextFieldFocused` 三个 `@State` 与
  `startEditing()` / `finishEditing()`（`:16-18, 66-73, 173-180, 188-199`）——标题编辑移进面板。
- `onTapGesture`（`:173-175`）改为：

  ```swift
  withAnimation(WarmAnimation.springStandard) {
      expandedTodoID = (expandedTodoID == todo.id) ? nil : todo.id
  }
  ```

- 展开时在卡片主 `HStack` 下方追加 `TodoDraftEditorPanel`，
  并**隐藏** `Anytime` 那行 `Menu`（`:102-125`）——面板里已有完整时段 chip，两处并存会重复。
- ✕ 删除按钮保留；删掉正在展开的卡片时把 `expandedTodoID` 置 `nil`。
- a11y：`accessibilityHint` 从 `a11y.edit_todo_title` 换成新 key `a11y.expand_todo`。

### 6. 展开态下的分组冻结（必须处理）

`ConfirmGroupedList.groupedSections`（`:50-96`）按 `dueDate` 实时分组。
用户在面板里改日期 → 卡片当场被算进另一个分组 → **展开着的面板会跳到别的 section 下**，
编辑被打断。且 `.animation(value: todos.count)`（`:28`）在 count 不变时不生效，会硬切。

对策：`ConfirmGroupedList` 在 `expandedTodoID != nil` 时**沿用上一帧的分组结果**
（`@State private var frozenSections: [GroupedSection]?`），收起时才重算并 `withAnimation` 播放归位。

流式期间用户在编辑属于边缘情形——以「新条目追加到冻结结果末尾」处理，不重排。

### 7. 弹层高度与滚动

`clampedSheetHeight`（`ConfirmSheetView.swift:333-341`）已按内容测高，面板撑高会自动长到
85% 屏高上限，超出走 ScrollView——**无需改高度逻辑**。

需补：展开时 `proxy.scrollTo(todo.id, anchor: .top)`，复用 `mainContent` 里已有的
`ScrollViewReader`（`:155`）——在 `.onChange(of: todos.count)`（`:184-191`）旁边加一条
`.onChange(of: expandedTodoID)`。

键盘弹起时 sheet 自身会上推，与现有标题编辑行为一致，不额外处理。

### 8. 本地化

`Resources/Localizable.xcstrings` 按字母序插入，en + zh-Hans 均 `"state": "translated"`：

| key | en | zh-Hans |
|---|---|---|
| `a11y.expand_todo` | `Tap to edit this task` | `点击编辑这条任务` |
| `confirm.collapse` | `Collapse` | `收起` |

同步调整：

- `confirm.hint`（底部操作提示，现为「Tap to edit title · Tap ✕ to delete」）改成
  「点击卡片编辑 · ✕ 删除」/「Tap a card to edit · ✕ to delete」
- `confirm.add %lld`（"Confirm (%lld)"，`extractionState: stale`，改版前遗留）顺手清掉

面板内其余文案直接复用详情页已有 key：`detail.add_date`、`detail.add_time`、`detail.time`、
`category.*`、`priority.*`。

---

## 改动文件清单

**新增**

- `UI/Shared/TodoFieldEditors.swift`
- `UI/ConfirmSheet/TodoDraftEditorPanel.swift`

**修改**

| 文件 | 改动 |
|---|---|
| `UI/Detail/TodoDetailView.swift` | 5 组控件替换为共享组件调用（纯删除 + 调用，无行为变化） |
| `UI/ConfirmSheet/TodoItemRow.swift` | 移除内联标题编辑、改 tap 语义、挂载面板 |
| `UI/ConfirmSheet/ConfirmGroupedList.swift` | 透传 `expandedTodoID`、分组冻结 |
| `UI/ConfirmSheet/ConfirmSheetView.swift` | `expandedTodoID` 状态、展开时 `scrollTo` |
| `Protocols/Models.swift` | `ExtractedTodo.dueDateUserEdited` |
| `Store/SwiftDataModels.swift` | `applyDueDateBasisFilter` 尊重 `dueDateUserEdited` |
| `Resources/Localizable.xcstrings` | 2 个新 key + 2 处文案调整 |

**新文件要登记进 Xcode 工程**：`project.yml` 的 `sources` 用的是目录级 `- path: UI`，
新文件会被 xcodegen 自动收进来，无需改 `project.yml`。

但注意 `15dc9ec`（*修正 .gitignore 让 pbxproj 能入库*）之后
**`VoiceTodo.xcodeproj/project.pbxproj` 已经进版本库**，所以新增源文件后必须：

```bash
xcodegen generate      # 或 ./prepare_xcode_project.sh
git add VoiceTodo.xcodeproj/project.pbxproj
```

把重新生成的 pbxproj **一起提交**，否则拉代码的人直接开 Xcode 会看不到这两个新文件。

（`.xcode_main_app_files.txt` 只有 33 行、明显早已停止维护，不是构建输入，不用管。）

---

## 验证

### 单元测试（`swift test`，`Package.swift` 的 target 只含 `Protocols`）

新增覆盖第 3 节那个坑——这是本次唯一有真实逻辑、且能在该层测到的部分：

- `dueDateUserEdited == true` 时 `TodoItem.from` 保留手动选的 `dueDate`
  （`dueDateBasis` 取 `nil` / `.inferred` / `.titleMention`，`rawTranscript` 取 `nil` /
  无时间状语文本，共 6 组）
- `dueDateUserEdited == false` 时原有过滤行为**逐条不变**（回归保护）
- `ExtractedTodo` 编码后 JSON **不含** `dueDateUserEdited` 字段
- 草稿时间适配器往返：`(dueDate, dueTime)` → `(Date?, Bool)` → 写回，
  「有钟点 / 清钟点 / 仅时段」三种状态无损

UI 组件是纯视图组合，仓库无 ViewInspector 依赖，**不要为抽组件硬造测试**。

### 构建

`.xcodeproj` 现已入库，但本方案新增了源文件，仍需重新生成后再构建（并记得提交 pbxproj）：

```bash
xcodegen generate      # 或 ./prepare_xcode_project.sh
xcodebuild -scheme VoiceTodo -destination 'platform=iOS Simulator,name=iPhone 16' build
```

### 手动验收（真正的验证在这里）

**详情页零回归**（第 1 节抽组件后必查）

1. 打开任一已保存任务的详情页：日期 popover 选中即收、钟点 picker、清钟点、时段 chip、
   分类格、优先级三档配色，与改动前逐项对比无差异。
2. 改任一字段 → 800ms 后出现「已保存 ✓」toast；不等 toast 直接下滑关闭 → 重开确认已存。
3. 双周/三周重复：日期行显示「起始日期」且无 ✕；daily / weekly(interval=1) / monthly：整行不渲染。

**确认页新流程**

4. 说 8-10 条任务 → 流式期间点某张卡片展开 → 后续条目仍正常从下方升起追加，展开的面板不跳位。
5. 展开面板改日期 → 卡片**不当场换组**；收起后才动画归位到新分组。
6. 展开面板改分类 → 卡片左侧色条与 emoji 同步变色。
7. 改钟点 → 时段 chip 变只读派生显示；点 ✕ 清钟点 → 时段 chip 恢复可选。
8. 展开着直接点 `Add N` → 面板里的改动全部落库（逐字段核对详情页）。
9. **第 3 节的坑**：录一条完全没有时间词的任务（如「买牛奶」）→ 展开手动选明天 → `Add`
   → 详情页确认日期**确实是明天**（改动前这里会丢）。
10. 展开着点 ✕ 删除该卡 → 面板收起、其余卡片不错位、`Add N` 计数正确。
11. 展开后内容超 85% 屏高 → sheet 到顶后转为滚动，`Add N` / `Cancel` 始终可点。
12. `Cancel` / 下滑关闭 → 走 `onCancel`，草稿全丢，无残留。

**无障碍 + 本地化**

13. VoiceOver：卡片播报新 hint「点击编辑这条任务」；展开后面板内各控件可达、可操作。
14. 切 en / zh-Hans 各跑一遍 4-12，确认无 key 泄漏、无 `%lld` 未替换。

### UI 测试

`VoiceTodoUITests/AppLaunchHelper.swift:152,297` 与 `ScenarioTests.swift` 依赖
`TodoRow_\(index)` / `TodoTitle_\(index)` / `DeleteTodo_\(index)`。
标题编辑从 `TodoItemRow` 移进面板后，`TodoTitle_\(index)` 的**出现路径变了**（需先展开），
必须同步更新这些测试的操作序列，否则是红。

---

## 工作量

| 部分 | 量 | 风险 |
|---|---|---|
| 抽 5 组共享控件 + 详情页替换 | ~250 行搬运 | 低-中——纯搬运，但详情页是全 app 编辑入口，必须逐项目视回归 |
| `TodoDraftEditorPanel` | ~180 行 | 低 |
| 展开状态透传 + `TodoItemRow` 改造 | ~60 行 | 低 |
| 分组冻结 | ~30 行 | 中——`ConfirmGroupedList` 已有为防越界写的 `firstIndex` 现查逻辑，冻结要与之共存 |
| `dueDateUserEdited` + 过滤器 + 单测 | ~20 行 + 4 组测试 | 低 |
| 本地化 + UI 测试修 | ~15 行 | 低 |

**合计：1.5-2 天**，其中约一半是抽组件后的详情页回归验证。
