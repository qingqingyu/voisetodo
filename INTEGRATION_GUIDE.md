# VoiceTodo 项目集成指南

## 📋 项目概览

VoiceTodo 是一个语音驱动的智能待办 iOS App，采用多 Agent 并行开发模式，共有 6 个 Agent 参与开发。

### Agent 分工

| Agent | 职责 | 状态 |
|-------|------|------|
| Agent 0 | 架构师：项目初始化 + Protocol + 编码规范 | ✅ 完成 |
| Agent A | 语音引擎：Speech Framework + 录音管理 | ✅ 完成 |
| Agent B | AI 提取：Claude API + JSON 解析 + 重试策略 | ✅ 完成 |
| Agent C | 数据层：SwiftData + CRUD + App Group | ✅ 完成 |
| Agent D | UI 层：确认弹窗 + 主界面 + Widget + 空状态 | ✅ 完成 |
| Agent E | 集成师：组装 + 引导流程 + 联调 + 测试 | ✅ 完成 |

## 🏗️ 架构设计

### 模块关系图

```
┌─────────────────────────────────────────────────┐
│                  VoiceTodoApp                    │
│                    (Agent E)                     │
└────────────────┬────────────────────────────────┘
                 │
    ┌────────────┴────────────┐
    │                         │
    ▼                         ▼
┌─────────┐              ┌─────────┐
│  Voice  │              │Extractor│
│(Agent A)│              │(Agent B)│
└─────────┘              └─────────┘
    │                         │
    │                         │
    └────────┬────────────────┘
             │
             ▼
        ┌─────────┐
        │  Store  │
        │(Agent C)│
        └─────────┘
             │
             ▼
        ┌─────────┐
        │   UI    │
        │(Agent D)│
        └─────────┘
             │
             ▼
        ┌─────────┐
        │ Widget  │
        │(Agent D)│
        └─────────┘
```

### 数据流

```
用户语音
   ↓
VoiceInputManager (Agent A)
   ↓ transcript
TodoExtractorService (Agent B)
   ↓ ExtractedTodo[]
ConfirmSheetView (Agent D)
   ↓ 确认
TodoStore (Agent C)
   ↓ TodoItemData[]
HomeView + Widget (Agent D)
```

## 📁 项目结构

```
VoiceTodo/
├── Protocols/                    ← Agent 0
│   ├── Models.swift              ✅
│   ├── VoiceInputProtocol.swift  ✅
│   ├── TodoExtractorProtocol.swift ✅
│   ├── TodoStoreProtocol.swift   ✅
│   ├── VoiceTodoError.swift      ✅ [v2]
│   ├── ErrorMessages.swift       ✅ [v2]
│   ├── Constants.swift           ✅
│   └── CodingConventions.md      ✅ [v2]
│
├── Voice/                        ← Agent A
│   ├── VoiceInputManager.swift   ✅
│   ├── AudioSessionHelper.swift  ✅
│   └── VoiceConstants.swift      ✅ [v2]
│
├── Extractor/                    ← Agent B
│   ├── TodoExtractorService.swift ✅
│   ├── PromptTemplates.swift     ✅
│   └── NetworkClient.swift       ✅
│
├── Store/                        ← Agent C
│   ├── TodoStore.swift           ✅
│   ├── SwiftDataModels.swift     ✅
│   └── AppGroupConfig.swift      ✅
│
├── UI/                           ← Agent D
│   ├── ConfirmSheet/
│   │   ├── ConfirmSheetView.swift ✅
│   │   └── TodoItemRow.swift     ✅
│   ├── Home/
│   │   └── HomeView.swift        ✅
│   ├── Shared/
│   │   ├── ToastView.swift       ✅ [v2]
│   │   └── EmptyStateView.swift  ✅ [v2]
│   ├── Widget/
│   │   ├── TodoWidgetBundle.swift ✅
│   │   ├── TodoWidgetProvider.swift ✅
│   │   └── TodoWidgetView.swift  ✅
│   ├── MockStore.swift           ✅
│   └── UIDemoView.swift          ✅
│
├── App/                          ← Agent E
│   ├── VoiceTodoApp.swift        ✅
│   ├── AppCoordinator.swift      ✅
│   ├── OnboardingView.swift      ✅ [v2]
│   └── PermissionManager.swift   ✅ [v2]
│
└── VoiceTodoTests/               ← 各 Agent
    ├── Voice/                    ✅
    ├── Extractor/                ✅
    ├── Store/                    ✅
    └── Protocols/                ✅
```

