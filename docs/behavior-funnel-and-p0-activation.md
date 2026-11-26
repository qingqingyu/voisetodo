# 行为漏斗读数与 P0 激活实验规格

- 状态:**草案,2026-11-26 已过一轮代码事实核查并修订**(修订明细见 `docs/behavior-funnel-factcheck-results.md`)
- 日期:2026-11-07 起草 / 2026-11-26 修订
- 目的:支撑软启动 4 周窗口内的「找激活时刻 → 小实验放大」两步(增长方法论第三/四步),让漏斗与留存读数**开箱可查**,并定义第一个激活实验。
- 关联文档:`TELEMETRY.md`(事件口径)、`PROMOTION_PLAN.md`(漏斗与 KPI)、`docs/onboarding-first-voice-trial.md`(first_voice_trial 设计)、`docs/day-clock-day-boundary-inconsistencies.md`(日界教训)

---

## 0. TL;DR 与两处修正

> **修正一**:此前讨论曾说「需要新建一张 events 表」——不准确。`telemetry_events` **本身就是事件级表**(`device_id` 哈希 + `session_id` + 事件名 + 脱敏 params),漏斗事件(`onboarding_step`、`first_voice_trial`、`paywall_shown` 等)大多已存在。
>
> **修正二(2026-11-26 核查)**:初稿默认 `received_at` ≈ 事件发生时间——**不成立**。客户端只在「充电 + 联网」时由后台任务批量上报(`App/TelemetryUploader.swift:82-83`),服务端给同批事件写同一个 `received_at`(`AIProxy/worker.js:780`)。直接用 `received_at` 会:TTFT 恒为 0、day0 归属漂移、多天捕捉压成一天。**分析一律改用 `event_timestamp`**(worker 已存,缺失时回落 `received_at`,见附录 A 前导)。
>
> 本规格做四件事:
>
> 1. **补一个维度**:设备语言(§3 G1);
> 2. **把查询写出来**:留存 / TTFT / 首条闭环漏斗的 SQL 给全(§3 G2、附录 A,已按核查口径重写);
> 3. **定义 P0 实验**:假设、读数、改动、止停线(§4);
> 4. **附带一个前置读数**:自然捕捉节奏分布(§4.5 / A8),为软启动后的习惯追踪器定链频率备料。
>
> 不新建表、不引入第三方分析 SDK、不动 App Store 隐私营养标签与 xcprivacy(§5)。
> 「事件采集层零新增」的初稿结论**不成立**:A7 依赖一个从未发送的值(§2.2),上报机制本身也需先修(§6 步 0)。

## 1. 背景与目标

PROMOTION_PLAN.md 已定义漏斗 `install → first_record → wow_shown → quota_hit → trial → paid` 与 KPI(install→first_record >60% 等),但其中「留存」「首条耗时」「按语言切分」三类读数目前**算不出来**——不是数据没采,是缺维度、缺查询。

本规格回答三个问题:

1. 现有数据能算什么?(§2)
2. 缺什么、怎么补?(§3)
3. 第一个实验做什么、怎么读数?(§4)

## 2. 现状盘点:已有哪些资产

### 2.1 表结构(`AIProxy/schema.sql` → D1 `voicetodo-telemetry`)

```
telemetry_events(
  received_at     服务端毫秒时间戳(同批上报的事件相同——是「接收」时刻,不是「发生」时刻)
  event_name      事件名
  event_timestamp 客户端毫秒时间戳(worker 落库,缺失时已回落为 received_at,worker.js:789)
  session_id      每次启动 UUID(不持久化)
  device_id       sha256 哈希设备标识
  app_version / ios_version
  params          脱敏 JSON(仅枚举/数字,PII 红线见 TELEMETRY.md)
  extract_id      提取链路关联 ID
)
```

数据保留 90 天(每日 GC),对 4 周窗口绰绰有余。已有索引覆盖 device / event / received_at / session / extract。

### 2.2 漏斗相关事件清单(全部已上线;口径按 2026-11-26 代码核查修正)

