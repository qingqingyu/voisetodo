# 结果:解析准确率埋点(只传改了什么,不传原文)

> 任务书:`docs/task-parse-correction-telemetry.md`(基线 main @ 16f66aa)。
> 执行分支:`maidian`(= 本地 main @ 9fbbcba 之上)。全量单测 403 过 1 已知基线红
> (CN 时区 DST,`TodoDueDateShifterTests.testDSTSpringForward_fallsBackToMidnight`,
> CLAUDE.md 记录在案的非回归);新增 32 测全绿;冻结测试
> `StoreTests.testSchemaMatchesFrozenV1Baseline` 在 iPhone 17 Pro 模拟器原样通过。

---

## 1. 改动摘要

| 文件 | 改动 |
|---|---|
| `Protocols/Domain/ParseExpressionClassifier.swift` | **新增**。时间说法分类纯函数 `classify(dueHint:hasDate:hasTime:locale:)`,中英日关键词并集,按 `ParseExpressionKind` 声明顺序先命中先返回 |
| `Protocols/Domain/ParseCorrectionTelemetry.swift` | **新增**。`FieldCorrection` / `ConfirmSheetParseDiff`(纯数据);`ParseCorrectionDiff`(确认面板 + after_save 对比引擎,纯函数);`ParseCorrectionDiff.Rules`(§2.3 四条判定);`ParseCorrectionReportedSet`(App Group 去重集合,48h 过期 / 上限 500);`ParseCorrectionRecorder`(after_save 上报收口);`ParseCorrectionTelemetry.localeCode`(语言代码映射) |
| `Protocols/Telemetry.swift` | 新增 `parseConfirmed` / `parseFieldCorrected` 两个事件 case + `name` + `params` 编码(差值缺失即不带,键不存在 ≠ 0) |
| `App/AppCoordinator.swift` | ①新增 `confirmExtractionContext`(path+extractID,与 `extractedTodos` 同生命周期:processTranscript / recoverPendingItems 写入,cancelTodos / cancelExtraction / clearExtractionPresentation 清空);②新增 `confirmParseOriginals`(AI 原始输出快照:partial 帧 / pending 恢复写入 `extractedTodos` 时同步快照,清理点同 ①)——确认面板通过 `$extractedTodos` 绑定就地编辑/删除,confirm 时 `extractedTodos` 已是用户改过的状态,对比引擎必须用快照,否则自己比自己恒零;③`confirmTodos` 成功路径在 `Task.detached(priority:.utility)` 里对比+上报,extractID 用 `VoiceTodoLog.$extractID.withValue` 绑定进 payload |
| `Store/TodoStore.swift` | `updateFull` 变更前快照 `oldHasDueTime` / `oldDueHint`,`saveOrRollback` 成功后调 `ParseCorrectionRecorder.recordAfterSaveIfNeeded`(失败路径不记) |
| `project.yml` + `VoiceTodo.xcodeproj` | Widget target 的显式文件清单补两个新文件(它编译 `Telemetry.swift`,事件枚举引用新类型);xcodegen 重新生成 |
| `TELEMETRY.md` | 事件表两行 + 「`parse_confirmed` / `parse_field_corrected` 口径」一节(指标算法 + after_save 四条判定 + expressionKind 取值)+ PII 红线补 expressionKind 说明 |
| `AIProxy/schema.sql` | 末尾补三段 SQL:修改率/删除率分组、dayDelta 分布、按说法类型的错误率(kinds 用 `json_each` 拆)。**服务端零代码改动**,事件照常进 `telemetry_events` |
| `VoiceTodoTests/Protocols/ParseCorrectionTelemetryTests.swift` | **新增**,32 个测试(清单见 §4) |

数据模型、解析逻辑、确认面板与详情页的界面交互:零改动。

## 2. 两个事件的最终参数表

### parse_confirmed(每次确认面板确认记 1 枚)

