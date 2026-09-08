# 层 B/C 告警 review 修复方案

对已合入 main 的告警实施（`3f7f051` 层 B/C 实施 + `503e448` 双 review 循环修正）做 review 后发现的 5 处缺陷与修法。

**背景文档：** `ALERTING.md`（四层告警设计）。本文档只处理已实施的层 B/C，层 A/D 仍待发版，不在范围内。

## 先说结论

实施质量是好的：状态机（`classifyLevel` / `shouldNotify` / `nextRecord`）是干净的纯函数 + 注入 `now`，KV 存取降级完整，测试覆盖 30+ 条、超出原方案要求（连 body cancel、非 2xx 心跳留痕这些都覆盖了）。

但有 5 处缺陷，**其中 3 处会让故障变得不可见**。对告警系统而言这是最糟的失效方向——宁可吵，不可哑。一个在故障时报绿的告警系统，比没有告警系统更危险，因为它会让人以为「没收到告警 = 没出事」。

按严重度：

| # | 缺陷 | severity | 后果 |
|---|------|----------|------|
| 1 | `/v1/health` 把 `half-open` 当健康 | **HIGH** | 层 C-1 基本失效，外部拨测扫不到故障 |
| 2 | secret 全缺时三层同时装瞎 | **HIGH** | 密钥轮换出错 → 100% 提取失败 → 零告警 |
| 3 | `enabled: false` 的 provider 计入分母 | MEDIUM（潜伏） | 总故障被报成局部，不推 🚨 |
| 4 | 告警状态先落盘再发送 | MEDIUM | Telegram 偶发失败 → 告警永久丢失 |
| 5 | 心跳 `/fail` 字符串拼接 | LOW（潜伏） | 故障心跳被当成成功心跳 |

## ⚠️ 缺陷 1、2 的源头是方案文档，不是实施

**这一点接手前务必先看，否则会误判代码质量、或以为照现有 `ALERTING.md` 改就行。**

实施方是严格按 `ALERTING.md` 的硬约束执行的，代码注释里还逐条引用了约束编号。是**约束本身有洞**：

- 缺陷 1 ← `ALERTING.md` 层 C-1 硬约束 3 原文写的是「全部 provider **`open`** → 503」。写方案时漏掉了 `half-open` 这个**读时派生状态**的存在。
- 缺陷 2 ← `ALERTING.md` 层 B 边界原文写的是「没有可探活的 provider 不算 `down`。secrets 全缺时……不告警，避免配置问题被误报成服务故障」。这句话本身是错的判断。

所以**修代码的同时必须修 `ALERTING.md`**（具体改法见文末「文档同步修订」一节）。只修代码不修文档，下一个照文档做事的人会把它改回去。

缺陷 3、4、5 是实施层面的，与方案文档无关。

---

## 缺陷 1：`/v1/health` 把 `half-open` 当健康（HIGH）

### 证据

`AIProxy/worker.js:863`：

```js
const allOpen = entries.length > 0 && entries.every((e) => e.state === "open");
const status = allOpen ? "down" : entries.some((e) => e.state === "open") ? "degraded" : "ok";
const httpStatus = allOpen ? 503 : 200;
```

`entries[].state` 来自 `sharedHealthStore.snapshot(p.id, now)`，其值由 `AIProxy/src/health.js` 的 `classifyState()` 算出：

```js
function classifyState(record, now) {
  if (record.state !== "open") {
    return record.state === "half-open" ? "half-open" : "closed";
  }
  const cooldown = record.cooldownMs > 0 ? record.cooldownMs : configuredInitialCooldownMs;
  return now - record.openedAt >= cooldown ? "half-open" : "open";   // ← 关键
}
```

**熔断打开后，只要冷却期一过，读出来就是 `half-open` 而不是 `open`。** 而 `half-open` 既不满足 `every(state === "open")` 也不满足 `some(state === "open")` → 落到 `else` 分支 → `200 + "ok"`。

### 实际后果（按默认参数算）

`health.js` 默认值：`DEFAULT_THRESHOLD = 5`、`DEFAULT_INITIAL_COOLDOWN_MS = 10_000`、`DEFAULT_MAX_COOLDOWN_MS = 5 * 60_000`。

故障发生后：

