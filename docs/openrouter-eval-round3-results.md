# 评测轮 3 结果——主力判定:glm-5.3-flash vs glm-4.5-air(直连)+ GPT 点名

> 执行:2026-11-03(北京周二,窗口内)。基线 `main` @ `a760042`,分支 `task/eval-round3-run`。
> 任务书:`docs/task-eval-round3.md`(投递分支 `claude/pre-launch-review-jy86zk` @ `0901dc0`)。
> 日期锚 2026-11-04(周三);75 条 dataset,过关线分母 73 条(剔白名单 zh-017/ja-014,≤1 错)。

## 1. 结论先行(§4.2 四选一)

**【待 R2/R1b/R2b 完成后填写】**

## 2. 对比总表

延迟口径:firstText/firstTodo/total 均只统计**计分(ok)case**;infra_error(含超时)另有 infra 列。
单次成本:z.ai 组按轮 2 §5 估算口径(输入 6k tok × 输入单价 + 输出 250 tok × 输出单价,SSE 不透出 usage,待 console 校准);OpenRouter 组用 key usage 前后差**实测**。

| 实验 | 模型 | 端点/开关 | 全对(75) | 73 条(过关线) | infra | firstText P50/P95/max | firstTodo P50/P95/max | total P50/P95/max | >30s | 单次成本 |
|---|---|---|---|---|---|---|---|---|---|---|
| R1 r3-zai-5.3-flash | glm-5.3-flash | z.ai anthropic 直连,默认(思考强制) | 72/74(97.3%) | **71/73** | 1 | 5851/21274/43127ms | 7757/22765/44055ms | 7528/22788/46138ms | 1 | ~$0.0001 |
| R2 r3-zai-air | glm-4.5-air | z.ai anthropic 直连,默认 | 68/75(90.7%) | **66/73** | 0 | 1336/4910/16077ms | 2633/6315/16950ms | 2751/9656/17009ms | 0 | ~$0.0009 |
| R3 r3-zai-air-openai | glm-4.5-air | z.ai openai 兼容直连,默认 | **受阻未执行**(§5.1) | — | 75* | — | — | — | — | $0 |
| R3b r3-zai-air-nothink | glm-4.5-air | z.ai openai 兼容直连,thinking disabled | **受阻未执行**(§5.1) | — | — | — | — | — | — | $0 |
| R4 r3-zai-5.3-flash-openai | glm-5.3-flash | z.ai openai 兼容直连 | **受阻未执行**(§5.1) | — | — | — | — | — | — | $0 |
| R5 r3-or-gpt-4o-mini | gpt-4o-mini | OpenRouter(经代理) | 60/75(80.0%) | **58/73** | 0 | 3444/7549/10483ms* | 3526/7551/10484ms* | 3444/7552/10485ms | 0 | **$0.00057(实测)** |
| R6 r3-or-gpt-5-nano | gpt-5-nano | OpenRouter(经代理) | 65/71(91.5%) | **68/73†** | 4 | 12267/25938/38014ms* | 12636/25941/38015ms* | 12268/25941/38016ms | 2 | **$0.0011(实测)** |

† R6 的 73 口径按「4 条 infra 全对」的最好情形计(实际计分 67 条非白名单中错 5);infra 4 条本身即流形态不兼容(见 §3 R6 明细),不影响不合格结论。

注:R5/R6 走 `--proxy`(curl 子进程),该路径**整包缓冲交付**,事件时序被压成一帧——firstText/firstTodo 退化为 ≈totalMs(上界),仅质量结论有效,延迟列不参与判定(见 §7 口径说明)。

## 3. 各组明细

### R1:glm-5.3-flash 直连(生产现主力,同端点同 prompt)

