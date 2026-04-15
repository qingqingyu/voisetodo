# VoiceTodo Xcode 项目配置清单

## 必需配置

### Targets
- [ ] VoiceTodo (iOS App)
- [ ] VoiceTodoTests (Unit Tests)
- [ ] VoiceTodoUITests (UI Tests)
- [ ] VoiceTodoWidget (Widget Extension)

### Capabilities
- [ ] App Groups (VoiceTodo): group.com.voicetodo.shared
- [ ] App Groups (VoiceTodoWidget): group.com.voicetodo.shared

### Build Settings
- [ ] iOS Deployment Target: 17.0
- [ ] Swift Language Version: 5
- [ ] Enable Testability: Yes (Debug)

### Frameworks
- [ ] SwiftData.framework
- [ ] Speech.framework
- [ ] AVFoundation.framework
- [ ] WidgetKit.framework (Widget only)
- [ ] SwiftData.framework (Widget only)

### File Target Memberships
- [ ] 主应用文件 → VoiceTodo
- [ ] 单元测试文件 → VoiceTodoTests
- [ ] UI 测试文件 → VoiceTodoUITests
- [ ] Widget 文件 → VoiceTodoWidget
- [ ] 共享协议文件 → VoiceTodo + VoiceTodoWidget + VoiceTodoTests

### Schemes
- [ ] VoiceTodo (包含测试)
- [ ] VoiceTodoWidget

## 可选配置

### Debug Settings
- [ ] Code Coverage: Enabled
- [ ] Thread Sanitizer: Enabled (Debug)
- [ ] Address Sanitizer: Enabled (Debug)

### CI/CD
- [ ] GitHub Actions 配置
- [ ] 自动化测试运行
- [ ] 代码覆盖率报告

## 验证步骤

1. [ ] 编译通过（无错误）
2. [ ] 运行单元测试
3. [ ] 运行 UI 测试
4. [ ] 测试 Widget 显示
5. [ ] 验证 App Group 数据共享

## 注意事项

⚠️ 确保 Widget Extension 的 Bundle ID 是主应用 Bundle ID 的子集
   例如: com.voicetodo.app.widget

⚠️ 所有 targets 使用相同的 App Group ID
   group.com.voicetodo.shared

⚠️ SwiftData ModelContainer 配置使用共享容器路径