1. 连续 5 次失败 → 熔断 `open`，`openedAt = now`，`cooldownMs = 10s`
2. **10 秒后**，任何 `/v1/health` 读取都返回 `half-open` → `200 ok`
3. 每 30 分钟 cron 探活失败 → `recordFailure` 见 `previousState === "half-open"` → 重新 `open`、`openedAt` 重置、冷却翻倍（10s → 20s → 40s …… 封顶 5min）

所以稳态下，**每 30 分钟的周期里最多只有 5 分钟窗口报 503**（≈17%），故障刚发生时窗口只有 10 秒。5 分钟间隔的 UptimeRobot 绝大多数轮询都会扫到那个 `200 ok`。

夜间无流量时更糟：没有请求就不会触发新的 `recordFailure`，`half-open` 会一直挂着（这是读时派生状态，不需要写入就一直成立），探针**永远绿**。

层 C-1 的存在意义就是「Worker 还活着但 AI 全挂」时给出外部可见信号，这个缺陷让它基本失效。

### 修法

`half-open` 的语义是「曾经挂了，尚未证明恢复」——恢复是靠 `recordSuccess` 把状态写回 `closed` 的。对一个外部探针来说，只有 `closed` 才算健康。

```js
const unhealthy = (s) => s === "open" || s === "half-open";
const allBad = entries.length > 0 && entries.every((e) => unhealthy(e.state));
const status = allBad ? "down" : entries.some((e) => unhealthy(e.state)) ? "degraded" : "ok";
const httpStatus = allBad ? 503 : 200;
```

> 单次抖动打开熔断后会短暂显示 `degraded`（200，不是 503），这是可接受且正确的——`degraded` 本来就该表达「有 provider 不在健康态」。只有全部不健康才 503。

### 为什么现有测试没抓住

`worker.test.js` 的三条探针状态测试是 `全 closed → ok` / `部分 open → degraded` / `全 open → 503`，**没有一条构造 `half-open`**。测试忠实地镜像了方案文档里的口径，而方案文档漏了这个状态。

---

## 缺陷 2：secret 全缺时三层同时装瞎（HIGH）

### 证据

`AIProxy/worker.js:1094`：

```js
const probeable = results.filter((r) => {
  if (r.status !== "fulfilled") return false;
  return r.value?.reason !== "no_key" && r.value?.reason !== "no_adapter";
}).length;
let level = null;
if (probeable === 0) {
  logInfo("health_check.alert_skipped", { reason: "no_probeable_provider", total });
} else {
  level = classifyLevel(succeeded, total);
}
if (level) {
  await notifyProviderHealthTransition(env, { level, succeeded, total, failedDetails, fetchImpl });
}
return level;
```

全部 provider 缺 `apiKey` 时，三层同时失效：

- **层 B**：`level` 为 `null` → 不告警，且**不写告警状态**（`notifyProviderHealthTransition` 根本没被调用）
- **层 C-2**：`runProviderHealthCheck` 返回 `null` → `handleScheduled` 里 `level === "down"` 为 false → 发**成功**心跳。healthchecks.io 一切正常
- **层 C-1**：这些 provider 的熔断器从没被 `recordFailure` 过 → 记录停在 `closed` → `/v1/health` 返回 `200 ok`

即：**密钥轮换写错一个字符 → 100% 的提取请求失败 → 层 B、C-1、C-2 全部报健康。**

这正是整套告警系统要防的头号场景，而且是运维时真实会发生的操作（`wrangler secret put` 贴错、secret 名改了没同步 `PROVIDERS` 的 `secretName`）。

### 为什么原判断是错的

原方案的理由是「配置问题不该被误报成服务故障」。这个理由在 `total === 0`（压根没配 provider）上成立，但套到「provider 配置在、secret 全缺」上就错了——**后者是真实的、100% 的服务不可用**，用户此刻一个字都提取不出来。它是不是「配置问题」不重要，重要的是用户用不了。

两边代价也完全不对等：误报一次的代价是维护者瞥一眼 Telegram；漏报一次的代价是全部用户不可用而维护者不知道。

（顺带：`classifyLevel` 里 `total <= 0 → null` 的纯函数兜底可以保留，它确实到不了——`loadProviders` 对空 `PROVIDERS` 直接抛错，走 `providers_failed` 早退。有问题的只是 `probeable === 0` 这个分支。）

