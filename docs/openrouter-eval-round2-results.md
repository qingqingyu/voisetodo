# 结果文档:OpenRouter 评测第二轮——glm-4.5-air 掉分归因 + Gemini 3.5 Flash / GLM 5.x

> 2026-10-22 执行,任务书 `docs/openrouter-eval-round2-task.md`。结果分支:`claude/openrouter-eval-round2`(自 `origin/claude/capacity-scenario-a` = 477fd25 拉出,未合 main)。

## 1. 运行信息

- UTC 日期:2026-10-22(周四,窗口内);基准日 `anchorToday = 2026-10-21`(周三)。
- 执行环境:本机 macOS + 本地 HTTP 代理(sing-box 转发用户提供的 ss 节点,仅 openrouter.ai 走代理)。
- **出口验证:Gemini 预检 HTTP 200(provider=Google)**;不走代理时同一请求 403 `region_blocked`(与第一轮一致)。E1-E5 全部经代理执行。
- Key:`OPENROUTER_API_KEY` 仅存在于环境变量与 0600 临时文件,已清理;**用后请撤销**(见 §9)。

## 2. 模型与托管商(§4.1/4.2 查证)

| 模型 ID | 输入 $/M | 输出 $/M | Z.AI 官方端点(量化) | 其他端点示例 |
|---|---|---|---|---|
| z-ai/glm-4.5-air | $0.13 | $0.85 | Z.AI(fp8) | Novita(bf16)、SiliconFlow(fp8) |
| z-ai/glm-5.2 | $0.03 | $7.00 | Z.AI(fp8) | 30+ 家(fp4/fp8 混杂) |
| z-ai/glm-5.3-flash | $0.01 | $0.20 | Z.AI(fp8) | 30+ 家 |
| google/gemini-3.5-flash | $1.50 | $9.00 | —(Google 托管) | — |

固定托管商用 `extraBody.provider = {"order":["Z.AI"],"allow_fallbacks":false}`(OpenRouter Provider Routing 文档);E1/E2/E3/E5/E5b/加测全部固定 Z.AI 官方,E4 默认路由(实测落到 Google)。

## 3. 预检结果(§4.3,非流式,temperature=0 + json_object)

| 实验 | HTTP | 实际托管商 | reasoning_tokens | 判定 |
|---|---|---|---|---|
| E1/E2(air) | 200 | Z.AI | 86 | 默认开推理 → E3 必跑 |
| E3(air noreason) | 200 | Z.AI | **0** | `reasoning:{enabled:false}` 生效 |
| E4(gemini) | 200 | Google | 98 | 默认开推理 |
| E4b(gemini noreason) | **400** | — | — | **平台拒绝:`Reasoning is mandatory for this endpoint and cannot be disabled`** → E4b 不可执行 |
| E5(glm-5.2) | 200 | Z.AI | 14 | 默认开推理 → E5b 必跑 |
| E5b(glm-5.2 noreason) | 200 | Z.AI | **0** | 生效 |
| 加测(5.3-flash noreason) | **400** | — | — | 同 E4b,推理强制 → 无关推理变体 |
| 加测(5.3-flash) | 200 | Z.AI | 166 | — |

推理参数出处:OpenRouter 统一参数 `reasoning`(docs.openrouter.ai;实测区分:`{"enabled":false}` 关闭,`exclude:true` 只不回传不关闭,`effort:"low"` 降档不关闭)。

## 4. 结果总表(75 条;72 条口径 = 剔周日边界 en-031/zh-025/ja-019;73 条口径 = 剔白名单 zh-017/ja-014,即过关线分母,≤1 错过线)

