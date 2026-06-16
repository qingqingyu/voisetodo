# VoiceTodo Xcode 项目创建指南

本指南将帮助你将 VoiceTodo 从纯 SPM 项目转换为完整的 Xcode iOS 项目，以支持所有测试。

## 前置条件

- Xcode 15.0+
- iOS 17.0+ SDK
- 已安装当前项目代码

## 步骤 1：创建 Xcode 项目

1. 打开 Xcode
2. 选择 **File → New → Project**
3. 选择 **iOS → App**
4. 配置项目：
   - **Product Name**: VoiceTodo
   - **Team**: 选择你的开发团队
   - **Organization Identifier**: com.voicetodo
   - **Bundle Identifier**: com.voicetodo.app
   - **Interface**: SwiftUI
   - **Language**: Swift
   - **Storage**: SwiftData
   - **Include Tests**: ✅ 勾选

5. **保存位置**:
   - 选择 `/Users/TWJ/工作/git/doflow/` 目录
   - ⚠️ **重要**: 不要选择现有的 VoiceTodo 文件夹，而是让 Xcode 创建新的

## 步骤 2：清理自动生成的文件

创建完成后，删除 Xcode 自动生成的以下文件（我们已有自己的实现）：

```
VoiceTodo/
├── VoiceTodoApp.swift       ❌ 删除
├── ContentView.swift        ❌ 删除
├── Item.swift               ❌ 删除（如果存在）
└── Assets.xcassets         ✅ 保留
```

## 步骤 3：添加现有代码文件到项目

### 3.1 添加源文件

在 Xcode 项目导航器中，右键点击项目根节点 → **Add Files to "VoiceTodo"**：

**主应用文件 (Target: VoiceTodo)**:
```
✅ App/
   ✅ VoiceTodoApp.swift
   ✅ AppCoordinator.swift
   ✅ OnboardingView.swift
   ✅ PermissionManager.swift
   ✅ SystemCalendarWriter.swift
   ✅ Intents/ (整个文件夹)
   （ServiceContainer+VoiceTodo.swift 已移除）

✅ Voice/
   ✅ VoiceInputManager.swift
   ✅ AudioSessionHelper.swift
   ✅ VoiceConstants.swift

✅ Extractor/
   ✅ TodoExtractorService.swift
   ✅ NetworkClient.swift

✅ Store/
   ✅ SwiftDataModels.swift
   ✅ TodoStore.swift
   ✅ AppGroupConfig.swift

✅ UI/
   ✅ ConfirmSheet/ (整个文件夹)
   ✅ Home/ (整个文件夹)
   ✅ Shared/ (整个文件夹)
   ✅ Widget/ (整个文件夹 - 暂时不添加，见步骤 5)
   ✅ MockStore.swift (仅 Debug 配置)
   ✅ UIDemoView.swift (仅 Debug 配置)
```

**共享协议文件 (Target: VoiceTodo)**:
```
✅ Protocols/
   ✅ Models.swift
   ✅ VoiceInputProtocol.swift
   ✅ TodoExtractorProtocol.swift
   ✅ TodoStoreProtocol.swift
   ✅ VoiceTodoError.swift
   ✅ ErrorMessages.swift
   ✅ Constants.swift
   ✅ NetworkMonitor.swift
   ✅ CalendarWriteMode.swift
   ✅ UITestLaunchOptions.swift
   （ServiceContainer.swift 已移除）
```

**重要设置**:
- ✅ **Copy items if needed**: 不勾选（文件已在本地）
- ✅ **Create groups**: 选中
- ✅ **Add to targets**: 只勾选 VoiceTodo
- ⚠️ **不要勾选** VoiceTodoTests 或 VoiceTodoUITests

### 3.2 添加测试文件

**单元测试 (Target: VoiceTodoTests)**:
```
✅ VoiceTodoTests/
   ✅ Protocols/ProtocolsTests.swift
   ✅ Voice/VoiceInputTests.swift
   ✅ Extractor/ExtractorTests.swift
   ✅ Store/StoreTests.swift
   ✅ Integration/IntegrationTests.swift
```

**设置**:
- Add to targets: **只勾选 VoiceTodoTests**

**UI 测试 (Target: VoiceTodoUITests)**:
```
✅ VoiceTodoUITests/
   ✅ MockSetup.swift
   ✅ AppLaunchHelper.swift
   ✅ ScenarioTests.swift
   ✅ WidgetSnapshotTests.swift
```

**设置**:
- Add to targets: **只勾选 VoiceTodoUITests**

## 步骤 4：配置 Target 设置

### 4.1 VoiceTodo (主应用) 配置