### 修法

`probeable === 0` 判为 `down`，照常走告警 + `/fail` 心跳。**区分的是文案，不是告不告警**：

```js
let level;
if (probeable === 0) {
  // 全部 provider 缺 key/adapter = 100% 提取不可用,这是真实故障不是「配置问题可以不管」。
  // 用独立 reason 让告警文案说清是配置问题,便于第一时间判断该去改 secret 而不是查上游。
  level = "down";
  logWarn("health_check.no_probeable_provider", { total });
} else {
  level = classifyLevel(succeeded, total);
}
```

告警消息里要能一眼看出是配置问题——`failedDetails` 里本来就带 `no_key` / `no_adapter` 作为 reason，会渲染进 `failedLines`，确认这条路径下消息可读即可（必要时在 `buildHealthAlertMessage` 里对全 `no_key` 的情况加一句提示）。

### 要改的测试

现有测试 `cron 告警: secrets 全缺(无可探活 provider)不推 down,不写告警状态`（`worker.test.js:5236`）**固化了错误行为**，必须改成断言相反的结果：推 down 告警 + 打 `/fail` 心跳。

---

## 缺陷 3：`enabled: false` 的 provider 被计入分母（MEDIUM，当前潜伏）

### 证据

`AIProxy/src/config.js:99` 只是给字段赋值，`loadProviders` **仍然返回**停用的 provider：

```js
enabled: entry.enabled !== false,
```

而真正派流量的 `AIProxy/src/selector.js:34` 会跳过它们：

```js
if (provider.enabled === false) continue;
```

告警侧两处都没有对齐这个口径，直接用了 `loadProviders` 的全量结果：

- `worker.js:1061`（`runProviderHealthCheck`）：`const total = providers.length;`，且 `providers.map()` 会去探活停用的 provider
- `worker.js:859`（`/v1/health`）：`providers.map()` 把停用的 provider 也列进 `entries`

### 后果

- **停用但健康** → 撑高 `succeeded` 与 `total`。唯一在跑的 provider 挂掉时算出 `degraded`(1/2) 而不是 `down`(0/1) → **不推 🚨、没有 6h reminder、心跳照发成功、探针 200**。总故障被报成局部故障。
- **停用且已挂** → 永久假 `degraded`。更糟的是之后真的全挂时是 `degraded → degraded`，**不产生任何新告警**（`shouldNotify` 只在 level 变化时推，且 reminder 只对 `down` 生效）。

当前 `AIProxy/wrangler.toml` 里两个 provider 都是 `"enabled": true`，所以尚未发作。但停用某个 provider 正是运维会做的动作（比如某家上游涨价或不稳时先摘掉），这是个等着被踩的雷。

另外，探活停用的 provider 也在白白消耗上游配额——虽然 probe 用的 transcript 是 `"test"`，量很小，但没有意义。

### 修法

两处都按 `enabled` 过滤，与 `pickCandidates` 口径对齐：

```js
const activeProviders = providers.filter((p) => p.enabled !== false);
```

`runProviderHealthCheck` 用它算 `total` 和做 `map`；`/v1/health` 用它构造 `entries`。

> 注意保持与 `selector.js:34` 完全同一个谓词（`=== false` 而非 truthy 判断），避免两处漂移。

---

## 缺陷 4：告警状态先落盘再发送，且忽略发送结果（MEDIUM）

### 证据

`AIProxy/worker.js:897`：

```js
const previous = await sharedAlertStateStore.load();
const decision = shouldNotify(previous, level, now);
const record = nextRecord(previous, level, decision, now);
await sharedAlertStateStore.save(record);      // ← lastNotifiedAt 已写成 now,但还没发
if (!decision.notify) return;
// ...
const sent = await sendTelegramAlert(env, text, fetchImpl);   // ← 失败也不回滚
logInfo("alert.health.notified", { kind: decision.kind, level, delivered: sent.ok, ... });
```

`nextRecord`（`src/alertState.js:63`）：

```js
lastNotifiedAt: decision.notify ? now : (previous?.lastNotifiedAt || 0)
```

只看 `decision.notify`，不看实际是否送达。

### 后果

