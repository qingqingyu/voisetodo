# 行为漏斗读数与 P0 激活实验规格

- 状态:**草案,待 review**
- 日期:2026-11-07
- 目的:支撑软启动 4 周窗口内的「找激活时刻 → 小实验放大」两步(增长方法论第三/四步),让漏斗与留存读数**开箱可查**,并定义第一个激活实验。
- 关联文档:`TELEMETRY.md`(事件口径)、`PROMOTION_PLAN.md`(漏斗与 KPI)、`docs/onboarding-first-voice-trial.md`(first_voice_trial 设计)、`docs/day-clock-day-boundary-inconsistencies.md`(日界教训)

---

## 0. TL;DR 与一处修正

> **修正**:此前讨论曾说「需要新建一张 events 表」——不准确。`telemetry_events` **本身就是事件级表**(`device_id` 哈希 + `session_id` + 事件名 + 脱敏 params),漏斗事件(`onboarding_step`、`first_voice_trial`、`paywall_shown` 等)大多已存在。本规格做的是三件事:
>
> 1. **补一个维度**:设备语言(§3 G1);
> 2. **把查询写出来**:留存 / TTFT / 首条闭环漏斗的 SQL 目前不存在,附录 A 给全(§3 G2);
> 3. **定义 P0 实验**:假设、读数、改动、止停线(§4);
> 4. **附带一个前置读数**:自然捕捉节奏分布(§4.5 / A8),为软启动后的习惯追踪器定链频率备料。
>
> 不新建表、不引入第三方分析 SDK、不动 App Store 隐私营养标签与 xcprivacy(§5)。

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
  received_at     服务端毫秒时间戳
  event_name      事件名
  event_timestamp 客户端毫秒时间戳
  session_id      每次启动 UUID(不持久化)
  device_id       sha256 哈希设备标识
  app_version / ios_version
  params          脱敏 JSON(仅枚举/数字,PII 红线见 TELEMETRY.md)
  extract_id      提取链路关联 ID
)
```

数据保留 90 天(每日 GC),对 4 周窗口绰绰有余。已有索引覆盖 device / event / received_at。

### 2.2 漏斗相关事件清单(全部已上线)

| 漏斗环节 | 事件 | 关键口径(详见 TELEMETRY.md,此处只列分析要点) |
|---|---|---|
| 留存锚点 | `app_launch(coldLaunch, hasCompletedOnboarding)` | 冷热启动可分;新设备 = 窗口内首见(§A1) |
| 引导漏斗 | `onboarding_step(step)` | 每次进入记一枚,**分析按 step 去重** |
| 首条闭环 | `first_voice_trial(armed / hint_shown / dismissed / completed)` | `completed` **混入键盘输入**;`dismissed/armed` 是必盯比值;权限未齐路径也记 `armed` |
| 录音路径 | `recording_started(source)` / `recording_outcome` / `recording_failed(reason)` | `source` 含 `manual_input`(键盘);`reason` 是错误 case 名(如 `microphonePermissionDenied`) |
| 保存 | `todo_saved(source, count)` | source = confirm / siri_add / widget_toggle |
| 变现 | `paywall_shown(source)` + `purchase_*` 五事件 | 四来源由 `presentPaywall(source:)` 统一收口 |
| 复盘 | `review_entry_impression / review_flow_started / review_flow_finished` | 曝光 session 去重;started 记在首次呈现 |

**结论:事件采集层不需要新增任何事件。** P0 所需读数全部可由现有事件组合算出。

## 3. 缺口与补法

### G1(唯一代码改动):缺「设备语言」维度

`telemetry_events` 没有语言列;唯一带 `locale` 的是 `parse_confirmed` / `parse_field_corrected` 的 params——但那是**内容语言**(用户说了什么语言,跟随输入),而漏斗/留存切分需要**设备语言**(哪个市场的用户)。

> ⚠️ 项目已拍板「内容语言与系统语言解耦」(二者不同是正常场景,不是 bug 归因),因此**不能复用 params.locale**,必须独立维度。

**补法**:

- D1:`ALTER TABLE telemetry_events ADD COLUMN device_locale TEXT;`(幂等注意:重复执行会报 duplicate column,迁移一次)
- 客户端:`TelemetryPayload` 增加 `deviceLocale` 字段,取系统首选语言,收敛为枚举 `zh-Hans / en / ja / other`(避免自由字符串)
- 文档:`TELEMETRY.md`「✅ 可上报」清单登记

**隐私影响**(§5 详述):与 `ios_version` 同级的粗维度,不新增数据类型。

### G2:分析查询未成文

留存(W1/W4)、TTFT(time-to-first-todo)、首条闭环率、onboarding 漏斗的 SQL 一条都不存在。附录 A 给全;其中高频三条建议追加到 `schema.sql` 注释区(与现有 DAU 示例并列)。**不建视图、不建物化表**——软启动量级下手跑 `wrangler d1 execute` 即可。

### G3:日界口径(声明,不改代码)

- 分析侧一律 **UTC 日界**(`received_at`),避免客户端时钟漂移;
- App 内业务日界是 day-clock 本地日界,**两套口径不混用**(教训见 `docs/day-clock-day-boundary-inconsistencies.md`);
- 「新用户」= 该 device 在 90 天保留窗内的首见 UTC 日(cohort day0)。90 天 GC 会使极老用户被误判为新用户——4 周窗口内无影响,记录为已知局限。

### 已知局限(不接受 review 挑战的部分,已拍板/已接受)

- **幸存者偏差**:设置页关闭遥测的用户完全不可见,留存读数偏向活跃人群;
- **device_id 换机即换人**:重装/换设备会当新用户,与 ASC 口径有差,趋势读数够用;
- 小样本下不追求统计显著(§4.4 纪律)。

## 4. P0 实验:「首条语音待办闭环」

### 4.1 假设

> 新用户在首次打开的几分钟内完成一次「录音 → 看到 AI 解析出的待办卡 → 确认添加」,这一瞬间(下称**首条闭环**)是决定留存的激活时刻。

与 PROMOTION_PLAN 漏斗的 `install → first_record → wow_shown` 同源;本实验是把它从「KPI 数字」升级为「可对比、可干预的因果假设」。

### 4.2 验证读数(全部现有事件可算,SQL 见附录 A)

| 读数 | 定义 | 查询 |
|---|---|---|
| **R1 首日首条闭环率** | cohort day0 内出现 `first_voice_trial(completed)` 或 `todo_saved` 的设备占比 | A3 |
| **R2 TTFT** | 首见 `app_launch` → 首条闭环的中位分钟数 | A4 |
| **R3 W1 留存分组对比** | day0 闭环 vs 未闭环两组,day 7–13(安装后第 2 个 UTC 周内)任一事件的设备占比 | A5 |

**口径声明**:R1 的「闭环」**含键盘兜底**(权限被拒后走键盘也算)——这是有意为之,激活的定义是「拿到了第一份价值」,不是「用了麦克风」。语音/键盘占比用 `recording_started(source)` 单独看。

**判定**:R3 两组差异显著(经验值 ≥15 个百分点,且每组 cohort ≥30)则假设成立,进入放大;否则换 P1 假设(解析「聪明感」高亮)。

### 4.3 放大改动(实验变量,一次只上一个)

| # | 改动 | 现有读数支撑(改动前就能量化「值不值得做」) |
|---|---|---|
| **C1** | onboarding 演示页之后**直接引导录第一条**,不插额外说明 | A2 onboarding 漏斗:演示页 → 首录之间的流失步 |
| **C2** | 麦克风/语音权限被拒时**立即**落到键盘输入路径(不卡死在授权页) | A7:`recording_failed(reason=microphonePermissionDenied)` 的设备中,后续用过 `manual_input` 的占比——占比低说明兜底没兜住 |

改动进新版本后,用 `app_version` 列切前后 cohort 对比(见 4.4)。

### 4.4 实验纪律(小样本,4 周窗)

1. **不跑 A/B 分流**:软启动量级下分流读不出差异。用**前后对照 + `app_version` cohort 切分**;时间混杂(周内效应、渠道效应)作为已知噪声接受,每周固定动作相同可部分对冲(PROMOTION_PLAN §3)。
2. **只认大位移**:R1 类比率指标,位移 <5 个百分点视为噪声;W1 留存位移 <3 个百分点视为噪声。
3. **样本门槛**:任一组 cohort <30 时,只报原始数、不下结论。
4. **一次一变量**:C1、C2 不同时上(若必须同版,读数只看 R1/R2 总量,不做归因)。
5. **上线日 = 基线起点**:先攒 1 周基线再上 C1/C2(PROMOTION_PLAN Week 1 本就是容错最高的 r/iosapps,基线期与其重叠)。

### 4.5 附带读数:自然捕捉节奏(习惯追踪器的前置观察)

软启动后的候选功能「习惯追踪器」(复盘页内)第一条习惯是**每日捕捉**——每天记 ≥1 条,语音/键盘/Siri/Widget 皆算。链的目标频率必须贴自然节奏设计:比自然节奏高一档是激励,高两档就是断链挫败制造机。**因此先读数、后定链频率**——不先建功能。

- **R4 捕捉节奏分布**:每设备每自然周「有捕捉的天数」的分布(查询 A8)。
- 解读:众数 ≈ 6–7 天/周 → 「每日链」成立;3–5 天 → 改「周目标 N 天」型链;≤2 天 → 习惯链暂缓,先回到激活问题(P0)。

口径声明:

- **观察口径**(遥测侧,仅本读数):「捕捉日」= 当日出现过 `todo_saved` 事件的 UTC 日;分析周用 SQLite `%W`(周一始 ISO),与产品复盘的周日始口径**不同**——本读数只看分布形状,周锚点偏移一天不影响结论,不与产品周数对齐(与 §3 G3 同一处理方式:声明,不混用)。
- **习惯链本体的口径**(实现时):以本地 SwiftData 创建时间为准——按创建日挂、不按 due date(「想到」≠「排期」)、四来源全收、离线兜底(needsAIProcessing)也算,与「永不丢话」原则同构:记了就是胜利,不问后续。断链宽容沿用复盘 streak 既有设计(`ReviewAggregator`:今天未记不算断,从最近有捕捉的那天往回数);封顶对齐复盘 streak 拍板,不另立第二套 streak 口径。
- `todo_saved` 触发点是否覆盖离线兜底与 Siri/Widget 的全部创建路径,需实现时核对(开放问题 B7);若不覆盖,R4 系统性低估捕捉日——只影响观察精度,不影响习惯链本体(本体读本地数据)。

## 5. 隐私论证(为什么不动营养标签 / xcprivacy)

1. **不新增事件、不新增内容字段**:params 仍全为枚举/数字,PII 红线(TELEMETRY.md)不变;
2. `device_locale` 是四值枚举的系统语言,与已上报的 `ios_version`、`device_id` 哈希同敏感级;
3. **opt-out 已有**:设置页开关(`TelemetrySettings`),关闭即完全不上报;
4. ASC 隐私问卷申报口径仍是「标识符(哈希)+ 使用数据,不与身份关联,不出境给第三方」——**数据类型与接收者都没变**,故营养标签与 xcprivacy 不动。这也是与引入 Mixpanel/PostHog 的本质区别(第三方接收者变更才需要重申报)。

## 6. 落地顺序(每步独立可回滚)

| 步 | 内容 | 改动面 | 时机 |
|---|---|---|---|
| 1 | 附录 A SQL 启用,攒基线(R1/R2/R3 + A7;R4 随后两周可读) | **零改动**(手跑查询) | 上线日起 |
| 2 | G1 `device_locale` 列 + 客户端字段 | 1 列迁移 + payload 序列化 + TELEMETRY.md 登记 | 随下一版 App |
| 3 | 按 R3 判定假设;成立则上 C1(或 C2) | onboarding/权限分支 UI,单独 PR | 基线满 1 周后 |

---

## 附录 A:查询集(D1 / SQLite,毫秒时间戳,UTC 日界)

> 占位 `'2026-11-07'` 处替换为实际上线日;所有查询假设窗口内数据未被 GC(90 天保留)。

### A1 每日新设备(cohort)

```sql
WITH first_seen AS (
  SELECT device_id, date(MIN(received_at)/1000, 'unixepoch') AS d0
  FROM telemetry_events GROUP BY device_id
)
SELECT d0, COUNT(*) AS new_devices
FROM first_seen GROUP BY d0 ORDER BY d0;
```

### A2 onboarding 漏斗(按 step 去重)

```sql
WITH first_seen AS (
  SELECT device_id, date(MIN(received_at)/1000, 'unixepoch') AS d0
  FROM telemetry_events GROUP BY device_id
),
cohort AS (SELECT * FROM first_seen WHERE d0 >= '2026-11-07')
SELECT json_extract(e.params, '$.step') AS step,
       COUNT(DISTINCT e.device_id) AS devices