- **准确率 71/73,不过线**(差 1 条):失败 en-016、ja-016,同一族错误(`due_date` want 有值 got null;`due_date_basis` want `user_explicit` got `title_mention`)。en-016 即轮 2 遗留的「是否入困难白名单」候选,本轮再次失败;ja-016 轮 2 时 glm-5.2 同错。
- **首条待办延迟远超线**:firstTodo P50 **7.76s**(线 ≤5s)/ P95 **22.8s**(线 ≤12s);57/74 条 >5s,19/74 条 >12s。firstText P50 5.85s——思考型模型近 6 秒一个字不出,与体感延迟的主控因素吻合。
- **>30s 共 1 条**(ok case,max 46.1s),另有 1 条 infra 超时:en-027 在 worker 50s 超时,worker 日志 `chunkCount=1297, emittedChars=0`——**收了 1297 个流块、0 字文本输出**,纯思考摊死,重试一次同样形态(48.9s 超时)。这是 10-24 探测「2/8 >30s」尾部在 75 条样本上的重现与定性。
- 与轮 2 加测(OpenRouter 5.3-flash:70/71、7 条 >30s)对照:直连当日延迟分布略好(P50 7.5s vs 9.9s),但「准确率过线、延迟不过线」的结构性结论一致——**不适合做实时主路径**。

### R2 明细:glm-4.5-air 直连(生产现回落,同端点同 prompt)

- **准确率 66/73,大幅不过线**(差 6 条):失败 7 条,含**周日边界三连**(en-031/ja-019/zh-025,want 2026-11-08 got 2026-11-15——「下周日」语义算成 +8 天)、en-009(due/basis 双 null)、en-028(basis 反标)、ja-016(与 flash 同错)、ja-017(basis 多标)。72 条口径(再剔周日边界 3 条)= 68/72。
- **与 09-22 直连基线(97.2%,旧 prompt)对照:−6.8pp,但严格口径不可比**(README §6 自己声明:10-17 ja 转正 + 周制变更 + few-shot 修复,09-22 留档与新 prompt 不构成同口径对照)。混杂因素三重:数据集 10-17 改版、prompt 三改、z.ai 托管侧更新,无法分离。参照锚点:10-17 用 `--replay` 把 09-22 air 留档在新 ja golden 上重评为 ja 17/18(仅白名单 ja-014 错)——旧响应在新口径下依然强,而今天 R2 全集崩 7 条(周日边界 3 + en-009 等),崩幅量级远超数据集口径差,**漂移真实存在、主嫌是 prompt 改动后的 air 表现退化**。干净归因需「直连 + 旧 prompt」复跑,prompt 在 worker 代码内,超出本轮「不改 Worker」约束,未执行。**该结论同时波及生产:air 是现役 p3 回落条目,回落质量已非 09-22 时的档案。**
- **延迟全过且余量大**:firstText P50 1.34s / firstTodo P50 2.63s / P95 6.32s / max 17.0s / >30s 零条 / infra 零条。今天的 anthropic 端点上 air 未表现出重思考(firstText 1.3s 即出字)。
- 交叉观察:周日边界 3 条 flash 全对(思考模式算得动),air 全错;en-016 只有 flash 错、ja-016 两者皆错——两个模型的失败集几乎不重叠(flash: 语义边界;air: 日期推演),对 prompt 修复方向是重要线索。

### R5 明细:gpt-4o-mini(OpenRouter,经代理)

- **准确率 58/73,不合格**:失败 15 条,重灾区 `due_date` 相对日期推演(en-014/ja-010/zh-007 同错 +2 天、en-031/ja-019/zh-025 周日边界同错 +5 天、zh-015 −2 天、en-027 双条 −2 天、en-017 多标日期)+ category_hint 4 条 + basis 反标。质量结论:**不进备选池**。
- 延迟:total P50 3.44s / P95 7.55s / max 10.5s、零 >30s、零 infra。firstText/firstTodo 带 * 号——代理整包缓冲伪时序(≈total),非真实 TTFB。
- 成本实测(key usage 前后差):**$0.0429 / 75 次 = $0.00057/次**。

### R6 明细:gpt-5-nano(OpenRouter,经代理)

