# 任务书:日语测评第二批(节假日表 + 营业日 + 今週中)及一处日语日期丢失 bug

> 2026-11-27 起草。本文档是**交给执行者的任务书**,不是结果。
> 基线:`main`(本任务书所在提交)。
> 完成后写 `docs/eval-ja-batch2-holidays-results.md`(格式见 §10),交回审查。
>
> **流程要求:** 从基线拉分支 `task/eval-ja-batch2-holidays`,改完**只推这个分支,不要合进 `main`**,
> 也不要让别的分支把它带进 `main`。把分支名交回,审过再合。
> Part A(§2)和后面几部分互相独立,**先做 Part A 并单独提交**,方便它先合。

---

## 0. 背景

- 第一批 20 条日语题(`ja-021`~`ja-040`,`AIProxy/eval/dataset.json`)已跑完并入常驻集:最终 prompt
  下全量 97/99,ja 40/40。结论是**这类说法模型本身就会**,第一批只能当回归防线,分不出强弱。
- 第一批故意没放的,才是模型真会错的地方:需要节假日才能算的说法(週明け、N営業日),以及口径没定的
  「今週中」。用户已拍板(见 §1)。
- 设计方向和 `TODOS.md`「解析改两段式」那条一致:**日期推算交给代码**。节假日、营业日、週明け、今週中
  都由服务端算好,作为事实注入 prompt(和现有的「月初/月中/月末/来月1日」注入同一个模式,
  `AIProxy/src/adapters/base.js` `buildSystemPrompt`),模型只负责查表,不心算。
- 写任务书时顺带发现一个**线上 bug**(§2):App 保存待办时,日语里用户明确说了的日期几乎全部被清空。
  测评只测代理输出,所以 ja 40/40 看不出来。

## 1. 已拍板的口径(不要改,有异议写进结果文档)

| 说法 | 口径 | 备注 |
|---|---|---|
| 营业日 | 周一到周五,且不是日本法定节假日(祝日、振替休日、国民の休日) | 年末年始(12/29–1/3)、お盆**不算**节假日,它们不是法定假日 |
| 翌営業日 | 今天之后的第 1 个营业日 | 今天不算 |
| N営業日以内 / N営業日後 | 今天之后的第 N 个营业日 | 今天不算(商务惯例从翌营业日起数) |
| N > 10 | `due_date` = null,basis = `user_explicit`,`due_hint` 保留原话 | 注入表只给 10 个营业日,超出让用户在确认页自己选 |
| 週明け / 来週明け | 今天之后的第一个周一;那天不是营业日就顺延到下一个营业日 | 例:2026-11-18(水)说「週明け」→ 11/23 是勤労感謝の日 → **11/24** |
| 祝日名(「勤労感謝の日に」) | 今天或之后最近的那个同名节假日 | basis = `user_explicit` |
| **今週中** / 这周内 / 本周内 / 这周之内 / 本周之内 / this week(不带星期几、不是 weekend)/ sometime this week / by the end of the week / by the end of this week / within this week | **本周五**(周日起始的本周) | 用户拍板。今天是周六时 → 今天。周五是节假日也**仍算周五**,不顺延 |
| 今週末 / 这周末 / this weekend | 不变:`due_date` = null + `user_explicit` | 和「今週中」区分开 |

不在范围:中文「周中」(= 周三前后,和「今週中」不是一回事)、上旬/中旬/下旬、月初/月半ば、寝る前、
中国节假日与调休、zh/en 的「N 个工作日」。

---

## 2. Part A(先做,独立提交):日语日期在 App 保存时被清空

### 2.1 现象(高度疑似,需先用测试证实)

`Store/SwiftDataModels.swift` `applyDueDateBasisFilter`:AI 标 `user_explicit` 时,只要传了 `rawTranscript`
且 `TodoDueDateResolver.hasExplicitTimeCue(in:)` 返回 false,就把 `dueDate` 清空。在线确认路径
(`AppCoordinator` → `store.addBatch(todos, rawTranscript: confirmSheetTranscript, …)`)和 Siri 路径都会传原文。

但 `hasExplicitTimeCue`(`Protocols/Domain/TodoDueDateResolver.swift` 的 `hasDirectTimeWord` / `daysOffset` /
`weekdayNumber`)**只认中文和英文**,一个日语词都没有,连「明日」都不认。