Telegram 偶发失败（网络抖动、超时、429 限流）时，这次跃迁已经被记成「已通知」。下一次 cron 跑，level 没变 → `shouldNotify` 返回不推。

- 对 `down`：还能等 6 小时后的 reminder 兜底，**延迟 6 小时**
- 对 `degraded`：`shouldNotify`（`src/alertState.js:51`）的 reminder 分支只对 `current === "down"` 生效，**这条告警永久丢失**，直到 level 再次变化

### 修法

`level` / `since` 照常落盘（不然 `since` 会漂、恢复消息里的故障时长会算错），但 `lastNotifiedAt` 只在真正送达后才写：

```js
const decision = shouldNotify(previous, level, now);
if (!decision.notify) {
  await sharedAlertStateStore.save(nextRecord(previous, level, decision, now));
  return;
}
// ... 构造消息
const sent = await sendTelegramAlert(env, text, fetchImpl);
// 发送失败(非 skipped)则不写 lastNotifiedAt,下次 cron 自然重试这条跃迁
const effectiveDecision = { ...decision, notify: sent.ok || Boolean(sent.skipped) };
await sharedAlertStateStore.save(nextRecord(previous, level, effectiveDecision, now));
logInfo("alert.health.notified", { kind: decision.kind, level, delivered: sent.ok, skipped: Boolean(sent.skipped) });
```

> `skipped`（未配 `TELEGRAM_*`）要当成「已处理」写入，否则每次 cron 都会重算一遍跃迁、刷无用日志。真正需要重试的只有 `ok === false && skipped !== true`。

---

## 缺陷 5：心跳 `/fail` 字符串拼接（LOW，当前潜伏）

### 证据

`AIProxy/worker.js:965`：

```js
const base = String(env.HEALTHCHECK_PING_URL).replace(/\/+$/, "");
const pingUrl = level === "down" ? `${base}/fail` : base;
```

healthchecks.io 的标准 ping URL 是 `https://hc-ping.com/<uuid>`，没有 query string，所以当前不发作。

但只要 URL 带 query——healthchecks.io 自身支持 `?rid=` 形式，或换用 Uptime Kuma 的 push URL（`/api/push/<token>?status=up&msg=OK`）——拼出来就是 `https://.../<uuid>?rid=xxx/fail`：**`/fail` 落进了 query value 里，服务端收到的是一次普通成功心跳。** 故障信号被静默降级成健康信号，正好是死人开关最不能出的错。

### 修法

用 `URL` 对象操作 pathname，而不是字符串拼接：

```js
function buildPingUrl(rawUrl, failed) {
  const url = new URL(rawUrl);
  if (failed) {
    url.pathname = `${url.pathname.replace(/\/+$/, "")}/fail`;
  }
  return url.toString();
}
```

非法 URL 会抛 `TypeError`，包在现有的 try/catch 里即可（心跳失败只 log，不打断 cron）。

---

## 改动清单

| 文件 | 改什么 |
|------|--------|
| `AIProxy/worker.js` | 缺陷 1（`:863`）、2（`:1094`）、3（`:859` + `:1061`）、4（`:897`）、5（`:965`） |
| `AIProxy/worker.test.js` | 改 `:5236`；补 4 类新测试（见下） |
| `ALERTING.md` | 文档同步修订（见下），**必做** |

## 要补/要改的测试

全部加在 `AIProxy/worker.test.js`，复用现有的 `makeFakeKV()` / `providersEnv()` / `jsonResponse()` helper。

| 测试 | 断言 | 对应缺陷 |
|------|------|----------|
| **half-open 探针**（新增） | 熔断打开且冷却已过 → 探针返 503 `down`（单 provider）/ `degraded`（多 provider 之一），**不能是 `ok`** | 1 |
| **secret 全缺**（改 `:5236`） | 推 `down` 告警 + 打 `/fail` 心跳 + 写告警状态 | 2 |
| **`enabled: false`**（新增） | 停用的健康 provider + 唯一启用的挂掉 → 判 `down` 而非 `degraded`；探针 `entries` 不含停用的 | 3 |
| **Telegram 发送失败**（新增） | `sent.ok === false` → `lastNotifiedAt` 不写入；下次 cron 同 level 仍重推 | 4 |
| **未配 `TELEGRAM_*`**（新增） | `skipped === true` → `lastNotifiedAt` 照常写入，不无限重算 | 4 |
| **ping URL 带 query**（新增） | `/fail` 落在 pathname 上，query 参数保留 | 5 |

