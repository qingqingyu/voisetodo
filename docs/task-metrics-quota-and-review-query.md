# 任务书：① 监控统计排除用户额度拒绝 ② 回顾页按时间范围查询

> 2026-10-31 起草，代码对照基线 `main` @ `16f66aa`。本文档是**交给执行者的任务书**。
> 两件事互不依赖，**分两个提交**。第一件只改代理（AIProxy），第二件只改 App。
> 完成后把结果写进 `docs/task-metrics-quota-and-review-query-results.md`（格式见 §4），交回审查。

---

## 1. 第一件：监控统计排除「用户自己的额度/限速拒绝」

### 1.1 问题

`AIProxy/src/extractMetrics.js` 的成功率口径是：`success` / `cache_hit` / `empty_todos` 算成功，
`client_disconnected` 排除出分母，**其余都算失败**。于是 `outcome = quota_rejected` 的请求被算成了失败：

- 免费用户每天用完 3 次后每再说一次，就多一次「失败」。用户一多，`handleScheduled` 的「解析失败率高」告警会频繁误报；
- 这些请求几毫秒就返回，又被算进 `total_ms` 的 P95，把 P95 拉低，掩盖真正的变慢。

（起因是上一份任务书写了「提前拒掉的也写一行，这样才能算真实的失败率」，口径不严谨。写一行是对的，算进成功率和耗时是错的。）

### 1.2 新口径

按 `error_type` 区分两类 `quota_rejected`：

| 类别 | error_type | 成功率 | 耗时统计（P50/P95） | 说明 |
|---|---|---|---|---|
| **用户自己的限制** | `quota_exceeded`、`subscription_quota_exceeded`、`rate_limited`、`deepread_limit_exceeded` | **排除出分母** | **排除** | 按设计拦下的，不是服务故障 |
| **我方容量问题** | `key_pool_full`、`global_budget_exceeded`、`global_budget_exceeded_pro` | **计为失败** | 计入 | 用户想用但我方给不了，要能告警 |

- 现有 `client_disconnected` 的处理不变（排除出成功率分母）。
- `client_disconnected` 和「用户自己的限制」**也排除出耗时统计**：前者是用户中途走了，后者几毫秒就返回，都不代表解析速度。
- `cache_hit` 照旧计入成功率和耗时（用户真实拿到了结果）。
- 「用户自己的限制」的 error_type 集合定义成**一个常量**，`summarizeExtractRequests`（管理接口）和 `evaluateExtractAlerts`（告警）共用，不要两处各写一份。
  代码里已有的 `QUOTA_REJECTION_TYPES`（`worker.js`）保持不变，它决定的是 `outcome` 写不写成 `quota_rejected`，和这次的统计口径是两回事。

### 1.3 要改的地方

1. `AIProxy/src/extractMetrics.js`：成功率、P50/P95、按模型/按 Key 分组、告警判定（含「最慢的模型」「失败分布」）全部换成 §1.2 的口径。
   告警的最小样本数（20 次）按**参与成功率统计的行数**判断（耗时告警按参与耗时统计的行数）。
2. `AIProxy/worker.js` `runExtractMetricAlerts`：查询语句现在只取 `provider_id, model, total_ms, outcome`，**要加上 `error_type`**，否则区分不了两类。
3. 管理接口返回体新增一个字段 `userLimitRejections`：窗口内「用户自己的限制」被拦下的次数（便于看免费额度撞墙有多频繁）。`byOutcome` 照旧按 outcome 计数，不变。
4. 顺手修一个小问题：流式 `onSuccess` 里 `total_ms` 是在 `await result.confirmSuccess()` 和空结果退额度之后才取时间，会多算几十毫秒。
   把结束时刻在回调**第一行**取好存下来，后面写行时用这个值。`onFailure` 同样处理。
5. `docs/extract-latency-monitoring-results.md` 的「成功率口径」那一段、`TELEMETRY.md` 里 `extract_requests` 的说明同步改成新口径。

### 1.4 测试（`AIProxy/worker.test.js`，先在改前代码上跑出失败，再改代码跑通过）

1. 窗口内 20 次成功 + 30 次 `quota_rejected / quota_exceeded`：成功率 = 100%，**不触发**失败率告警；`userLimitRejections = 30`。
2. 20 次成功 + 10 次 `quota_rejected / key_pool_full`：成功率 = 20/30，按阈值 0.9 **触发**失败率告警。
3. 25 次 `total_ms = 25000` 的成功 + 100 次 `total_ms = 5` 的 `quota_exceeded`：P95 = 25000，**触发**耗时告警（改前会被拉低而不触发）。
4. 15 次成功 + 40 次 `rate_limited`：参与统计的只有 15 次，**样本不足不告警**。
5. 流式成功：`total_ms` 不包含 `confirmSuccess` 的耗时（用会延迟的假 `confirmSuccess` 断言）。
6. 已有的监控测试全部继续通过。

`cd AIProxy && npm test` 全部通过，报告改前改后的通过数。

---

## 2. 第二件：回顾页按时间范围查询

### 2.1 问题

首页已经只读「全部未完成 + 最近一段时间完成的」（见 `docs/completed-todos-performance.md`），不随数据量变慢。
但「回顾」页和复盘第一步还在把**全部历史**读进内存：

| 文件 | 查询 |
|---|---|
| `UI/Review/ReviewView.swift` 约 `:87-100` | `@Query` 全部已完成待办、全部 `TodoOccurrenceCompletion`、全部 `TodoItem` |
| `UI/Review/Flow/ReviewStepRecap.swift` 约 `:32-41` | 同样三个 |

