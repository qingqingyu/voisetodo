# 任务书执行结果:① 监控统计排除用户额度拒绝 ② 回顾页按时间范围查询

> 对照任务书 `docs/task-metrics-quota-and-review-query.md`(基线 `main` @ `16f66aa`)。
> 执行分支:`task/metrics-quota-and-review-query`(自最新 main `9fbbcba` 拉出,含基线)。
> 两件事两个代码提交 + 本结果文档一个 docs 提交;未合 main、未部署。

## 1. 提交与改动摘要

| 提交 | 内容 |
|---|---|
| `ed2ecae` | 第一件:代理监控口径修正 |
| `89dc02e` | 第二件:回顾页/复盘第 1 步按窗取数 |
| (本提交) | docs:本结果文档 |

### 第一件(`ed2ecae`,只改 AIProxy + 两份文档)

| 文件 | 改动 |
|---|---|
| `AIProxy/src/extractMetrics.js` | 新增 `USER_LIMIT_REJECTION_TYPES` 常量(四类用户限制)与 `isExcludedFromStats`;`successRateOf`、新增 `latencyValuesOf`、分组 successRate/P50/P95、`evaluateExtractAlerts` 的成功率分母/耗时样本/失败分布/最慢模型全部换新口径;返回体新增 `userLimitRejections`;告警最小样本数按各自参与统计的行数判断 |
| `AIProxy/worker.js` | `runExtractMetricAlerts` 查询补 `error_type` 列(区分两类的依据);流式 `onSuccess`/`onFailure` 改在回调第一行取结束时刻,`total_ms` 不再包含 `confirmSuccess`(KV 写)与空结果退额度(DO 往返)的簿记耗时 |
| `AIProxy/worker.test.js` | 新增 `quotaRows`/`adminExtractMetrics` 测试助手 + 12a–12g 七条测试(先在改前代码跑出 7 红再改绿) |
| `docs/extract-latency-monitoring-results.md` | 「成功率口径」段落与 `quota_rejected` 行说明同步新口径 |
| `TELEMETRY.md` | `extract_requests` 说明:口径分两类 + `userLimitRejections` 字段 + 断连不进耗时 |

### 第二件(只改 App)

| 文件 | 改动 |
|---|---|
| `Protocols/TodoStoreProtocol.swift` | 新增 `ReviewWindowInputs` 值类型 + `ReviewSummaryReading` 协议(`reviewWindowInputs` / `dueTodoCount`);`ReviewFlowStore` 组合追加该能力 |
| `Store/TodoQueryActor.swift` | 实现 `reviewWindowInputs(from:to:)`(窗口内已完成 + 规律完成 + 按 todoId 反查父分类 + fetchCount 新增)与 `dueTodoCount`(dueDate 范围计数);每处谓词附与旧内存过滤的等价性注释 |
| `Store/TodoStore.swift` | 两个门面方法下沉 queryActor;`refreshTodos` 的过时注释(「分母走 ReviewView 的 @Query」)同步更正 |
| `UI/Review/RecapComponents.swift` | 聚合尾段抽成 `assemble`(新旧两路共用同一聚合核);新增按窗入口 `summary(inputs:...)`;`weekWindowLabel` 单一来源(weekSummary 与按窗路径共用标签推导);`monthSummary`/`weekSummary` 全量签名原样保留(地板 B `backlogFlowNumbers` 与对照测试的基准) |
| `UI/Review/ReviewView.swift` | 删除三个全量 `@Query`;`@State fixedSummary/periodSummary` 由 `reloadSummaries()` 后台按窗取数(`.task(id: selectedPeriod)` 首次+切周期,复盘 dismiss 后重查);`decidablePendingCount` 改走 `store.todos` 工作集内存过滤(同步可算,入口卡不闪 0);图表子视图改为显式传参,不再每次 body 重算全量聚合;preview 注入 in-memory TodoStore |
| `UI/Review/Flow/ReviewStepRecap.swift` | 删除三个全量 `@Query`,改收 `summary: ReviewSummary?`(容器查好传入;nil 加载中不渲染数字块) |
| `UI/Review/Flow/ReviewFlowView.swift` | 新增 `loadRecapSummary()`(窗口 = `weekWindow` 单一来源;「还挂着」走工作集;到期数走 `dueTodoCount`)挂在 `.task(id: currentStep)`——首次进流程与回跳第 1 步都重查本期窗口 |
| `UI/Home/HomeSettingsSheet.swift` + `UI/Home/HomeView.swift` | 设置深链穿入 `reviewStore`(与 sheet 入口同源;生产 `VoiceTodoApp.swift:355` 注入同一 `todoStore`) |
| `VoiceTodoTests/Review/ReviewWindowQueryParityTests.swift` | 新旧对照护栏 5 条(见 §3) |