| 实验 | 模型 | 托管/开关 | 全对(75) | en+zh | 72 条 | **73 条(过关线)** | infra | due_date | due_time | recur | mean | P50 | P95 | >30s | 单次成本估 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| E1 | z-ai/glm-4.5-air | Z.AI(fp8),默认 | 55/75(73.3%) | 42/56 | 55/72 | **55/73** | 0 | 83/96 | 95/96 | 95/96 | 10.4s | 9.6s | 23.2s | 0 | $0.0009 |
| E2 | z-ai/glm-4.5-air | Z.AI(fp8),默认 / 旧prompt | 58/75(77.3%) | 45/56 | 58/72 | **58/73** | 0 | 83/96 | 95/96 | 95/96 | 10.8s | 9.5s | 24.2s | 1 | $0.0009 |
| E3 | z-ai/glm-4.5-air | Z.AI(fp8),reasoning off | 56/75(74.7%) | 42/56 | 56/72 | **54/73** | 0 | 80/96 | 96/96 | 96/96 | 4.4s | 3.9s | 9.9s | 0 | $0.0009 |
| E4 | google/gemini-3.5-flash | Google,默认(推理强制) | 72/75(96.0%) | 54/56 | 70/72 | **70/73** | 0 | 94/96 | 96/96 | 96/96 | 7.0s | 6.5s | 12.1s | 0 | $0.0113 |
| E5 | z-ai/glm-5.2 | Z.AI(fp8),默认 | 70/75(93.3%) | 52/56 | 68/72 | **69/73(94.5%)** | 0 | 94/96 | 96/96 | 96/96 | 7.9s | 5.4s | 20.1s | 1 | $0.0019 |
| E5b | z-ai/glm-5.2 | Z.AI(fp8),reasoning off | 71/75(94.7%) | 53/56 | 71/72 | **70/73** | 0 | 93/96 | 96/96 | 96/96 | 6.1s | 4.0s | 16.8s | 0 | $0.0019 |
| 加测 | z-ai/glm-5.3-flash | Z.AI(fp8),默认(推理强制) | 72/73(98.6%) | 54/55 | 69/70 | **70/71** | 2 | 87/88 | 88/88 | 88/88 | 12.6s | 9.9s | 31.6s | 7 | $0.00005 |

单次成本估算口径:输入 6k tok × 输入单价 + 输出 250 tok × 输出单价(README §5 口径,待 console 校准)。⚠️ 思考型模型的推理 token 按输出价计费,实际成本高于本列(Gemini 尤甚)。初版把 Gemini 误写为 $0.0032、5.3-flash 误写为 $0.00005,2026-10-22 复审更正(见 §10 更正记录)。

**过关判定(73 条口径 ≤1 错,且延迟适配生产 30s 超时)——⚠️ 初版结论有算错,本节为 2026-10-22 复审更正版:**

- ❌ **E5 glm-5.2(默认):69/73(94.5%)**——失败 en-016/en-020/ja-016/zh-025(+白名单 zh-017),**未过线**。初版结论段误写「72/73 唯二过线、唯一失败 en-016」,与其自身原始汇总不符,总表数值(69/73)才是对的。
- ❌ **加测 glm-5.3-flash:准确率 70/71 过线,但不能用于实时解析**——7 例 >30s(P95 31.6s)+ 2 例直接超时未计分;把超时视为失败则约 86%。便宜($0.0001/次)且质量够,定位只能是**后台补解析/降级档**。
- ❌ E4 gemini-3.5-flash:70/73(95.9%,差 3 条:en-013/en-016/ja-019);延迟面最好(P50 6.5s / P95 12.1s / 零 >30s),但**单次 $0.0113**(初版误算 $0.0032):Pro 用户 100 次/天满打月模型成本 ≈ $34,远超 $4.99 月费,只适合吸收高峰溢出。
- ❌ E5b glm-5.2-noreason:70/73(3 条周日边界全败——关推理后复杂周语义算不动)。
- ❌ E1/E3 air(固定 Z.AI 官方,新旧 prompt、开关推理):73 条口径 55/73(75.3%)——换官方托管、换回旧 prompt、关推理都救不回来。

**修正后总判定:OpenRouter 上目前没有模型同时达到准确率与延迟两条线,不能直接选主力。**

## 5. §7 结论:E1 vs E2 归因(72 条口径,两边可比)

| 组 | 72 条口径 | 结论 |
|---|---|---|
| E1(固定 Z.AI 官方,**新 prompt**) | 55/72(76.4%) | — |
| E2(固定 Z.AI 官方,**旧 prompt**) | 58/72(80.6%) | prompt 改动只解释 ~4pp |
| (参照)09-22 z.ai 直连 + 旧 prompt | ~70/72(97.2%) | — |