FROM telemetry_events e JOIN cohort c USING(device_id)
WHERE e.event_name = 'onboarding_step'
  AND date(e.received_at/1000, 'unixepoch') = c.d0
GROUP BY step ORDER BY devices DESC;
```

### A3 首日首条闭环率(R1)

```sql
WITH first_seen AS (
  SELECT device_id, date(MIN(received_at)/1000, 'unixepoch') AS d0
  FROM telemetry_events GROUP BY device_id
),
cohort AS (SELECT * FROM first_seen WHERE d0 >= '2026-11-07'),
activated AS (
  SELECT DISTINCT e.device_id
  FROM telemetry_events e JOIN cohort c USING(device_id)
  WHERE date(e.received_at/1000, 'unixepoch') = c.d0
    AND (e.event_name = 'todo_saved'
         OR (e.event_name = 'first_voice_trial'
             AND json_extract(e.params, '$.stage') = 'completed'))
)
SELECT COUNT(*) AS cohort_size,
       (SELECT COUNT(*) FROM activated) AS activated_day0,
       ROUND(100.0 * (SELECT COUNT(*) FROM activated) / COUNT(*), 1) AS rate_pct
FROM cohort;
```

### A4 TTFT 中位分钟数(R2,小样本直接看分布)

```sql
WITH first_seen AS (
  SELECT device_id, MIN(received_at) AS first_ts
  FROM telemetry_events GROUP BY device_id
),
first_todo AS (
  SELECT device_id, MIN(received_at) AS t
  FROM telemetry_events
  WHERE event_name = 'todo_saved'
     OR (event_name = 'first_voice_trial'
         AND json_extract(params, '$.stage') = 'completed')
  GROUP BY device_id
)
SELECT f.device_id, CAST((ft.t - f.first_ts)/60000 AS INTEGER) AS minutes
FROM first_seen f JOIN first_todo ft USING(device_id)
ORDER BY minutes;
-- 样本 >50 后可加 NTILE(4) 看 P25/P50/P75
```

### A5 W1 留存分组对比(R3)

```sql
WITH first_seen AS (
  SELECT device_id, MIN(received_at) AS first_ts
  FROM telemetry_events GROUP BY device_id
),
activated AS (
  SELECT DISTINCT device_id FROM telemetry_events
  WHERE event_name = 'todo_saved'
     OR (event_name = 'first_voice_trial'
         AND json_extract(params, '$.stage') = 'completed')
),
w1_active AS (
  SELECT DISTINCT e.device_id
  FROM telemetry_events e JOIN first_seen f USING(device_id)
  WHERE e.received_at - f.first_ts >= 7*86400000   -- 安装后第 2 个 UTC 周
    AND e.received_at - f.first_ts <  14*86400000
)
SELECT CASE WHEN a.device_id IS NULL THEN 'not_activated' ELSE 'activated' END AS grp,
       COUNT(DISTINCT f.device_id) AS cohort_size,
       COUNT(DISTINCT w.device_id) AS w1_retained,
       ROUND(100.0 * COUNT(DISTINCT w.device_id) / COUNT(DISTINCT f.device_id), 1) AS ret_pct