| 漏斗环节 | 事件 | 关键口径(详见 TELEMETRY.md,此处只列分析要点) |
|---|---|---|
| 留存锚点 | `app_launch(coldLaunch, hasCompletedOnboarding)` | 冷热启动可分;**装机锚点 = 最早一次 `hasCompletedOnboarding=false` 的 `event_timestamp`**(§A1;无此事件的设备 = 升级/老用户,不进 cohort) |
| 引导漏斗 | `onboarding_step(step)` | 每次进入记一枚,**分析按 step 去重**;`actionButton` 步只在支持的机型出现,A2 里它的设备数天然偏低,勿误读为该步流失 |
| 首条闭环 | `first_voice_trial(armed / hint_shown / dismissed / completed)` | `completed` **混入键盘输入**;`dismissed/armed` 是必盯比值;权限没给全时也会记 `armed`;`hint_shown` 每次启动最多一条(会话级曝光,不是展示次数) |
| 录音路径 | `recording_started(source)` / `recording_outcome` / `recording_failed(reason)` | **实际只发 `button` / `action_button`**(`AppCoordinator.swift:433`;枚举里的 `manual_input` 已定义未发送,键盘路径不记本事件)。键盘兜底的可观测信号是 `extract_outcome(path='keyboard')`。`reason` 是错误 case 名 |
| 保存 | `todo_saved(source, count)` | **实际只发 `confirm` / `siri_add`**;枚举里的 `widget_toggle` 已定义未发送,且「切换完成状态」不算捕捉,即便将来发送也不进 R1/R4。覆盖面见 §4.5 |
| 键盘/兜底 | `extract_outcome(path)` | path=`live_voice / keyboard / …`;键盘兜底率读它(§A7)。`reason` 不在本事件参数里(它属于 `extract_failed` / `recording_failed`) |
| 变现 | `paywall_shown(source)` + `purchase_*` 五事件 | 四来源由 `presentPaywall(source:)` 统一收口 |
| 复盘 | `review_entry_impression / review_flow_started / review_flow_finished` | 曝光 session 去重;started 记在首次呈现 |

**结论(2026-11-26 修正)**:事件名层面不需要新增;但「采集零改动」不成立——
1. A7 的键盘兜底读数依赖从未发送的 `recording_started(source=manual_input)`,已改走 `extract_outcome`(§A7);
2. 上报机制需先修两处丢数据/偏差(§6 步 0 的 M1/M2),否则基线本身失真。

## 3. 缺口与补法

### G1(代码改动):缺「设备语言」维度

`telemetry_events` 没有语言列;唯一带 `locale` 的是 `parse_confirmed` / `parse_field_corrected` 的 params——但那是**内容语言**(用户说了什么语言,跟随输入),而漏斗/留存切分需要**设备语言**(哪个市场的用户)。

> ⚠️ 项目已拍板「内容语言与系统语言解耦」(二者不同是正常场景,不是 bug 归因),因此**不能复用 params.locale**,必须独立维度。

**取值源(2026-11-26 拍板,附录 B-3)**:`Locale.preferredLanguages.first`(**设备**首选语言),分桶 `zh / en / ja / other`(命名对齐 `parse_confirmed` 的 `zh`,不用 `zh-Hans`)。不用 App 展示语言(`Bundle.preferredLocalizations` / `Locale.current` 是解析后的回落结果,韩语/德语用户会被折成 `en`,恰好抹掉「非目标市场」这个按市场切分要看的信号;展示语言可从设备语言推导)。zh-Hant 是否单独分桶,待有港台市场数据再定。

**改动面(2026-11-26 核查补全,初稿写漏三处)**:

- D1:`ALTER TABLE telemetry_events ADD COLUMN device_locale TEXT;`(幂等注意:重复执行报 duplicate column,迁移一次)
- **`AIProxy/worker.js` 的 INSERT 语句加列 + 服务端取值白名单校验**(枚举外一律 NULL)——不加则新列永远是 NULL;
- **`AIProxy/schema.sql` 的 `CREATE TABLE` 本体同步加列**——否则新建的库没有这一列;
- 客户端:`TelemetryPayload` 增加 `deviceLocale` 字段,按上述分桶收敛(避免自由字符串);
- **`PRIVACY_POLICY.md` 同版本同步更新**(文件头注释要求字段变化须随同一 release 更新该页;现逐项列出上报字段);
- 文档:`TELEMETRY.md`「✅ 可上报」清单登记。