- **准确率不合格**:计分 65/71(91.5%),失败 6 条(en-006/en-013/ja-016/zh-017 的 category_hint 互串 life↔health、work↔finance、social↔life;en-017 多标日期+basis 反标;en-028 basis 反标且拆分数量不匹配)。剔白名单后最好情形 68/73,距 ≤1 线远。
- **延迟面差**:total P50 **12.3s** / P95 25.9s / max 38.0s、>30s 2 条——nano 推理型,出字前思考久(缓冲伪时序下 firstText≈total,真实 TTFB 未知但 total 已说明问题)。
- **流形态不兼容**:4 条 infra——3 条 `AI provider stream event too large`(en-009/en-027/zh-018,30~36s 处思考块单事件超 worker 流事件上限)+ 1 条 `stream ended before done`(ja-007,50s)。与代理路径无关,是 worker 流解析对超大事件的防护触发。
- 成本实测:$0.0837 / 76 次(含 1 次重试)≈ **$0.0011/次**。
- **结论:不进备选池**(质量 + 延迟 + 流形态三重)。

### R3/R4/R3b:z.ai openai 兼容端点直连——账户余额受阻(未执行)

- R3 整轮启动后 75/75 infra_error:上游对**每一个请求**秒回 `HTTP 429 {"code":"1113","message":"Insufficient balance or no resource package. Please recharge."}`(worker 6 连败熔断后转 no_candidates,原始前 6 条均为亚秒 503 包装)。人工直发单条复现同一 1113,glm-4.5-air 与 glm-5.3-flash 同报——**与模型无关,是账户在该端点无按量余额**。
- 该 key(ZAI_KEY = 生产 PROVIDER_KEY_ZAI_ANTHROPIC)在 **anthropic 端点**有额(R1/R2 各 75 条全通,生产 10-24 起在服),两个端点计费池不同(anthropic 走订阅通道,openai 兼容走按量余额)。
- **影响范围**:R3(轮 2 归因遗留)、R4(顺手)、R3b(R7 补救实验)三组全部无法执行,除非产品负责人给 z.ai 账户充按量余额。零成本发生(错误响应不扣费,75×1113 = $0)。
- R7 的「关思考」问题因此**双料受阻**:anthropic 端点被 worker extraBody 限制挡(§5),openai 端点被余额挡(本节)。可参照的最近数据是轮 2 E3(OpenRouter air 关推理:54/73,mean 4.4s)——关推理在 OpenRouter 托管下未救回准确率。

## 4. 晚高峰对比(R1 vs R1b、R2 vs R2b)

【待 20:00–22:00 复跑后填写】

## 5. R7:air 关闭思考(anthropic 端点)——受阻记录 + 补救实验

- **R7 原案无法执行**:任务书要求 anthropic 模板以 `extraBody: {thinking: {type: "disabled"}}` 关思考,但 worker 配置层(src/config.js:182)只允许 **openai 类型条目**带 `extraBody`,anthropic 条目直接 `PROVIDERS[0] extraBody is only supported on openai-type entries` → 每请求 500(已用 2 条冒烟实证,零上游调用)。任务书同时禁止改 Worker 代码,故如实记录受阻。
- z.ai 官方文档(docs.z.ai/guides/llm/glm-4.5)确认 `thinking: {"type": "disabled"}` 是官方参数,但仅文档化于 chat completions 端点;anthropic 兼容端点对 disabled 的执行本身有社区报告的不一致(thinking.type=disabled 透传后仍出思考块)。
- **补救实验 R3b**:`zai-openai-air-nothink.json`(openai 兼容端点 + thinking disabled,worker 原生支持 extraBody,零代码改动)。与 R3(同端点默认思考)对照可单独归因「思考开关」;与 R2(anthropic 默认)对照归因「端点形态」。注意生产走 anthropic 端点,若 R3b 显著加速,落地仍需 worker 支持 anthropic 条目 extraBody(一次代码改动,超出本轮范围)。**R3b 因 §3 余额受阻未执行。**
- 生产配置现状(wrangler.toml):主力条目 `ZAI_ANTHROPIC_AIR` 实跑 glm-5.3-flash(timeoutMs 35000),回落条目 `ZAI_ANTHROPIC` 实跑 glm-4.5-air;**两处均未配置任何 thinking 参数 = 生产 air 用端点默认思考行为**。
- 轮 2 参照:OpenRouter 上 air 关推理 56/75(54/73)vs 默认 55/75——关推理在 OpenRouter 托管下未掉准确率但也没救回;5.3-flash 关推理被平台 400 拒(推理强制)。

