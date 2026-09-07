# D1 遥测开通方案(上线前置)

> 创建:2026-09-07 · 分支:`yaoce` · 状态:**待执行**
> 性质:运维执行单。客户端与 worker 代码**均已实现**,本方案零代码改动,只做:
> 建库 → 初始化 schema → salt 决策 → wrangler.toml 绑定 → deploy → 验证。
> 调研中发现的 4 个相邻缺口见 §6(其中 6.2 建议也列为上线前置,需另立拍板)。

---

## 0. 问题与动机

- 4 周软启动的过关判据是 **install→Pro ≥5%**(PROMOTION_PLAN §0/§4),漏斗七事件
  (`install → first_record → wow_shown → quota_hit → trial_start → trial_end → paid`)
  全部依赖遥测落库。ASC 后台只有下载量和订阅数(总分),给不出断在哪一环。
- 现状:`TELEMETRY_DB` 未绑定,`/v1/telemetry/events` 返回 503
  "Telemetry DB not configured"(`AIProxy/worker.js:455-458`)。
- **行为口径澄清**(修正此前"静默丢弃"的说法):
  - 服务端并不静默——返回 503 + `logWarn(telemetry.db_not_configured)`,日志可见;
  - 客户端收到非 2xx 会把事件回滚进队列下次重试(`App/TelemetryUploader.swift:156-161`),
    429 则丢弃当批(`:150-154`);
  - 真实风险是队列自身上限:**7 天 GC + 500 条容量**(`Protocols/TelemetryQueue.swift:66-70`),
    长期欠账必然丢;且若带着这个状态上线,4 周漏斗度量直接作废。
- 为什么必须赶在上线前:① 它是 PROMOTION_PLAN §2.3 的 gating 项;② `LOG_HASH_SALT`
  的决策窗口在**首个真实用户到来之前**(§3 Step 3)——上线后换 salt 等于自断设备维度口径。

## 1. 现状核实(2026-09-07 实测,证据可复查)

| # | 项 | 状态 | 证据 |
|---|---|---|---|
| 1 | 客户端 9 事件埋点 | ✅ 已实现 | TELEMETRY.md「9 个核心事件」;HomeView / AppCoordinator 等调用点 |
| 2 | 客户端队列 + 上传 | ✅ 已实现 | TelemetryQueue.swift(容量 500/保留 7 天/批上限 100)、TelemetryUploader.swift(BGProcessingTask,充电+联网,间隔 ≥1h) |
| 3 | worker 接收端点 | ✅ 已实现 | worker.js:444 `handleTelemetryBatch`:token 鉴权 → 设备配额 500/天(RATE_LIMIT_KV) → body 256KB/100 条上限 → batch insert |
| 4 | cron GC | ✅ 已激活 | wrangler.toml:127 `crons = ["*/30 * * * *"]`;worker.js:985 `if (env.TELEMETRY_DB)` 守卫,无 binding 时跳过不报错 |
| 5 | **D1 数据库** | ❌ **不存在** | `wrangler d1 list` 仅有 `voicetodo-feedback` |
| 6 | wrangler.toml 绑定 | ❌ 注释未填 | wrangler.toml:116-119(`[[d1_databases]]` 整块注释) |
| 7 | TELEMETRY_DAILY_LIMIT | ✅ =500 | wrangler.toml:45 |
| 8 | APP_TOKEN secret | ✅ 已配置 | `wrangler secret list` |
| 9 | LOG_HASH_SALT secret | ❌ 未配置 | fallback 链 `LOG_HASH_SALT → APP_TOKEN → "voicetodo"`(worker.js:2032-2036),现以 APP_TOKEN 兼任 salt |
| 10 | ADMIN_TOKEN secret | ❌ 未配置 | 影响 AI 成本拍板后的 admin 灰度切换,见 §6.3 |
| 11 | 线上部署版本 | 2026-09-05 11:42 UTC | `wrangler deployments list`;其后 main 有 **2 个未部署的 AIProxy 提交**:`503e448`、`7d3ea0c`(均为告警修复,见 §3 Step 5) |

## 2. 方案总览

```
Step1 建库 → Step2 schema(--remote) → Step3 LOG_HASH_SALT(拍板)
→ Step4 wrangler.toml 解注释+填 id → Step5 deploy(携带告警修复) → Step6 验证(§5)
```

仓库内唯一 diff = `AIProxy/wrangler.toml`(`wrangler.toml.example` 保持模板形态不动)。

## 3. 分步执行清单

### Step 1 创建 D1 数据库

```bash
cd AIProxy
npx wrangler d1 create voicetodo-telemetry
```