构造 half-open 的办法：用 `makeFakeKV()` 预置一条 `health:<id>` 记录，`{ state: "open", openedAt: <past>, cooldownMs: 10000 }`，让 `openedAt` 早于 `now - cooldownMs`；或用 `configureHealthParams` 把冷却调到极短后触发失败再读。前者更直接、不依赖时序。

## 验证

```bash
cd AIProxy && npm test     # 全量,确认既有 30+ 条告警测试不回归
```

手测按 `ALERTING.md` 的「服务端手测」一节，**额外补一条专门暴露缺陷 1 的**：

```bash
cd AIProxy && npx wrangler dev
# 把 wrangler.toml 的 provider url 改成不可达地址
curl "http://localhost:8787/cdn-cgi/handler/scheduled"   # 触发探活,让熔断打开
# 关键:等 15 秒(超过默认 10s 初始冷却)再查
curl -i "http://localhost:8787/v1/health"
# 修复前:200 + {"status":"ok"}   ← 故障中却报健康,就是缺陷 1
# 修复后:503 + {"status":"down"}
```

这条最能直观说明问题，建议接手后**先跑它复现**，再动手改。

## 不要改的

- **状态机本身**（`classifyLevel` / `shouldNotify` / `nextRecord`，`src/alertState.js`）：逻辑正确，纯函数 + 注入 `now`，测试充分。缺陷 4 改的是 `worker.js` 里的调用顺序，不是状态机
- **探针的 15s isolate 缓存**、**body cancel**、**非 2xx 心跳留痕**：`503e448` 那轮加的，都是对的，别当成冗余删掉
- **单个 provider 缺 secret 计入 `degraded`**：这条与缺陷 2 是不同口径且**有意并存**——failover 容量减半该知道。只有「全部缺」才是缺陷 2 要改的
- **层 A / D**：仍待发版，不在本次范围

## 文档同步修订（必做）

改完代码后，同步修 `ALERTING.md`，否则下一个照文档实施的人会把缺陷改回去：

1. **层 C-1 硬约束 3**：把「全部 provider `open` → 503」改为「全部 provider **不健康（`open` 或 `half-open`）** → 503」，并补一句说明 `half-open` 是 `classifyState` 的读时派生状态、语义是「曾经挂了尚未证明恢复」，对外部探针必须算不健康。body 的 `status` 取值说明同步改。

2. **层 B 边界「没有可探活的 provider 不算 `down`」**：整条删掉，改成——

   > **全部 provider 缺 secret / adapter 判为 `down`。** 这是 100% 的服务不可用（用户一个字都提取不出来），不是「配置问题可以不告警」。用独立 reason 让告警文案说清是配置问题，**区分的是文案不是告不告警**。误报一次只是瞥一眼，漏报一次是全部用户不可用而没人知道。
   >
   > （`classifyLevel` 的 `total <= 0 → null` 纯函数兜底可保留，实际到不了：`loadProviders` 对空 `PROVIDERS` 直接抛错，走 `providers_failed` 早退。）

3. **层 B / C-1 补一句 `enabled` 口径**：探活与探针都只算 `enabled !== false` 的 provider，与 `selector.js` 的 `pickCandidates` 对齐——停用的 provider 不承接流量，计入分母会把总故障稀释成局部故障。

4. **层 C-2 心跳**：把 `env.HEALTHCHECK_PING_URL + "/fail"` 的写法改成 `new URL()` 操作 pathname 的描述。

---

## 实施记录（2026-09-07）

5 处修复已全部实施，`AIProxy` 全量测试 264 pass。与本文档的三处偏差，均为实施时发现文档自身不自洽，按下述方式收敛：