## 2. 第一件:测试与示例

### 2.1 §1.4 每条对应的测试名

| §1.4 | 测试名(先改前红、改后绿) |
|---|---|
| 1 | `extract metrics 12a: 用户额度拒绝不计失败——成功率 100%,不触发失败率告警,userLimitRejections=30` |
| 2 | `extract metrics 12b: key_pool_full 是我方容量问题——计为失败并触发失败率告警` |
| 3 | `extract metrics 12c: 几毫秒的用户额度拒绝不进 P50/P95(25 次 25s 成功 + 100 次 5ms 拒绝)` + `extract metrics 12d: 快速拒绝占绝对多数时不得拖低 P95 掩盖变慢——耗时告警仍触发`(数字偏离见 §5-1) |
| 4 | `extract metrics 12e: 15 次成功 + 40 次 rate_limited——参与统计仅 15 次,样本不足不告警` |
| 5 | `extract metrics 12f: 流式 total_ms 不含 confirmSuccess 的耗时`(put 延迟 300ms 的假 KV,断言 total_ms < 250ms;改前实测 ≥ 330ms 红) |
| 映射表 | `extract metrics 12g: 口径映射表——四类用户限制全排除,三类容量拒绝全计失败,断连出耗时统计` |
| 6 既有全绿 | `cd AIProxy && npm test` 改前 389/389 → 改后 **396/396**(+7 全为新测试) |

### 2.2 管理接口示例返回(含 `userLimitRejections`)

21 次成功(其中 1 次 failover 后 28s 慢成功)+ 30 次 `quota_exceeded` + 1 次 `key_pool_full`:

```json
{
  "hours": 24,
  "rowCount": 52,
  "sampled": false,
  "requests": 52,
  "successRate": 0.9545,
  "userLimitRejections": 30,
  "p50Ms": 3560,
  "p95Ms": 3960,
  "failoverCount": 1,
  "byProvider": [
    { "key": "ZHIPU_MAIN|glm-x", "requests": 21, "successRate": 1, "p50Ms": 3600, "p95Ms": 3960, "status429": 0 }
  ],
  "byKeySlot": [
    { "key": "ZHIPU_KEY", "requests": 21, "successRate": 1, "p50Ms": 3600, "p95Ms": 3960, "status429": 0 }
  ],
  "byOutcome": [
    { "outcome": "quota_rejected", "count": 31 },
    { "outcome": "success", "count": 21 }
  ]
}
```

读法:30 次用户额度拒绝只进 `userLimitRejections` 与 `byOutcome`,不进成功率(21/22=95.45%,分母只剩成功 + 1 次 key_pool_full 容量拒绝)也不进 P50/P95;若 429 刷屏足够多,P95 不再被几毫秒的拒绝稀释。

## 3. 第二件:口径对照与测试

### 3.1 「每个数字 → 用到的数据 → 需要的时间范围」对照表

**回顾页(ReviewView)**

