# VoiceTodo App Layer (Agent E)

这是 VoiceTodo iOS App 的应用层实现，负责组装所有模块并协调流程。

## 📁 文件结构

```
App/
├── VoiceTodoApp.swift       # 主应用入口
├── AppCoordinator.swift     # 流程编排器
├── OnboardingView.swift     # 首次启动引导 [v2]
└── PermissionManager.swift  # 权限管理 [v2]
```

## ✅ 已实现功能

### 1. VoiceTodoApp
- SwiftData ModelContainer 配置（App Group 共享）
- 依赖注入（VoiceInputManager、TodoExtractorService、TodoStore）
- 首次启动判断（OnboardingView）
- Action Button 启动判断
- App 前后台切换处理

### 2. AppCoordinator [核心]
完整的语音录入流程编排：

1. **启动录音** → `voiceInput.startRecording()`
2. **录音停止** → 获取 transcript
3. **网络检查** →
   - 有网：调用 `extractor.extract(from:)`
   - 无网：降级路径
4. **降级路径** →
   - `store.addRawTranscript(transcript)`
   - 显示 Toast: ErrorMessages.savedOffline
   - 跳过 ConfirmSheet
5. **提取成功但为空** →
   - 显示 Toast: ErrorMessages.noTodosFound
   - 跳过 ConfirmSheet
6. **提取成功且非空** →
   - 弹出 ConfirmSheetView
7. **用户确认** →
   - `store.addBatch()`
   - `WidgetCenter.reloadAllTimelines()`

### 3. OnboardingView [v2 新增]
分步引导流程（5 步）：

- **Step 1**: 欢迎页
  - App 名称 + 一句话介绍
  - 功能特点展示

- **Step 2**: 麦克风权限
  - 说明文案
  - 请求权限按钮
  - 被拒绝时显示引导跳转设置

- **Step 3**: 语音识别权限
  - 隐私说明（本地处理）
  - 请求权限
  - 被拒绝处理

- **Step 4**: Action Button 配置引导
  - 配置步骤说明
  - 跳转系统设置按钮

- **Step 5**: 完成
  - 成功提示
  - 使用提示

### 4. PermissionManager [v2 新增]
权限管理功能：

- 检查权限状态（麦克风、语音识别）
- 请求权限（异步）
- 打开系统设置
- 权限状态判断（是否永久拒绝）

## 🔄 流程图

### 完整录入流程

```
启动 App
   ↓
检查首次启动 ──Yes──→ OnboardingView
   ↓ No
HomeView
   ↓
点击录音/Action Button
   ↓
startRecording()
   ↓
用户说话
   ↓
静音检测/手动停止
   ↓
stopRecording()
   ↓
获取 transcript
   ↓
检查网络 ──No──→ addRawTranscript()
   ↓ Yes              ↓
extract()         Toast: savedOffline
   ↓
todos.isEmpty?
   ↓ Yes ──────→ Toast: noTodosFound
   ↓ No
ConfirmSheetView
   ↓
用户确认 ──→ addBatch() + reloadWidget
   ↓
成功动画 → dismiss
```

### 网络恢复补处理流程

```
App 进入前台
   ↓
store.pendingItems()
   ↓
为空? ──Yes──→ 什么都不做
   ↓ No
后台静默处理
   ↓
逐条调用 extract()
   ↓
全部完成
   ↓
BatchConfirmView
   ↓
用户一次性确认
   ↓
replacePendingWithExtracted()
```

## 🎯 关键设计决策

### 1. 依赖注入
所有模块通过构造器注入，便于测试和替换：

```swift
let voiceInput = VoiceInputManager()
let extractor = TodoExtractorService()
let store = TodoStore(modelContext: modelContainer.mainContext)

let coordinator = AppCoordinator(
    voiceInput: voiceInput,
    extractor: extractor,
    store: store
)
```

### 2. 状态管理
使用 `@StateObject` 和 `@Published` 管理状态：