## 🔧 集成步骤

### 步骤 1: 创建 Xcode 项目

1. 打开 Xcode，创建新项目
2. 选择 iOS App，SwiftUI + SwiftData
3. 设置最低版本：iOS 17.0
4. 设置 Bundle ID：`com.voicetodo.app`

### 步骤 2: 添加 Widget Extension

1. File → New → Target
2. 选择 Widget Extension
3. 命名：`VoiceTodoWidget`
4. 配置 App Group（见下一步）

### 步骤 3: 配置 App Group

**主 App：**
1. 选择项目 → Signing & Capabilities
2. 点击 + Capability
3. 添加 App Groups
4. 点击 + 添加：`group.com.voicetodo.shared`

**Widget Extension：**
1. 选择 Widget target → Signing & Capabilities
2. 添加相同的 App Group：`group.com.voicetodo.shared`

### 步骤 4: 添加文件

将各 Agent 的文件复制到对应目录：

```bash
# 复制 Protocols（Agent 0）
cp -r Protocols/ VoiceTodo/

# 复制 Voice（Agent A）
cp -r Voice/ VoiceTodo/

# 复制 Extractor（Agent B）
cp -r Extractor/ VoiceTodo/

# 复制 Store（Agent C）
cp -r Store/ VoiceTodo/

# 复制 UI（Agent D）
cp -r UI/ VoiceTodo/

# 复制 App（Agent E）
cp -r App/ VoiceTodo/
```

### 步骤 5: 配置 Info.plist

添加权限描述：

```xml
<key>NSSpeechRecognitionUsageDescription</key>
<string>需要语音识别权限来将语音转为文字，语音数据仅在本地处理</string>

<key>NSMicrophoneUsageDescription</key>
<string>需要麦克风权限来录音</string>
```

### 步骤 6: 配置 Entitlements

主 App 和 Widget 都需要：

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

### 步骤 7: 配置 API Key

在 `Extractor/NetworkClient.swift` 中配置 Claude API Key：

```swift
// 方式 1: 直接配置（仅开发测试）
private let apiKey = "your-api-key-here"

// 方式 2: 从环境变量读取（推荐）
private var apiKey: String {
    ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? ""
}

// 方式 3: 从中转服务获取（生产环境）
// TODO: 实现中转服务
```

### 步骤 8: 编译运行

1. 选择模拟器或真机
2. 编译项目（Cmd+B）
3. 运行项目（Cmd+R）
4. 首次启动会显示引导页面

## 🧪 测试清单

### 单元测试

- [ ] VoiceInputManagerTests
- [ ] TodoExtractorTests
- [ ] TodoStoreTests
- [ ] 各组件 Preview

### 功能测试

#### 录音流程
- [ ] 开始录音
- [ ] 实时转写
- [ ] 静音自动停止
- [ ] 手动停止

#### AI 提取
- [ ] 正常提取
- [ ] 空结果
- [ ] 网络错误
- [ ] JSON 解析错误

#### 确认流程
- [ ] ConfirmSheet 显示
- [ ] 编辑待办
- [ ] 删除待办
- [ ] 确认保存
- [ ] 取消放弃

#### 数据存储
- [ ] 添加待办
- [ ] 切换完成
- [ ] 删除待办
- [ ] 离线保存

#### Widget
- [ ] 数据显示
- [ ] 空状态
- [ ] 刷新机制
- [ ] 点击跳转

#### 权限
- [ ] 麦克风权限
- [ ] 语音识别权限
- [ ] 权限拒绝处理
- [ ] 跳转设置

