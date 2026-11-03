# Prompt 修复轮 1——救 air(2026-11-03 夜)

> 起因:评测轮 3 结论「都不过」(docs/openrouter-eval-round3-results.md)。air 延迟全绿但准确率 66/73,
> 错题确诊为四类可机械化修复的规则缺口。本轮以 few-shot/规则文本修复,评测护栏验证。
> 分支 `task/prompt-fix-air`(基于 `task/eval-round3-run`)。

## 1. 确诊(错题原始输出逐条核对,非摘要推断)

| 病根 | 错题 | 机理 |
|---|---|---|
| F1 周制错位 | en-031/ja-019/zh-025(稳定错,白天+晚高峰零漂移) | air 按 ISO 周一起始算「下周日」→ +15 日;产品口径周日起始 → +08 日。10-17 周制切换时只修了「下周三」示例,周日(两制分歧最大的日子)无示例覆盖 |
| F2 可定位性判断 | en-028(air 稳定错)+ en-016/ja-016(flash 稳定错、air 抖) | 「Friday night」能定位具体日期=活动发生时间→应进 due+user_explicit(flash 却折进标题);「next month」模糊=对象属性→应 title_mention(air 却标 user_explicit)。prompt 无此判据 |
| F3 提醒丢锚定日 | en-009(air 抖) | 「today at 3,5,7」→ reminder_times 算对(15/17/19)但 due_date 丢空;示例 12 只教了「无日期词→due null」形态 |
| F4 recurrence 抢 basis | ja-017(air 抖) | 「每周日早9点」时间被 recurrence 吸收后 basis 应为 null,air 多标 user_explicit |

## 2. 修复(src/adapters/base.js,三语等价)

- **规则 4 尾部**:「下周X」机械算法——先定位**严格晚于今天的下一个周日**(周日起始制下恒为下周第一天),再按 X 加偏移(周日=0)。「下周日」=偏移 0,**绝不多加 7 天**
- **4b 扩展**:「下个月的会议」类时间词修饰**动作对象**而非动作发生时间 → title_mention(对照示例对:可定位的「星期+时段」→ user_explicit vs 模糊的「下个月」→ title_mention)
- **4b 新增 ⚠️ 行**:时间词被 recurrence_rule 吸收 → due null 且 basis null
- **新规则 4d**:reminder_times 带日期词 → 日期必须进 due_date + user_explicit(对照示例 12 的无日期形态)
- **新 few-shot×3 语**(刻意避开评测原句,用同构新句防「教题」):下周日示例(周三锚 07-15→07-19)、星期+时段排期示例(周四晚→07-16+evening)、模糊对象属性示例(下个月评审会议→title_mention)、带日期提醒示例(今天 4/6 点→due 今日+reminders)
- **worker.test.js**:新增三语守卫测试(pin 规则标记+示例输入+输出侧关键字段),防误删

双 review 循环(Three Check × code-review-expert)2 轮收敛:7 处修复(ja 示例超 15 字约束、中文借词「団建」、4d 排他措辞与 4b 特例互斥、en detail 原文大小写、守卫测试补输出侧 pin、4d MUST 限定+模糊词 carve-out、测试名同步),第 2 轮双零发现。

## 3. 评测护栏(75 条全量,直连 z.ai anthropic 端点)

| 组 | 73 口径 | 回退 | firstTodo P50/P95 | >30s | infra |
|---|---|---|---|---|---|
| 基线 R2 air(旧 prompt,白天) | 66/73 | — | 2633/6315ms | 0 | 0 |
| fix1-air(review 前 prompt) | **73/73(75/75)** | 0 | 2421/3990ms | 0 | 0 |
| fix2-air(**review 后终版**) | **73/73(75/75)** | 0 | 2512/4607ms | 0 | 0 |
| 基线 R1 flash(旧 prompt,白天) | 71/73 | — | 7757/22765ms | 1 | 1 |
| fix2-flash(终版) | **72/73** | en-009⚠️ | 7359/19655ms | 3 | 1(en-027) |

七个错题(en-009/en-016/en-028/ja-016/ja-017/ja-019/zh-025)在 air 上全部转绿,含两条白名单(zh-017/ja-014)——75/75 全对超过 09-22 基线(97.2%)的历史最好成绩。air 三条主力门槛全过:≤1 错 / firstTodo P50≤5s、P95≤12s / 零 >30s。

**flash 附带结果**:en-016/ja-016(其稳定错题)被 F2 修复,71→72/73;延迟面无变化(firstTodo P50 7.4s、3 条 >30s、en-027 纯思考摊死复现)——**仍不适任实时主路径,结论与轮 3 一致**。⚠️ en-009 对 flash 是新回退:裸钟点「3, 5 and 7」被按示例 16 的「无前缀=上午」字面解析成 03/05/07,而 golden 期望情境推断 15/17/19(喝水提醒);air 两轮均推断正确。这是示例 16 默认与 golden 情境期望的**既有张力**(deepseek 轮 3 同错 03:00),非本轮规则引入;为不影响 air 满分不在本轮追加修改,列为下一轮独立诊断项(方向:裸钟点+habitual 活动的醒时推断规则)。

## 4. 待产品负责人拍板

1. **合入并部署 worker**(prompt 在 worker 代码内,不部署不生效)
2. **主力切回 air**:`DELETE /v1/admin/providers/primary` 撤销 10-24 的 override(条目 id 未变,回落即生效),flash 转回落/后台补解析定位
3. 可选:明日晚高峰(20:00–22:00)对 fix2-air 复跑一轮高峰护栏再切
4. 已知取舍:三语 prompt 各 +~1.5KB(输入 token +~8%),air 单次成本估算 ~$0.0009→~$0.001