| 数字 | 用到的数据 | 范围 |
|---|---|---|
| Hero 完成总数 / 周期标签「近 30 天」 | 窗口内已完成一次性 + 窗口内规律完成(union) | `[今天−1月(用户日), 明天用户日起点)` |
| Stats 连续天数 streak | 同上按用户日聚成 byDay 后从最新活动日往前数 | 同窗(窗口封顶,见 §5-2) |
| 「当天记当天做完」行与判词(分子/分母) | 窗口内已完成一次性(要 createdAt) | 同窗 |
| 「未来 7 天还有 N 项」副文案 | `dueTodoCount`:dueDate 范围计数,不过滤完成/划掉/规律(旧口径如此) | `dueDate ∈ (今天用户日, 今天+7用户日]`,谓词换算为 `[明天起点, 第8天起点)` |
| 图表区:分类分布 / 每日趋势 / 有完成天数 / 最忙一天 | 所选周期窗的完成事件 | `[今天−7天 或 −1月, 明天起点)`,随 picker 重查 |
| 新增(入 ReviewSummary,本页不展示) | fetchCount(createdAt 范围) | 各窗 |
| 还挂着(入 ReviewSummary,本页不展示) | `store.todos` 工作集内存过滤(`!isCompleted && abandonedAt==nil && recurrenceRule==nil`) | 全时段(积压口径,三处同源硬约束;工作集=全部未完成+近90天完成,对该过滤完整覆盖) |
| 入口卡「N 件事等你决定」+ A15 曝光 hasPending | `store.todos` 工作集 + `triageInput` 同一函数(含已排未来排除) | 同上,同步可算(首帧即有,不闪 0) |

**复盘第 1 步(ReviewStepRecap,容器加载)**

| 数字 | 用到的数据 | 范围 |
|---|---|---|
| 主卡回退「完成 N」/ 周期标签 | 窗口完成事件(union) | `[上次复盘完成时刻, 明天起点)`,首次回落近 7 天(`weekWindow` 单一来源,下界时刻粒度) |
| 「本期完成」 | 同上 total | 同窗 |
| 「新增」 | fetchCount(createdAt 范围) | 同窗 |
| 「还挂着」(深色块) | `store.todos` 工作集 | 全时段 |
| 「当天记当天做完」卡 + 判词 | 窗口内已完成一次性 | 同窗 |
| streak(入 struct,本步不展示) | 同 total 的 byDay | 同窗(封顶同上) |

未动:流程容器地板 B(`reviewFlowRecapInputs` 全量快照,流程启动一次)——不在本任务两页范围内,口径保持。

### 3.2 新旧一致测试(§2.4-1,`VoiceTodoTests/Review/ReviewWindowQueryParityTests.swift`)

旧算法保留为测试基准:`legacyFixedSummary`(= 改前 `monthSummary` 原样调用)、`legacyPeriodSummary`(改前 `ReviewView.periodSummary` 的逐字复刻)、`legacyRecapSummary`(= 改前 `weekSummary` 原样调用),输入为全量数组(模拟旧 `@Query`)。`assertSummariesEqual` 对 ReviewSummary **13 个字段逐一断言**(再加整体相等)。每条对照同时覆盖:固定 30 天窗、周窗、月窗、复盘窗(有 since / 首次回落),外加入口卡 N 的全量表 vs 工作集等价。

| 测试 | 覆盖 |
|---|---|
| `testParityMixedDataset` | 跨周(7/8 天前)、跨月(31/32 天前)边界;远历史(400 天前);规律完成(父在 .study / 父已删 fallback .other / 父已转一次性仍查到 .work);已划掉(含划掉+未来到期照计到期数);已完成但排在未来的到期照计;开放态(第 0/1/7/8 天到期、无日期、过期);当天记当天做完三种 createdAt 形态 |
| `testParityFirstReviewFallbackWindow` | 同一数据 + 首次复盘(since=nil 回落近 7 天) |
| `testParityStreakScenarios` | 今天已完成+连续 5 天;今天未完成+往前 5 天(不算断);昨天断开 streak 归 1;**连续 71 天(今天+1…70 天前)** |
| `testUpcomingDueBoundaries` | 第 0 天不计、第 7 天计(闭端)、第 8 天不计;新旧同值且=1 |
| `testWindowQueryRowCountWithLargeHistory` | 数据量(见 §3.3) |

### 3.3 数据量测试(§2.4-2)

种子:20,000 条已完成(32…731 天前,两年内,createdAt=完成日)+ 本月 50 条(0…29 天前,全部当天记当天做完)。实测(iPhone 17 Pro 模拟器):

```
seed 20050 rows: 3.80s; windowed fetch: 24ms; aggregate: 1ms
```

