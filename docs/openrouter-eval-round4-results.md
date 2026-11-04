# OpenRouter 评测轮 4 结果(2026-11-03/04)

> 阵容与动机见 `AIProxy/eval/README.md` §10(轮3结论「都不过」→ 弃 z.ai 直连转 OR 选「准确+快」)。本分支基于 task/eval-round3-run 切出,附带为 Q7c 解锁 anthropic 条目 extraBody 通道(见 §5)。

## TL;DR

1. **无模型在默认思考档过 98% 线**;最高 97.3% 两席:deepseek-v4.1-flash(快)、gemini-3.8-flash(慢)。
2. **thinking:low 族全案否决**:anthropic 方言 92% + priority 通胀×3(质量红线);openai 方言「low」实为调低非关闭,质量无损但延迟红利未兑现;OR 路由对 thinking 参数透传不可靠。
3. **归因结论:z.ai 慢是直连路由,不是 glm-5.3-flash 模型**——同模型换 OR 路由单跑 100%(68/68)+ p50 3.5s(有 9% 思考流超时尾巴,波动带 94~100)。
4. 唯一过线跑:Q7b-r2(glm 直连 paas/v4 + level:low)98.6%——但该方言 low 未关死思考,延迟≈默认,且属 glm 波动带上沿,需复验。
5. 失败 case 高度共享(en-016 毒 6/9 组)→ prompt 修复轮是全候选集体过线的最高杠杆靶点。

## §1 主表(全部晚高峰窗口;延迟=p50/p95/max,ms 省略)

| label | 模型@路由@档位 | 全对 | en/ja/zh | total p50/p95/max | >30s | infra | 备注 |
|---|---|---|---|---|---|---|---|
| Q1 or-ds41-flash | deepseek-v4.1-flash @OR 默认 | 72/74 97.3% | 31/31·17/19·24/24 | 2238/10284/17868 | 0 | 1 | **主力第一候选**;$0.04/$0.50 |
| Q5 or-gemini-38-flash(-r2) | gemini-3.8-flash @OR | 73/75 97.3% | 30/31·19/19·24/25 | 5070/15233/32811 | 1 | 0 | 备线;r1 遇 15:36 网络瞬断作废(§4) |
| Q6 or-glm-53-flash-ctrl(-r2) | glm-5.3-flash @OR 默认 | 68/68 **100%** | 29/29·16/16·23/23 | 3482/11069/28835 | 0 | **7** | 对照线;7×50s 思考流超时;波动带 94~100(Q7a 反证) |
| Q4 or-qwen37-flash | qwen3.7-flash @OR | 72/75 96.0% | 29/31·18/19·25/25 | 10632/31778/40228 | **4** | 0 | 延迟出局:与 z.ai 直连同量级 |
| Q2 or-haiku-55 | claude-haiku-5.5 @OR | 71/75 94.7% | 29/31·19/19·23/25 | 2689/6054/7809 | 0 | 0 | 尾部最干净(p95 6.1s)但分数不够 |
| Q3 or-minimax-m31 | minimax-m3.1-flash @OR | 70/75 93.3% | 27/31·19/19·24/25 | 1484/6525/12448 | 0 | 0 | 全场最快 p50,分数垫底 |
| Q7a or-glm-53-flash-low | glm @OR + low(openai 方言) | 68/72 94.4% | 28/31·17/18·23/23 | 2998/11891/41599 | 1 | 3 | **无效数据**:延迟未塌→参数疑似被 OR 吞 |
| Q7b-r2 zai-5.3-flash-low-r2 | glm @直连paas/v4 + enabled/low | 72/73 **98.6%** | 29/30·18/18·25/25 | 6255/19981/29095 | 0 | 2 | 唯一过线;但 firstText p50 5.1s+2 思考流超时→low 未关死思考;波动带上沿待复验;r1 因旧 key 平台额度干涸全灭 |
| Q7c zai-anth-5.3-flash-low | glm @直连anthropic + type:low | 69/75 **92.0%** | 28/31·16/19·25/25 | **2543/7377/10341** | 0 | 0 | 延迟大奖(-65% p95)但 priority 通胀×3+日期偏一周×2 |