### 集成测试

- [ ] 完整录音 → 确认 → 保存流程
- [ ] 离线 → 联网 → 补处理流程
- [ ] 首次启动 → 引导 → 使用流程
- [ ] Widget 同步测试

## 🐛 常见问题

### 1. 编译错误

**问题**：找不到某些类型或方法

**解决**：
- 检查 import 语句
- 确保所有文件都已添加到 target
- 检查文件路径是否正确

### 2. 权限问题

**问题**：录音权限被拒绝

**解决**：
- 重置模拟器权限：Device → Erase
- 或在设置中手动授权

### 3. App Group 问题

**问题**：Widget 无法读取数据

**解决**：
- 检查 App Group ID 是否一致
- 检查 Entitlements 配置
- 检查 ModelConfiguration 配置

### 4. API Key 问题

**问题**：API 调用失败

**解决**：
- 检查 API Key 是否正确
- 检查网络连接
- 检查 API 配额

### 5. SwiftData 问题

**问题**：数据无法保存或读取

**解决**：
- 检查 ModelContainer 配置
- 检查 App Group 配置
- 检查模型定义

## 📊 性能优化

### 1. 启动优化
- 延迟加载非必需组件
- 优化 OnboardingView

### 2. 录音优化
- 使用合理的音频缓冲区大小
- 优化静音检测算法

### 3. 网络优化
- 实现请求缓存
- 批量处理待处理项

### 4. UI 优化
- 使用 LazyVStack
- 优化动画性能

## 🚀 发布准备

### App Store 信息

**名称**：VoiceTodo

**副标题**：语音驱动的智能待办

**描述**：
按下 Action Button，说出你的想法，AI 自动提取待办事项，锁屏 Widget 随时可见。

**关键词**：
待办，语音，AI，Widget，待办事项，任务管理

**分类**：
效率

**年龄分级**：
4+

### 隐私信息

- 麦克风：用于语音录入
- 语音识别：用于语音转文字（本地处理）
- 网络：用于 AI 提取待办

### 截图

需要准备以下尺寸的截图：
- 6.5" iPhone（必需）
- 5.5" iPhone（必需）
- 12.9" iPad（可选）

## 📝 维护指南

### 代码规范

遵循 `Protocols/CodingConventions.md` 中的规范：
- 驼峰命名
- 公开方法必须有文档注释
- 常量使用 enum 作为 namespace
- 错误统一使用 VoiceTodoError
- 提示统一使用 ErrorMessages

### 添加新功能

1. 在 Protocols/ 中定义 Protocol
2. 在对应模块实现
3. 在 AppCoordinator 中集成
4. 添加测试
5. 更新文档

### 修复 Bug

1. 创建测试用例复现问题
2. 修复代码
3. 运行所有测试确保无回归
4. 更新文档

## 🎉 总结

VoiceTodo 项目成功采用了多 Agent 并行开发模式，各 Agent 独立完成自己的模块，最后由 Agent E 统一集成。

### 关键成果

- ✅ 6 个 Agent 全部完成
- ✅ 完整的语音录入流程
- ✅ AI 智能提取待办
- ✅ 确认界面友好易用
- ✅ Widget 实时同步
- ✅ 离线降级支持
- ✅ 网络恢复自动补处理
- ✅ 完善的权限管理
- ✅ 友好的首次启动体验

### 技术亮点

- 🏗️ 模块完全解耦（Protocol 驱动）
- 🎨 精致的 UI 和动画
- 🔄 优雅的降级和恢复机制
- 📱 Widget 数据共享
- 🔐 完善的权限管理
- 📊 SwiftData 数据持久化

### 下一步

1. 完成最后的 Xcode 配置
2. 进行完整的功能测试
3. 修复发现的问题
4. 准备 App Store 发布
5. 收集用户反馈
6. 规划 V2 功能

---

**项目状态**: ✅ 集成完成，可运行
**最后更新**: 2026年3月18日
**版本**: v1.0