起草时我用 Python 按 Swift 逻辑等价模拟了一遍,输入是 `dataset.json` 里所有「golden basis = user_explicit
且 due_date 非空」的 case:

- **ja:25/25 会被清空**(ja-001、007、008、009、010、015、016、018、019、021–025、027–036、040)
- en:2 条(`en-010` "this evening"、`en-013` "by the end **of the** month":词表只有 "end of month" / "end of this month")
- zh:1 条(`zh-017` "晚上十点半睡觉":词表有「今晚」没有「晚上」)

### 2.2 要做的

1. **先写失败测试证实**:新建表驱动单测,把 `dataset.json` 里上述所有 case 的 transcript 抄成 fixture,
   断言 `hasExplicitTimeCue == true`;再加几条 `TodoItem.from(extracted, rawTranscript:)` 端到端用例
   (如 ja「明日の午後3時に会議」+ basis user_explicit → dueDate 保留)。在结果文档里贴出修复前的失败数。
   如果实测结论和 §2.1 不一致,**停下来写清楚实测情况,不要硬改**。
2. 修 `hasExplicitTimeCue`:
   - 日语直接时间词:今日、今夜、今晩、明日、明後日、あさって、しあさって、明々後日、N日後、来週、再来週、
     今週(含今週中、今週末)、週明け、営業日、月末、月初、月中、来月、年内、年度末、令和、X月X日,
     以及时段词(朝、午前、午後、昼、夕方、夜)。可复用 `ParseExpressionClassifier.swift` 里已有的 ja 词表,
     不要再抄一份。
   - 日语星期(日曜〜土曜、「金曜」「金曜日」):默认算有线索,但「〜の準備」「〜のため」「〜用の」这类
     目标语义要排除(对应 `ja-006`「日曜日のパーティーの準備をする」必须仍是 false)。
     **不要**把日语星期加进 `weekdayNumber`:`resolve()` 也用它,会改变兜底重算的行为。单独写一个 ja 判断。
   - 中文补「晚上」「这周内/本周内/这周之内/本周之内」「工作日」;英文补 "end of the month"、
     "this evening"、"this week"、"end of the week"、"business day(s)"。
   - 节假日名(勤労感謝の日 等)算有线索。
3. 第 1 步的表驱动测试改成通过。**保持** `ja-006`、`ja-014`、`en-007`、`zh-014` 等 title_mention / 无日期
   case 原有的判定不变(也放进表里,断言 false)。
4. 这是真机行为问题,模拟器上可走键盘输入路径(`BottomInputPanelView`)验证:日语输入
   「明日の午後3時に会議」,确认后待办落在明天 15:00。截图放结果文档。

---

## 3. Part B:日本节假日模块

新建 `AIProxy/src/jpHolidays.js`(纯函数,零依赖,worker 与 eval runner 共用,**只此一份数据源**):

- 按现行《国民の祝日に関する法律》规则生成任意年份(2000–2099)的节假日:固定日期、Happy Monday
  (成人の日 1 月第 2 周一、海の日 7 月第 3 周一、敬老の日 9 月第 3 周一、スポーツの日 10 月第 2 周一)、
  春分/秋分(天文公式)、振替休日(节假日落在周日 → 之后第一个非节假日)、国民の休日(夹在两个节假日之间的非周日)。
- 留一个 `JP_HOLIDAY_OVERRIDES`(增/删)应对特别法临时调整,现在为空。
- 导出:`jpHolidaysBetween(startISO, endISO)`、`isJpBusinessDay(iso)`、`nthJpBusinessDayAfter(iso, n)`、
  `jpWeekStartBusinessDay(iso)`、`thisWeekFriday(iso)`、`nextJpHoliday(iso, name)`。日期一律 `YYYY-MM-DD`,
  UTC 日历运算,和 `buildSystemPrompt` 现有月份事实同口径。
- **单测必须对照官方数据**:内閣府「国民の祝日」CSV(`https://www8.cao.go.jp/chosei/shukujitsu/syukujitsu.csv`)
  的 2026、2027 两年全部条目。起草环境访问不了该站,下面是我按规则算的结果,**只能作为交叉核对用,以官方 CSV 为准**;
  两者不一致时写进结果文档。

<details><summary>起草时按规则算出的 2026–2027 节假日(待对照官方)</summary>

