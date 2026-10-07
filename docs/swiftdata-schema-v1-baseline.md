# SwiftData Schema V1 基线(1.0 发版冻结)

1.0 一旦上架,`VoiceTodoSchema.schema` 当前的存储结构就是所有用户磁盘上的「V1」。
之后任何轻量迁移覆盖不了的改动,都需要一个**与已发布版本逐字段一致**的 V1 定义,
否则用户升级后容器打不开(`App/VoiceTodoApp.swift` 会退到内存库 + `sharedStorageUnavailable`)。

## 为什么现在不挂 `SchemaMigrationPlan`

给 `ModelContainer` 传 `migrationPlan:` 会改变打开数据库的路径:库的模型 hash 必须命中计划里的某个版本,
否则 SwiftData 报 unknown model version。TestFlight / 开发机上的旧库(字段是一路轻量迁移加出来的)
不保证命中,上线前又无法在真机上验证——风险大于收益。所以 1.0 **运行时代码不变**,只冻结快照。

## 守护机制

`VoiceTodoTests/Store/StoreTests.swift` `testSchemaMatchesFrozenV1Baseline` 把四个实体
(`TodoItem` / `TodoOccurrenceCompletion` / `VoiceCaptureRecord` / `TaskEvent`)的
存储属性名 + 是否 Optional 冻结成字面量。改了存储字段,这个测试就会挂。

测试挂了按下表处理:

| 改动 | 轻量迁移能否覆盖 | 动作 |
|---|---|---|
| 新增 Optional 字段 | ✅ | 更新测试快照,照旧发版 |
| 新增带默认值的非 Optional 字段 | ✅ | 同上 |
| 新增 `#Index` | ✅(Widget `readOnly()` 首开要建索引,见 `SwiftDataModels.swift` 注释) | 快照不涉及,真机验证升级 |
| 改字段类型 / 改名 / 删字段 / 加关系 / 拆实体 | ❌ | 走下面的 V2 流程,**不要**只改快照 |

## 第一次需要非轻量迁移时(V2 流程)

1. 从 1.0 发版 tag 的 `Store/SwiftDataModels.swift` + `Store/TaskEventModels.swift` 复制四个 `@Model`,
   嵌套进 `enum VoiceTodoSchemaV1: VersionedSchema`(`versionIdentifier = Schema.Version(1, 0, 0)`),
   只保留存储属性、`@Attribute`、`#Index`,删掉计算属性和方法。字段以本测试快照为准逐一核对。
2. 新建 `VoiceTodoSchemaV2`,用新结构;顶层类型改成 `typealias TodoItem = VoiceTodoSchemaV2.TodoItem` 等。
3. `VoiceTodoMigrationPlan.stages` 写 V1→V2 的 `.custom` 或 `.lightweight` stage。
4. `VoiceTodoSchema.schema` 改为 `Schema(versionedSchema: VoiceTodoSchemaV2.self)`,
   `App/VoiceTodoApp.swift` 与 `Store/AppGroupModelContainerProvider.swift` 两处 `ModelContainer` 都传 `migrationPlan:`
   (Widget 与主 App 必须同口径)。
5. 真机验证:装 1.0 正式包 → 造数据 → 覆盖安装新包 → 数据完整、Widget 正常。

## 同样不可逆、发版前确认过的

- App Group ID `group.com.voicetodo.shared`:数据库在这个 group 容器里,改名等于用户数据「消失」。
