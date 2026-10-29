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
| 新增实体(新的 `@Model` 类型) | ✅ | 在 `VoiceTodoSchema.schema` 注册;更新测试快照(实体集合 + 字段);真机验证升级 |
| 改字段类型 / 改名 / 删字段 / 加关系 / 拆实体 | ❌ | 走下面的 V2 流程,**不要**只改快照 |

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