1. **缺陷 4 的修法补了另一半。** 「修法」小节只调整了 `worker.js` 的调用顺序（送达后才写 `lastNotifiedAt`），并断言「下次 cron 自然重试这条跃迁」，同时「不要改的」禁止动 `shouldNotify`——这两者矛盾：`level`/`since` 照常落盘后，下次 cron 时 level 未变，未修改的 `shouldNotify` 只会走 6h reminder（且仅 down 有），degraded 告警仍会永久丢失，本文测试规格里「sent.ok === false → 下次 cron 同 level 仍重推」也无法通过。实施时在 `shouldNotify` 补了一条纯函数规则：`current !== "ok" && !previous.lastNotifiedAt` → 重推（`kind = current`）。「不要改的」对状态机的保护相应收窄为：`classifyLevel` / `nextRecord` 未动，`shouldNotify` 仅增此分支。

2. **去掉了 `/v1/health` 的 `entries.length > 0` 守卫。** 缺陷 1 的修法片段保留了 `entries.length > 0 &&`，但缺陷 3 的 `enabled` 过滤落地后，空 `entries` 有了唯一新来源——全部 provider 停用（过滤前该守卫是死代码：`loadProviders` 对空 `PROVIDERS` 抛错走 `misconfigured`，`entries` 不可能为空）。此时 cron 探活走 `probeable === 0` 判 down + 打 `/fail` 心跳，探针若因空数组报 ok 就与心跳口径矛盾。空数组上 `every()` 的空真判定恰好给出 down/503，故直接去掉守卫，探针 / cron / 心跳三处口径一致。

3. **部署前提与事实不符。** 本文档写作时的前提是「B/C 已实施、尚未部署」。经 `wrangler deployments list` 核实：层 B/C 已随 **2026-09-05 11:43** 的部署上线（之后的两次 Secret Change 重新部署的也是修复前代码），**线上正在跑本文所述 5 处缺陷的版本**。结论从「先别急着部署」反转为「尽快重新部署」；`ALERTING.md` 状态表与警示块已照此改写。

其余按原文实施：缺陷 1/2/3/5 修法照抄；缺陷 2 的告警文案按「必要时加一句提示」落实（`buildHealthAlertMessage` 增 `configMissing` 提示行，覆盖 secrets 全缺与全部停用两种形态）；测试表 6 项全部落地，另补 open + half-open 混合探针与 `shouldNotify` 重推的单元断言。

---

# 第二轮 review（复核修复结果）

对 `7d3ea0c` 的复核。**5 处修复全部真修好了**，另发现 3 处遗留，其中 1 处说明缺陷 2 只修了三分之二。

## 复核结论：5 处修复通过

| 缺陷 | 复核 | 说明 |
|------|------|------|
| 1 half-open | ✅ | `unhealthy = open \|\| half-open`，`allBad` / `some` 两处都改了 |
| 2 secret 全缺 | ⚠️ **2/3** | cron 告警 ✅、`/fail` 心跳 ✅、**探针 ❌**（见遗留 1） |
| 3 enabled 过滤 | ✅ | 探活与探针两处都加了 `activeProviders`，谓词与 `selector.js:34` 一致 |
| 4 发送顺序 | ✅ | 见下，实施方补齐了本文档缺的另一半 |
| 5 ping URL | ✅ | `buildPingUrl` 用 `new URL()` 操作 pathname |

测试也复核过：`halfOpenCircuitRecord()` fixture 构造正确（`state:"open"` + `openedAt: now-60s` + `cooldownMs:10s`，`classifyState` 读时正是 `half-open`，就是缺陷 1 描述的故障稳态，不是假测试）；「发送失败重推」是三跑结构（失败→重推→送达→不再推），覆盖完整。

**「实施记录」里的三处偏差全部成立，本文档接受这三处修正：**

1. **缺陷 4 的修法确实自相矛盾。** 本文档只让调 `worker.js` 的调用顺序，又在「不要改的」里禁止动 `shouldNotify`。但 level 未变时未修改的 `shouldNotify` 根本不会重推（`degraded` 没有 reminder 兜底），本文档自己写的测试规格「下次 cron 同 level 仍重推」按原方案**无法通过**。实施方补的 `current !== "ok" && !previous.lastNotifiedAt → 重推` 分支是正确的补全。
2. **`entries.length > 0` 守卫该去掉。** `enabled` 过滤给空 `entries` 带来了新来源（全部停用），空真判定给出 down/503 恰好与 cron/心跳口径一致。
3. **部署前提写错了。** 层 B/C 已随 2026-09-05 上线，缺陷版本一直在线上跑，本文档「待部署」的前提不成立。