**General**:
- **Bundle Identifier**: `com.voicetodo.app`
- **Version**: 1.0
- **Build**: 1
- **Deployment Target**: iOS 17.0
- **Supported Destinations**: iPhone

**Signing & Capabilities**:
- ✅ **Automatically manage signing**
- **Capability**: App Groups
  - 点击 **+ Capability**
  - 搜索 "App Groups"
  - 添加 App Group: `group.com.voicetodo.shared`

**Build Settings**:
- **Swift Language Version**: Swift 5
- **Enable Testability**: Yes (Debug)
- **Defines Module**: Yes

**Build Phases**:
- **Link Binary With Libraries**:
  - ✅ SwiftData.framework
  - ✅ Speech.framework
  - ✅ AVFoundation.framework
  - ✅ WidgetKit.framework
  - ✅ Combine.framework

### 4.2 VoiceTodoTests 配置

**General**:
- **Bundle Identifier**: `com.voicetodo.tests`
- **Deployment Target**: iOS 17.0
- **Host Application**: VoiceTodo

**Build Phases**:
- **Link Binary With Libraries**:
  - ✅ SwiftData.framework
  - ✅ XCTest.framework

### 4.3 VoiceTodoUITests 配置

**General**:
- **Bundle Identifier**: `com.voicetodo.uitests`
- **Deployment Target**: iOS 17.0
- **Target Application**: VoiceTodo

## 步骤 5：创建 Widget Extension

### 5.1 添加 Widget Target

1. 在 Xcode 中，选择项目根节点
2. 点击底部的 **+** 按钮（添加 Target）
3. 选择 **iOS → Widget Extension**
4. 配置：
   - **Product Name**: VoiceTodoWidget
   - **Team**: 选择你的团队
   - **Include Configuration Intent**: ❌ 不勾选
   - **Include Live Activity**: ✅ 勾选（如果支持）

5. 点击 **Finish**
6. 弹出提示时，选择 **Activate**

### 5.2 添加 Widget 代码

删除自动生成的 Widget 文件，添加现有文件：

**Widget 文件 (Target: VoiceTodoWidget)**:
```
✅ UI/Widget/
   ✅ TodoWidgetBundle.swift
   ✅ TodoWidgetProvider.swift
   ✅ TodoWidgetView.swift
```

**共享文件 (Target: VoiceTodoWidget)**:
```
✅ Protocols/
   ✅ Models.swift
   ✅ VoiceTodoError.swift
   ✅ ErrorMessages.swift
   ✅ Constants.swift
```

### 5.3 配置 Widget Target

**Signing & Capabilities**:
- ✅ **App Groups**: `group.com.voicetodo.shared` (与主应用相同)

**Build Settings**:
- **Swift Language Version**: Swift 5

## 步骤 6：配置 App Group 和共享数据

### 6.1 配置 App Group

确保所有 targets 都配置了相同的 App Group：

1. 选择 VoiceTodo target → Signing & Capabilities → App Groups
   - ✅ `group.com.voicetodo.shared`

2. 选择 VoiceTodoWidget target → Signing & Capabilities → App Groups
   - ✅ `group.com.voicetodo.shared`

### 6.2 配置 SwiftData 共享

在 **VoiceTodoApp.swift** 中配置 SwiftData 使用共享容器：

```swift
import SwiftUI
import SwiftData

@main
struct VoiceTodoApp: App {
    @StateObject private var coordinator = AppCoordinator()

    init() {
        // 配置 SwiftData 使用 App Group 容器
        let containerURL = AppGroupConfig.sharedContainerURL
        // 配置代码...
    }

    var body: some Scene {
        WindowGroup {
            coordinator.rootView
        }
        .modelContainer(container)
    }
}
```

## 步骤 7：修复编译错误

### 7.1 处理 @testable import

在测试文件中，确保正确导入：

```swift
// VoiceTodoTests 中的文件
@testable import VoiceTodo  // 不是 VoiceTodoProtocols

// VoiceTodoUITests 中的文件
@testable import VoiceTodo
```

### 7.2 ~~更新 ServiceContainer~~（已移除）

ServiceContainer 方案已废弃（改为构造注入），本节不再适用。

### 7.3 处理条件编译

某些文件可能需要条件编译标记：

```swift
#if DEBUG
// 仅在 Debug 模式下编译的代码
#endif

#if !WIDGET_EXTENSION
// 不在 Widget Extension 中编译的代码
#endif
```

## 步骤 8：配置 Scheme 和运行设置

### 8.1 创建 Schemes

