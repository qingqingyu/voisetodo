# 任务书：给将来的同步留路——两处不改变行为的小改动

> 2026-10-27 起草，代码对照基线 `main` @ `9ff7e31`。本文档是**交给执行者的任务书**。
> 两处改动都**不改变 App 现有行为**：不改数据模型、不改权限、不触发数据迁移。
> 完成后把结果写进 `docs/sync-readiness-guards-results.md`（格式见 §5），交回审查。

---

## 0. 背景

将来可能做 iCloud 同步或共享。现在的 4 个数据模型都带唯一约束（`@Attribute(.unique)`），很多必填字段没有默认值，
SwiftData 自带的 iCloud 同步不接受这种结构。本次**不改已有模型**，只做两件事：

1. **改动 A**：把「新增模型 / 字段时怎么写，才不给将来的同步添堵」写进数据库基线文档
   `docs/swiftdata-schema-v1-baseline.md`。改数据库结构的人一定会读到它：冻结测试
   `testSchemaMatchesFrozenV1Baseline` 失败时，提示信息直接指向这份文档。
2. **改动 B**：在所有创建数据库的配置里显式写上「不开 iCloud 同步」（`cloudKitDatabase: .none`）。
   现在的默认值是 `.automatic`：哪天有人在 Xcode 里勾上 iCloud 能力，SwiftData 会自动尝试同步，
   因结构不兼容而建库失败，App 退到内存库，用户看到的就是「数据全没了」。写死之后，开同步必须是有意识的改动。

---

## 1. 改动 A：`docs/swiftdata-schema-v1-baseline.md`

### 1.1 表格补一行

「守护机制」一节的表格里，在 `新增 #Index` 那一行**之后**加一行：

| 改动 | 轻量迁移能否覆盖 | 动作 |
|---|---|---|
| 新增实体（新的 `@Model` 类型） | ✅ | 在 `VoiceTodoSchema.schema` 注册；更新测试快照（实体集合 + 字段）；真机验证升级 |

### 1.2 新增一节「给将来的同步留路」

放在「第一次需要非轻量迁移时(V2 流程)」那一节**之前**。按下面的内容写（措辞可以润色，意思不要改）：

```markdown
## 给将来的同步留路(新增模型 / 字段时遵守)

已有 4 个模型**保持不动**:不要顺手去掉它们的 `@Attribute(.unique)`,那属于将来开同步时的 V2 工作。
下面只约束以后**新加**的东西。

1. **新的 `@Model` 类型**
   - 不加 `@Attribute(.unique)`;
   - 每个存储字段要么 Optional,要么在声明处给默认值(如 `var count: Int = 0`);
   - 不用 SwiftData 关系,跨实体引用用 UUID 字段(与现有模型一致,冻结测试也断言了无关系);
   - 写入前按 id 先查重,沿用 `TodoStore` 的 `existingTodoItem(by:)` 写法——没有唯一约束兜底,忘了查会出重复数据。

   原因:SwiftData 自带的 iCloud 同步不接受唯一约束,也不接受没有默认值的必填字段。
   新模型现在就按这个写,将来开同步时要迁移的范围不会变大。

2. **只在本机有效的标识,不写进待办这类将来可能同步的模型**
   例如 EventKit 的事件 ID、本地通知 ID。需要持久化时单独存(例如 App Group UserDefaults 里按待办 id 建映射)。
   已有的 `systemCalendarEventIdentifier` / `parentCalendarEventIdentifier` 不动。

   原因:数据同步到另一台设备后,那台设备会拿着这台设备的 ID 去改、删日历事件,对不上。

3. **iCloud 同步是有意识的开关**
   所有创建 `ModelContainer` 的配置都显式写了 `cloudKitDatabase: .none`。将来要开同步,必须先完成 V2 结构迁移
   (去掉唯一约束、补默认值),再改这几处;不要只在 Xcode 里勾上 iCloud 能力。
```

---

## 2. 改动 B：显式关闭 iCloud 同步

所有**正式代码**里的 `ModelConfiguration(...)` 都加上 `cloudKitDatabase: .none`，共 5 处：

