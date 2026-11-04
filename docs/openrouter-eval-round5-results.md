# 评测轮 5 结果:新 prompt 复验 + 三席供应商选型(2026-11-04)

> 背景:prompt 修复(0e8108b)合入并部署后,轮 4 的旧 prompt 分数全部失效,第二/三席候选需新口径重测;用户拍板「三席三供应商」结构,第三席诺达中转为用户自有渠道。

## TL;DR

1. **deepseek-v4.1-flash@OR 新 prompt 复验 74/74 = 100%**(三语满分,hard 七字段全绿,p50 2.2s/p95 5.9s/零超时)——旧 prompt 错的 2 条 ja 日期正是 prompt 修复靶点,药到病除。**定第二席**。
2. **诺达中转(claude-sonnet-5-5)三重不合格判死**:infra 51%(38/75,重试仅救回 13)/计分 91.9%/p50 11.3s+firstText 9.9s。渠道级劣化,换模型无解;两例「日期偏一天」疑似中转注入自身时区干扰。用户原设的 glm-5.3-flash 在诺达不存在(该渠道仅 8 个 Claude 系模型)。
3. **gemini-3.8-flash@OR 新 prompt 97.3%**(73/75):仅剩 2 错全是 category_hint 语义灰区(work/finance、life/health),日期/basis 全 100%——差一条过线且非 prompt 可修。**留档不进池**。
4. 终局阵容(路线乙,供应商交错):`air(z.ai,100%) → deepseek(OR,100%) → flash(z.ai,97.3% 保留现产位)`;OR_DEEPSEEK_FLASH 条目=prio 2,flash 原位 prio 3 无需降位。

## §1 新 prompt 复验对照(同模板同数据集,仅 prompt 版本不同)

| 候选 | 旧 prompt(轮4) | 新 prompt(轮5) | 失败形态变迁 |
|---|---|---|---|
| deepseek-v4.1-flash@OR | 97.3%(ja 日期×2) | **100%**(74/74) | 2 错清零,延迟 p95 10.3s→5.9s |
| gemini-3.8-flash@OR | 97.3%(en-016 日期+zh-017 类目) | 97.3%(73/75) | 日期错清零,剩类目灰区×2 |
| glm-5.3-flash 直连(参照,R1/R1b) | 97.3% | 未复验(留第三席维持) | — |

## §2 诺达中转判死记录(r5-nuoda-sonnet55)

- 探针:渠道活、key 有效、claude-sonnet-5-5 上游为真 Claude Messages API(usage 元数据 anthropic 源)。
- 评测:75 发 → **38 infra**(流式/超时形态,重试救回 13),计分 37 条中 34 对(91.9%);ja-010/zh-007 日期偏一天(want 11-11 got 11-12)疑渠道侧时区/系统注入。
- 延迟:p50 11.3s / firstText p50 9.9s / 1 条>30s。
- 结论:通道质量<模型质量的重演(CLAWTO 同款,且 infra 更甚),**渠道出局**;预充额度不建议续充。

## §3 第三席路线对比(拍板依据)

| 路线 | 阵容 | 供应商结构 | 取舍 |
|---|---|---|---|
| 甲 | air → deepseek → gemini | z.ai/OR/**OR** | 二三席共享 OR 通道,OR 全灭只剩 air |
| **乙(拍板)** | air → deepseek → flash | z.ai/OR/**z.ai** | 交错结构,任一家全灭都有一家在场;flash 零改动 |

## §4 落地清单

- toml:`OR_DEEPSEEK_FLASH`(prio 2,timeout 30s,secret OPENROUTER_PROD_KEY,extraHeaders OR 归因)——d240435。
- 生产 secret OPENROUTER_PROD_KEY 已于 2026-11-04 经 wrangler 写入(从与线上同配置目录执行,零行为变化,待部署激活)。
- MAX_ATTEMPTS=2 不变,客户端 55s 预算不动;gemini 模板+分数留档(翻案=改 toml 加条目)。
- key 安全待办:OPENROUTER_KEY(评测,聊天暴露)、OPENROUTER_KEY2(已过期)、ZAI_KEY_2、NUODA_KEY 全部建议吊销;生产仅留 OPENROUTER_PROD_KEY(新建,亦经聊天交付,长期建议轮换为后台直接操作)。
