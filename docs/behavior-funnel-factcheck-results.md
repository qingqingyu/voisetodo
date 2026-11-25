# 结果文档:行为漏斗规格——代码事实核查修订

> 输入:外部审计会话 2026-11-25/26 交回的核查报告(对 `docs/behavior-funnel-and-p0-activation.md`
> 逐项核对代码 + SQLite 实测;报告侧对仓库只读,未做任何修改;其 /tmp 修正 SQL 已被会话清理,
> 附录 A 由本分支按报告语义重写)。
> 分支:`task/behavior-funnel-factcheck`,基线 `main` @ `a6341cc`。
> 性质:**文档修订 + TELEMETRY.md 标注**,零代码改动(报告中的代码级修法 M1/M2 已写进规格
> §6 步 0,作为后续独立任务,不在本分支实施)。

## 1. 修订总表(按报告章节)

### 前提性错误(报告 §结论)

| 初稿假设 | 事实 | 修订落点 |
|---|---|---|
| `received_at` ≈ 事件发生时间 | 只在「充电+联网」时批量上报(`TelemetryUploader.swift:82-83`),同批共用一个 `received_at`(`worker.js:780`)→ TTFT 恒 0 / day0 漂移 / 多天压一天 | §0 修正二、§3 G3 重写、附录 A 全部查询改 `event_timestamp`(含异常钳制) |

### §2 事实核对(报告 §1)

| 初稿说法 | 修订 |
|---|---|
| `recording_started(source)` 含 `manual_input` | 实际只发 `button / action_button`(AppCoordinator:433);表格改真值,键盘信号改 `extract_outcome(path='keyboard')` |
| `todo_saved(source)` 含 `widget_toggle` | 实际只发 `confirm / siri_add`;widget_toggle 显式排除出 R1/R4 |
| `first_voice_trial` 三条口径 | 补第①条:`hint_shown` 会话级曝光,非展示次数 |
| `onboarding_step` | 补 actionButton 机型偏差提示 |
| 表结构 | 索引补 `idx_session`/`idx_extract`;`received_at`/`event_timestamp` 语义注明 |
| 「事件采集层不需要新增任何事件」 | 不成立(A7 依赖未发送值 + 上报机制需修),结论行改写 |

### 附录 A SQL(报告 §2;审计侧已实测复现,修正版数字:TTFT 6/9/10 分钟、兜底率 100%、内测机正确排除)

| 查询 | 修订 |
|---|---|
| 通用 | 新增前导:`ts` = event_timestamp(上线日/晚于 received_at 钳制)、`install` 装机锚点(app_launch hasCompletedOnboarding=false 最早 ts)、内测设备排除清单占位 |
| A1 | 新设备改按装机锚点日 |
| A2 | 加 devices DESC 排序说明 + actionButton 偏差注 |
| A3 | 去掉 `first_voice_trial(completed)` 冗余 OR(必伴随 confirm 保存) |
| A4 | cohort 闸门 + day0 首条过滤(对齐 R2「day0 首条」口径,晚激活设备不进分布)+ NTILE「等频桶非精确分位数」注 |
| A5 | 按修正后 R3 定义重写:分组 = **day0** 是否闭环;分母只含 `d0 <= now-17d`(14 天窗 + 3 天上报滞后);回访只认 `app_launch`;附「第 1–6 天回访率」先行指标变体 |
| A6 | 不变(依赖 G1),补 JOIN install 注 |
| A7 | **重写**:denied 的 reason 集合加 `speechRecognitionPermissionDenied`;键盘判定改 `extract_outcome(path='keyboard')` 且时刻 > 拒绝时刻;onboarding 拒权限盲区注明 |
| A8 | `%W` → ISO `%G-W%V`;cohort 过滤(d0 ≥ 上线日,审计口径);三个偏差注(零捕捉周不出现 / 残缺周排除两端 / UTC 分日对 UTC+9 早晨归前一天) |

### §5 隐私论证(报告 §3)

- §5.4 申报口径更正为四类(Device ID / Purchase History / Other User Content / Other Usage Data);
- G1 改动面补 `PRIVACY_POLICY.md` 同版本更新义务(初稿漏);
- 补「不要用 `UITextInputMode.activeInputModes`」(Required Reason API);
- 留档另开 issue:PRIVACY_POLICY「hashed before leaving your device」与事实不符(客户端发原始随机 UUID,加盐哈希在服务端 `worker.js:3670/3695`)。

### 附录 B 七问(报告 §4)

全部按裁决写死进正文/附录 B(R1 含键盘 + 纯语音子指标;W1 `[7d,14d)`+成熟 cohort+先行指标;
语言取 `Locale.preferredLanguages.first` 分桶 zh/en/ja/other;不新增 install 事件;C1/C2 分版;
schema.sql 只合修订版 + DAU 示例加注;todo_saved 覆盖面结案)。

