# VoiceTodo 编码规范

## 命名
- 遵循 Swift API Design Guidelines
- 使用驼峰命名（camelCase）
- 文件名与主类型名一致（TodoStore.swift 包含 class TodoStore）

## 文档注释
- 公开方法必须有 `///` 文档注释
- 注释应说明「做什么」而非「怎么做」

## 常量管理
- 常量使用 enum 作为 namespace
- 示例：`enum VoiceConstants { static let threshold: Float = -40.0 }`
- 配置常量统一放在 Protocols/Constants.swift

## 错误处理
- 统一抛出 VoiceTodoError，不使用自定义错误类型
- 用户提示统一使用 ErrorMessages 常量，不硬编码字符串

## 异步编程
- 优先使用 async/await
- 避免回调地狱

## 访问控制
- 默认 internal
- 只对必要的接口用 public

## 模块依赖
- 第 2 阶段的 Agent（A/B/C/D）不能直接 import 彼此的具体实现
- 只能依赖 Protocols/ 目录定义的 Protocol 和 Models