## 6. 归因表(R3/R4:直连 anthropic vs 直连 openai 兼容 vs 轮 2 OpenRouter)

| 维度 | R2 直连 anthropic | R3 直连 openai 兼容 | 轮 2 E1 OpenRouter |
|---|---|---|---|
| glm-4.5-air 全对(73 条) | **66/73(90.4%)** | **受阻**(1113 余额,§3) | 55/73(75.3%) |
| firstTodo P50 | 2633ms | 受阻 | n/a(轮 2 无此字段) |
| total P50/P95 | 2751/9656ms | 受阻 | 9.6s / 23.2s |

R3 受阻使「接口形态 vs OpenRouter 托管」的分离实验无法完成。可用的替代推理:直连 anthropic(66/73)与轮 2 E1(55/73,OpenRouter 路由钉 Z.AI 官方 fp8 托管、同代新 prompt)相差 11pp;轮 2 内部 E1 vs E2(新旧 prompt,同托管)差 ~4pp,剩余 ~7pp 归因悬置(接口形态/托管量化均无直证);R4(5.3-flash openai 兼容)同样受阻(同 1113),无法补 5.3-flash 行。

## 7. run.mjs 改动说明(firstTextMs / firstTodoMs 判定方法)

- `firstTextMs`:发出请求 → 收到第一个 `text` 事件(SSE `data:` JSON 含字符串 `text` 字段)。
- `firstTodoMs`:发出请求 → 累计文本里**第一条待办完整出现**。判定与 App 的 `TodoExtractorService.tryParsePartialTodos` 同构:剥开头 markdown 围栏 → 正则找 `"todos"\s*:\s*\[` → 字符串/转义感知的括号配平扫出第一个闭合 `{...}` 对象。与 App 口径的差异:App 还要求该对象通过 `ExtractedTodo` decode,本 runner 以 `JSON.parse` 通过近似(结构合法;字段级 decode 失败在最终解析必然暴露为 infra_error)。单元自测 5 组(分片命中、字符串内花括号、坏对象跳过、无 todos、preamble)全绿。
- 汇总口径:三字段均只统计计分(ok)case 的 P50/P95/最大值;`>30s` 统计 ok case 的 totalMs(生产 35s 超时口径;infra_error 含超时单列)。旧 scored.json 无新字段时 `--table` 显示「-」。
- **已知局限**:`--proxy` 路径(R5/R6)经 curl 子进程整包缓冲交付,事件间真实时序丢失,firstText/firstTodo 在该路径退化为 ≈totalMs(上界),不能当真实 TTFB 用。

## 8. 错题明细

### R1 r3-zai-5.3-flash
| case | 字段 | want | got |
|---|---|---|---|
| en-016 | due_date / due_date_basis | 2026-11-06 / user_explicit | null / title_mention |
| ja-016 | due_date / due_date_basis | 2026-11-06 / user_explicit | null / title_mention |
| en-027 | (infra) | — | 50s 超时,chunkCount 1297 / emittedChars 0,重试同形态 |

### R2 r3-zai-air(7 败,73 口径 6 败)
| case | 字段 | want | got | 备注 |
|---|---|---|---|---|
| en-031 / ja-019 / zh-025 | due_date | 2026-11-08 | 2026-11-15 | **周日边界三连**,「下周日」+8 天;flash 全对 |
| en-009 | due_date / basis | 2026-11-04 / user_explicit | null / null | 轮 2 clawto 评测同错此条 |
| en-028 | due_date_basis ×2 | title_mention | user_explicit | basis 反标(两条 todo 同错) |
| ja-016 | due_date / basis | 2026-11-06 / user_explicit | null / title_mention | 与 R1 同错 |
| ja-017 | due_date_basis | null | user_explicit | basis 多标 |