另外实施方抓到本文档「文档同步修订」漏了一处：`ALERTING.md`「验证」小节的测试清单仍是旧口径（「全 open → 503」「无可探活 provider → 不推」），照那份清单写测试会把缺陷改回去。四处规格修订漏了第五处，已由实施方补上。

---

## 遗留 1：`/v1/health` 在 secret 全缺时仍报 `200 ok`（HIGH）

**缺陷 2 只修好了 cron 告警与心跳两层，探针这层没修。**

### 证据

`AIProxy/worker.js:863` 的探针只读熔断状态，**不看 `apiKey`**：

```js
const entries = await Promise.all(activeProviders.map(async (p) => ({
  id: p.id,
  state: (await sharedHealthStore.snapshot(p.id, now)).state
})));
```

而 `runProviderHealthCheck`（`worker.js:1066`）遇到缺 key 的 provider 是**提前 return，从不调 `recordFailure`**：

```js
if (!provider.apiKey) {
  logWarn("health_check.skip_no_key", { providerId: provider.id });
  return { providerId: provider.id, ok: false, reason: "no_key" };
}
```

所以 `health:<id>` 记录压根不存在 → `HealthStore.load()` 返回 `freshRecord()` → `state: "closed"` → 探针 `200 ok`。

### 后果

密钥轮换贴错这个场景下，修复后的行为是：

- 层 B cron 告警 → 🚨 **响了**（`probeable === 0 → down`）
- 层 C-2 心跳 → `/fail` **响了**
- 层 C-1 探针 → **仍然全绿**

UptimeRobot 是独立于 Cloudflare 的外部眼睛，恰恰在「Worker 活着但一个 provider 都用不了」时最该红——这正是缺陷 2 要防的头号场景。

顺带，修复里的注释写着「与 cron 探活(probeable===0 → down)和 /fail 心跳口径一致」，但这个一致**只在「全部停用」时成立，「secret 全缺」时不成立**——注释本身会误导下一个读代码的人，要一并改。

### 修法

探针把「缺 key / 缺 adapter」也算不健康，与 cron 的 `probeable` 谓词同源：

```js
const entries = await Promise.all(activeProviders.map(async (p) => ({
  id: p.id,
  state: p.apiKey && getAdapter(p.type)
    ? (await sharedHealthStore.snapshot(p.id, now)).state
    : "unconfigured"
})));
const unhealthy = (s) => s === "open" || s === "half-open" || s === "unconfigured";
```

`"unconfigured"` 不是凭据，不违反 body 的脱敏约束（provider id 本来就在 body 里）。

### 测试

- 全部 provider 缺 key → 探针 **503 + `down`**（与「cron 告警: secrets 全缺…」那条形成对照，两层口径一致）
- 部分缺 key → `degraded`
- 缺 adapter（未知 type）同理——若 `loadProviders` 的校验已经挡住未知 type 使其不可达，在测试里注明即可，不必强造

---

## 遗留 2：恢复消息发送失败会永久丢失（MEDIUM）

### 证据

`AIProxy/src/alertState.js:58` 的重推分支排除了 `ok`：

```js
if (current !== "ok" && !previous.lastNotifiedAt) {
  return { notify: true, kind: current };
}
```

但 `worker.js` 现在对**所有 kind** 都是「送达才写 `lastNotifiedAt`」。于是：

1. down 告警送达 → `lastNotifiedAt = T1`
2. 恢复 → `kind: "recovered"`，Telegram 偶发 500 → 不写 `lastNotifiedAt`
   → 记录变成 `{ level: "ok", since: now, lastNotifiedAt: T1 }`
3. 下次 cron：`prevLevel === current === "ok"` → 跳过分支 1；重推分支 `current !== "ok"` 为 false → 跳过；reminder 只对 `down` → 跳过

**✅ 恢复消息永久丢失。** 收到 🚨 的人一直以为故障还在。

排除 `ok` 本身是必要的——首跑 ok 的 `lastNotifiedAt` 就是 0，不能当成待补发。问题在于用「`lastNotifiedAt` 是否为 0」表达「有没有待补发」，在 `ok` 上失效了：这是把两件事挤进同一个字段的后果。

### 修法（推荐）

改用显式的「上次成功通知的是哪个 level」，对三种 kind 统一生效：

