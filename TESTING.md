# VoiceTodo 测试文档

## 测试目录结构

```
VoiceTodo/
├── VoiceTodoTests/                    # 单元测试 target
│   ├── Protocols/                     # 协议和模型测试
│   │   └── ProtocolsTests.swift
│   ├── Voice/                         # 语音模块测试
│   │   └── VoiceInputTests.swift
│   ├── Extractor/                     # AI 提取模块测试
│   │   └── ExtractorTests.swift
│   ├── Store/                         # 数据层测试
│   │   └── StoreTests.swift
│   └── Integration/                   # 集成测试
│       └── IntegrationTests.swift
│
├── VoiceTodoUITests/                  # UI 测试 target
│   ├── MockSetup.swift                # Mock 数据和配置
│   ├── AppLaunchHelper.swift          # App 启动助手
│   ├── ScenarioTests.swift            # E2E 场景测试
│   └── WidgetSnapshotTests.swift      # Widget 快照测试
│
└── TestReport.md                      # 测试报告
```

## 测试类型

### 1. 单元测试 (Unit Tests)

**目的**: 验证每个模块内部逻辑正确性

**位置**: `VoiceTodoTests/`

**运行方式**:
```bash
# Swift Package Manager
swift test

# Xcode
xcodebuild test -scheme VoiceTodo -destination 'platform=iOS Simulator,name=iPhone 15 Pro'
```

**测试覆盖模块**:
- Protocols (6 tests)
- Voice (11 tests)
- Extractor (10 tests)
- Store (16 tests)

### 2. 集成测试 (Integration Tests)

**目的**: 验证模块之间的接口调用正确性

**位置**: `VoiceTodoTests/Integration/`

**测试场景**:
- Voice → Extractor pipeline
- Extractor → Store pipeline
- Store → Widget data access
- Offline fallback full path
- Pending recovery full path
- Error propagation
- Full workflow
- Concurrent writes

### 3. E2E 场景测试 (End-to-End Tests)

**目的**: 模拟用户完整操作流程

**位置**: `VoiceTodoUITests/`

**测试场景** (S01-S15):
- S01: 正常录入 → 提取多条 → 确认保存
- S02: 纯感受输入 → 空结果 Toast
- S03: 编辑提取结果后确认
- S04: 删除提取结果中的某条
- S05: 删除全部提取结果
- S06: 取消确认
- S07: 网络失败 → 离线降级保存
- S08: 网络恢复后批量补处理
- S09: HomeView 勾选完成
- S10: HomeView 左滑删除
- S11: HomeView 空状态
- S12: 首次启动引导流程
- S13: 权限被拒绝场景
- S14: 紧急单条待办
- S15: Widget 显示验证

### 4. Widget 测试

**目的**: 验证 Widget 在不同尺寸和状态下的渲染

**位置**: `VoiceTodoUITests/WidgetSnapshotTests.swift`

**测试内容**:
- Medium Widget (3 条待办)
- Small Widget (1 条待办)
- Large Widget (6 条待办)
- 空状态显示
- 优先级标记
- 分类 emoji
- 排序逻辑

## Mock 数据配置

### MockScenarios

在 `MockSetup.swift` 中定义了预配置的测试场景:

```swift
// 正常多条待办
MockScenarios.multiTodo

// 纯感受（无待办）
MockScenarios.noTodo

// 紧急单条
MockScenarios.urgentSingle

// 网络错误
MockScenarios.networkError
```

### App 启动参数

```swift
// UI 测试模式
--ui-testing

// 跳过引导
--skip-onboarding

// 网络断开
--network-off

// 麦克风权限被拒绝
--mic-permission-denied

// 预置待办数据
--preset-todos
--todos-data=<json>

// 重置用户数据
--reset-user-data
```

## Accessibility Identifiers

为了可靠的 UI 测试，所有 UI 元素都应该设置 accessibility identifier:

```swift
// 录音按钮
"RecordButton"

// 确认弹窗
"ConfirmSheet"

// 待办列表
"TodoList"

// 确认添加按钮
"ConfirmAddButton"

// 待办单元格
"TodoCell_\(index)"

// 删除按钮
"DeleteTodo_\(index)"

// 待办标题文本框
"TodoTitle_\(index)"
```

## 测试最佳实践

### 1. 测试独立性
- 每个测试应该独立运行
- 不依赖执行顺序
- 在 `setUp` 中初始化，在 `tearDown` 中清理

### 2. 命名规范
```swift
// 单元测试
test_<methodName>_<scenario>()

// 集成测试
test_<module>To<Module>_<scenario>()

// E2E 测试
test_S<number>_<scenarioDescription>()
```

### 3. Mock 使用
- 使用 Mock 对象隔离外部依赖
- 不依赖真实网络或麦克风
- 使用内存数据库

### 4. 断言清晰
```swift
// 好的断言
XCTAssertEqual(todos.count, 3, "应该有 3 条待办")

// 避免模糊的断言
XCTAssertTrue(todos.count > 0)  // 不够具体
```

### 5. 异步测试
```swift
let expectation = XCTestExpectation(description: "Description")

Task {
    // 异步操作
    expectation.fulfill()
}

wait(for: [expectation], timeout: 5.0)
```

## CI/CD 集成

### GitHub Actions 示例

```yaml
name: Tests

on: [push, pull_request]

jobs:
  test:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v2
      - name: Run tests
        run: |
          xcodebuild test \
            -scheme VoiceTodo \
            -destination 'platform=iOS Simulator,name=iPhone 15 Pro' \
            -enableCodeCoverage YES
```

## 测试覆盖率目标

- **单元测试**: 80%+
- **集成测试**: 关键路径 100%
- **E2E 测试**: 所有用户场景 100%

## 常见问题

### Q: 为什么无法运行测试？
A: 检查是否有编译错误。当前存在 ServiceContainer.swift 的编译错误需要先修复。

### Q: 如何在真机上运行 UI 测试？
A:
```bash
xcodebuild test \
  -scheme VoiceTodo \
  -destination 'platform=iOS,name=Your iPhone'
```

### Q: 如何只运行特定测试？
A:
```bash
# Xcode
xcodebuild test \
  -scheme VoiceTodo \
  -only-testing:VoiceTodoTests/IntegrationTests/test_voiceToExtractor_pipeline

# Swift PM
swift test --filter IntegrationTests.test_voiceToExtractor_pipeline
```

### Q: 如何生成测试覆盖率报告？
A:
```bash
xcodebuild test \
  -scheme VoiceTodo \
  -enableCodeCoverage YES \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro'

# 使用 slather 生成报告
gem install slather
slather coverage VoiceTodo.xcodeproj
```

## 相关文档

- [测试策略文档](../voicetodo-test-strategy.docx)
- [测试报告](./TestReport.md)
- [Agent Prompts v2](../voicetodo-agent-prompts-v2.md)
- [产品需求文档](../VoiceTodo.md)

---

**最后更新**: 2026年3月18日
**维护者**: Agent F (测试 Agent)
