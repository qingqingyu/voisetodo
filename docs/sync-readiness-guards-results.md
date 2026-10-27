# 结果:`docs/sync-readiness-guards-task.md` 执行回执

> 分支 `claude/sync-readiness-guards`,基于 `main` @ `9ff7e31`(与任务书对照基线一致)。
> 执行环境:macOS(Darwin 25.5.5),Xcode 生成项目后模拟器编译/测试。

## 1. 改动摘要

| 文件 | 改动 |
|---|---|
| `docs/swiftdata-schema-v1-baseline.md` | 「守护机制」表格在「新增 `#Index`」后补「新增实体」一行;在「第一次需要非轻量迁移时(V2 流程)」前新增「给将来的同步留路」一节(三条规则,按任务书原文) |
| `App/VoiceTodoApp.swift` | 4 处 `ModelConfiguration` 全部显式加 `cloudKitDatabase: .none`(启动报错内存库 / App Group 共享库 / 本地库 / 打开失败回退库);建库注释块加一行原因注释 |
| `Store/AppGroupModelContainerProvider.swift` | `makeContainer` 的 `ModelConfiguration` 加 `cloudKitDatabase: .none`(`readOnly()` / `writable()` 共用这一处);配置上方加一行原因注释 |

未动:两个 entitlements、`project.yml`、`Package.swift`、`ReviewView.swift` 的 3 处 `#Preview` 配置、
`App/README.md` / `App/IMPLEMENTATION_SUMMARY.md` 示例代码、所有 `@Model` 定义与冻结测试快照。

## 2. 代码检查(§4.1)

- `grep -rn "ModelConfiguration(" App Store` 命中 7 处,其中正式代码 5 处全部带 `cloudKitDatabase: .none`
  (`App/VoiceTodoApp.swift` 4 处 + `Store/AppGroupModelContainerProvider.swift` 1 处);
  其余 2 处为文档示例代码,任务书明确不改。
- `git diff --stat` 仅涉及 `App/VoiceTodoApp.swift`、`Store/AppGroupModelContainerProvider.swift`、
  `docs/swiftdata-schema-v1-baseline.md` 与本结果文档。

## 3. 编译和单元测试(§4.2)

- `xcodebuild build -scheme VoiceTodo`(iPhone 17 Pro 模拟器):**BUILD SUCCEEDED**,
  `VoiceTodo.app` 与 `VoiceTodoWidget.appex` 均产出并嵌入。警告 4 条,全部位于
  `UI/Home/HomeMonthGridButton.swift` / `UI/Home/HomeView.swift` 既有代码,与本次改动文件无关,无新增警告。
- macOS 单元测试 `arch -arm64 swift test`:**349 个测试,348 通过,1 失败**。
  唯一失败为 `TodoDueDateShifterTests.testDSTSpringForward_fallsBackToMidnight`——
  CLAUDE.md 记载的已知基线失败(依赖 US DST 时区,CN 时区 Mac 必红),与本次改动无关。
- 冻结测试 `testSchemaMatchesFrozenV1Baseline`(`VoiceTodoTests/Store/StoreTests.swift:51`)不在
  Package.swift 测试 target 覆盖内,已在 iPhone 17 Pro 模拟器上单独运行:
  `StoreTests` 套件 **70/70 通过(TEST SUCCEEDED)**;冻结测试单独复跑亦 passed,
  快照未动、原样通过。

## 4. 真机覆盖安装(§4.3)——待执行

真机验证无法由执行方完成,以下清单留待真机操作时逐项勾选:

| 检查项 | 结果 |
|---|---|
| 前置:改动前构建(≥5 条待办,含 1 条重复待办勾掉某次;1 条已写系统日历;主屏放小组件) | ☐ |
| 不删 App 覆盖安装后,待办全部还在,重复待办勾选状态保留 | ☐ |
| 无「存储不可用」提示 | ☐ |
| 小组件正常显示,点勾选生效 | ☐ |
| Siri / 快捷指令新建待办成功(App Group 可写容器) | ☐ |
| 控制台出现 `app.storage.container_created shared=true`,无 `app.storage.primary_container_failed` | ☐ |
| 杀掉 App 冷启动后重复以上各项 | ☐ |

机型 / iOS 版本 / 改动前构建来源:__________

## 5. 偏离任务书的地方

1. 任务书 §4.2 要求报告 `VoiceTodoTests` 通过数。`swift test` 只覆盖协议层 target
   (`VoiceTodoTests/Protocols`,349 个);含冻结测试的 `VoiceTodoTests/Store` 等目录不在
   Package.swift 内,故在模拟器上单独补跑 StoreTests 套件(见 §3),未跑完整 Xcode 测试 target。
   其余无偏离。