对照基线(轮3,R1/R1b 同端点同 prompt 默认档):97.3% / 97.3%,p50 5.9s(白天)~7.3s(晚峰),p95 21.3~26.9s,>30s 1~4 条。

## §2 thinking:low 方言拆解(Q7 核心)

| 方言 | 思考实际状态 | 质量 | 延迟 | 结论 |
|---|---|---|---|---|
| anthropic `{"type":"low"}` | **全关**(firstText p50 1.4s,思考块消失,A3 同款) | 92%,priority 100%→96.9%(normal→high ×3) | p95 -65% | **否决**:紧迫感判断最吃思考深度,关掉就轻率标高优 |
| openai `{"type":"enabled","level":"low"}` | **调低未关**(firstText 5.1s,残留思考流超时) | 98.6%(priority 100%) | ≈默认(-0~10%) | 温和但无生产价值:延迟红利没拿到 |
| OR 透传(openai 方言) | 疑似未达模型(延迟分布=默认) | 94.4% | 未塌 | OR 对厂商参数透传不可靠,此路不通 |

priority 通胀的证据强度:该字段在轮4 全部其他 ~10 组(含 R1/R1b 默认档)100%,仅 Q7c 连错 3 条——真实退化,非波动。priority=high 改变用户提醒语义,属产品级风险。

## §3 失败 case 共享分析(prompt 修复轮靶点)

| case | 毒倒组数 | 错误形态 |
|---|---|---|
| en-016 | **6/9** | due_date null + basis 误标 title_mention(全场最毒) |
| zh-017 | 3 | category life vs health 边界 |
| en-028 | 3 | basis title_mention vs user_explicit(双向都有) |
| ja-016 | 2(ds/Q7a) | 同 en-016 形态的 ja 版 |
| ja-019/en-031 | 2~3 | 相对日期偏一周(11-08→11-15) |
| priority 三连 | 仅 Q7c | 见 §2,不属 prompt 靶点 |

同一批 case 反复坑倒不同厂商模型 → prompt 表述歧义,修复杠杆最高。与 task/prompt-fix-air 分支(并行轮)的工作正交:prompt × 路由 × 档位三轴,其 prompt 修复落地后可用本矩阵复测定终局。

## §4 infra 事件记录

- **15:36 UTC 网络瞬断**:Q5 r1 中断(56 infra)+ Q6 r1 全灭(75 infra),持续 ~2min,恢复后 r2 补跑双绿。探活确认非模型问题。
- **Q7b r1 旧 key 平台额度干涸**:PROVIDER_KEY_ZAI_ANTHROPIC 在 paas/v4 侧 quota_exhausted(75/75)。生产无恙——anthropic 端点探活 200、worker 双 closed,两额度池独立。已充值+启用新 key(ZAI_KEY_2,仅评测用)。**轮3 遗留「z.ai 余额」开放项就此关闭。**
- glm 思考流超时签名:`chunkCount 2000+/emittedChars 0/47~49s 超时`,直连/OR 均现,随模型不随路由。

## §5 附带代码变更:anthropic 条目 extraBody 通道

为跑 Q7c 解锁(Q7a/Q7b 证明不开通道无法测生产路由档位):`config.js` 校验放开至 anthropic(保留字段护栏原样)+ `anthropic.js` 同型 spread 合并 + worker.test.js 拆旧用例新增 3 用例。**npm test 398/398 绿**。生产行为零变化(现网无 anthropic+extraBody 条目);low 已否决,该通道留作后续档位/参数的配置级管线。

## §6 决定建议(待拍板)

1. 5.3-flash **留作回落线**(默认档;直连 anthropic)。
2. thinking:low 生产化**否决**(§2)。
3. 主力候选 **deepseek-v4.1-flash**,备线 gemini-3.8-flash;终测建议=prompt 修复轮落地后,以新 prompt 复跑 Q1/Q5(+Q7b-r2 复验 glm 上沿)。
4. 白天窗口复跑留给入围者(本表全为晚高峰口径)。
5. 成本:全轮 ~675 发,OR 侧 ~$0.2 + zai 直连 ~$0.01,远低于 $5 key 上限。