| 参数 | 取值 | 与任务书差异 |
|---|---|---|
| `path` | `live_voice` / `keyboard` / `pending_recovery`(能到确认面板的三条路径;`siri` 不经面板) | 无 |
| `locale` | `zh` / `en` / `ja` / `other`(只取语言代码,zh-Hant 等变体归 zh) | 无 |
| `extracted` `kept` `dropped` `added` `edited` | 计数;`added` 为面板手动新增(当前 UI 不支持,恒 0,按 id 匹配通用计算) | 无 |
| `dateEdited` `timeEdited` `titleEdited` `recurrenceEdited` `reminderEdited` `categoryEdited` | 计数 | `reminderEdited` 含提前量(`reminderOffsetMinutes`)变化——提前量是提醒设置的一部分 |
| `kinds` | **JSON 对象串**,如 `{"weekday":2,"none":1}`,按枚举声明顺序稳定输出 | **有差异**:任务书示例 `weekday:2,none:1`;改为 JSON 对象串后 D1 `json_each(json_extract(params,'$.kinds'))` 直接可拆,服务端零代码(SQL 已实测,见 schema.sql) |
| payload `extractID` | live_voice/keyboard = 本次提取 ID(与 extract_outcome / 代理 X-Extract-ID 同源) | **有差异**:pending_recovery 一次确认覆盖多次提取,存恢复流程 flowID(`pending-xxx`,只关联 coordinator 日志,不与单次提取行 join) |

### parse_field_corrected(每条待办每个被改的日期/时间字段记 1 枚)

| 参数 | 取值 | 与任务书差异 |
|---|---|---|
| `stage` | `confirm_sheet` / `after_save` | 无 |
| `field` | `date` / `time` | 无 |
| `change` | `changed` / `added` / `removed` | 无 |
| `dayDelta` | 仅 date+changed;按 `DayClock.startOfUserDay` 两端日界,DST 安全(dateComponents),截断 ±60 | 无 |
| `minuteDelta` | 仅 time+changed;截断 ±1440 | 无 |
| `expressionKind` | 9 个枚举(见 §3) | 无短语有日期的边角归 `other`(任务书未定义此形态) |
| `basis` | 仅 confirm_sheet(原始解析的 `due_date_basis`);after_save 无持久化 basis,不带 | 无 |
| `recurring` | 确认/修改后的最终重复状态 | 无 |
| `locale` | 同上 | 无 |
| `minutesSinceCreated` | 仅 after_save | 无 |

## 3. 分类规则覆盖清单(`ParseExpressionClassifier`,三语并集)

| 类型 | 中文 | 英文 | 日文 |
|---|---|---|---|
| relative_day | 今天/今日/今晚/今夜/明天/明日/明晚/后天/大后天/当天 | today/tonight/tomorrow/day after tomorrow | 今日/明日/明後日/一昨日/今夜/今晩 |
| weekday | X周X/星期X/礼拜X(前缀 本这下下下上来先 可选)、裸 下周/本周/这周/上周/下下周/来周(负向排除后接星期字/数字/后/内)、周末 | 周名全称+缩写(可带 next/last/this/coming)、next/this/last week、weekend | (今/来/再来/先)週、月火水木金土日曜 |
| month_part | 月初/月中/月底/月末 | mid-month/midmonth | 月初/月中/月末/月半ば/月初め |
| relative_offset | 数字+个?+(天/日/周/星期/礼拜/月/年/小时)+(之?后/以后/内),数字含中文数字;英文 month-part 另有 early/mid/end of the month 未覆盖(归 other) | in N days/weeks/months/years;N days/weeks later / from now/today | N(日/週間/ヶ月/か月/年)後/あと |
| absolute_date | N月N日/N月N号/N月N號、NNNN年 | 月名+日 / 日+月名、M/d(/yyyy) | N月N日(与中文同正则) |
| holiday | 春节/除夕/元旦/元宵/清明/端午/中秋/重阳/国庆/五一/六一/劳动节/情人节/圣诞/万圣/感恩节/复活节/腊八 | christmas/xmas/new year/easter/halloween/thanksgiving/valentine/independence day | 正月/お盆/彼岸/節分/七夕/大晦日/クリスマス/ハロウィン/勤労感謝/建国記念/天皇誕生/みどりの日/こどもの日/海の日/山の日/文化の日 |
| time_only | 上午/中午/下午/傍晚/晚上/夜里/凌晨/早上/早晨/清晨/午夜/半夜/深夜、N点(半)、N时 | N am/pm、at N、o'clock/noon/midnight | 午前/午後/正午/朝/夕方、N時 |
| none | 无短语且无日期(只有钟点没日期 → time_only) | 同左 | 同左 |
| other | 有短语认不出;**无短语但有日期(AI 直接给 ISO 日期没给说法)也归 other** | 同左 | 同左 |

