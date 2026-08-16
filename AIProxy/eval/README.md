# AI 抽取质量评测(AIProxy/eval)

> 目的:为 PROMOTION_PLAN.md §2.1 的 AI 成本决策(方案 A 换便宜模型)提供质量 A/B 证据。
> 「每 Pro 用户月亏 $10」不解决不上线——本工具回答:**便宜模型在抽取质量上掉多少,值不值得换**。
> 零依赖(Node ≥ 18 全局 fetch),不需要 npm install。

## 1. 快速开始

### 1.1 单 provider 本地起服务(防 failover 混样)

评测期间 `wrangler dev` 的 PROVIDERS **只配一条**(多条 enabled 时超时会静默切到别家,结果混样)。临时改法——不要动正式 `wrangler.toml`,复制一份:

```bash
cd AIProxy
cp wrangler.toml wrangler.eval.toml
# 编辑 wrangler.eval.toml:
#   [vars] DAILY_REQUEST_LIMIT = "200"   # 必须 ≥ case 数 + 重试余量(72+),否则跑一半 429
#   PROVIDERS = [ ...只留你要测的这一条,model 改成候选... ]
npx wrangler dev -c wrangler.eval.toml   # 默认 http://localhost:8787
```

wrangler.eval.toml 已在 AIProxy/.gitignore,不会误提交。

API key 放 `.dev.vars`(已在 .gitignore,格式 `PROVIDER_KEY_XXX=sk-...`)。

**候选模型(Z.AI 系,零新 key)**:在 Z.AI 控制台确认 air/flash 档可选模型名后填进 PROVIDERS 的 `model`。基线 = 现役 Sonnet 配置。

### 1.2 跑评测

```bash
cd AIProxy/eval
# 基线
node run.mjs --endpoint http://localhost:8787 --token <APP_TOKEN> --label baseline-sonnet
# 候选(改 wrangler.eval.toml 的 model 后重启 wrangler dev,再跑)
node run.mjs --endpoint http://localhost:8787 --token <APP_TOKEN> --label glm-air
# 中断续跑
node run.mjs ... --label glm-air --resume
# 改了 golden 只想重评(不花钱重发)
node run.mjs --replay results/glm-air-<ts>.json
```

参数:`--gap`(请求间隔 ms,默认 300)/`--timeout`(单条超时,默认 90s)/`--dataset`(默认 dataset.json)。

退出码:0 正常 / 1 用法或环境错误 / 2 有 case 重试后仍失败(看 results 里的 error)。

⚠️ **运行窗口约束**:golden 的相对日期语义按周三锚定,worker 对 `X-Local-Date` 只容忍 ±1 天漂移 → **只能在 UTC 周二/周三/周四 运行**(北京时间周二 8 点 ~ 周五 8 点)。其他日子 run.mjs 会直接报错并说明原因,不会静默产出错位结果。

## 2. 机制(为什么这么设计)

| 机制 | 原因 |
|------|------|
| `stream: true` 发请求 | 绕开 KV 结果缓存(缓存条件 `!stream && !personalHints`)。否则同一 transcript 跨模型重跑会命中同一份缓存,测了个寂寞 |
| 每次 run 生成唯一 `X-Device-ID`(`eval-<label>-<ts>`) | 配额桶按 sha256(设备ID)+日期计;固定设备 ID 会在第二个 provider 时 429。唯一 ID 同时避免污染真实用户桶 |
| `X-Local-Date` 动态周三锚 | 该头同时驱动 quota 日期与 prompt 的 today 注入,但 worker 的 `resolveQuotaDate` 只容忍 ±1 天漂移(超限回退 server UTC,prompt 参考日期跟着变)。固定写 dataset 里的 `2026-01-07` 在其他任何一天都会被拒。因此 runner 每次 run 在 UTC 今天 ±1 天内选一个周三作锚(与 authoring 锚同星期 → tomorrow/下周三/周五前 等的目标偏移完全同构),把 golden 日期按锚偏移平移;`end-of-month` tag 的 case(en-013/zh-010/ja-009)重算为锚当月最后一天。每条响应回读 `X-Quota-Reset-Date` 校验锚确实被接受,被拒立即中止 |
| 5xx/超时/429/JSON 解析失败 → `infra_error` | 不计入准确率,收尾自动重试一次;仍失败退出码 2 |
| 原始响应先落盘 `results/<label>-<ts>.json`(含本次锚 `anchorToday`) | 评分独立可重放(`--replay` 复用落盘时的锚,重放与当时发送用同一套期望日期),改 golden 不用重新花钱 |

## 3. 评分口径