**隐私影响**(§5 详述):与 `ios_version` 同级的粗维度,不新增数据类型。**不要**用 `UITextInputMode.activeInputModes` 推断语言——它属于「active keyboards」类 Required-Reason API,用了就要申报;`Locale.preferredLanguages` 不在需申报清单。

### G2:分析查询未成文

留存(W1/W4)、TTFT(time-to-first-todo)、首条闭环率、onboarding 漏斗的 SQL 一条都不存在。附录 A 给全(**2026-11-26 已按核查口径重写**:event_timestamp 时间基准、装机锚点、cohort 闸门);其中高频三条建议追加到 `schema.sql` 注释区(与现有 DAU 示例并列;DAU 示例用 `received_at` 看接收量,需加一行注释说明它只适合看接收量、不适合看行为)。**不建视图、不建物化表**——软启动量级下手跑 `wrangler d1 execute` 即可。

### G3:时间与日界口径(2026-11-26 重写)

- **分析时间基准一律 `event_timestamp`**(客户端事件时刻;worker 已做缺失回落)。再钳一层异常:早于上线日或晚于 `received_at`(客户端时钟被手动调过)的值回落 `received_at`——见附录 A 通用前导。`received_at` 只用于「接收量」类运维读数;
- 分析侧 **UTC 日界**;App 内业务日界是 day-clock 本地日界,**两套口径不混用**(教训见 `docs/day-clock-day-boundary-inconsistencies.md`);
- 「新用户」= **装机锚点**(`app_launch(hasCompletedOnboarding=false)` 的最早 `event_timestamp`,§A1)所在 UTC 日 = cohort day0。初稿的「窗口内首见事件日」会被上报延迟漂移(隔夜充电才上报 → day0 归属漂一天)。90 天 GC 会使极老用户误判为新用户——4 周窗口内无影响,记录为已知局限;
- **cohort 闸门**:cohort 类读数(A2–A5、A8)过滤 `d0 >= 上线日`;A1 全量列出锚点日供核对;A6 是按语言的设备普查(不分 cohort,切片时按其注释 JOIN install 后同理可加过滤);A7 是行为兜底率(不分新老用户)。另需维护**内测/开发设备排除清单**(哈希后的 device_id,前导占位)——D1 遥测上线早于软启动,内测机与 TestFlight 数据会混入 cohort(核查实测 11-01 的内测机同时污染 A4/A5)。

### 已知局限(不接受 review 挑战的部分,已拍板/已接受)

- **上报幸存者偏差(M1,2026-11-26 新增)**:只在「充电 + 联网」时上报,首日装完就走、当场删 App 的用户,本地队列随 App 删除而消失,永远进不了 D1——「装了没激活就走」的人系统性缺失,R1 偏高,R3「未激活」组失真。这与「关闭遥测的幸存者偏差」是两回事。修法见 §6 步 0;
- **关闭遥测的用户完全不可见**,留存读数偏向活跃人群;
- **device_id 换机即换人**:重装/换设备会当新用户,与 ASC 口径有差,趋势读数够用;
- 小样本下不追求统计显著(§4.4 纪律)。

## 4. P0 实验:「首条语音待办闭环」

### 4.1 假设

> 新用户在首次打开的几分钟内完成一次「录音 → 看到 AI 解析出的待办卡 → 确认添加」,这一瞬间(下称**首条闭环**)是决定留存的激活时刻。

与 PROMOTION_PLAN 漏斗的 `install → first_record → wow_shown` 同源;本实验是把它从「KPI 数字」升级为「可对比、可干预的因果假设」。

### 4.2 验证读数(SQL 见附录 A)

| 读数 | 定义 | 查询 |
|---|---|---|
| **R1 首日首条闭环率** | cohort **day0** 内出现 `todo_saved` 的设备占比 | A3 |
| **R2 TTFT** | 装机锚点 → day0 首条 `todo_saved` 的中位分钟数 | A4 |
| **R3 W1 留存分组对比** | **day0 闭环 vs day0 未闭环**两组,`[t0+7d, t0+14d)` 内有 `app_launch` 的设备占比;分母只含已满观察窗(+上报滞后)的 cohort | A5 |

