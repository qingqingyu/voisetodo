# 任务书：解析准确率埋点——只上传「改了什么」，不上传原文

> 2026-11-01 起草，代码对照基线 `main` @ `16f66aa`（执行时以最新 main 为准）。本文档是**交给执行者的任务书**。
> 完成后把结果写进 `docs/task-parse-correction-telemetry-results.md`（格式见 §8），交回审查。

---

## 0. 目的和红线

上线后要能回答：

1. AI 解析出来的待办，用户**改了多少**？改的是日期、时间、标题，还是整条删掉？
2. **日期改错**的比例多大，一般差几天？
3. 哪类时间说法最容易错（「下周五」「月中」「明天」……）？中文、英文、日文分别怎样？

**红线（不可违反）**：不上传任何用户内容——不传转写原文、待办标题、`dueHint` 原文、备注。
只传**枚举值和数字**。这样与 `PRIVACY_POLICY.md`「转写实时处理、不存档」的承诺、`TELEMETRY.md` 的 PII 红线、
App Store 隐私标签（Other Usage Data）都保持一致，**不需要改隐私政策**。

---

## 1. 两个修改时机

| 时机 | 场景 | 来源 |
|---|---|---|
| **确认面板里改** | 解析结果出来后、点确认前，用户改了某条，或删掉某条 | `App/AppCoordinator.swift` `confirmTodos`：已经在拿「原始解析结果 `self.extractedTodos`」和「确认后的 `todos`」做对比（标题纠错学习，约 `:822-840`），在同一处加 |
| **保存后马上改** | 确认保存后不久，用户在详情页又改了日期或时间 | 详情页保存走 `TodoStore.updateFull(_:update:origin:)`，`origin == .detail` |

---

## 2. 新增 2 个事件

### 2.1 `parse_confirmed`：每次在确认面板点确认，记 1 条

| 参数 | 类型 | 说明 |
|---|---|---|
| `path` | 枚举 | 复用解析耗时监控的取值：`live_voice` / `keyboard` / `pending_recovery` / `reextract` / `main`（来源同 `ExtractTiming` 的 `path`） |
| `locale` | 枚举 | 语言，只取语言代码：`zh` / `en` / `ja` / `other` |
| `extracted` | Int | AI 解析出几条 |
| `kept` | Int | 确认保存了几条（原始解析里的） |
| `dropped` | Int | 在确认面板里删掉了几条 |
| `edited` | Int | 保存的条目里，至少改了一个字段的有几条 |
| `dateEdited` / `timeEdited` / `titleEdited` / `recurrenceEdited` / `reminderEdited` / `categoryEdited` | Int | 各字段被改的条数 |

- 事件带上本次的 `extractID`（埋点队列已有这个字段），可以和 `extract_outcome`、代理端 `extract_requests` 对上号。
- 如果确认面板支持用户手动新增条目，新增的条目不计入上面任何一项（它不是 AI 解析的结果）；若能区分，再加一个 `added` 计数。

### 2.2 `parse_field_corrected`：每条待办每个被改的字段，记 1 条

只针对**日期和时间**这两个字段记明细（准确率的核心）；其他字段只在 2.1 里计数。

| 参数 | 类型 | 说明 |
|---|---|---|
| `stage` | 枚举 | `confirm_sheet`（确认面板里改）/ `after_save`（保存后改） |
| `field` | 枚举 | `date` / `time` |
| `change` | 枚举 | `changed`（原来有、改成别的）/ `added`（原来没有、用户补上）/ `removed`（原来有、用户删掉） |
| `dayDelta` | Int? | 仅 `field=date` 且 `change=changed`：改后日期 − 原日期，按**用户日**算天数（用 `DayClock.startOfUserDay` 取两边的日界再相减），截断到 ±60 |
| `minuteDelta` | Int? | 仅 `field=time` 且 `change=changed`：改后 − 原时间的分钟差，截断到 ±1440 |
| `expressionKind` | 枚举 | 原始时间说法的类型（§3），只传类型，不传原文 |
| `basis` | 枚举? | 原始解析的 `dueDateBasis`（已有字段，原样传它的 rawValue；没有就不带） |
| `recurring` | Bool | 这条是不是重复任务 |
| `locale` | 枚举 | 同 2.1 |
| `minutesSinceCreated` | Int? | 仅 `after_save`：保存到修改过了多少分钟 |