- **hard 字段(过关线只看这些)**:`due_date` / `due_time` / `recurrence_rule`(frequency/interval/weekdays/day_of_month/end_date 归一化后整体比对)/ `category_hint` / `priority` / `due_date_basis` / `reminder_times` + **拆分数量**
- **soft 字段(仅诊断,不 gate)**:`title` / `time_bucket` / `recurrence_end` / `ignored`(双空/双非空)/ `detail`(不评)
- **两级配对**:先按 hard 字段全集签名做顺序无关贪心配对(模型输出顺序不保证);case 过关 = 数量一致 + 全部严格配对。未严格配对的部分再用「字段重合度最大」兜底配对,只为产出字段级诊断(定位是日期错还是分类错)
- 归一化:缺 `interval` → 1、`weekdays`/`reminder_times` 排序、缺字段 → null

## 4. 过关线与决策规则

### 4.1 过关线(en + zh,ja 不 gate)

1. case 全对率 **≥ 98%**(即 54 条 en+zh 里最多错 1 条)
2. 相对 Sonnet 基线:case 全对率差距 **≤ 1pp**(基线不满分时按相对差距判)
3. **日期/重复组零回归**:`due_date`、`due_time`、`recurrence_rule` 三列字段准确率不得低于基线

### 4.2 决策规则(接 PROMOTION_PLAN §2.1)

| 结果 | 动作 |
|------|------|
| 候选过关 + 成本降 ≥90% | 方案 A:换主力(生产用 admin 端点灰度切换,别一次全量) |
| 候选差 1-3pp,集中在个别字段 | 加针对性 few-shot 示例后重测一轮;两轮不过 → 方案 B(限额) |
| 候选差 >3pp | 方案 B:PAID_DAILY_LIMIT 100 → 30-50/day,Sonnet 保留 |
| Sonnet 基线本身 <95% | 先修 prompt/dataset(golden 可能过严,`--replay` 复核),再谈对比 |

## 5. 成本模型(填空表)

单次请求成本 ≈ (prompt tokens × 输入单价 + 输出 tokens × 输出单价)。token 估算用校准因子:跑 3 条样本去 provider console 核对实际 token 数,把 chars/token 比值填进来:

| locale | prompt chars(实测 base.js 三版本) | chars/token 校准 | 输出均值(实测) |
|--------|------|------|------|
| en | ____ | ____ | run 报告的 `avgResponseChars` |
| zh | ____ | ____ | 〃 |
| ja | ____ | ____ | 〃 |

| 模型 | 输入 $/M tok | 输出 $/M tok | 单次 ≈ | Pro 100/day 月成本 ≈ |
|------|------|------|------|------|
| claude-sonnet-4.5(基线) | ____ | ____ | ____ | ____ |
| 候选 1: ____ | ____ | ____ | ____ | ____ |

> 决策只依赖**相对比较**(候选 vs 基线的倍数),绝对值标「估算」。填好后按 4.2 决策。
> 注意 PROMOTION_PLAN §2.1 的量级参考:Pro 100/day × Sonnet ≈ 月成本 $15 vs 收入 $4.99。

## 6. 日文就绪判读(ja 18 条,全 provisional)

ja golden 无母语审,只看两点:
1. **结构性错误率**:ja 的 due_date/recurrence 与 en+zh 的差距 ≤ 3pp → 说明模型对日期/重复的日语理解不掉档
2. **已知失败模式专项**:`ja-014`(「今度」歧义→应为 due null + user_explicit)、`ja-015`(敬体)、标题语言保持(soft 的 title 列)

ja 过关 ≠ 日文市场开放(还差母语审,见 PROMOTION_PLAN 附则 3);ja 不过关也不影响英文市场上线。

## 7. 维护

- **改 golden**:`--replay` 重评旧 results,确认分数变化符合预期再跑新模型
- **加 case**:日期一律按 `meta.anchor_today`(2026-01-07 周三)口径写绝对日期,runner 会动态平移;**月底 case 必须打 `end-of-month` tag**(runner 对这类 case 重算为锚当月最后一天,均匀平移会算错;⚠️ 「月中」目前不支持——tag 只映射月底,加月中 case 需先扩展 runner);case 级 `today` 覆盖**不支持**(runner 会显式报错——其 golden 的星期语境未知);ja 加 `provisional: true`
- **prompt 变更后**:全模型重跑基线(few-shot 一变,旧结果不可比)
- `results/` 已 gitignore(`eval/.gitignore`),不要提交原始响应;`wrangler.eval.toml` 已 gitignore(`AIProxy/.gitignore`)

## 8. 已知边界

- 评测走流式路径(`stream: true`),与非流式路径的模型行为理论上一致(同一 prompt、同一模型),但极端情况下 SSE 拼装差异会计入 `infra_error` 而非质量问题
- 超长 transcript 未覆盖:worker 对 >4000 chars 输入直接 413(`MAX_TRANSCRIPT_CHARS`);客户端的 `transcriptTooLong` 是 max_tokens 输出截断的错误映射(提示用户分批),两者评测集都不覆盖
- 温度非 0 的模型有随机性;如见单 case 抖动,重跑该 case(`--resume` 跳过其他)对比