**属于任务书 §7 表的第三行:E1 明显低于 97%,E2 也明显低于 97%——prompt 改动只解释 ~4pp,不是主因**(同模型同旧 prompt:z.ai 直连 97.2%/mean 3.7s vs 经 OpenRouter 80.6%/mean 10.8s,慢约 3 倍)。附带证据:E2 与 E1 失败用例高度重叠(en-009/016/017/025/028、ja-005/007/010/014/016、zh-017/018/020 双双在列),失败模式同源(due_date ±1-2 天算术错);E2 与 E1 延迟几乎相同(10.8s vs 10.4s)。

⚠️ **归因边界(复审补充)**:「剩余差距来自 OpenRouter 托管平台」这一步**说满了**——09-22 基线走的是 z.ai **Anthropic 兼容端点**(无 `response_format`),本轮走 OpenRouter 的 **OpenAI 兼容接口**(`response_format: json_object` 默认带上、推理默认开)。E3 已排除推理因素,但「接口形态 + JSON 模式」与「托管平台」两个因素没有分离。**实用结论不变:air 经 OpenRouter 无论怎么配置都在 75% 档,不可用**;机理归因待 z.ai 按量 key 开通后用「OpenAI 兼容端点直连」一组实验分离。

注意:对照组 glm-5.2/5.3-flash 经**同一 Z.AI 官方端点**却过了 98% 线——「OpenRouter 的 Z.AI 托管劣化」只对 glm-4.5-air 成立(小模型对托管侧量化/配置更敏感),不构成对 5.x 的否定。

**生产影响(任务书 §10.1)**:`wrangler deployments list`(2026-10-22 UTC 查)显示:10-13、10-14 两次代码部署(10-06 的 prompt 改动 `58b2a4e` 自此应已上线),10-18/10-19 为 secret 变更,**10-20、10-21、10-22T10:23(UTC)有新部署**——10-17 的两次 prompt 改动(`54a6be2`/`37006ac`)若随这些部署上线,则生产 prompt 已是新版。⚠️ E2 证明 prompt 改动对 air 只 ~4pp(直连侧未测),影响量级有限;**请人工确认 10-20/21/22 三次部署各部署了什么分支**以闭合此问题。

## 6. 选型建议(§6 规则,由人拍板)

(初版建议建立在「glm-5.2 过线」的算错上,已废;以下为复审更正版。)

- **主力:继续 glm-4.5-air,切到 z.ai 按量付费 API**(替换 Coding Plan key,这本就是上线阻断项)。9-22 直连数据(97.2% / mean 3.7s)仍是全场最好组合;开通后用**新 prompt** 补跑一轮基线(同命令),顺带回答「线上当前质量到底如何」。
- **OpenRouter 定位:溢出与灾备通道,不选主力。** 候选二选一由人权衡:**gemini-3.5-flash**(延迟最好,差 3 条 95.9%,但 $0.0113/次,只配高峰溢出)vs **glm-5.2-noreason**(差 3 条 95.9%、$0.0019/次、P50 4.0s;弱点=周日边界 3 条全错)。Gemini 入选前必须先实测生产 Workers 出口的地域可用性(§10.2)。
- **glm-5.3-flash 定位:后台补解析/全局预算吃紧时的降级档**(质量过线、$0.0001/次,但 ~10% 用例 >30s,不能接实时流量)。
- **两处用例复核(下轮任务)**:`en-016` 全模型皆错(含 09-22 Sonnet),golden 疑似过严,`--replay` 即可复核;3 条周日边界用例多数模型也错,10-17「一周从周日开始」规则的表达方式需要打磨。
- **A 场景容量口径**:若主力维持 air 直连,容量模型(6s/次、130 名额)与第一轮压测完全一致,无需重算。

## 7. 各实验 runner 原始汇总

#### E1 r2-air-zai(z-ai/glm-4.5-air,默认)

```
case: 55/75 全对(73.3%)  拆分数量正确: 98.7%  golden todo 总数: 96
分语言: en 23/31  ja 13/19  zh 19/25
延迟: mean 10385ms / p50 9617ms / p95 23194ms / max 27440ms
超过 30s 用例: 0   infra_error(重试后): 0
失败 case: en-003; en-009; en-016; en-017; en-020; en-027; en-028; en-031; ja-005; ja-007; ja-010; ja-014; ja-016; ja-019; zh-003; zh-015; zh-017; zh-018; zh-020; zh-025
```
#### E2 r2-air-zai-oldprompt(z-ai/glm-4.5-air,默认 / 旧prompt)