FROM first_seen f
LEFT JOIN activated a USING(device_id)
LEFT JOIN w1_active w USING(device_id)
GROUP BY grp;
```

### A6 按设备语言切分(依赖 G1 落地后)

```sql
SELECT device_locale, COUNT(DISTINCT device_id) AS devices
FROM telemetry_events
GROUP BY device_locale ORDER BY devices DESC;
-- 其余查询同理:JOIN first_seen 后加 device_locale 到 GROUP BY
```

### A7 权限被拒者的键盘兜底率(C2 的前置证据)

```sql
WITH denied AS (
  SELECT device_id, MIN(received_at) AS denied_ts
  FROM telemetry_events
  WHERE event_name = 'recording_failed'
    AND json_extract(params, '$.reason') = 'microphonePermissionDenied'
  GROUP BY device_id
)
SELECT COUNT(*) AS denied_devices,
       SUM(CASE WHEN EXISTS (
             SELECT 1 FROM telemetry_events e2
             WHERE e2.device_id = denied.device_id
               AND e2.event_name = 'recording_started'
               AND json_extract(e2.params, '$.source') = 'manual_input'
               AND e2.received_at > denied.denied_ts
           ) THEN 1 ELSE 0 END) AS used_keyboard_after,
       ROUND(100.0 * SUM(CASE WHEN EXISTS (
             SELECT 1 FROM telemetry_events e2
             WHERE e2.device_id = denied.device_id
               AND e2.event_name = 'recording_started'
               AND json_extract(e2.params, '$.source') = 'manual_input'
               AND e2.received_at > denied.denied_ts
           ) THEN 1 ELSE 0 END) / COUNT(*), 1) AS fallback_pct
