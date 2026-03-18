# VoiceTodo iOS 项目架构

## 项目概述

这是 VoiceTodo iOS App 的架构基础，由 Agent 0 (架构师) 创建。包含所有协议定义、数据模型和模块接口。

## 目录结构

```
VoiceTodo/
├── Protocols/              ← 所有 Agent 只读，接口定义
│   ├── VoiceInputProtocol.swift
│   ├── TodoExtractorProtocol.swift
│   ├── TodoStoreProtocol.swift
│   ├── Models.swift            ← 共享数据模型（含 TodoItemData）
│   ├── VoiceTodoError.swift    ← 统一错误类型
│   ├── ErrorMessages.swift     ← 用户可见的错误提示文案
│   ├── Constants.swift         ← 配置常量
│   └── CodingConventions.md    ← 编码规范文档
├── Voice/                  ← Agent A 负责
│   ├── VoiceInputManager.swift
│   └── AudioSessionHelper.swift
├── Extractor/              ← Agent B 负责
│   ├── TodoExtractorService.swift
│   ├── PromptTemplates.swift
│   └── NetworkClient.swift
├── Store/                  ← Agent C 负责
│   ├── SwiftDataModels.swift
│   ├── TodoStore.swift
│   └── AppGroupConfig.swift
├── UI/                     ← Agent D 负责
│   ├── ConfirmSheet/
│   │   ├── ConfirmSheetView.swift
│   │   └── TodoItemRow.swift
│   ├── Home/
│   │   └── HomeView.swift
│   ├── Shared/
│   │   ├── EmptyStateView.swift
│   │   └── ToastView.swift
│   └── Widget/
│       ├── TodoWidgetBundle.swift
│       ├── TodoWidgetProvider.swift
│       └── TodoWidgetView.swift
├── App/                    ← Agent E 负责
│   ├── VoiceTodoApp.swift
│   ├── AppCoordinator.swift
│   ├── OnboardingView.swift
│   └── PermissionManager.swift
├── VoiceTodoTests/         ← 单元测试
│   ├── Voice/
│   ├── Extractor/
│   ├── Store/
│   └── Protocols/
└── Package.swift           ← Swift Package 配置（用于验证编译）
```

## 创建 Xcode 项目

当前目录包含所有源文件，但需要使用 Xcode 创建完整的项目配置：

### 步骤 1: 创建 Xcode 项目

1. 打开 Xcode → File → New → Project
2. 选择 iOS → App
3. 配置：
   - Product Name: `VoiceTodo`
   - Team: 你的开发者账号
   - Organization Identifier: `com.voicetodo`
   - Interface: SwiftUI
   - Storage: SwiftData
   - Language: Swift
   - Minimum Deployments: iOS 17.0

4. 保存到当前目录的父目录（与 VoiceTodo 文件夹同级）

### 步骤 2: 添加 Widget Extension

1. File → New → Target
2. 选择 Widget Extension
3. 配置：
   - Product Name: `VoiceTodoWidget`
   - Include Configuration Intent: 否
   - Include Live Activity: 是

### 步骤 3: 配置 App Group

1. 选择主 App target → Signing & Capabilities
2. 点击 + Capability → App Groups
3. 添加: `group.com.voicetodo.shared`
4. 对 Widget Extension target 重复此操作

### 步骤 4: 添加源文件

将当前目录下的所有源文件添加到 Xcode 项目中：
- Protocols/ → 添加到主 App target
- Voice/ → 添加到主 App target
- Extractor/ → 添加到主 App target
- Store/ → 添加到主 App target
- UI/ → 添加到主 App target（Widget 文件同时添加到 Widget target）
- App/ → 添加到主 App target
- VoiceTodoTests/ → 添加到测试 target

## 验收标准

- [x] 所有 Protocol 文件存在且编译通过
- [x] Models.swift 中的类型可正常实例化
- [x] VoiceTodoError 的所有 case 都有对应的 ErrorMessages
- [x] Constants.swift 中的常量已定义
- [x] CodingConventions.md 存在且内容完整
- [x] VoiceTodoTests target 存在且可运行
- [x] 所有测试通过 (7 tests, 0 failures)

## Agent 职责分配

| Agent | 负责模块 | 主要文件 |
|-------|---------|---------|
| A | Voice | VoiceInputManager, AudioSessionHelper |
| B | Extractor | TodoExtractorService, PromptTemplates, NetworkClient |
| C | Store | SwiftDataModels, TodoStore, AppGroupConfig |
| D | UI | ConfirmSheet, HomeView, Widget |
| E | App | VoiceTodoApp, AppCoordinator, OnboardingView, PermissionManager |

## 编码规范

详见 [Protocols/CodingConventions.md](Protocols/CodingConventions.md)

---

*Created by Agent 0 (Architect) on 2026-03-18*