记下返回的 `database_id`(uuid 形态)。

### Step 2 初始化 schema(⚠️ 必须带 `--remote`)

```bash
npx wrangler d1 execute voicetodo-telemetry --remote --file=./schema.sql
# 验证表已建:
npx wrangler d1 execute voicetodo-telemetry --remote \
  --command "SELECT name FROM sqlite_master WHERE type='table';"
```

⚠️ TELEMETRY.md「部署步骤」的原命令**缺 `--remote`**——不带只会写进本地 miniflare,
线上库仍是空表,部署后所有 insert 失败。本方案已修正;完成后回写 TELEMETRY.md(§7)。

### Step 3 LOG_HASH_SALT(决策点 D1,先拍板再动)

背景:`device_id = "sha256:" + sha256(salt:原始ID)`(worker.js:2032-2036)。
**salt 一换,全部设备身份重置**——D1 里 90 天留存内的同一台设备会变成两个 ID,
DAU / 留存 / 漏斗的纵向口径全部断链。

| 选项 | 做法 | 代价 |
|---|---|---|
| **A(推荐)** | `openssl rand -hex 32` → `npx wrangler secret put LOG_HASH_SALT` | 无。现在 D1 是空库,切换零成本 |
| B | 维持现状(APP_TOKEN 兼任 salt) | APP_TOKEN 将来若轮换,同样断链;token 与 salt 职责耦合,泄露面重叠 |

推荐 A 的一句理由:**换 salt 的代价在上线后从 0 变成"自断度量",现在做是免费的**。

### Step 4 wrangler.toml 解注释并填 id

`AIProxy/wrangler.toml:116-119` 解注释,`database_id` 填 Step 1 的真实值:

```toml
[[d1_databases]]
binding = "TELEMETRY_DB"
database_name = "voicetodo-telemetry"
database_id = "<Step 1 返回的 uuid>"
```

改完跑一次配置断言,确认没破坏现有不变量:

```bash
node --test wrangler-config.test.js
```

### Step 5 部署

```bash
npx wrangler deploy
```

**影响面(必须知情)**:deploy 是整包上传,本次**必然携带** main 上两个未部署的告警
修复(`503e448` 双 review 循环修正、`7d3ea0c` 层 B/C 5 缺陷修复)。二者已过双 review
并 push,本就处于"待 wrangler deploy"状态,顺势一起上是预期内的好事——但验证清单因此
必须包含告警项(§5 第 5 条)。除非先 revert 它们,否则无法"只上遥测"(不建议 revert:
它们修的是"故障不可见",正是本次要开通的观测能力的一部分)。

与周二(2026-09-08)AI 成本评测窗口无冲突:评测走本地 `wrangler.eval.toml` + 本地
wrangler dev,不碰生产。若评测后要换主力模型,届时走 admin 端点灰度(需先补
ADMIN_TOKEN,§6.3),与本方案解耦。

### Step 6 验证

见 §5,部署后 30 分钟内逐项过。

## 4. 回滚

| 层 | 手段 | 说明 |
|---|---|---|
| worker 代码 | `npx wrangler rollback` | 回到 09-05 版本;告警修复与遥测绑定一起回退 |
| 数据 | 无需回滚 | D1 数据独立于 worker 版本,回滚不丢已落库事件 |
| 配置 | git revert wrangler.toml 改动 + redeploy | 无预期场景:遥测端点失败不影响核心链路(`/v1/todo-extractions` 不经过 TELEMETRY_DB) |
| salt | **不要回滚** | LOG_HASH_SALT 一旦产生数据就冻结(§3 Step 3) |

## 5. 验证清单(部署后逐项勾)

1. **冒烟(无 app,可留前后对照)**——部署前先打一次期望 503,部署后同命令期望 200:

   ```bash
   curl -sS -X POST https://ai.saydo.org/v1/telemetry/events \
     -H "X-App-Token: <APP_TOKEN>" -H "X-Device-ID: verify-smoke-01" \
     -H "Content-Type: application/json" \
     -d '{"events":[{"name":"app_launch","timestamp":0,"sessionID":"verify","deviceID":"x","appVersion":"verify","iosVersion":"verify","params":{},"extractID":"none"}]}'
   ```

   期望 `200` + `{"accepted":1,...}`(`timestamp:0` 会被 worker 用服务端时间兜底,worker.js:495)。

2. **落库**:

   ```bash
   npx wrangler d1 execute voicetodo-telemetry --remote \
     --command "SELECT event_name, device_id, received_at FROM telemetry_events ORDER BY id DESC LIMIT 5;"
   ```