### §6 与风险(报告 §5)

- **步 0(新增)= M1 + M2 上报修复**,作为基线可信的前提,含具体修法(后台 `beginBackgroundTask`
  补报 / 按 `maxBatchSize=100` 分批 / 429 不丢整批)——**代码实施留待独立任务**;
- M3(G1 改动面)写全:worker INSERT + 白名单、schema.sql 本体、PRIVACY_POLICY.md;
- M4 时间线:W1 需 t0+14d+3d,窗口内以 R1/R2/第 1–6 天回访率判断;
- R3 判定标准改为 C1 前后因果对比(原 ≥15pt 闸门不可证伪,只留作描述性参考);
- 漏斗盲区注记:AI 同意 gate 拒绝(`ensureAIConsent()`)与 onboarding 内拒权限均无事件。

### TELEMETRY.md

- `recording_started` / `todo_saved` 两行加「已定义、从未发送」标注(manual_input / widget_toggle),
  防止下一份规格再照抄枚举(本次事故根因);
- 双 review 循环中补充:设计目标与「后续扩展」两处「仅 WiFi + 充电」改为「充电 + 联网」
  ——代码是 `requiresNetworkConnectivity`(任意联网,`TelemetryUploader.swift:82-83`),原表述与代码
  及同文件架构图(「充电 + 网络满足时触发」)不一致,按「以代码为准改文档」顺手对齐。

## 2. 本分支不做、留待后续的(按报告级别)

| 项 | 去向 |
|---|---|
| M1 后台补报 + M2 分批/429 修复(代码) | 规格 §6 步 0;建议下一个独立任务(需自带测试 + 双 review) |
| PRIVACY_POLICY.md 哈希措辞修正 | 另开 issue(报告建议;改文案前可顺手把 X-Device-ID 链路写准) |
| onboarding 拒权限 / AI 同意 gate 可观测性 | 随 C2 实验任务 |
| 内测设备排除清单 | 攒数据前人工建(哈希 device_id 清单,查询占位已留) |

## 3. 验证

- 文档修订无代码;附录 A 前导与各查询为 SQLite 方言,语法要点(CTE、json_extract、
  strftime %G-W%V、date('now','-17 days'))与审计侧实测通过的修正版同构
  (其实测结论:TTFT 6/9/10 分钟、内测机与未满窗设备正确排除、键盘兜底率 100%)。
- 本分支双 review 循环中另用 sqlite3 3.51 以最小种子表实跑 A1–A8:语法全过;
  A4 的 day0 首条过滤(分支内补充,超出审计修正版)与 A5 的 day0 分组语义按种子
  数据验证通过;A6 在 G1 落地前列不存在会报 no such column(预期,文档已注明依赖)。
- 上线启用时仍按 §A7 注释先跑一条 `GROUP BY reason` 核对实际取值。

## 4. 双 review 循环(2026-11-26)

**5 轮收敛,状态 DONE**(第 5 轮 Three Check 与 code-review-expert 均 0 发现;上限 10 轮),
累计发现并修复 15 项,无 skill 冲突(途中两次网关 503 中断后恢复,A8 口径歧义按审计
原口径裁决,非矛盾)。代表性修复:

1. **行号漂移 7 处**:外部报告引用的行号与当前仓库不符,全部改为实测行号
   (`TelemetryUploader 78-79→82-83`、`166→174`;`worker.js 668→780`、`676→789`、
   `37/653→40/764`、`3159→3670/3695`;`AppCoordinator 1253→1275`——报告基于的快照
   与 main 之间隔了多轮合入);
2. **A4 与 R2 口径不一致**:`first_todo` 不限 day0,晚激活设备会污染 TTFT 分布,
   已加 day0 过滤(种子数据实测排除生效;超出审计修正版的分支内补强);
3. **A8 补 cohort 过滤**(按审计口径)+ **G3「所有读数过滤」措辞收窄**为
   A2–A5、A8 实际范围(A1 全量诊断清单 / A6 普查 / A7 兜底率各有说明);
4. §5.2 取值源与 G1 拍板矛盾、`extract_outcome` 不存在的 `reason` 参数、
   M4 标签未定义、前导拼接缺逗号注释、TELEMETRY.md「仅 WiFi+充电」两处按代码
   对齐为「充电+联网」等精确性修正。

验证方式(替代测试套件):19 条外部核查事实逐条落地核对;12 处代码引用逐行核对;
A1–A8 全部以 sqlite3 3.51 最小种子表实跑(A6 依赖 G1 属预期);双文档一致性逐项核对。