```
2026: 01-01 元日 / 01-12 成人の日 / 02-11 建国記念の日 / 02-23 天皇誕生日 / 03-20 春分の日 /
      04-29 昭和の日 / 05-03 憲法記念日(日) / 05-04 みどりの日 / 05-05 こどもの日 / 05-06 振替休日 /
      07-20 海の日 / 08-11 山の日 / 09-21 敬老の日 / 09-22 国民の休日 / 09-23 秋分の日 /
      10-12 スポーツの日 / 11-03 文化の日 / 11-23 勤労感謝の日
2027: 01-01 元日 / 01-11 成人の日 / 02-11 建国記念の日 / 02-23 天皇誕生日 / 03-21 春分の日(日) /
      03-22 振替休日 / 04-29 昭和の日 / 05-03 憲法記念日 / 05-04 みどりの日 / 05-05 こどもの日 /
      07-19 海の日 / 08-11 山の日 / 09-20 敬老の日 / 09-23 秋分の日 / 10-11 スポーツの日 /
      11-03 文化の日 / 11-23 勤労感謝の日
```
</details>

- 函数级测试向量(全部在 §8 表里,直接抄成单测)。另加:今天是周六/周日时 `thisWeekFriday` 分别为当天/本周五
  (2026-11-21 → 11-21;2026-11-22 → 11-27);2026-11-22(日)的 `jpWeekStartBusinessDay` = 11-24。

## 4. Part C:prompt 注入与规则(三语平行)

### 4.1 注入(`buildSystemPrompt`,today 合法时)

- **ja**:在现有参照日行后追加(措辞可调,信息不能少):
  - 今后 365 天的节假日:`YYYY-MM-DD(曜・名称)` 列表;今天本身是节假日时注明。
  - 今后 10 个营业日:`YYYY-MM-DD(曜)` 列表,第 1 个即翌営業日。
  - `週明け=YYYY-MM-DD`、`今週中=YYYY-MM-DD(今週の金曜日)`。
- **zh / en**:只追加 `这周内=YYYY-MM-DD(本周五)` / `this week (by Friday)=YYYY-MM-DD`。不注入日本节假日。
- 注入算不出(today 非法、年份超出 2000–2099)时不注入、不 500,打一条 warn 日志,行为同现有月份事实的兜底。

### 4.2 规则(三语 prompt 的「曖昧な日付の換算約束」区及对应的中英文段落)

- ja:「翌営業日」= 营业日表第 1 个;「N営業日以内/後」= 第 N 个,N > 10 → due null + user_explicit;
  「週明け」「来週明け」= 注入的 週明け;祝日名 = 节假日表里今天或之后最近的同名日;「今週中」= 注入的 今週中。
  全部 basis = `user_explicit`,`due_hint` 保留原话。**明确写:这些日期只能取注入行里的值,不要自己推算。**
- zh / en:§1 表里「今週中」那一行列出的说法 → 注入的周五日期,basis `user_explicit`;和「这周末 / this weekend」
  (仍为 null)的对比写清楚。
- 各语言加 1–2 个 few-shot 例子,例子里写明「参照行で 週明け=… と仮定」这类前提,日期要和例子的参照日自洽
  (上次 review 就抓到过例子日期算错,写完逐个复核)。

### 4.3 测试(`AIProxy/worker.test.js`)

- 用 §8 的固定日期断言 ja 注入行的内容(节假日、营业日列表、週明け、今週中),zh/en 注入的周五日期。
- 断言 zh/en prompt **不**含日本节假日。

## 5. Part D:eval runner(`AIProxy/eval/run.mjs`)

1. **带参数的日期规则 tag**:在 `DATE_RULE_TAGS` 机制上支持 `名称:参数`,新增
   `jp-bizday:N`、`jp-week-start-bizday`、`jp-holiday:<祝日名>`,实现**调用 `../src/jpHolidays.js`**,不另写一份。
   一个 case 仍然最多一个日期规则 tag,作用于该 case 所有非 null 的 due_date。
   「今週中=周五」不需要 tag:锚永远是周三,周五 = +2,均匀平移就对。
2. **过关线按白名单自动算**:`dataset.meta` 加 `known_hard: ["zh-017", "ja-014"]`;case 带 `observation` tag 的
   也不进分母、单独列出。报告多打一行:
   `gate: 分母 n(全部 − known_hard − observation),失败 k,允许 ⌊n×2%⌋ → PASS/FAIL`。
   这一行就是 README §4.1 的判法,README 同步改成「以 gate 行为准」。