3. **真机端到端**:开发 build 启动 + 录一条 → 触发 `uploadNow()`(或等 BGTask,
   注意其条件是充电+联网,手动验证时直接调 uploadNow 更快)→ D1 出现
   `app_launch` / `recording_started`,且 `device_id` 为 `sha256:` 前缀。
4. **cron GC 路径**:等下一个 `*/30`,`npx wrangler tail` 过滤 `telemetry.cron`,
   期望 `gc_done`(首次为 `deleted: 0` 也算通过——走通即证明 binding 在 scheduled
   路径可见)。
5. **搭车的告警修复验证**:按 `docs/alerting-layer-bc-review-fixes.md` 的验收口径
   (half-open 探针 / Telegram 推送 / healthchecks.io 心跳)。
6. **(可选)配额守卫**:同一 device 连发 >500 条,期望 429。

## 6. 调研中发现的相邻缺口(不阻塞本方案,需另立)

### 6.1 上传不分批(积压场景丢事件)

`uploadBatch` 一次 `drain()` 整个队列发**单个**请求(TelemetryUploader.swift:113-126),
而 worker 每请求只取前 100 条(worker.js:470,`MAX_TELEMETRY_EVENTS_PER_BATCH`),
超出部分在响应里计入 `dropped` 且 HTTP 200——客户端视为成功、队列已清空 → **永久丢**。
触发条件:队列积压 >100(即服务端长期故障后恢复)。另有对偶风险:body 超 256KB →
413 → 回滚 → 再 413 死循环(7 天 GC 兜底)。

正常上线流量(单设备日均几十条)不会触发。**处置:上线后按周查
`telemetry.events.accepted` 日志里的 dropped 字段,发现 >0 再修 uploader 分批循环**
(按 `maxBatchSize=100` 切片,改动小、测试基建现成)。

### 6.2 遥测开关未实现,但隐私政策已承诺(建议列为上线前置)

`PRIVACY_POLICY.md:63/112` 明文承诺 *"You can turn diagnostic reporting off at any
time in the app's settings"*;设置页(HomeSettingsSheet)没有这个开关,TELEMETRY.md
「关闭遥测」一节也标注待实现。**已上线的政策页与实现不符** → App Review 5.1.1 风险,
也是对用户的失信。二选一(决策点 D2):

- 实现 toggle(设置页加开关 + `TelemetryUploader` 短路 + 本地队列停入队);
- 或先把 Pages 政策措辞改为与现状一致(代价:D1 开通后无用户退出手段,申报口径
  "App 功能用途"虽仍成立,但政策不能再承诺不存在的控制)。

推荐实现 toggle:工作量小,且政策页已对外发布,改回来的成本更高。

### 6.3 ADMIN_TOKEN 未配置

AI 成本评测拍板后的"admin 端点灰度切换 provider 主力"(AIProxy/eval/README.md §4.2)
依赖 `X-Admin-Token`,当前 secret 列表里没有。届时执行
`wrangler secret put ADMIN_TOKEN`(openssl rand -hex 32),与本方案解耦,仅备忘。

### 6.4 文档过时(随 §7 一并修)

- LAUNCH_MATERIALS_INDEX.md §3「生产部署停在 2026-07-24」已过时:
  实际 08-30 已上 free=3(wrangler.toml:17 注释有载),09-05 已上告警 B/C;
- schema.sql:3 注释「每天 03:00 UTC 清理」与实际 `*/30` cron 不符(每次 cron 都跑,
  按 90 天 cutoff 删);
- TELEMETRY.md 部署命令缺 `--remote`(§3 Step 2 已述)。

## 7. 完成后的文档同步(一次性)

| 文件 | 改什么 |
|---|---|
| TELEMETRY.md | 部署步骤补 `--remote`;头部状态注记"已开通(日期)" |
| AIProxy/wrangler.toml | [vars] 注释块追加一行部署记录(日期 + 本次内容) |
| LAUNCH_MATERIALS_INDEX.md | §1.7 TELEMETRY 状态 ⚠️→✅;§3 生产部署行刷新到本次 |
| app-store-submit-checklist.md | §0 前提里已过时的"待部署生效"表述修正 |
| docs/telemetry-d1-enablement.md | 本文件:状态改"已执行",勾选 §5 |

## 8. 决策点汇总

| # | 决策 | 推荐 | 状态 |
|---|---|---|---|
| D1 | LOG_HASH_SALT 现在配独立值,还是接受 APP_TOKEN 兼任 | 现在配(§3 选项 A) | 待拍板 |
| D2 | 遥测开关(§6.2):实现 toggle 还是改政策措辞 | 实现 toggle | 待拍板(另立工作项) |