```
case: 58/75 全对(77.3%)  拆分数量正确: 98.7%  golden todo 总数: 96
分语言: en 25/31  ja 13/19  zh 20/25
延迟: mean 10770ms / p50 9469ms / p95 24203ms / max 32732ms
超过 30s 用例: 1   infra_error(重试后): 0
失败 case: en-009; en-016; en-017; en-025; en-028; en-031; ja-005; ja-007; ja-010; ja-014; ja-016; ja-019; zh-005; zh-017; zh-018; zh-020; zh-025
```
#### E3 r2-air-zai-noreason(z-ai/glm-4.5-air,reasoning off)

```
case: 56/75 全对(74.7%)  拆分数量正确: 100.0%  golden todo 总数: 96
分语言: en 21/31  ja 14/19  zh 21/25
延迟: mean 4412ms / p50 3943ms / p95 9862ms / max 11016ms
超过 30s 用例: 0   infra_error(重试后): 0
失败 case: en-003; en-009; en-013; en-014; en-016; en-020; en-025; en-027; en-028; en-031; ja-007; ja-010; ja-013; ja-016; ja-019; zh-007; zh-018; zh-020; zh-025
```
#### E4 r2-gemini-3.5-flash(google/gemini-3.5-flash,默认(推理强制))

```
case: 72/75 全对(96.0%)  拆分数量正确: 100.0%  golden todo 总数: 96
分语言: en 29/31  ja 18/19  zh 25/25
延迟: mean 7033ms / p50 6489ms / p95 12107ms / max 16393ms
超过 30s 用例: 0   infra_error(重试后): 0
失败 case: en-013; en-016; ja-019
```
#### E5 r2-glm-5.2(z-ai/glm-5.2,默认)

```
case: 70/75 全对(93.3%)  拆分数量正确: 100.0%  golden todo 总数: 96
分语言: en 29/31  ja 18/19  zh 23/25
延迟: mean 7865ms / p50 5425ms / p95 20059ms / max 31014ms
超过 30s 用例: 1   infra_error(重试后): 0
失败 case: en-016; en-020; ja-016; zh-017; zh-025
```
#### E5b r2-glm-5.2-noreason(z-ai/glm-5.2,reasoning off)

```
case: 71/75 全对(94.7%)  拆分数量正确: 100.0%  golden todo 总数: 96
分语言: en 30/31  ja 18/19  zh 23/25
延迟: mean 6073ms / p50 3998ms / p95 16828ms / max 29256ms
超过 30s 用例: 0   infra_error(重试后): 0
失败 case: en-031; ja-019; zh-017; zh-025
```
#### 加测 r2-glm-5.3-flash(z-ai/glm-5.3-flash,默认(推理强制))

```
case: 72/73 全对(98.6%)  拆分数量正确: 100.0%  golden todo 总数: 88
分语言: en 29/30  ja 18/18  zh 25/25
延迟: mean 12567ms / p50 9929ms / p95 31576ms / max 39445ms
超过 30s 用例: 7   infra_error(重试后): 2
失败 case: en-016
```

## 8. 偏离任务书的地方

1. **执行环境**:任务书推荐「Claude Code 云端会话」,实际经用户提供的 ss 节点 + 本地 sing-box 代理执行;出口合规以任务书规定的 Gemini 预检 200 判定(已通过)。过程中发现 OpenRouter 的 Cloudflare 前置按 TLS 指纹拦截 Node 的 ClientHello(自建 CONNECT 隧道全 403,同一隧道 curl 放行),代理 fetch 改为子进程 curl 承载 TLS(`eval/run.mjs` `--proxy`,随修复轮 477fd25 已提交)。
2. **加测 r2-glm-5.3-flash**(任务书清单外,单次成本约 air 的 1/13):非顶替——E5 按点名用 glm-5.2(现备用实际映射);加测反成并列过线者。
3. E4b / 5.3-flash-noreason 未执行:平台 400 明示推理强制不可关(预检留档),属任务书「参数无效→记录」分支。
4. 单次成本为估算(SSE 不透出 usage),待 console 校准(§9.4 允许)。