3. **固定锚**:新增 `--anchor YYYY-MM-DD`,**只允许和 `--provider-file` 一起用**(HTTP 端点模式下 worker 的
   ±1 天漂移校验会拒),且必须是 `meta.anchor_weekday`(周三)。实现方式:`worker.js` 导出测试钩子
   `_testSetServerToday(isoOrNull)`(同现有 `_testReset*` 系列),`resolveQuotaDate` 的 serverToday 优先取它;
   进程内 transport 在发请求前设好。**不要**用 env 变量开关(会被误配到生产);加一条 worker 测试证明不设钩子时行为不变。
   `--resume` 时锚以落盘为准,和 `--anchor` 冲突就报错。

## 6. Part E:新题(全部先带 `observation` tag)

日期按 authoring 锚 2026-01-07(周三)写,其他锚下由 runner 按 tag 重算(§8 有各锚期望值)。
以下所有 todo 未列出的字段都是:`due_time`/`time_bucket`/`recurrence_rule`/`recurrence_end`/`reminder_times` = null,
`priority` = `"normal"`,`ignored` = `""`。日语原文和期望值由起草者按母语用法判断过,**不要改写 transcript**。

| id | transcript | 日期规则 tag | todo(title / due_date / due_hint / basis / category) |
|---|---|---|---|
| ja-041 | 週明けに見積もりを送る | jp-week-start-bizday | 見積もりを送る / 2026-01-13 / 週明け / user_explicit / work |
| ja-042 | 来週明けに部長に報告する | jp-week-start-bizday | 部長に報告する / 2026-01-13 / 来週明け / user_explicit / work |
| ja-043 | 翌営業日までに先方に返信する | jp-bizday:1 | 先方に返信する / 2026-01-08 / 翌営業日までに / user_explicit / work |
| ja-044 | 3営業日以内に議事録を共有する | jp-bizday:3 | 議事録を共有する / 2026-01-13 / 3営業日以内に / user_explicit / work |
| ja-045 | 5営業日後に検品結果を連絡する | jp-bizday:5 | 検品結果を連絡する / 2026-01-15 / 5営業日後 / user_explicit / work |
| ja-046 | 15営業日以内に契約書を返送する | (无) | 契約書を返送する / null / 15営業日以内に / user_explicit / work |
| ja-047 | 勤労感謝の日に実家に帰る | jp-holiday:勤労感謝の日 | 実家に帰る / 2026-11-23 / 勤労感謝の日 / user_explicit / social |
| ja-048 | スポーツの日に市民マラソンに出る | jp-holiday:スポーツの日 | 市民マラソンに出る / 2026-10-12 / スポーツの日 / user_explicit / health |
| ja-049 | 今週中に企画書を仕上げる | (无) | 企画書を仕上げる / 2026-01-09 / 今週中に / user_explicit / work |
| ja-050 | 今週中に部屋を片付ける | (无) | 部屋を片付ける / 2026-01-09 / 今週中に / user_explicit / life |
| ja-051 | 今週中に企画書を仕上げて、今週末は部屋を片付ける | (无) | ① 企画書を仕上げる / 2026-01-09 / 今週中に / user_explicit / work ② 部屋を片付ける / null / 今週末 / user_explicit / life |
| ja-052 | 週明けに取引先に電話して、見積もりを送る | jp-week-start-bizday | ① 取引先に電話する / 2026-01-13 / 週明け / user_explicit / work ② 見積もりを送る / 2026-01-13 / 週明け / user_explicit / work |
| zh-028 | 这周内把方案写完 | (无) | 把方案写完 / 2026-01-09 / 这周内 / user_explicit / work |
| zh-029 | 本周之内去趟银行 | (无) | 去趟银行 / 2026-01-09 / 本周之内 / user_explicit / finance |
| en-033 | Finish the slide deck sometime this week | (无) | Finish the slide deck / 2026-01-09 / sometime this week / user_explicit / work |
| en-034 | Clean out the garage by the end of the week | (无) | Clean out the garage / 2026-01-09 / by the end of the week / user_explicit / life |

说明:
- `detail` 填原句(多 todo 时填该 todo 对应的分句),不评分。
- authoring 锚 2026-01-07 下,週明け 正好撞上 1/12 成人の日 → 1/13,3営業日 也因此是 1/13。
  这正是要测的,**不要**为了好看换锚。
- 多 todo case 只放「所有 todo 同一日期规则」的组合(ja-052),或不需要 tag 的组合(ja-051);
  混合规则的 case 现在的 runner 不支持,不要加。
