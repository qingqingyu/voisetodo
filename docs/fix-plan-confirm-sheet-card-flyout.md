# 修复方案：确认页卡片流式期间「向右闪出」

> 状态：**待实施**。本文档是排查结论 + 实施方案，实施后请对照「验证」一节逐项确认。
> 主改动文件：`Extractor/TodoExtractorService.swift`
> 相关文件（只读参考）：`Protocols/Models.swift`、`UI/ConfirmSheet/ConfirmGroupedList.swift`

> ⚠️ **本文档为修订版（v2）。** 初版（commit 593e4f7）诊断错误，已作废——初版把现象归因到
> `TodoItemRow` 手写的 `offset = 300` 泄漏。该归因不成立：`offset` 仅在 `performDelete()`
> 内被写入，流式期间用户并未点击删除，该值恒为 0，不存在泄漏源。错误来源是分析时所在分支
> 落后 origin/main 二十余个提交，`UI/ConfirmSheet/` 已重构出 `ConfirmGroupedList.swift`，
> 而初版读的是旧版 `ConfirmSheetView.swift`（其 transition 为 `.move(edge: .top)`，无横向动作）。

## 现象

流式解析任务时，卡片一条条出现；当内容写满屏幕后，部分卡片不是正常向上排布，而是**向右飞出**消失。

## 根因（已逐层核实）

**1. 每次 decode 都生成新 UUID**

`Protocols/Models.swift:259`：

```swift
id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
```

AI 返回的 JSON 中**没有 `id` 字段**（prompt schema 只含 title / detail / due_date / priority / category_hint 等），因此 `decodeIfPresent` 恒为 nil，每次解码都落到 `UUID()` 生成全新 id。

**2. 流式解析每轮重解析全部对象**

`Extractor/TodoExtractorService.swift` 的 `tryParsePartialTodos` 在每次 partial yield 时，把累积文本中**所有**已完整的对象重新 decode 一遍。结果：

```
yield #1: [买菜(uuid-A)]
yield #2: [买菜(uuid-B) ← id 变了!, 开会(uuid-C)]
```

**3. UI 层以 id 为 ForEach 身份，并声明了向右移出的 removal transition**

`UI/ConfirmSheet/ConfirmGroupedList.swift:113-129`：

```swift
ForEach(section.todoIDs, id: \.self) { id in
    ...
    .transition(
        .asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .move(edge: .trailing).combined(with: .opacity)   // ← 向右飞出
        )
    )
}
```

**4. 合流结果**

每次 partial 更新，SwiftUI 判定旧 id 全部「被删除」→ 播放 `removal` 向右飞出；新 id 全部「被插入」→ 播放 `insertion` 从下升起。

这同时解释了现象的两半：「从下往上一个个跳出」= insertion transition；「向右闪出」= removal transition。

**附带发现**：`ConfirmGroupedList.swift` 中的注释声称「流式过程 .partial 整体替换 todos，**但 id 不变**」——该不变量已被解析层违反，注释与实现不符。实施本方案后该注释才真正成立。

## 改动方案

核心：**让流式期间同一个逻辑 todo 在多轮 yield 之间保持同一个 id**。UI 层的 removal transition 是期望行为（真删除时就该向右飞出），不应改动。

### `Extractor/TodoExtractorService.swift`（`extractStream` 内）

1. 在流的作用域内维护稳定 id 列表：`var stableIDs: [UUID] = []`
2. 增加映射步骤：按 index 取 `stableIDs[i]`，数量不足时追加新 UUID；用它覆盖新 decode 出的 id
3. **三个 yield 点全部套用，缺一不可**：
   - partial yield（约 225 行）
   - 错误兜底 partial yield（约 239 行）
   - **流结束后的 final yield（约 232 行，`parseResponse(accumulatedText)`）**

   第三处最易遗漏：final 是一次全新的完整解析，同样生成新 UUID。只修 partial 会导致「最后一次 partial → final」切换时再整批飞一次右。

4. `ExtractedTodo.id` 目前是 `let`，需提供复制改 id 的途径（新增内部 `withID(_:)` 辅助方法，或将 `id` 改为 `var`）

### 为什么按 index 做 key 是安全的

（消解「merge key 选不准可能引入新 bug」这一风险）

- `tryParsePartialTodos` 依靠括号深度匹配，**只吐出完整的 `{...}` 对象**——对象一旦被解析出来，其内容即为最终态，不会在后续轮次中变化
- `partialTodos.count > lastYieldedCount` 的判定保证条目数**单调增长**，不会中途减少或重排
- final 解析基于同一份 `accumulatedText`，产出顺序与 partial 一致

因此 index N 恒定指向同一个逻辑 todo，index → 身份的映射天然稳定。

## 不在本次范围

`TodoItemRow` 的手写删除动画（`@State offset` / `opacity` + `deleteTask` + `deleteTaskGeneration` 三个状态互相牵制，而 removal transition 已能表达同样效果）是**独立的代码质量问题，与本 bug 无关**。清理它有价值，但应另开一次改动，不要混入本次修复。

## 验证

- 构建通过
- 模拟器：一次说出 8-10 条任务触发流式解析
  - 卡片应逐条从下方升起，**全程无任何卡片向右飞出**
  - 流式结束（final yield）瞬间同样不应出现整批闪动
- 删除单条卡片：仍为向右飞出 + 淡出（该 transition 是期望行为，保持不变）
- 流式进行中删除某条：其余卡片不受影响、不发生错位
- 断网 / 中途失败触发错误兜底 partial 分支，确认同样无闪动
