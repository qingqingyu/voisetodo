# VoiceTodo UI Layer (Agent D)

这是 VoiceTodo iOS App 的 UI 层实现，遵循 v2 Prompt 规范。

## 📁 文件结构

```
UI/
├── ConfirmSheet/
│   ├── ConfirmSheetView.swift    # 确认弹窗视图
│   └── TodoItemRow.swift          # 待办条目行组件
├── Home/
│   └── HomeView.swift             # 主页视图
├── Shared/
│   ├── EmptyStateView.swift       # 空状态组件 [v2]
│   └── ToastView.swift            # 轻量提示组件 [v2]
├── Widget/
│   ├── TodoWidgetBundle.swift     # Widget Bundle
│   ├── TodoWidgetProvider.swift   # Widget 数据提供者
│   └── TodoWidgetView.swift       # Widget 视图
└── MockStore.swift                # Mock 数据源（开发用）
```

## ✅ 已实现功能

### 1. ToastView [v2 新增]
- 轻量级提示组件，从顶部滑入
- 支持 3 种样式：info / success / warning
- 2 秒后自动消失
- 使用 `.toast(message:style:isPresented:)` 修饰符
- 使用 `ErrorMessages` 常量作为提示文案

### 2. EmptyStateView [v2 新增]
- 通用空状态组件
- 提供 3 种预设样式：
  - `.homeEmpty()` - 主页空状态
  - `.widgetEmpty()` - Widget 空状态（水印风格）
  - `.lockscreenEmpty()` - 锁屏 Widget 空状态

### 3. TodoItemRow
- 可编辑的待办条目行
- 支持点击编辑标题（全选文字）
- 删除动画：向右滑出 + 淡出（0.28s）
- 显示分类 emoji、时间标签、优先级标签

### 4. ConfirmSheetView
- 语音录入后的确认面板
- 显示语音原文 + AI 提取结果
- 支持编辑/删除待办
- 成功动画：绿色圆形背景 + 对号（0.4s 弹性动画）
- 1.5 秒后自动关闭
- 使用 `.presentationDetents([.medium, .large])`

### 5. HomeView
- 主页待办列表
- 支持勾选完成、左滑删除
- 下拉刷新（预留）
- 空状态使用 `EmptyStateView.homeEmpty()`
- 底部录音按钮（备用入口）

### 6. Widget 系统
- **TodoWidgetBundle**: 注册所有 Widget
- **TodoTimelineProvider**:
  - 每 30 分钟自动刷新
  - 从 App Group 读取数据
  - 根据尺寸返回不同数量的待办
- **TodoWidgetView**:
  - 支持小/中/大尺寸 + 锁屏 Widget
  - 水印风格：文字透明度 0.65，阴影确保可读性
  - 空状态：淡色文字 + 勾选图标

## 🎨 设计规范

### 颜色
- 优先级高：红色标签
- 成功状态：#10B981（绿色）
- 文字透明度：0.65（水印风格）
- 阴影：`.black.opacity(0.3), radius: 1, y: 1`

### 动画
- 成功动画：0.4s，spring(dampingFraction: 0.6)
- 删除动画：0.28s，easeOut
- Toast 动画：0.3s，spring

### 配置常量（来自 Constants.swift）
```swift
UIConfig.successAnimationDuration = 0.4
UIConfig.toastDuration = 2.0
UIConfig.deleteAnimationDuration = 0.28

WidgetConfig.refreshInterval = 1800  // 30 分钟
WidgetConfig.smallItemCount = 1
WidgetConfig.mediumItemCount = 3
WidgetConfig.largeItemCount = 6
WidgetConfig.lockscreenItemCount = 2
```

## 🔧 使用方式

### Mock 数据开发
所有 UI 组件都使用 `TodoStoreProtocol`，开发时可以使用 `MockStore`：

```swift
// 预览数据
let store = MockStore.preview

// 空状态
let emptyStore = MockStore.empty

// 包含待处理项
let pendingStore = MockStore.withPendingItems
```

### Toast 使用示例
```swift
@State var showToast = false

view.toast(
    message: ErrorMessages.noTodosFound,
    style: .info,
    isPresented: $showToast
)
```

### ConfirmSheet 使用示例
```swift
@State var showConfirm = false
@State var todos: [ExtractedTodo] = [...]

.sheet(isPresented: $showConfirm) {
    ConfirmSheetView(
        transcript: "语音转写文本",
        todos: $todos,
        onConfirm: { confirmedTodos in
            try? store.addBatch(confirmedTodos)
        },
        onCancel: {
            // 取消处理
        }
    )
}
```

## ⚠️ 约束

1. **所有数据通过 Protocol 调用**，不直接操作 SwiftData
2. **Mock 数据使用 TodoItemData**（不依赖 SwiftData）
3. **用户提示统一使用 ErrorMessages 常量**，不硬编码字符串
4. **不要 import Voice/、Extractor/、Store/**
5. **不要修改 Protocols/**

## 📝 注意事项

### Widget 数据读取
`TodoTimelineProvider` 中的数据读取是临时 Mock 实现，实际应该：
1. 从 App Group 的 UserDefaults 读取
2. 或从 SwiftData 共享容器读取
3. 由 Agent C 实现完整的数据共享方案

### Xcode 项目配置
Widget 需要在 Xcode 项目中：
1. 添加 Widget Extension target
2. 配置 App Group: `group.com.voicetodo.shared`
3. 添加必要的 Capabilities

## 🧪 测试

每个组件都包含 Preview，可以在 Xcode 中预览：
```swift
#Preview {
    ToastView(message: "测试提示", style: .info)
}

#Preview {
    EmptyStateView.homeEmpty()
}
```

## 📋 Agent D 验收清单

- [x] ToastView 实现（支持 info/success/warning）
- [x] EmptyStateView 实现（homeEmpty/widgetEmpty/lockscreenEmpty）
- [x] TodoItemRow 实现（编辑、删除动画）
- [x] ConfirmSheetView 实现（原文显示、列表、成功动画）
- [x] HomeView 实现（列表、空状态、录音按钮）
- [x] TodoWidgetBundle 实现
- [x] TodoWidgetProvider 实现（30 分钟刷新）
- [x] TodoWidgetView 实现（小/中/大/锁屏）
- [x] MockStore 创建（用于开发和预览）
- [x] 使用 ErrorMessages 常量
- [x] 使用 TodoItemData 而非 SwiftData
- [x] 遵循配置常量（UIConfig、WidgetConfig）

---

**实现者**: Agent D
**日期**: 2026年3月18日
**版本**: v2.0