1. **VoiceTodo** (主应用)
2. **VoiceTodoTests** (单元测试)
3. **VoiceTodoUITests** (UI 测试)
4. **VoiceTodoWidget** (Widget 开发)

### 8.2 配置测试 Scheme

1. 选择 **Product → Scheme → Manage Schemes**
2. 对于 VoiceTodo scheme:
   - ✅ **Shared**
   - **Test**: VoiceTodoTests, VoiceTodoUITests

## 步骤 9：验证项目结构

最终的项目结构应该是：

```
VoiceTodo/
├── VoiceTodo.xcodeproj
│   └── project.pbxproj
│
├── VoiceTodo (Target: VoiceTodo)
│   ├── App/
│   ├── Voice/
│   ├── Extractor/
│   ├── Store/
│   ├── UI/
│   │   ├── ConfirmSheet/
│   │   ├── Home/
│   │   ├── Shared/
│   │   └── Widget/ (仅引用，不包含)
│   └── Protocols/
│
├── VoiceTodoTests (Target: VoiceTodoTests)
│   ├── Protocols/
│   ├── Voice/
│   ├── Extractor/
│   ├── Store/
│   └── Integration/
│
├── VoiceTodoUITests (Target: VoiceTodoUITests)
│   ├── MockSetup.swift
│   ├── AppLaunchHelper.swift
│   ├── ScenarioTests.swift
│   └── WidgetSnapshotTests.swift
│
├── VoiceTodoWidget (Target: VoiceTodoWidget)
│   └── UI/Widget/
│
└── VoiceTodo.xcodeproj
```

## 步骤 10：运行测试

### 10.1 运行单元测试

```bash
# 命令行方式
xcodebuild test \
  -project VoiceTodo.xcodeproj \
  -scheme VoiceTodo \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro' \
  -only-testing:VoiceTodoTests
```

或在 Xcode 中：
1. 选择 VoiceTodo scheme
2. **Product → Test** (或 ⌘U)

### 10.2 运行 UI 测试

```bash
# 命令行方式
xcodebuild test \
  -project VoiceTodo.xcodeproj \
  -scheme VoiceTodo \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro' \
  -only-testing:VoiceTodoUITests
```

或在 Xcode 中：
1. 选择特定的 UI 测试文件
2. 点击测试导航器中的 ▶️ 按钮

### 10.3 运行所有测试

```bash
xcodebuild test \
  -project VoiceTodo.xcodeproj \
  -scheme VoiceTodo \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro'
```

## 步骤 11：故障排查

### 编译错误

**"No such module 'SwiftData'"**
- 检查 Deployment Target 是否为 iOS 17.0+
- 确保 Link Binary With Libraries 包含 SwiftData.framework

**"Cannot find type 'TodoItem' in scope"**
- 检查 SwiftDataModels.swift 的 Target Membership
- 确保它包含在 VoiceTodo 和 VoiceTodoTests targets 中

**"Use of unresolved identifier"**
- 检查文件的 Target Membership
- 确保相关文件包含在正确的 target 中

### 运行时错误

**"Failed to find or create execution policy"**
- 检查 App Group 配置
- 确保所有 targets 使用相同的 App Group ID

**"The model configuration is not valid"**
- 检查 SwiftData ModelContainer 配置
- 确保使用共享容器路径

## 步骤 12：优化设置

### 12.1 配置 Debug 设置

在 **Build Settings** 中：
- **Enable Testability**: Yes (Debug only)
- **Optimization Level**: -Onone (Debug)
- **Debug Information Format**: DWARF with dSYM (Release)

### 12.2 配置代码覆盖率

1. **Product → Scheme → Edit Scheme**
2. **Test → Options**
3. ✅ **Code Coverage**: Enable

### 12.3 配置 Sanitizers (可选)

在 Scheme 中启用：
- ✅ **Thread Sanitizer**
- ✅ **Address Sanitizer**
- ✅ **Undefined Behavior Sanitizer**

## 后续步骤

项目创建完成后：

1. ✅ 运行所有单元测试，确保通过
2. ✅ 运行 UI 测试，确保基本场景通过
3. ✅ 配置 CI/CD（GitHub Actions / Bitrise）
4. ✅ 添加到 Git 仓库
5. ✅ 创建第一个 Release build

## 参考资源

- [Xcode 项目配置指南](https://developer.apple.com/documentation/xcode)
- [SwiftData 配置](https://developer.apple.com/documentation/swiftdata)
- [Widget Extension 开发](https://developer.apple.com/documentation/widgetkit)
- [XCTest 框架](https://developer.apple.com/documentation/xctest)

---

**创建完成后，请返回更新 `TestReport.md` 以反映所有测试的执行结果。**