## 9. 待人工处理

1. **撤销本次使用的 OpenRouter Key**(对话中出现过明文;评测已完成,建议作废重建)。
2. 确认 10-20 / 10-21 / 10-22T10:23 三次部署各部署了什么(§5),闭合「10-17 prompt 是否已上线」。
3. 若 Gemini 入选备用:先在部署好的 Worker 上实测地域可用性(任务书 §10.2),必要时调整 Worker 运行区域。
4. 拍板主力/备用组合(§6);若选 glm-5.2,重估成本(输出 $7/M:Pro 100 次/天满打 ≈ $0.19/天/用户,无缓存口径)与 `GLOBAL_DAILY_LIMIT`。
5. z.ai 直连 + 新 prompt 的 air 基线仍未测(需按量 key);开通后同命令可补。

## 10. 更正记录(2026-10-22 复审)

初版结论段两处算错 + 一处说满,均由 review 指出、已在本版更正:

1. **glm-5.2 过线判定错误**:初版写「72/73 唯二过线,唯一失败 en-016」;原始汇总的失败集是 en-016/en-020/ja-016/zh-017/zh-025,剔白名单后 4 败 → **69/73(94.5%),未过线**(总表数值本来就对,结论段手写错)。连带推翻「主力建议 glm-5.2」。
2. **Gemini 单次成本少算 3.5×**:$0.0032 → **$0.0113**(6k×$1.5/M + 250×$9/M;推理 token 按输出价计费还会更高);glm-5.3-flash $0.00005 → $0.0001。
3. **归因表述收窄**:「主因是 OpenRouter 的 Z.AI 托管」改为「air 经 OpenRouter 不可用(实用结论);机理归因(托管平台 vs OpenAI 兼容接口形态)未分离」——09-22 基线走 Anthropic 兼容端点,不可直接对比。

修正后总判定:**OpenRouter 上没有模型同时过准确率与延迟两条线**;主力维持 air@z.ai 按量付费,OpenRouter 作溢出/灾备(§6)。

## 11. 附:en-016 字段级复核(2026-10-23,零成本 replay,不调模型)

应 review 建议第 3 条做的诊断(此前只在执行方会话里,现补录进文档供审查方独立查看)。

transcript:`Call the plumber, buy a birthday gift for mom, and book a table for Friday night`

golden(authoring 锚 2026-01-07 周三)对第三条 todo 的要求:

| 字段 | golden | glm-5.2 / glm-5.3-flash | gemini-3.5-flash | glm-4.5-air(E1) |
|---|---|---|---|---|
| title | `Book a table`(净化:**"for Friday night" 被消费进日期字段**) | `Book a table for Friday night`(原文保留) | `Book table for Friday night` | `Book a table` ✅ |
| due_date | `2026-01-09`(周五) | `null` | `null` | `2026-10-25` ❌(锚 10-21 周三,周五应=10-23;算成了周日) |
| due_date_basis | `user_explicit` | `title_mention` | `title_mention` | `user_explicit` ✅ |
| category_hint | `life` | `life` ✅ | `life` ✅ | `social` ❌ |

**结论:golden 自洽,不是答案过严。** 这条用例要求三件事同时做对:title 净化 + 显式周几的日期计算 + category 判定。三个新模型全卡在同一形态——**title 保留原文、basis 标 `title_mention`、日期 null**(把「title 提及日期」用成了「提及了但不计算」的逃生门);air 则反向证明净化能做到,但周几计算错(周五→周日)+ category 偏差。09-22 的 Sonnet 基线同样失败 → **全模型困难用例,反映的是 prompt 能力缺口(相对周几计算 + title 净化规则),不是评测集缺陷**。

**待人工拍板**:golden 不建议改;en-016 是否加入困难白名单(与 zh-017/ja-014 同列,失败不进分母)由人决定——不豁免则它是对所有模型的永久扣分项,豁免则全对率口径整体 +1 条。周日边界 3 条的 prompt 表达打磨属下一轮任务(线索:glm-5.2 默认推理对 2/3,关推理 0/3——周日语义对推理量敏感,打磨方向是把规则写得更机械化)。