### 2.3 `after_save` 的判定（避免把正常改期算成解析错误）

只有**同时满足**以下条件才记：

1. `origin == .detail`（详情页直接改）。首页「移到明天」、复盘排期（`origin == .app / .review`）都是用户改计划，**不算**解析错误，不记。
2. 这条待办是 AI 解析来的（`TodoItem.source` 为语音或键盘解析；手动新建的不算）。
3. 距离创建（`createdAt`）**不超过 120 分钟**。
4. 这条待办的这个字段**第一次**被改。用 App Group UserDefaults 记一个「已上报过的 待办id+字段」集合，条目 48 小时后过期，集合上限 500 条，超过时删最旧的。

---

## 3. 时间说法分类（`expressionKind`，在手机上算，只上传结果）

输入是原始解析结果里的 `dueHint`（模型给出的时间短语），以及有无 `dueDate` / `dueTime`。
在**手机本地**按关键词规则归类，**`dueHint` 原文绝不上传、也不写日志**。

| 取值 | 含义 | 中文例 | 英文例 | 日文例 |
|---|---|---|---|---|
| `none` | 原始解析没有日期 | — | — | — |
| `relative_day` | 今天 / 明天 / 后天 / 大后天 | 明天、后天 | today, tomorrow | 今日、明日、明後日 |
| `weekday` | 星期几（含本周 / 下周 / 下下周 / 上周） | 周五、下周三 | Friday, next Friday | 金曜、来週の水曜 |
| `month_part` | 月初 / 月中 / 月底 / 月末 | 月中、月底前 | mid-month, end of month | 月半ば、月末 |
| `relative_offset` | N 天 / 周 / 个月后 | 三天后、两周后 | in 3 days | 3日後 |
| `absolute_date` | 具体日期 | 11 月 5 号 | Nov 5 | 11月5日 |
| `holiday` | 节日 | 国庆、春节 | Christmas | 正月 |
| `time_only` | 只有时间没有日期 | 下午三点 | at 3pm | 午後3時 |
| `other` | 有 `dueHint` 但规则认不出 | — | — | — |

- 写成一个纯函数（如 `ParseExpressionClassifier.classify(dueHint:hasDate:hasTime:locale:)`），放在 `Protocols/Domain/`。
- 规则覆盖上表的常见说法即可，**不追求完美**；认不出就归 `other`。`other` 占比高本身也是信号。
- 多个类型同时命中时按上表从上到下的顺序取第一个（如「下周五下午三点」→ `weekday`）。

---

## 4. 实现要求

1. 在 `Protocols/Telemetry.swift` 加两个事件 case 和参数编码，沿用现有事件的写法（`extract_outcome` 是很好的参照）。
2. 对比原始解析和确认结果时，按 `id` 配对（`confirmTodos` 里已经这么做）。日期比较按用户日；时间比较用 `dueTime`；「改了」的判断要和 UI 实际能改的字段一致：
   - 标题：去掉首尾空白后比较；
   - 重复规则、提醒：比较规范化后的值，不要因为字段顺序或空数组 vs nil 误报。
3. 对比、分类、上报都放在后台（`Task.detached(priority: .utility)` 或现有学习逻辑同一个 Task 里），不能拖慢确认后的界面。
4. Siri 新建（`AddTodoIntent`）不经过确认面板，不记 `parse_confirmed`；它保存后的修改按 §2.3 正常判定。
5. **不改数据模型**（不加字段）；冻结测试 `testSchemaMatchesFrozenV1Baseline` 必须原样通过。
6. `TELEMETRY.md`：
   - 事件表加这两个事件和参数；
   - 加一节「解析准确率口径」，写明各指标怎么算（见 §5）和 `after_save` 的判定条件；
   - PII 红线一节注明：`expressionKind` 是手机上算出的类型，`dueHint` 原文不上传。