断言:窗口(−1 月)返回 `completedTodos.count == 50`、`recurringCompletions == 0`、`createdCount == 50`(2 万条历史的 createdAt 全在窗外)、聚合 total==50、byDay==30 天、sameDay==50——**查询量只和本月数据有关**;种子写入 3.8s 是测试建库成本,与页面无关。

### 3.4 测试套件

- `xcodebuild test -only-testing:VoiceTodoTests`(iPhone 17 Pro 模拟器):**857 例,854 过,2 skipped,1 失败 = `TodoDueDateShifterTests.testDSTSpringForward_fallsBackToMidnight`**(CLAUDE.md 记录的 CN 时区已知基线红灯,非回归)。
- `arch -arm64 swift test`(SPM 协议层):**371 例,1 失败 = 同一已知 DST 红灯**。
- 冻结测试 `testSchemaMatchesFrozenV1Baseline` 原样通过(数据模型零改动、未加索引、未删数据)。

## 4. 人工验收(§2.5)

未做(需真机/模拟器人工走查,沿用本仓惯例列为开放项,交回后随 review 安排):

- [ ] 回顾页切换「本周 / 本月」,数字与改前一致(改前截图对比);
- [ ] 走一遍复盘流程,第 2 步划卡/拆小后回跳第 1 步,数字正确刷新(现在只重查本期窗口);
- [ ] 灌几千条历史完成记录,回顾页打开不卡(预期:与历史总量无关,冷启动后首帧空转即被窗口数据替换)。

已机器验证的部分:新旧数字逐字段一致(§3.2)、数据量下窗口查询 24ms(§3.3)、模拟器整包构建通过。

## 5. 偏离任务书的地方

1. **§1.4-3 的数字**:任务书预期「25 次 25s + 100 次 5ms 时改前 P95 被拉低而不触发」——实测(nearest-rank)100/125 = 80% < 95%,P95 在改前也落在 25000 上、告警照触发;被 5ms 拒绝真正拉低的是 **P50**(改前=5,改后=25000)。处理:12c 按任务书原数字测 P50/P95(改前红在 P50),另补 12d(25 次 25s + **475** 次 5ms)演示任务书想覆盖的场景——改前 P95 确实被拖到 5ms 不告警,改后 P95=25s 告警。
2. **§2.3-4 streak「往前数,不受所选周/月限制」**:旧算法的 streak 本来就**按窗口封顶**(`ReviewAggregator.summarize` 的游标停在窗口起点,byDay 只含窗口内事件;30 天窗最多显示 ~31)。「数字一个不变」(硬性要求)与「往前数到断开」在 streak 跨过窗口起点时矛盾,按硬性要求执行:计算规则一字不改、仍窗口封顶,因此**无需**也**不应**往前分批查(「每批 60 天」的机制不适用;若按任务书实现反而会改数字)。70 天连续场景的对照测试证明两侧一致(都封顶)。
3. **busiestDay 平局**:多天并列最大时旧算法按字典遍历序取第一个,本就非确定(进程内稳定、跨构造不稳定),新旧同逻辑。对照测试种子在固定一天多放一条避免平局(测试文件内有口径注);所有计数数字与平局无关。
4. **读失败的呈现**:按窗读取失败时,回顾页 error 日志留痕并保留上一份数字(切周期/复盘 dismiss 自动重试);复盘第 1 步 error 日志 + 现有 `presentError` toast。旧 `@Query` 无失败路径,这是新增的显式错误处理,不新增页面文案(遵守「不改文案」约束)。
5. **设置深链注入**:统计不再走隐式 `@Query` 环境后,`HomeSettingsSheet` 需要穿一个 `reviewStore` 参数(HomeView 注入,生产即同一 `todoStore`);preview 由裸容器改为构造 in-memory `TodoStore` 注入。
6. **首帧异步化**:数字从同步变为异步就绪,首帧渲染空(不闪「还没有完成」空态文案);入口卡 N 与 A15 曝光 hasPending 走工作集同步值,不受影响;`dailyTrendData` 每帧重算全量聚合的问题顺带消除(聚合结果缓存进 `@State`)。

其余:无。