```swift
@Published var isRecording = false
@Published var transcript = ""
@Published var showConfirmSheet = false
```

### 3. 错误处理
统一在 `handleError()` 中处理所有错误，转换为用户提示：

```swift
private func handleError(_ error: Error) {
    if let voiceError = error as? VoiceTodoError {
        // 映射到 ErrorMessages
    }
}
```

### 4. 离线降级
网络不可用时自动降级：

```swift
guard await isNetworkAvailable() else {
    await handleOfflineMode(transcript: text)
    return
}
```

### 5. App Group 配置
SwiftData 使用 App Group 共享数据：

```swift
let configuration = ModelConfiguration(
    schema: schema,
    groupContainer: .identifier("group.com.voicetodo.shared")
)
```

## 📝 使用方式

### 集成到项目

1. **配置 App Group**
   - 在 Xcode 中添加 App Group capability
   - 设置 ID: `group.com.voicetodo.shared`

2. **添加 Widget Extension**
   - 创建 Widget Extension target
   - 配置相同的 App Group

3. **配置 URL Scheme**（可选）
   - 添加 URL Scheme 用于 Action Button

### 触发录音

```swift
// 方式 1: 通过 Coordinator
await coordinator.startRecording()

// 方式 2: Action Button 启动
await coordinator.handleActionButtonLaunch()
```

### 监听状态

```swift
// 在 View 中监听
@EnvironmentObject var coordinator: AppCoordinator

if coordinator.isRecording {
    RecordingIndicator()
}

.sheet(isPresented: $coordinator.showConfirmSheet) {
    ConfirmSheetView(...)
}
```

## ⚠️ 注意事项

### 1. App Group ID
确保 App Group ID 与 Widget Extension 一致：
```
group.com.voicetodo.shared
```

### 2. 权限处理
首次使用必须经过 OnboardingView，确保权限授予。

### 3. 网络检测
当前使用简单的 URL 请求检测网络，生产环境建议使用 `NWPathMonitor`。

### 4. Action Button 判断
V1 使用简单判断，实际可通过以下方式改进：
- URL Scheme 参数
- User Activity
- UserDefaults 标记

### 5. 后台处理
网络恢复补处理是静默进行的，不阻塞 UI。

## 🧪 测试

### 预览测试

```swift
#Preview {
    VoiceTodoApp()
}
```

### 流程测试

1. 首次启动 → 应显示 OnboardingView
2. 完成引导 → 应进入 HomeView
3. 点击录音 → 应开始录音
4. 说话后停止 → 应弹出 ConfirmSheet
5. 确认 → 应保存到数据库
6. 离线测试 → 应显示离线提示
7. 网络恢复 → 应自动补处理

## 🔧 配置清单

### Info.plist 权限

```xml
<key>NSSpeechRecognitionUsageDescription</key>
<string>需要语音识别权限来将语音转为文字</string>

<key>NSMicrophoneUsageDescription</key>
<string>需要麦克风权限来录音</string>
```

### Capabilities

- App Groups
- Siri (可选)

### Entitlements

```xml
<key>com.apple.security.application-groups</key>
<array>
    <string>group.com.voicetodo.shared</string>
</array>
```

## 📋 Agent E 验收清单

- [x] VoiceTodoApp 实现（ModelContainer、依赖注入）
- [x] AppCoordinator 实现（完整流程编排）
- [x] OnboardingView 实现（5 步引导）
- [x] PermissionManager 实现（权限管理）
- [x] 离线降级处理
- [x] 网络恢复补处理
- [x] Action Button 判断
- [x] App 前后台切换处理
- [x] 错误统一处理
- [x] Toast 提示集成
- [x] ConfirmSheet 集成
- [x] Widget 刷新触发
- [x] App Group 配置
- [x] 首次启动判断

---

**实现者**: Agent E
**日期**: 2026年3月18日
**版本**: v2.0
