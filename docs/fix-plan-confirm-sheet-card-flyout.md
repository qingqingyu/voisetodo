# 修复方案：确认页卡片「向右闪出」

> 状态：**待实施**。本文档是排查结论 + 实施方案，实施后请对照「验证」一节逐项确认。
> 相关文件：`UI/ConfirmSheet/TodoItemRow.swift`、`UI/ConfirmSheet/ConfirmSheetView.swift`

## 现象

流式解析任务时，卡片一条条出现；当内容写满屏幕后，部分卡片不是正常向上排布，而是**向右飞出**消失。

## 排查结论

这个「向右飞出 300pt」就是删除动画本身（`TodoItemRow.performDelete()` 里的 `offset = 300`），它泄漏到了没有被删除的卡片上。

根因链：

1. `TodoItemRow.swift:14,127,157-167` 用 `@State offset/opacity` + `.offset(x:)` 手写删除动画，并且是**先播 300ms 动画、播完才调 `onDelete()` 真正移除数据**
2. `@State` 绑定在**视图身份槽位**上而非数据上
3. `ConfirmSheetView.swift:124` 的 `ForEach(Array($todos.enumerated()), id: \.element.id)` 身份链脆弱：流式追加时数组不断变化，`index` 作为 `let` 传下去会随插入移位
4. 身份槽位被复用时，新条目继承上一条残留的 `offset = 300` → 一渲染出来就在右侧/已飞出

放大器：删除动画的 300ms 空窗期内数组未变但视图已偏移；此时若流式又追加条目，父级 `.animation(springSlow, value: todos.count)`（`ConfirmSheetView.swift:146`）重排整个子树，错配概率显著上升。屏幕写满后 ScrollView 内容高度频繁变化，重排更剧烈，所以「写满时」最容易复现。

同源问题在 `ConfirmSheetView.swift:237` 的注释里已被记录过（ForEach id 冲突导致「勾 A 影响 B」）。

## 改动方案

核心思路：**动画与真实删除绑定，杜绝可泄漏的中间状态**。手写 offset 状态之所以危险，是因为它能在「数据还在、视图已偏移」的窗口里被别的行继承；改用 transition 后，飞出动画只在条目真正从数组移除时播放，物理上不可能落到存活的行上。

### 1. `UI/ConfirmSheet/TodoItemRow.swift`

- 删除 `@State private var offset` / `@State private var opacity`（14-15 行）及 `.offset(x: offset)` / `.opacity(opacity)`（127-128 行）
- `performDelete()` 简化为直接调用 `onDelete()`，不再自己播动画、不再 `Task.sleep`
- `UIConfig.deleteAnimationDuration` 若无其他引用则一并清理；有引用就保留

### 2. `UI/ConfirmSheet/ConfirmSheetView.swift`

- `TodoItemRowWithDelete.onDelete`（282-285 行）保持 `withAnimation { todos.removeAll { ... } }`，删除动画由下面的 transition 表达
- 行的 `.transition`（130 行）改为**非对称**，用 `.asymmetric(insertion:removal:)`：
  - 插入：`.opacity.combined(with: .move(edge: .top))`（保持现有"从上落下"观感不变）
  - 移除：`.opacity.combined(with: .move(edge: .trailing))`（复刻原来"向右飞出"的删除观感）
- 收紧 ForEach 身份（124 行）：改用 SwiftUI 原生 binding 形式 `ForEach($todos) { $todo in ... }`。`ExtractedTodo` 已符合 `Identifiable`（`Protocols/Models.swift:126`），身份天然稳定，且不再依赖 `enumerated()` 产生的临时元组
- `index` 目前只用于 `accessibilityIdentifier("TodoRow_\(index)")`（`TodoItemRow.swift:130`）。改为在闭包内用 `todos.firstIndex(where: { $0.id == todo.id })` 派生（列表规模小，O(n) 可接受），**保持该 a11y id 格式不变**

## 验证

- 构建通过
- UITest：已 grep 确认 `VoiceTodoUITests/` 无用例依赖 `TodoRow_` 前缀，但 id 格式仍保持不变以防外部依赖；跑 `ScenarioTests` 中确认页相关用例
- 模拟器手动验证：
  - 一次说出 8-10 条任务触发流式解析，观察卡片逐条出现、内容超屏后**不再有卡片向右闪出**，滚动位置正常
  - 删除单条卡片：仍是向右飞出 + 淡出的观感（与改动前一致）
  - 流式解析进行中删除某条：其余卡片不受影响、不发生错位
  - 编辑某条标题后删除另一条，确认编辑态（`isEditing`/`editedTitle` 这两个 @State）不串行到别的行

## 备注

`.animation(springSlow, value: todos.count)`（`ConfirmSheetView.swift:146`）保留不动——身份稳定后它不再是风险源。