**口径声明**:R1 的「闭环」**含键盘兜底**(权限被拒后走键盘也算)——激活的定义是「拿到了第一份价值」,不是「用了麦克风」。语音占比用 `extract_outcome(path='live_voice')` 单独看一个**纯语音子指标**(B-1 裁决:不另立 R1',但 C1 的有效性不能被键盘用户稀释,读数时并列看)。

**判定(2026-11-26 修订)**:初稿「R3 两组差 ≥15pt 则假设成立」**不可证伪**——愿意激活的用户本来就更可能留下,两组出差异几乎是必然,「否则换 P1」的退路永远不会触发。改为:**假设是否成立看 C1 上线前后的因果对比**(同 §4.4 前后对照):C1 上线后新 cohort 的 R1 / 先行指标位移达到 §4.4 阈值,才说「首条闭环是可放大的激活时刻」;R3 仅作描述性参考,不再作闸门。

**先行指标(2026-11-26 新增;M4 = 核查报告的时间线风险项「W1 成熟太慢」)**:W1 要等 `t0 + 14 天 + 约 3 天上报滞后`才可读——4 周窗口内能读到 W1 的 cohort 极少(以 11-20 为截止跑修正版 A5 结果为空)。窗口内用 **「第 1–6 天回访率」**(`app_launch`,A5 改窗口参数即得)做快速信号。

### 4.3 放大改动(实验变量,一次只上一个)

| # | 改动 | 现有读数支撑(改动前就能量化「值不值得做」) |
|---|---|---|
| **C1** | onboarding 演示页之后**直接引导录第一条**,不插额外说明 | A2 onboarding 漏斗:演示页 → 首录之间的流失步 |
| **C2** | 麦克风/语音权限被拒时**立即**落到键盘输入路径(不卡死在授权页) | A7(已重写):`recording_failed(reason ∈ {microphonePermissionDenied, speechRecognitionPermissionDenied})` 的设备中,后续 `extract_outcome(path='keyboard')` 的占比——占比低说明兜底没兜住 |

C1/C2 可解耦(C1 改演示页之后的首页引导,C2 改权限被拒分支),**默认分版上线**;若必须同版,按权限子群分开读,且前提是 A7 已能分出被拒子群 + 补上 onboarding 内拒权限的可观测性(现在 onboarding 里直接拒权限的用户可能不触发 `recording_failed`——不走 `startRecording`,A7 分母天然缺失,这是已知盲区)。

改动进新版本后,用 `app_version` 列切前后 cohort 对比(见 4.4)。

### 4.4 实验纪律(小样本,4 周窗)

1. **不跑 A/B 分流**:软启动量级下分流读不出差异。用**前后对照 + `app_version` cohort 切分**;时间混杂(周内效应、渠道效应)作为已知噪声接受,每周固定动作相同可部分对冲(PROMOTION_PLAN §3)。
2. **只认大位移**:R1 类比率指标,位移 <5 个百分点视为噪声;回访率/W1 位移 <3 个百分点视为噪声。
3. **样本门槛**:任一组 cohort <30 时,只报原始数、不下结论。
4. **一次一变量**:C1、C2 不同时上(若必须同版,见 §4.3 的分群读数前提)。
5. **上线日 = 基线起点**:先攒 1 周基线再上 C1/C2(PROMOTION_PLAN Week 1 本就是容错最高的 r/iosapps,基线期与其重叠)。**前提是步 0(M1/M2)已上线**——否则「零改动攒基线」攒出来的基线本身带系统性偏差。

### 4.5 附带读数:自然捕捉节奏(习惯追踪器的前置观察)

软启动后的候选功能「习惯追踪器」(复盘页内)第一条习惯是**每日捕捉**——每天记 ≥1 条,语音/键盘/Siri/Widget 皆算。链的目标频率必须贴自然节奏设计:比自然节奏高一档是激励,高两档就是断链挫败制造机。**因此先读数、后定链频率**——不先建功能。

- **R4 捕捉节奏分布**:每设备每自然周「有捕捉的天数」的分布(查询 A8)。
- 解读:众数 ≈ 6–7 天/周 → 「每日链」成立;3–5 天 → 改「周目标 N 天」型链;≤2 天 → 习惯链暂缓,先回到激活问题(P0)。

口径声明:

- **观察口径**(遥测侧,仅本读数):「捕捉日」= 当日出现过 `todo_saved` 的 UTC 日;分析周用 ISO 周 `%G-W%V`(2026-11-26 修正:初稿 `%W` 不是 ISO 周,跨年会把一周拆成两半),与产品复盘的周日始口径**不同**——本读数只看分布形状,不与产品周数对齐。三个已知偏差:**一次都没捕捉的周不会出现在结果里**,装机当周与当前周是残缺周,读分布时排除两端;UTC 分日对 UTC+9 的早晨捕捉会归到前一天(偏差声明;G1 落地后可按 `device_locale` 做 +8/+9 近似校正,或维持声明);
- **`todo_saved` 覆盖面(2026-11-26 按代码核实,原开放问题 B-7 结案)**:Siri 全覆盖(同意 gate 原文保存与兜底保存都发,`AddTodoIntent.swift:52/184`);键盘走确认面板,覆盖;**App 内离线原文保存不覆盖**(`TodoStore.swift:202` 不发事件,要等补解析确认时才记一次 confirm——捕捉日被挪到恢复那天);Widget 无添加入口,`widget_toggle` 也无人发。**裁决:软启动阶段接受 R4 因此系统性低估捕捉日,口径照此写死;要让 R4 更准,再给离线原文保存补一个 `source` 值**(进 §6 步 0 之后的低优先级小改);
- **习惯链本体的口径**(实现时):以本地 SwiftData 创建时间为准——按创建日挂、不按 due date(「想到」≠「排期」)、四来源全收、离线兜底(needsAIProcessing)也算,与「永不丢话」原则同构:记了就是胜利,不问后续。断链宽容沿用复盘 streak 既有设计(`ReviewAggregator`:今天未记不算断,从最近有捕捉的那天往回数);封顶对齐复盘 streak 拍板,不另立第二套 streak 口径。

## 5. 隐私论证(为什么不动营养标签 / xcprivacy)

1. **不新增事件、不新增内容字段**:params 仍全为枚举/数字,PII 红线(TELEMETRY.md)不变;
2. `device_locale` 是四值枚举的系统语言,与已上报的 `ios_version`、`device_id` 哈希同敏感级;Apple 数据类型清单里没有「语言」类,作为分析维度挂在已申报的 **Other Usage Data(用途 Analytics)** 下即可。取值只用 `Locale.preferredLanguages`(G1 拍板;即便将来改用 `Bundle.preferredLocalizations`,同样**不属于** Required Reason API),`NSPrivacyAccessedAPITypes` 不动(不要用 `UITextInputMode.activeInputModes`,它属 active keyboards 类,需申报);
3. **opt-out 已有**:设置页开关(`TelemetrySettings`),关闭即完全不上报;
4. ASC 申报口径实际是**四类数据**:`Device ID`、`Purchase History`、`Other User Content`、`Other Usage Data`(见 `PrivacyInfo.xcprivacy` 与 `APPSTORE_REVIEW_KIT.md` §2;初稿写成「标识符 + 使用数据」两类,已更正)——**数据类型与接收者都没变**,故营养标签与 xcprivacy 不动。这也是与引入 Mixpanel/PostHog 的本质区别(第三方接收者变更才需要重申报);
5. **`PRIVACY_POLICY.md` 必须同版本更新**(G1 落地时):该页逐项列出上报字段,文件头注释要求变化随同一 release 更新。

> 留档(超出本规格,建议另开 issue):`PRIVACY_POLICY.md` 写设备 ID「hashed before leaving your device」,实际客户端发的是原始随机 UUID(`X-Device-ID` 头),加盐哈希在服务端做(`worker.js` 的 `safeDeviceId`——行号会随其他分支合并漂移,以函数名为锚)。随机 UUID 非硬件标识、风险低,但描述与事实不符,应择机修正文案。

## 6. 落地顺序(每步独立可回滚;2026-11-26 重排)

| 步 | 内容 | 改动面 | 时机 |
|---|---|---|---|
| **0** | **M1 + M2 上报修复(基线可信的前提)**:M1 = App 进后台时(`VoiceTodoApp.swift:415` 已有分支)用 `beginBackgroundTask` 补一次 `uploadBatch`,不再只等「充电+联网」;M2 = 客户端按 `TelemetryQueue.maxBatchSize = 100` 分批 drain(服务端每批只收前 100 条,`worker.js:40/764`,超发静默丢;常量已定义从未使用)+ 429 时**不丢整批**(保留事件,次日重试;现状 `TelemetryUploader.swift:174` 整批清空)。另:本地队列 7 天过期、上限 500(`TelemetryQueue.swift:67-73`),补报拖延超 7 天的事件会被 GC——M1 的后台补报同时也是这条丢失路径的缓解 | App 侧 Swift(+ 代理侧无),单独 PR,自带测试 | **先于/伴随基线期** |
| 1 | 附录 A SQL 启用,攒基线(R1/R2 + 第 1–6 天回访率 + A7;W1 待 cohort 成熟) | 零改动(手跑查询,口径已修正) | 上线日起 |
| 2 | G1 `device_locale` 列 + 客户端字段 + worker INSERT/白名单 + schema.sql 本体 + PRIVACY_POLICY.md + TELEMETRY.md | 见 §3 G1 改动面清单 | 随下一版 App |
| 3 | 按 §4.2 修订后的判定(C1 前后对比)决定放大;成立则上 C1(或 C2) | onboarding/权限分支 UI,单独 PR | 基线满 1 周后 |

**时间线现实(M4)**:W1 读数要等 `t0 + 14 天 + ~3 天上报滞后`;C1 在基线满 1 周后上线,它的 W1 在 4 周窗口内基本读不到——窗口内用 R1、R2 和第 1–6 天回访率判断,W1 只做终局确认。

---

## 附录 A:查询集(D1 / SQLite,毫秒时间戳,UTC 日界;2026-11-26 按核查口径重写)

> 占位 `'2026-11-07'` 处替换为实际上线日;所有查询假设窗口内数据未被 GC(90 天保留)。
> **通用前导(拼进每条查询的 WITH 开头)**:

```sql
-- LAUNCH 替换为上线日;EXCLUDED_DEVICES 替换为内测/开发设备排除清单(哈希 device_id,
-- 与上线日过滤一起用;清单建立前可先置空跑通再补——SQLite 的 NOT IN () 合法,恒真)。
-- 拼接注意:前导最后的 install CTE 与各查询自带的 CTE(cohort/denied/cap_days…)之间
-- 需补一个逗号;A1 无自带 CTE,前导后直接跟 SELECT 即可。
WITH ev AS (
  SELECT device_id, event_name, params,
         CASE WHEN event_timestamp >= strftime('%s','2026-11-07') * 1000
               AND event_timestamp <= received_at
              THEN event_timestamp ELSE received_at END AS ts
  FROM telemetry_events
  WHERE device_id NOT IN (/* EXCLUDED_DEVICES */)
),
install AS (
  -- 装机锚点:最早一次「未完成 onboarding 的启动」。升级/老用户没有该事件 → 不进 cohort。
  SELECT device_id, MIN(ts) AS t0
  FROM ev
  WHERE event_name = 'app_launch'
    AND json_extract(params, '$.hasCompletedOnboarding') = 0
  GROUP BY device_id
)
```

### A1 每日新设备(cohort)

```sql
SELECT date(t0/1000, 'unixepoch') AS d0, COUNT(*) AS new_devices
FROM install GROUP BY d0 ORDER BY d0;
```

### A2 onboarding 漏斗(按 step 去重)

```sql
cohort AS (SELECT device_id, t0 FROM install WHERE date(t0/1000,'unixepoch') >= '2026-11-07')
SELECT json_extract(e.params, '$.step') AS step,
       COUNT(DISTINCT e.device_id) AS devices
FROM ev e JOIN cohort c USING(device_id)
WHERE e.event_name = 'onboarding_step'
  AND date(e.ts/1000, 'unixepoch') = date(c.t0/1000, 'unixepoch')
GROUP BY step ORDER BY devices DESC;
-- 按 devices DESC 排序(不是步骤序),读漏斗时按 onboarding 实际步序对齐;
-- actionButton 步只在支持的机型出现,设备数天然偏低,勿读成流失。
```

### A3 首日首条闭环率(R1)

```sql
cohort AS (SELECT device_id, t0 FROM install WHERE date(t0/1000,'unixepoch') >= '2026-11-07'),
activated AS (
  SELECT DISTINCT e.device_id
  FROM ev e JOIN cohort c USING(device_id)
  WHERE e.event_name = 'todo_saved'
    AND date(e.ts/1000, 'unixepoch') = date(c.t0/1000, 'unixepoch')
)
SELECT COUNT(*) AS cohort_size,
       (SELECT COUNT(*) FROM activated) AS activated_day0,
       ROUND(100.0 * (SELECT COUNT(*) FROM activated) / COUNT(*), 1) AS rate_pct
FROM cohort;
-- 只看 todo_saved:first_voice_trial(completed) 必然伴随一次 confirm 保存
-- (HomeView.swift:1338-1351,核查确认),初稿的 OR 条件冗余,已去。
```

### A4 TTFT 中位分钟数(R2,小样本直接看分布)

```sql
cohort AS (SELECT device_id, t0 FROM install WHERE date(t0/1000,'unixepoch') >= '2026-11-07'),
first_todo AS (
  -- R2 口径是「day0 首条」:只取装机当日的保存,day1 及以后才首存的设备不进分布
  SELECT e.device_id, MIN(e.ts) AS t
  FROM ev e JOIN install i USING(device_id)
  WHERE e.event_name = 'todo_saved'
    AND date(e.ts/1000, 'unixepoch') = date(i.t0/1000, 'unixepoch')
  GROUP BY e.device_id
)
SELECT f.device_id, CAST((ft.t - f.t0)/60000 AS INTEGER) AS minutes
FROM cohort f JOIN first_todo ft USING(device_id)
ORDER BY minutes;
-- 样本 >50 后可加 NTILE(4) 看 P25/P50/P75;NTILE 是等频桶,不是精确分位数。
```

### A5 W1 留存分组对比(R3;窗口参数改小即得「第 1–6 天回访率」先行指标)

```sql
cohort AS (
  SELECT device_id, t0 FROM install
  WHERE date(t0/1000,'unixepoch') >= '2026-11-07'
    -- 只读已满观察窗的 cohort:W1 = [7d,14d),再加约 3 天批量上报滞后
    AND date(t0/1000,'unixepoch') <= date('now', '-17 days')
),
day0_activated AS (
  SELECT DISTINCT e.device_id
  FROM ev e JOIN cohort c USING(device_id)
  WHERE e.event_name = 'todo_saved'
    AND date(e.ts/1000, 'unixepoch') = date(c.t0/1000, 'unixepoch')
),
w1_active AS (
  -- 回访只认 app_launch:widget_load_failed 等小组件进程后台事件不代表用户回来过
  SELECT DISTINCT e.device_id
  FROM ev e JOIN cohort c USING(device_id)
  WHERE e.event_name = 'app_launch'
    AND e.ts - c.t0 >= 7*86400000 AND e.ts - c.t0 < 14*86400000
)
SELECT CASE WHEN a.device_id IS NULL THEN 'not_activated_day0' ELSE 'activated_day0' END AS grp,
       COUNT(DISTINCT f.device_id) AS cohort_size,
       COUNT(DISTINCT w.device_id) AS w1_retained,
       ROUND(100.0 * COUNT(DISTINCT w.device_id) / COUNT(DISTINCT f.device_id), 1) AS ret_pct
FROM cohort f
LEFT JOIN day0_activated a USING(device_id)
LEFT JOIN w1_active w USING(device_id)
GROUP BY grp;
-- 分组 = day0 是否闭环(不是「任何时候激活过」——用结果定义分组会自我实现);
-- 先行指标版:把 w1_active 的窗口换成 (0, 7*86400000) 且去掉 cohort 的 -17 天闸门
-- (留 -7 天),即「第 1–6 天回访率」。
```

### A6 按设备语言切分(依赖 G1 落地后)

```sql
SELECT device_locale, COUNT(DISTINCT device_id) AS devices
FROM telemetry_events
GROUP BY device_locale ORDER BY devices DESC;
-- 其余查询同理:先把 device_locale 加进前导 ev 的 SELECT 列表(或直接查基表),
-- 再 JOIN install 后把它加进 GROUP BY。
```

### A7 权限被拒者的键盘兜底率(C2 的前置证据;2026-11-26 重写)

```sql
denied AS (
  SELECT device_id, MIN(ts) AS denied_ts
  FROM ev
  WHERE event_name = 'recording_failed'
    AND json_extract(params, '$.reason') IN ('microphonePermissionDenied', 'speechRecognitionPermissionDenied')
  GROUP BY device_id
),
keyboard AS (
  -- 键盘兜底的真信号:extract_outcome(path='keyboard')(AppCoordinator.swift:1275)。
  -- recording_started(source=manual_input) 从未发送,不能用作判据。
  SELECT device_id, MIN(ts) AS kb_ts
  FROM ev
  WHERE event_name = 'extract_outcome'
    AND json_extract(params, '$.path') = 'keyboard'
  GROUP BY device_id
)
SELECT COUNT(*) AS denied_devices,
       SUM(CASE WHEN k.device_id IS NOT NULL AND k.kb_ts > d.denied_ts THEN 1 ELSE 0 END) AS used_keyboard_after,
       ROUND(100.0 * SUM(CASE WHEN k.device_id IS NOT NULL AND k.kb_ts > d.denied_ts THEN 1 ELSE 0 END) / COUNT(*), 1) AS fallback_pct
FROM denied d LEFT JOIN keyboard k USING(device_id);
-- 已知盲区:onboarding 内直接拒权限的用户可能不触发 recording_failed(不走 startRecording),
-- 不会进分母;C2 上线时需配套补该路径的可观测性。
```

> `reason` 值以 `VoiceTodoError` case 名为准(`Telemetry.reason(for:)` 输出),上线后先用一条 `GROUP BY reason` 核对实际取值。

### A8 自然捕捉节奏分布(R4,习惯追踪器前置读数)

```sql
cap_days AS (
  SELECT e.device_id, date(e.ts/1000, 'unixepoch') AS day
  FROM ev e JOIN install i USING(device_id)
  WHERE e.event_name = 'todo_saved'
    AND date(i.t0/1000, 'unixepoch') >= '2026-11-07'
  GROUP BY 1, 2
),
device_weeks AS (
  -- %G-W%V = ISO 周(跨年不拆周);初稿的 %W 不是 ISO 周,已修
  SELECT device_id, strftime('%G-W%V', day) AS iso_week, COUNT(*) AS cap_days_in_week
  FROM cap_days GROUP BY 1, 2
)
SELECT cap_days_in_week AS days_per_week, COUNT(*) AS device_weeks
FROM device_weeks
GROUP BY 1 ORDER BY 1;
-- 三个偏差见 §4.5:零捕捉周不出现;装机当周/当前周是残缺周(读分布排除两端);
-- UTC 分日对 UTC+9 早晨归前一天(声明或按 device_locale 校正)。
```

---

## 附录 B:开放问题——2026-11-26 已逐条裁决

1. **R1 含键盘:维持现方案(「拿到第一份价值」),另加纯语音子指标** `extract_outcome(path='live_voice')` 并列读——C1 放大的是语音 wow,有效性不能被键盘用户稀释。
2. **W1 窗口取 `[7d, 14d)`**,但改为:`event_timestamp` 基准、只认 `app_launch`、只读已满 14 天 + 约 3 天上报滞后的 cohort(§A5);窗口内加读**第 1–6 天回访率**先行指标(M4:4 周窗内 W1 cohort 极少)。
3. **语言取值源:`Locale.preferredLanguages.first`(设备语言)**,分桶 `zh / en / ja / other`,不用 App 展示语言(会把非目标市场折成 en,恰好抹掉要看的信号;见 §3 G1)。
4. **不需要新增 install 事件**:`app_launch(hasCompletedOnboarding=false)` 最早 `event_timestamp` 即装机锚点(§A1);无该事件的设备(升级/老用户)不进 cohort。超过 90 天 GC 周期长跑时,再建「设备首见表」。
5. **C1 与 C2 默认分版上线**;必须同版时按权限子群分开读,前提 = A7 修好后能分出被拒子群 + 补 onboarding 拒权限可观测性(§4.3)。
6. **合入 `schema.sql` 注释区:同意,但只合入本修订版的 A1/A3/A5**;现有 DAU 示例(received_at)加注「只适合看接收量」。
7. **`todo_saved` 覆盖面已按代码结案**(§4.5):Siri 全覆盖、键盘覆盖、离线原文保存不覆盖、Widget 无入口;软启动接受 R4 低估并写死口径,要更准再补离线保存的 source 值。
