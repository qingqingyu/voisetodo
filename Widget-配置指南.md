# Widget Extension 配置指南

## 问题背景

Widget Extension 是一个**独立的 target**，需要单独配置它能够访问的源文件。修改代码后，需要在 Xcode 中配置文件归属。

---

## 必须添加到 Widget Extension Target 的文件

### 1. 数据模型文件

| 文件 | 路径 | 用途 |
|------|------|------|
| `Models.swift` | `Protocols/Models.swift` | Priority, TodoCategory, TodoItemData |
| `SwiftDataModels.swift` | `Store/SwiftDataModels.swift` | TodoItem (@Model) |
| `VoiceTodoError.swift` | `Protocols/VoiceTodoError.swift` | 错误类型 |
| `ErrorMessages.swift` | `Protocols/ErrorMessages.swift` | 错误提示文案 |
| `Constants.swift` | `Protocols/Constants.swift` | WidgetConfig 等配置 |

### 2. Widget UI 文件

| 文件 | 路径 |
|------|------|
| `TodoWidgetBundle.swift` | `UI/Widget/TodoWidgetBundle.swift` |
| `TodoWidgetProvider.swift` | `UI/Widget/TodoWidgetProvider.swift` |
| `TodoWidgetView.swift` | `UI/Widget/TodoWidgetView.swift` |

---

## Xcode 配置步骤

### 步骤 1: 检查 Widget Target 的 Compile Sources

1. 选择项目 → 选择 `VoiceTodoWidget` target
2. 切换到 **Build Phases** 标签
3. 展开 **Compile Sources**
4. 确保以下文件已添加：

```
✅ TodoWidgetBundle.swift
✅ TodoWidgetProvider.swift
✅ TodoWidgetView.swift
✅ Models.swift (Protocols/)
✅ SwiftDataModels.swift (Store/)
✅ VoiceTodoError.swift (Protocols/)
✅ ErrorMessages.swift (Protocols/)
✅ Constants.swift (Protocols/)
```

### 步骤 2: 配置 App Group

1. 选择 `VoiceTodoWidget` target
2. 切换到 **Signing & Capabilities** 标签
3. 点击 **+ Capability** → 添加 **App Groups**
4. 添加: `group.com.voicetodo.shared`

> ⚠️ **重要**: 主 App 和 Widget 必须使用相同的 App Group ID

### 步骤 3: 配置 SwiftData 权限

Widget Extension 的 `.entitlements` 文件需要包含：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.application-groups</key>
    <array>
        <string>group.com.voicetodo.shared</string>
    </array>
</dict>
</plist>
```

### 步骤 4: 添加必要的 Framework

在 Widget target 的 **Link Binary With Libraries** 中添加：

- `SwiftData.framework`
- `WidgetKit.framework`
- `SwiftUI.framework`

---

## 验证配置是否正确

### 方法 1: 编译检查

```bash
# 编译 Widget Extension
xcodebuild -scheme VoiceTodoWidget -destination 'platform=iOS Simulator,name=iPhone 15 Pro'
```

如果编译通过，说明文件归属配置正确。

### 方法 2: 运行检查

1. 在模拟器上运行主 App
2. 添加一条待办
3. 添加 Widget 到桌面
4. 检查 Widget 是否显示刚添加的待办

---

## 常见问题

### Q1: Widget 显示占位数据而不是真实数据

**原因**: Widget 无法读取 App Group 数据

**解决方案**:
1. 检查 App Group ID 是否一致
2. 检查 Widget target 是否配置了 App Groups capability
3. 检查 `SwiftDataModels.swift` 是否添加到 Widget target

### Q2: 编译错误 "Cannot find type 'TodoItem' in scope"

**原因**: `SwiftDataModels.swift` 未添加到 Widget target

**解决方案**: 在 Xcode 中选中 `SwiftDataModels.swift`，在右侧面板的 Target Membership 中勾选 `VoiceTodoWidget`

### Q3: Widget 显示空白

**原因**: 数据库文件不存在或无权限访问

**解决方案**:
1. 确保主 App 至少运行过一次（创建数据库）
2. 检查 App Group 配置

---

## 代码已完成的修改

### `TodoWidgetProvider.swift`

```swift
// ✅ 已修改：从 App Group SwiftData 读取真实数据
private func getRecentTodos(limit: Int) -> [TodoItemData] {
    do {
        // 获取 App Group 共享容器
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            return getPlaceholderTodos(limit: limit)
        }

        // 配置 SwiftData
        let schema = Schema([TodoItem.self])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            allowsSave: false,  // Widget 只读
            groupContainer: .identifier(appGroupIdentifier)
        )

        let container = try ModelContainer(for: schema, configurations: configuration)
        let context = container.mainContext

        // 查询未完成的待办
        var descriptor = FetchDescriptor<TodoItem>(
            predicate: #Predicate { !$0.isCompleted },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit

        let items = try context.fetch(descriptor)
        return items.map { $0.toData() }

    } catch {
        return getPlaceholderTodos(limit: limit)
    }
}
```

---

## 下一步

配置完成后，Widget 将能够：
- ✅ 显示用户添加的真实待办
- ✅ 只显示未完成的待办
- ✅ 按创建时间倒序排列
- ✅ 主 App 添加/删除/完成后自动更新

---

*配置指南更新于 2026年3月25日*