### R5 r3-or-gpt-4o-mini(15 败,73 口径 15 败)
| 族 | case | 形态 |
|---|---|---|
| 相对日期 +2 天 | en-014、ja-010、zh-007 | want 11-11 got 11-09 等 |
| 周日边界 +5 天 | en-031、ja-019、zh-025 | want 11-08 got 11-13 |
| 日期偏移 | en-027(双条 −2 天)、zh-015(−2 天)、zh-018(+2 天且月度重复丢失)、en-017(多标 11-20)、zh-020(due/basis 双 null) | |
| category_hint | en-007、en-013、en-014、en-017、ja-016 | social/work/life/finance 互串 |
| basis 反标 | en-028、en-017 | title_mention ↔ user_explicit |

### R6 r3-or-gpt-5-nano(6 败 + 4 infra)
| case | 形态 |
|---|---|
| en-006 / zh-017(白名单) | category_hint life→health |
| en-013 | category_hint work→finance |
| ja-016 | category_hint social→life |
| en-017 | 多标 due 2026-11-20 + basis 反标 |
| en-028 | basis 反标 ×2 + 拆分数量不匹配 |
| en-009 / en-027 / zh-018(infra) | stream event too large(30~36s) |
| ja-007(infra) | stream ended before done(50s) |

### R1b/R2b 晚高峰
【待填】

## 9. 偏离任务书的地方及理由

1. **R7 原案受阻**(anthropic 模板 + extraBody 被 worker 配置层拒绝,§5 详述):以 R3b(openai 端点 nothink)补救,归因链可用但与生产端点形态不同——**是否给 anthropic adapter 加 extraBody 支持,交产品负责人裁决**。
2. **OPENROUTER_KEY 交付方式偏离**:任务书要求 key 不进聊天、由产品负责人放环境变量;实际由产品负责人直接贴进聊天后转存 `.dev.vars`(gitignore 覆盖,全程未回显、未入任何提交/日志)。**建议本轮结束后吊销该 key**(与轮 2 同一处置)。
3. **key 限额 $5 而非任务书 $0.5**(实测 `limit: 5`):未阻塞——R5/R6 实际预算远低于 $0.5(轮 2 GPT 组配额 ≈$0.15 量级),已用 usage 实测监控;建议产品负责人有空降回 $0.5。
4. **key 明日(北京 11-04 12:29)过期**:R5/R6 已排程当日完成,不影响窗口;如需晚高峰复跑 GPT 组(任务书未要求)不可行,如实记录。
5. **R3/R4/R3b 全部受阻于 z.ai 账户余额**(openai 兼容端点 1113,§3 详述):R3 是「建议」级、R4「顺手」级,按任务书优先级不阻塞主线;R3b 是 R7 的补救实验,与 R7 原案(§5)叠加后「关思考」维度本轮**无直证**。若产品负责人给 z.ai 充按量余额,可在窗口内(北京周五 08:00 前)补跑,runner/模板已就绪。
6. **R1 infra 超时 1 条(en-027)未 --resume 重跑**:worker 侧 50s 超时×2 同形态(纯思考摊死),属模型行为而非瞬时故障,重跑大概率复现且烧配额,按「确定性错误不重试」口径留档。

## 10. 成本

- z.ai 组:SSE 不透出 usage,按轮 2 §5 估算口径列于 §2 表(待 console 校准)。注:思考型模型推理 token 按输出价计费,5.3-flash 实际成本高于估算列;本轮 z.ai 实际花费发生在 Coding Plan 订阅通道内,无按量扣费。
- OpenRouter 组(key usage 前后差实测):R5 $0.0429 / 75 次;R6 $0.0837 / 76 次(含 1 重试);**合计 $0.1266**,占 $5 限额 2.5%。