| 文件 | 约在第几行 | 这处配置的用途 |
|---|---|---|
| `App/VoiceTodoApp.swift` | 89 | 共享容器缺失时的内存库（启动报错状态） |
| `App/VoiceTodoApp.swift` | 107 | 正常启动：App Group 共享库 |
| `App/VoiceTodoApp.swift` | 114 | 没有共享容器或 UI 测试时的本地库 |
| `App/VoiceTodoApp.swift` | 134 | 主库打开失败后的回退库 |
| `Store/AppGroupModelContainerProvider.swift` | 42 | 小组件和 Siri 共用（`readOnly()` / `writable()` 都经过这里） |

注意：

- `cloudKitDatabase:` 是 `ModelConfiguration` 初始化器的**最后一个参数**，要放在 `groupContainer:` 之后；
  没有 `groupContainer:` 的，放在现有最后一个参数之后。顺序错了编译不过。
- 每个文件加**一行**注释说明原因即可，不用每处都写。参考：
  `// 显式关闭 iCloud 同步:现有 schema 含 .unique 等 CloudKit 不支持的约束,开同步前须先走 V2 迁移(见 docs/swiftdata-schema-v1-baseline.md)`
- **不改**：`UI/Review/ReviewView.swift` 里 3 处 `#Preview` 的配置；`App/README.md`、`App/IMPLEMENTATION_SUMMARY.md` 里的示例代码；测试代码。

为什么行为不变（帮助理解，不用写进代码）：

- `.automatic` 只有在权限文件里配了 iCloud（CloudKit）容器时才会去同步。现在 `VoiceTodo/VoiceTodo.entitlements`
  和 `VoiceTodoWidget/VoiceTodoWidget.entitlements` 都只有 App Group，所以现在 `.automatic` 就等于 `.none`。
- 这个选项不影响数据库文件的位置，也不触发迁移（迁移只看模型结构）。

---

## 3. 明确不做

- 不改任何 `@Model` 的字段、`@Attribute`、`#Index`；**不去掉已有的 `.unique`**。
- 不改冻结测试 `testSchemaMatchesFrozenV1Baseline` 的快照：这次结构没变，它必须原样通过。
- 不改 entitlements、`project.yml`、`Package.swift`。
- 不加 iCloud 能力，不写任何同步代码。
- 不改 `Protocols/CodingConventions.md`：规则集中写在基线文档，改结构的人会被冻结测试引到那里。

---

## 4. 验收

### 4.1 代码检查

- `grep -rn "ModelConfiguration(" App Store` 列出的每一处都带 `cloudKitDatabase: .none`。
- `git diff --stat` 只涉及 `App/VoiceTodoApp.swift`、`Store/AppGroupModelContainerProvider.swift`、
  `docs/swiftdata-schema-v1-baseline.md` 和结果文档。

### 4.2 编译和单元测试（Xcode）

- App 和小组件两个 target 都编译通过，没有新增警告。
- `VoiceTodoTests` 全部通过，`testSchemaMatchesFrozenV1Baseline` 原样通过。报告通过数。

### 4.3 真机覆盖安装（最重要）

1. 先在真机上装**改动前**的 main 构建（或当前 TestFlight 包），准备数据：
   - 至少 5 条待办，其中 1 条是重复待办，并勾掉其中某一次；
   - 如果开了日历同步，至少 1 条待办已写进系统日历；
   - 主屏幕放一个小组件。
2. **不删 App**，直接用改动后的构建覆盖安装。
3. 逐项确认：
   - 打开 App，待办全部还在，重复待办那一次的勾选状态也在；
   - 没有出现「存储不可用」之类的提示；
   - 小组件正常显示，在小组件上点勾选能生效；
   - 用 Siri 或快捷指令新建一条待办成功（走 App Group 的可写容器）；
   - Xcode 控制台里有 `app.storage.container_created shared=true`，没有 `app.storage.primary_container_failed`。
4. 杀掉 App 再冷启动一次，重复第 3 步。

---

## 5. 结果格式（`docs/sync-readiness-guards-results.md`）

1. 改动摘要：改了哪些文件，每处一句话。
2. 编译和单元测试结果，附通过数。
3. §4.3 真机覆盖安装的逐项结果，写明机型、iOS 版本、改动前的构建从哪来。
4. 偏离任务书的地方及理由（没有就写「无」）。

---

## 6. 执行约束

- 从最新 `main` 拉新分支（名字自定），**不要直接在 main 上改**；提交、推送分支后交回审查，**不合 main**。
- 提交信息里不要出现模型名称。