7. `AIProxy/schema.sql` 末尾的「常用查询示例」补 §5 的 SQL。服务端不用改代码，事件照常进 `telemetry_events`。

---

## 5. 要能算出的指标（写进 `TELEMETRY.md`，并在 `schema.sql` 给出 SQL）

| 指标 | 算法 |
|---|---|
| 确认面板修改率 | Σ`edited` ÷ Σ`kept` |
| 删除率 | Σ`dropped` ÷ Σ`extracted` |
| 日期修改率（确认面板） | Σ`dateEdited` ÷ Σ`kept` |
| 日期修改率（含保存后） | （`parse_field_corrected` 中 `field=date` 的条数）÷ Σ`kept` |
| 日期差几天的分布 | `field=date AND change=changed` 的 `dayDelta` 直方图（重点看 ±1、±7） |
| 哪类说法最容易错 | 按 `expressionKind` 分组的日期修改条数（分母需要各类型的总量，见下） |
| 分语言 | 以上都按 `locale` 分组 |

**分母问题**：按 `expressionKind` 算错误率需要知道每种说法一共出现多少次。在 `parse_confirmed` 里再加一个参数
`kinds`：本次保存的条目里各类型的计数，编码成紧凑字符串（如 `"weekday:2,none:1"`，只含 §3 的枚举名和数字）。

---

## 6. 测试（`VoiceTodoTests`）

1. **分类函数**：中英日各类型至少 2 个例子，加上 `none`、`other`、多类型命中取第一个。
2. **对比逻辑**（纯函数，喂原始和确认后的两组 `ExtractedTodo`）：
   - 没改：`edited = 0`；
   - 改日期（往后 1 天、往前 7 天）：`dayDelta` 正确，跨月、跨年正确；
   - 原来无日期、用户补上：`change = added`；删掉日期：`removed`；
   - 只改时间：`minuteDelta` 正确；
   - 删掉一条：`dropped = 1`，且不出现在字段统计里；
   - 标题只差首尾空格：不算改；提醒数组 `[]` 与 `nil`：不算改。
3. **`after_save` 判定**：`origin` 为 `.app` / `.review` 不记；超过 120 分钟不记；同一条同一字段第二次改不记；手动新建的待办不记；集合过期和上限生效。
4. **PII 测试**：构造带可识别字符串的标题和 `dueHint`（如 `"PII_CANARY_标题"`），断言编码后的事件参数里不出现它。
5. `VoiceTodoTests` 全部通过（已知的 CN 时区红灯除外，写明）。

### 人工验收

真机或模拟器各走一遍：说一句含「下周五」的话 → 在确认面板把日期改掉一天 → 确认；再说一句 → 确认后进详情页改日期。
在 Xcode 日志里核对两个事件的参数（不出现标题和原话）。

---

## 7. 约束

- 从最新 `main` 拉新分支（名字自定），**不要直接在 main 上改**；推送分支后交回审查，**不合 main**。
- 不上传、不打日志任何用户内容（见 §0）。
- 不改数据模型，不改解析逻辑，不改确认面板和详情页的界面与交互。
- 提交信息里不要出现模型名称。

---

## 8. 结果格式（`docs/task-parse-correction-telemetry-results.md`）

1. 改动摘要：文件 + 每处一句话。
2. 两个事件的最终参数表（如与本任务书不同，标出差异）。
3. 分类规则的覆盖清单（每种语言每个类型列了哪些关键词）。
4. §6 每条测试的名字；单元测试通过数。
5. 人工验收时日志里的两条事件原样（确认不含用户内容）。
6. 偏离任务书的地方及理由（没有就写「无」）。