而且 `ReviewView` 的多个计算属性（约 `:228`、`:430-510`）在每次 body 重算时对整批数据 `.map { $0.toData() }` 再统计。
页面只显示「本周 / 本月」，但读和算的是全部历史；用上几个月、积累几千条后，打开回顾页和在复盘里操作会明显变卡。

### 2.2 目标

- 回顾页和复盘第一步的读取量和计算量，只和**所选时间段内**的数据量有关，与库里总共存了多少条无关。
- **页面上显示的所有数字一个都不能变**（完成数、完成率、分类分布、连续天数 streak、7 天内到期数、复盘第一步的各项数字）。
- **不删任何数据**。

### 2.3 做法要求

执行者先通读这两个页面和 `UI/Review/RecapComponents.swift`、`Protocols/Domain/ReviewAggregator.swift`，
把**每个数字用到了哪些数据、需要多长的时间范围**列成表，写进结果文档，再动手。按下面的原则改：

1. **已完成的待办、重复任务的完成记录**：只查统计需要的时间范围（所选的周/月；如果有「与上一期对比」，就是两期）。
   用 `#Predicate` 按 `completedAt` 过滤，让数据库走已有的 `completedAt` 索引。
2. **「全部待办」**：现在用于两件事——给重复任务的完成记录查所属分类、作为某些统计的分母或输入。
   - 查分类：只需要**重复任务本身**（`recurrenceFrequencyRaw != nil`），它们数量很少；或者按本期完成记录里出现的 `todoId` 去查。
   - 作为分母或输入的：按该数字真正需要的条件写谓词（例如只要未完成的、只要某个日期范围的）。逐个列出，不要整表读。
3. **「7 天内到期」**（约 `:478`）：改成按 `dueDate` 范围的谓词查询，不在内存里过滤全表。
4. **连续天数（streak）**：它需要往前数，不受所选周/月限制。不要因此读全部历史：
   - 例如按 `completedAt` 倒序分批取（每批 60 天），数到第一个断开的日子就停；
   - 连续天数的计算规则（「今天还没完成不算断」等，见 `ReviewAggregator`）**一字不改**。
5. **查询放在后台**：参照首页已有的做法（`Store/TodoQueryActor.swift`，`@ModelActor` 在后台查询、返回 `TodoItemData` 值类型），
   不要在 body 里同步查大批数据。切换「本周 / 本月」时重新查。
   如果某处保留 `@Query`，必须是带时间范围谓词的，且谓词随所选时间段变化。
6. **body 里不再对整批数据反复 `.map { $0.toData() }`**：查询结果直接是值类型，统计结果算一次缓存起来，数据或时间段变了再重算。
7. 复盘流程里每次划卡都会写库，现在会触发这些全量 `@Query` 重跑（见 `ReviewFlowView.swift` 里的相关注释）。改完后要确认：划卡后的刷新只重算本期范围，且刷新后数字正确。

### 2.4 测试

1. **新旧结果一致（最重要）**：写单元测试，用同一份构造数据，分别跑「旧的全量算法」和「新的按范围查询 + 计算」，断言回顾页和复盘第一步的**每一个数字都相等**。
   构造数据要覆盖：
   - 跨周、跨月边界的完成记录；
   - 重复任务的完成记录（分类来自父任务）、父任务已被删除的完成记录（应 fallback 成「其他」）；
   - 已划掉（`abandonedAt`）的待办；
   - 连续天数：今天未完成、昨天断开、连续 70 天以上（跨两批）三种情况；
   - 7 天内到期：边界上的第 0 天和第 7 天。
   旧算法可以先抽成一个测试专用函数保留，作为对照的基准。
2. **数据量测试**：构造 2 万条已完成待办（分布在 2 年内）+ 本月 50 条，断言：
   - 按范围查询返回的行数只和本月数据有关；
   - 统计耗时在合理范围内（在测试里打印耗时，写进结果文档；不设硬阈值，避免 CI 机器差异导致不稳定）。
3. `VoiceTodoTests` 全部通过（已知的 CN 时区红灯除外，写明）。

### 2.5 人工验收（真机或模拟器）

- 回顾页切换「本周 / 本月」，数字与改前一致（改前先截图记下）。
- 走一遍复盘流程，划卡后第一步的数字正确刷新。
- 用测试数据灌入几千条历史完成记录，打开回顾页不卡（与改前对比，在结果里描述体感或附 Instruments 截图）。

---

## 3. 约束

- 从最新 `main` 拉新分支（名字自定），**不要直接在 main 上改**；两件事分两个提交；推送分支后交回审查，**不合 main**。
- 第一件：不改服务商选择、熔断、额度的逻辑，不改 `outcome` 的写入规则，只改统计和告警口径；不部署。
- 第二件：不改数据模型（冻结测试 `testSchemaMatchesFrozenV1Baseline` 必须原样通过），不加索引，不删数据，不改任何统计口径和页面文案。
- 提交信息里不要出现模型名称。

---

## 4. 结果格式（`docs/task-metrics-quota-and-review-query-results.md`）

1. 两个提交的哈希和改动摘要（文件 + 每处一句话）。
2. 第一件：§1.4 每条测试的名字；改前改后 `npm test` 通过数；管理接口的一份示例返回（含 `userLimitRejections`）。
3. 第二件：
   - §2.3 要求的「每个数字 → 用到的数据 → 需要的时间范围」对照表；
   - 新旧结果一致测试的覆盖清单；
   - 数据量测试打印的耗时；
   - 人工验收结果。
4. 偏离任务书的地方及理由（没有就写「无」）。