- 加完题后更新 `meta.notes` 和 README §6/§7(新 tag、`observation`、`known_hard`、`--anchor`)。

## 7. Part F:客户端审计器防误纠

`Protocols/Domain/ExtractDateAuditor.swift` 对零歧义 token(今日/明日…)会在开关打开时**改写**模型日期。
「明日から3営業日以内」这种 hint 会先命中「明日」被按 +1 天纠正。在 `parse()` 第 2 步后缀守卫里加
「営業日」「工作日」「business day」→ ambiguous,并加单测。§6 里的 hint 本身(週明け、今週中、这周内、
sometime this week、翌営業日、祝日名)按现有逻辑都落 ambiguous 或无日期表达,不会被纠,也加单测钉住。

## 8. 测试向量与验收跑测

### 8.1 各锚期望值(Part B 单测 + 固定锚 eval 共用)

| 锚(都是周三) | 翌営業日 | 3営業日 | 5営業日 | 15営業日 | 週明け | 今週中 | 次の勤労感謝の日 | 次のスポーツの日 |
|---|---|---|---|---|---|---|---|---|
| 2026-01-07 | 01-08 | 01-13 | 01-15 | 01-29 | 01-13 | 01-09 | 2026-11-23 | 2026-10-12 |
| 2026-04-29(当天是昭和の日) | 04-30 | 05-07 | 05-11 | 05-25 | 05-07 | 05-01 | 2026-11-23 | 2026-10-12 |
| 2026-09-16 | 09-17 | 09-24 | 09-28 | 10-13 | 09-24 | 09-18 | 2026-11-23 | 2026-10-12 |
| 2026-11-18 | 11-19 | 11-24 | 11-26 | 12-10 | 11-24 | 11-20 | 2026-11-23 | 2027-10-11 |
| 2027-01-06 | 01-07 | 01-12 | 01-14 | 01-28 | 01-12 | 01-08 | 2027-11-23 | 2027-10-11 |

2026-11-18 起的 10 个营业日:11/19 11/20 11/24 11/25 11/26 11/27 11/30 12/1 12/2 12/3。
2026-04-29 起:4/30 5/1 5/7 5/8 5/11 5/12 5/13 5/14 5/15 5/18。

### 8.2 跑测

1. 单测:`cd AIProxy && npm test`(报执行/失败数);Swift:`cd VoiceTodo && arch -arm64 swift test`
   (已知基线失败 `TodoDueDateShifterTests.testDSTSpringForward_fallsBackToMidnight`,不算回归)。
2. eval(UTC 周二–周四窗口内,用现行主力的 provider 模板,进程内模式):
   - 动态锚跑一轮全量(`node run.mjs --provider-file … --label b2-dyn`),gate 行 PASS,且**既有 99 条无回归**。
   - 固定锚各跑一轮,只需新题:`--anchor 2026-11-18`、`2026-09-16`、`2026-04-29`、`2027-01-06`
     (可加 `--dataset` 指向只含新题的临时文件,**不要提交**该临时文件)。
3. 准入:新题在动态锚 + 4 个固定锚下全对,或失败已逐条归因(改 prompt / 改 golden,改 golden 必须说明理由)。
   准入后去掉 `observation` tag,这一步**单独一个提交**。

## 9. 不要做

- 不改第一批及更早题目的 golden。
- 不碰 §1「不在范围」里的说法。
- 不把节假日表写进 iOS 客户端(这次只在服务端注入);不改 ConfirmSheet。
- 不切生产主力、不动 `wrangler.toml` 的 PROVIDERS;`prod-date-battery.py` 不在本任务范围(它本身缺变量定义跑不起来,另开任务)。
- 不重排 `dataset.json`(手工排版格式,只做单点文本插入)。

## 10. 结果文档格式(`docs/eval-ja-batch2-holidays-results.md`)

1. 分支名、各 Part 的提交 hash。
2. Part A:修复前失败测试数、修复后结果、模拟器截图;与 §2.1 不一致之处。
3. Part B:与官方 CSV 的对照结论(逐条一致/列出差异)。
4. 改动文件清单与一两句说明;prompt 增加的字符数(三语各多少)。
5. 单测执行/失败数(JS、Swift)。
6. eval:动态锚 gate 行原文 + 4 个固定锚的新题结果表;失败逐条归因。
7. 和任务书不一致的地方、自己做的判断,逐条写明。