多类型命中按上表顺序取第一个:「下周五下午三点」→ weekday;「两周后」→ relative_offset(裸周前缀负向约束);「明天下午」→ relative_day。规则**不按 locale 挑选**(内容语言跟随用户输入而非系统语言),`locale` 参数保留给未来特化。

## 4. 测试(§6 对应)

`VoiceTodoTests/Protocols/ParseCorrectionTelemetryTests.swift`,32 个,全绿:

- 分类(§6.1):`testClassifyRelativeDay` / `Weekday` / `MonthPart` / `RelativeOffset` / `AbsoluteDate` / `Holiday` / `TimeOnly` / `NoneAndOther` / `FirstMatchWinsByTableOrder`
- 对比(§6.2):`testConfirmSheetNoChange` / `DayDeltaForwardOneAndBackSeven`(跨月)/ `DayDeltaCrossYear` / `DayDeltaClampedTo60` / `DateAddedAndRemoved` / `TimeOnlyChangeMinuteDelta` / `DroppedNotInFieldStats` / `AddedCountedSeparately` / `TitleWhitespaceOnlyNotEdited` / `ReminderEmptyArrayVersusNilNotEdited` / `KindsEncoding` / `BasisCarriedFromOriginal`
- after_save(§6.3):`testAfterSaveAppAndReviewOriginsNotRecorded` / `Beyond120MinutesNotRecorded` / `ManualTodosNotRecorded` / `OnlyFirstChangePerFieldRecorded` / `TimeAddedAndRemoved`;去重集合:`testReportedSetExpiry` / `ReportedSetCapacityCap`
- PII(§6.4):`testPIICanaryNeverAppearsInEventParams`(金丝雀 `PII_CANARY_买牛奶标题` / `PII_CANARY_下周五下午`,键值逐项 + JSON 整串断言不泄漏,覆盖两个事件 + after_save 录制路径)
- 参数契约:`testLocaleCode` / `testParseConfirmedEventNameAndParams` / `testParseFieldCorrectedEventNameAndOptionalParams`

全量:`arch -arm64 swift test` 403 测 1 失败 = 已知 CN 时区 DST 基线红(非回归);
`xcodebuild test -only-testing:VoiceTodoTests/StoreTests/testSchemaMatchesFrozenV1Baseline`
(iPhone 17 Pro 模拟器)通过。整包 `xcodebuild build`(app+widget)成功。

## 5. 人工验收 —— **开放(待真机/模拟器走查)**

代码路径均被单测覆盖,但按任务书要求的两遍真机/模拟器走查未做(本会话无真机):
说一句含「下周五」的话 → 确认面板把日期改掉一天 → 确认;再说一句 → 确认后进详情页改日期。
Xcode 控制台过滤 `telemetry.enqueue` 核对 `parse_confirmed` / `parse_field_corrected`
参数(应只见枚举/数字,无标题无原话)。走查清单已并入上线前真机走查队列。

## 6. 偏离任务书的地方

1. **`kinds` 用 JSON 对象串**(`{"weekday":2}`)而非示例的 `weekday:2`:D1 侧
   `json_each` 直接可拆、服务端零代码;内容仍只有枚举名和数字。SQL 已本机 sqlite3 实测。
2. **pending_recovery 的 extractID 存恢复流程 flowID**:一次确认覆盖多次提取,
   没有单一提取 ID 可用;flowID 至少与 coordinator 日志关联。
3. **expressionKind 对「无短语有日期」归 `other`**:任务书只定义了「无日期 → none」,
   此形态(AI 给了 ISO 日期但没给 dueHint)没有说法可归类。
4. **`reminderEdited` 含提前量变化**:提前量是提醒设置的一部分,单独拆字段超出
   任务书的字段清单。
5. **Widget target 编译两个新文件**(project.yml 显式清单):它本来就编译
   `Telemetry.swift`,事件枚举的新 case 引用了新类型;纯 Foundation 逻辑,无体积负担。
6. **确认面板对比在 `Task.detached(priority:.utility)`、extractID 任务局部绑定**:
   任务书只要求后台执行,绑定方式沿 `Telemetry.record` 既有的 task-local 机制。