FROM denied;
```

> `reason` 值以 `VoiceTodoError` case 名为准(`Telemetry.reason(for:)` 输出),上线后先用一条 `GROUP BY reason` 核对实际取值。

### A8 自然捕捉节奏分布(R4,习惯追踪器前置读数)

```sql
WITH cap_days AS (
  SELECT device_id, date(received_at/1000, 'unixepoch') AS day
  FROM telemetry_events
  WHERE event_name = 'todo_saved'
  GROUP BY device_id, day
),
device_weeks AS (
  -- %W = 周一始 ISO 周;只影响锚点不影响分布形状(口径声明见 §4.5)
  SELECT device_id, strftime('%Y-%W', day) AS week, COUNT(*) AS cap_days_in_week
  FROM cap_days GROUP BY device_id, week
)
SELECT cap_days_in_week AS days_per_week, COUNT(*) AS device_weeks
FROM device_weeks
GROUP BY cap_days_in_week ORDER BY cap_days_in_week;
```

---

## 附录 B:请 reviewer 重点裁决的开放问题

1. **R1 含键盘兜底是否正确**——激活定义取「拿到第一份价值」(现方案)还是「完成一次语音解析」(纯语音)?后者与 first_voice_trial 的 wow 叙事更一致,但会把权限被拒用户全部判为未激活。
2. **W1 留存窗口**取 `[7d, 14d)`(第 2 个整周)还是 `(0, 7d]` 之外任意回访?现方案前者,与「周留存」直觉对齐。
3. **device_locale 取值源**:`Bundle.preferredLocalizations.first` vs `Locale.current.language.languageCode`——影响枚举收敛的实现细节,建议实现时以「App 实际展示语言」为准(与三语 MVP 对齐)。
4. **是否需要显式 install 锚点事件**(替代 min(received_at) 推导):4 周窗口内不需要,若长跑(>90 天 GC 周期)需要补 `first_launch` 事件或 device 首见表。
5. **C1 与 C2 能否同版**(4.4 第 4 条的例外情形):如果 onboarding 演示页重排本身就包含权限流程前置,两者可能无法解耦,需 reviewer 判断产品上是否允许。
6. **附录 A 查询的三条**(A1/A3/A5)是否随本规格合入 `schema.sql` 注释区,与既有 DAU 示例并列。
7. **`todo_saved` 触发点覆盖面**(影响 R4 低估程度):离线兜底保存(needsAIProcessing 原文落库)与 Siri/Widget 添加是否都记 `todo_saved`?若不全,R4 系统性低估捕捉日;习惯链本体读本地 SwiftData 不受影响,但实现时需以本地口径做一次对照校准。