```js
// nextRecord:送达才更新
lastNotifiedLevel: delivered ? current : (previous?.lastNotifiedLevel ?? "ok")

// shouldNotify:用户还不知道当前 level → 补发
if (previous.lastNotifiedLevel !== current) {
  return { notify: true, kind: current === "ok" ? "recovered" : current };
}
```

`lastNotifiedLevel` 初值取 `"ok"`，首跑 ok 不推自然成立。这条替换掉现有的 `current !== "ok" && !previous.lastNotifiedAt` 分支；`lastNotifiedAt` 继续只负责 6h reminder 的计时，两个字段各司其职。

> 这条要动 `nextRecord`，超出上一轮「只增 `shouldNotify` 分支」的边界。是刻意的：上一轮已经证明把「待补发」编码进 `lastNotifiedAt` 会漏掉 `ok`。
>
> 注意向后兼容：线上已有的 KV 记录没有 `lastNotifiedLevel` 字段，`?? "ok"` 会让第一次读到旧记录时视为「上次通知的是 ok」。若当时正处于 down，会补推一条——方向安全（宁吵勿哑），且只发生一次。

### 测试

- 恢复消息发送失败 → 下次 cron **重推 ✅**；送达后不再重推
- 首跑 ok 不推（回归防线，防止 `lastNotifiedLevel` 初值取错导致开机就推一条 ✅）
- 旧记录（无 `lastNotifiedLevel` 字段）能被正确读取，不抛错

---

## 遗留 3：`alert.health.notified` 日志覆盖掉 `level` 严重度字段（LOW）

### 证据

`AIProxy/worker.js:935`：

```js
logInfo("alert.health.notified", { kind: decision.kind, level, delivered: sent.ok, skipped: ... });
```

`src/log.js` 的 `log()` 把 `fields` 展开在后：

```js
const payload = { ts: ..., level, event, ...fields };
```

字段里的 `level: "down"` **覆盖掉严重度 `"info"`**。实际输出是 `"level":"down"`，按 `level=info|warn|error` 过滤的日志查询会漏掉这一行——而它正是唯一记录「告警到底发出去没有」的那行。

全仓仅此一处冲突（`worker.js` + `src/*.js` 已全量 grep 确认）。

### 修法

字段改名 `alertLevel`。顺手在 `src/log.js` 的文件头注释加一句：**`fields` 不得使用 `ts` / `level` / `event` 三个保留键**，防止再犯。

---

## 本轮改动清单

| 文件 | 改什么 |
|------|--------|
| `AIProxy/worker.js` | 遗留 1（`:863` 探针 + 修正那段注释）、遗留 3（`:935` 字段改名） |
| `AIProxy/src/alertState.js` | 遗留 2（`shouldNotify` 分支换成 `lastNotifiedLevel` 判定 + `nextRecord` 加字段） |
| `AIProxy/src/log.js` | 遗留 3 的保留键注释 |
| `AIProxy/worker.test.js` | 遗留 1×2、遗留 2×3（见各节「测试」） |
| `ALERTING.md` | 层 C-1 规格补「缺 key/adapter 也算不健康」；`shouldNotify` 规格第 4 条改为覆盖 recovered 的口径 |

## 不要改的

- **5 处修复本身**：复核通过，不返工
- **缺陷 4 补的重推分支**：方向对。遗留 2 是在它基础上补 `ok` 的缺口，不是推翻它
- **探针 15s 缓存 / 去掉 `entries.length > 0` 守卫 / `buildHealthAlertMessage` 传 `record: previous`**：都核过，正确（`record: previous` 仅 reminder 分支用到 `since`，而 reminder 时 level 未变、`nextRecord` 的 `since` 沿用旧值，两者同值）

## 验证

```bash
cd AIProxy && npm test
```

手测补一条针对遗留 1 的——把 `.dev.vars` 里的 `PROVIDER_KEY_*` 全部拿掉：

```bash
curl "http://localhost:8787/cdn-cgi/handler/scheduled"   # 应收到 down 告警 + /fail 心跳(已修好)
curl -i "http://localhost:8787/v1/health"
# 修复前:200 {"status":"ok"}   ← 遗留 1
# 修复后:503 {"status":"down"}
```

两条对照跑完，缺陷 2 的三层才算真正齐了。
