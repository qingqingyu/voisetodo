# ServiceContainer 编译错误修复摘要

> **历史记录（2026-03-18 时点）**：本文档记录当时 ServiceContainer 编译错误的修复过程。**ServiceContainer / @Injected 此后已被整体移除**（改为纯构造注入），故文中提到的 `Protocols/ServiceContainer.swift`、`App/ServiceContainer+VoiceTodo.swift` 均已不存在。本文保留作历史档案。

## 问题描述

`ServiceContainer.swift` 位于 `Protocols` SPM 包中，但其 `registerVoiceTodoServices` 方法引用了不在该包中的具体实现类，导致编译错误。

## 具体错误

```
error: cannot find 'VoiceInputManager' in scope
error: cannot find 'TodoExtractorService' in scope
error: cannot find 'TodoStore' in scope
error: use of protocol 'VoiceInputProtocol' as a type must be written 'any VoiceInputProtocol'
warning: main actor-isolated static property 'shared' can not be referenced from a nonisolated context
```

## 修复方案

### 1. 移除 Protocols 包中的具体实现引用

**文件**: `Protocols/ServiceContainer.swift`

**修改**: 移除 `registerVoiceTodoServices` extension，只保留注释说明

```swift
// MARK: - VoiceTodo Service Registration
// 注意：registerVoiceTodoServices 方法已移到主应用代码中
// 原因：该方法引用了具体实现类，而这些类不在 Protocols 包中
// 请参考 App/ServiceContainer+VoiceTodo.swift
```

### 2. 在主应用中创建服务注册

**新建文件**: `App/ServiceContainer+VoiceTodo.swift`

**内容**:
```swift
import Foundation
import SwiftData

/// ServiceContainer 的 VoiceTodo 扩展
/// 提供具体服务的注册方法
extension ServiceContainer {
    /// 注册 VoiceTodo 的所有服务
    /// - Parameter modelContext: SwiftData ModelContext
    @MainActor
    func registerVoiceTodoServices(modelContext: ModelContext) {
        // 注册 VoiceInputProtocol
        register(VoiceInputProtocol.self, service: VoiceInputManager())

        // 注册 TodoExtractorProtocol
        register(TodoExtractorProtocol.self, service: TodoExtractorService())

        // 注册 TodoStoreProtocol
        register(TodoStoreProtocol.self, service: TodoStore(modelContext: modelContext))

        // 注册 NetworkMonitor
        register(NetworkMonitor.self, service: NetworkMonitor.shared)
    }
}
```

### 3. 添加 @MainActor 注解

为 `registerVoiceTodoServices` 方法添加 `@MainActor` 注解，解决 MainActor 隔离警告。

## 修复结果

✅ **编译成功**: 无编译错误
✅ **警告消除**: 无编译警告
✅ **测试通过**: Protocols 包所有测试通过 (7/7)

## 测试验证

```bash
$ swift build
Building for debugging...
Build complete! (1.76s)

$ swift test
Test Suite 'All tests' passed at 2026-03-18 17:25:00.030.
Executed 7 tests, with 0 failures (0 unexpected) in 0.008 (0.009) seconds
```

## 架构改进

### 修复前
```
Protocols/ServiceContainer.swift
└── registerVoiceTodoServices()  ❌ 引用具体实现类
```

### 修复后
```
Protocols/ServiceContainer.swift
└── 通用服务容器（无具体实现）

App/ServiceContainer+VoiceTodo.swift
└── registerVoiceTodoServices()  ✅ 引用具体实现类
```

## 优势

1. **关注点分离**: Protocols 包保持纯净，只包含协议和共享类型
2. **依赖方向正确**: 主应用依赖 Protocols，而非反向
3. **更好的模块化**: 具体服务注册逻辑与具体实现放在一起
4. **可测试性**: Protocols 包可以独立编译和测试

## 影响范围

- ✅ Protocols 包可以独立编译
- ✅ 主应用可以正常注册服务
- ✅ 所有单元测试可以运行
- ✅ 依赖注入机制保持不变

---

**修复时间**: 2026年3月18日
**修复者**: Claude Code (Agent F 协助)
