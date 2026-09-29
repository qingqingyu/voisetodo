# 上线前风险清单

上线前对付费链路与服务端闸门做的一轮核查。**与 `docs/payment-test-plan.md` 互补，不重复**——那份已经覆盖了 L1/L2/L3 三层环境、A–G 七组用例，连本地 StoreKit 验签那个坑都写在 §1 了。本文档只写它没覆盖的残余风险。

按「规模说不准，先按最坏打算」定优先级。

## 结论先行

**付费主流程本身比想象中稳。** 最担心的退款/撤销路径（测试方案标为「沙盒不可测、风险移交线上」的 E7），核查下来客户端是健全的，财务敞口可忽略。详见文末「已核查确认没问题的部分」。

**但反刷限流层完全不认识付费用户**——这是比付费流程本身更大的上线风险，而且现有测试方案完全没覆盖。

| 优先级 | 风险 | 后果 |
|---|---|---|
| **P0** | 反刷闸门不认 tier | 付费用户被 503 掐掉，最长 10 小时 |
| **P1** | 告警没部署 + 遥测没开 | 付费链路出问题你从差评里知道 |
| P2 | 设备 ID 在 `UserDefaults.standard` | 重装即重置免费额度；与 P0 修法互相牵制 |
| P3 | 已有测试方案里两条最该盯的 | 审核硬伤 + 唯一的全链路用例 |

---

## P0：反刷限流会把付费用户一起掐掉

> ✅ **已由 `2c87f33` 修复**（Pro 豁免 IP 闸门、全局预算分免费/pro 两桶）。本节保留为问题记录与修法依据。
> **复核结果与 4 处新问题见文末「P0 修复 review（2026-09-24）」**——其中 2 处是修复本身引入的，动手前先读那一节。

### 问题

三道闸门**全部在订阅档位解析之前或之外执行**，没有一道知道谁付过钱：

| 闸门 | 位置 | 阈值 | 认 tier？ |
|---|---|---|---|
| 全局日预算 | `worker.js:1691` `enforceGlobalBudgetHotPath` | `GLOBAL_DAILY_LIMIT=5000` | ❌ |
| IP 每分钟 | `worker.js:1810` `enforceIpRateLimit` | `IP_RATE_PER_MINUTE=10` | ❌ |
| IP 每日 | `worker.js:1832` `enforceIpDailyLimit` | `IP_DAILY_LIMIT=500` | ❌ |

`enforceAllQuotas`（`worker.js:1237`）的执行顺序：

```js
// Step A: 前置检查
await enforceGlobalBudgetHotPath(env, requestContext);   // ← 全局预算
await enforceIpRateLimit(request, env, requestContext);  // ← IP 限流

// Step B: device + ip-daily 并行扣减
const [deviceResult, ipResult] = await Promise.allSettled([
  enforceDailyLimit(request, env, requestContext, ctx),   // ← tier 在这里面才解析
  enforceIpDailyLimit(request, env, requestContext, ctx)
]);
```

`resolveSubscriptionTier` 在 `enforceDailyLimit`（`:1428`）内部才被调用。**Step A 那两道闸门执行时，代码根本还不知道这是不是 Pro 用户。**

### 算一下就知道多容易踩

Pro = 100/天，免费 = 3/天，全局上限 5000/天：

- **50 个重度 Pro 用户就能独力拉满全局预算**
- 或者 1000 免费用户 × 3 + 20 Pro × 100 = 5000
- 一旦 tripped，`enforceGlobalBudgetHotPath` 对**所有人**抛 503，付费用户和白嫖用户一起被掐

**重置边界更要命。** trip 标记的 key 用的是 UTC 日期（`worker.js:1702`）：

```js
const today = new Date().toISOString().slice(0, 10);
const trippedKey = `global-budget-tripped:${today}`;
```

国内用户晚上 22:00（UTC 14:00）打穿 → 要等到**次日早上 8:00**（UTC 0 点）才恢复 → **10 小时付费用户完全不可用**，且正好覆盖晚间使用高峰。

**IP 侧同样危险。** 运营商 CGNAT 下大量用户共享出口 IP，**5 个 Pro 用户挤在同一出口就能打满 500/天**。`wrangler.toml:41` 的注释自己也承认：

> 50 → 500：VPN/公司网络共享出口极易撞限。本质缓解要靠订阅按用户配额，此处只是兜底防刷。

### 用户看到什么

503 → `VoiceTodoError.serviceUnavailable`（`NetworkClient.swift:124`）→「服务暂时不可用」toast，转写进 pending 队列。

付费用户**完全无法区分**这是「我付的钱没生效」还是「服务挂了」，而且收不到任何解释。这是退款申请与差评的直接来源——**用户刚付完钱就用不了，归因一定是「这 App 骗钱」。**

### 修法

1. **让闸门认 tier。** 把 `resolveSubscriptionTier` 提前到 `enforceAllQuotas` 入口解析一次，往下传：
   - Pro 用户豁免 IP 闸门，或给显著更高的 IP 阈值（IP 闸门的目标是挡「单 IP 轮换 device ID 刷免费额度」，付费用户不在威胁模型里）
   - 全局预算对 Pro 单独设桶，或直接豁免——付费用户的调用是**有收入覆盖的成本**，和防刷要挡的白嫖成本性质完全不同
2. **全局预算 trip 改为小时级滚动窗口**，或按设备本地日期分桶，避免一次打穿锁死 10 小时。
   > ✅ 2026-09-24 已修（DO 路径）：UTC 小时桶滚动窗口，`GLOBAL_BUDGET_WINDOW_HOURS`（默认 6h），窗口内阈值 = 日限 × 窗口长/24（日成本天花板不变），trip 标志 TTL 只到下一个整点边界后重评——单次打穿的锁死上限 ≤ 窗口长，替代「锁死到 UTC 0 点」。见 `AIProxy/worker.js` `enforceGlobalBudgetViaDOIncrement` 与 `AIProxy/src/do/quota-counter.js` `/consume-rolling`。KV degraded 路径仍按日桶（fail-safe 优先于不精确的滚动）。
3. **重新定 `GLOBAL_DAILY_LIMIT`**：按「预期 Pro 数 × 100 + 预期免费数 × 3」×（2~3 倍余量）。这个值是**成本上限，不是安全阈值**——打穿的代价（付费用户不可用 + 退款 + 差评）远大于超支那点钱。
4. **兜底：给 Pro 用户单独的错误码与文案**，别和「服务挂了」混为一谈。至少让用户知道「不是你的问题，也不是没生效」。

> ⚠️ 修 P0 时注意与 P2 的牵制：放松 IP 闸门会放大「重装刷免费额度」的洞。真正的解法是**按订阅身份而非设备/IP 计费**（`wrangler.toml:41` 的注释也是这么说的）。上线前先按「宁可多花钱，不可掐付费用户」的方向调参数，结构性重构放到上线后。

### 本地复现（建议实施前先跑一遍）

```bash
cd AIProxy && npx wrangler dev
# 把 wrangler.toml 的 GLOBAL_DAILY_LIMIT 临时改成 1
# 带一个合法的 Pro JWS(X-Subscription-JWS)打两次 /v1/todo-extractions
# 第二次必然 503 global_budget_exceeded —— Pro 身份完全没被考虑
```

比任何论证都直观。

---

## P1：出事了你不会知道

上线时告警与可观测性都还没就位：

- **告警层 B/C 修好了但没部署。** `ALERTING.md` 状态表写着「待重新部署」，线上跑的还是 2026-09-05 那版——那版探针把 `half-open` 当健康、secret 全缺时三层全绿。
  > ✅ 2026-09-25 更正 + 收口：一轮 5 缺陷修复实际已随 09-22 部署上线（线上版本 0157fdee，`wrangler deployments list` 核实）——当时「没部署」的判断是被 `ALERTING.md` 过期状态行误导。二轮 3 处遗留已于 09-25 修复并随当日部署上线。本条 P1 至此闭环。
- **还有 3 处遗留缺陷未修**（`docs/alerting-layer-bc-review-fixes.md` 第二轮 review）。其中遗留 1 让 secret 全缺时 `/v1/health` 仍报 200 ok。
  > ✅ 2026-09-25 已修（unconfigured 探针 / lastNotifiedLevel 送达回执 / 日志 alertLevel 字段），随当日部署上线。
- **D1 遥测没开。** `wrangler.toml` 的 `TELEMETRY_DB` binding 仍是注释掉的（方案见 `docs/telemetry-d1-enablement.md`）——上线后**没有任何事后复盘数据**，想查「昨天多少人失败了」都查不了。
- **订阅两层不一致无检测**（`docs/subscription-tier-mismatch.md`）。2026-08-20 那类「付费用户被静默降级」的 bug 会再次沉默——`wrangler.toml` 注释里记着那次是「订阅用户第 3 次录音弹免费限制墙」，靠用户反馈才发现的。

**上线前至少把告警部署掉。** 否则付费链路出问题，你是从 App Store 差评里知道的——而那时已经有一批用户付了钱没用上。

---

## P2：设备 ID 存在 `UserDefaults.standard`

`Constants.swift:56`：

```swift
static let proxyDeviceIdentifier: String = {
    let storageKey = "VoiceTodoProxyDeviceIdentifier"
    if let existing = UserDefaults.standard.string(forKey: storageKey), ... { return existing }
    let identifier = UUID().uuidString
    UserDefaults.standard.set(identifier, forKey: storageKey)
    return identifier
}()
```

随机 UUID 存 `UserDefaults.standard`，**删除 App 重装即重置** → 免费额度可无限刷新。IP 闸门是唯一兜底，而它正是 P0 里会误伤付费用户的那道。

不是上线阻塞项——重装一次换 3 条额度，性价比太低，不会有规模化滥用。但要知道这个洞存在，且它与 P0 的修法互相牵制（见上）。

### 顺手要验证的一件事

`UserDefaults.standard` 在 App Extension 里是**独立的 suite**。Siri / AppIntent 路径（`App/Intents/AddTodoIntent.swift`）如果跑在独立进程，会拿到**不同的 device ID → 独立的配额桶**。

仓库里其它跨进程状态都走 App Group（`Store/AppGroupConfig.swift`），这里没走，是个不一致。**需要实测确认**：用 Siri 添加待办，抓包看 `X-Device-ID` 是否与主 App 一致。

- 如果不一致：Pro 用户走 Siri 会被当成另一台设备（额度独立计算，对用户其实是"多送额度"，但配额统计口径就乱了）
- 修法：把 device ID 挪到 App Group UserDefaults，与仓库其它跨进程状态一致

---

## P3：已有测试方案里最该盯的两条

不重复 `docs/payment-test-plan.md`，只标出其中优先级最高的：

### E4 老用户退订后重订（审核硬伤）

`isEligibleForIntroOffer=false` 时，**试用文案必须消失**，CTA 变直接付费。文案与实际资格不符是 App Store 审核的明确拒绝项。

最容易漏测，因为要沙盒清购买历史 + 续订加速才能构造。**别跳过。**

### B3 购买后立刻录音（唯一的全链路用例）

这是唯一能验「钱 → 权益 → 服务端额度」完整链路的用例，且**只能在 L2 沙盒做**——L1 本地 StoreKit 的 JWS 由 Xcode 测试证书签发，服务端验签必然失败、fail-safe 免费档（详见 `docs/subscription-tier-mismatch.md`）。

通过判据：付费墙显示 `1/100` 且**没有**「(estimated)」标记，`wrangler tail` 看到 `proxy.subscription.verified tier=pro`。

---

## 已核查确认没问题的部分

免得重复排查，这几条我核过代码，是健全的：

**退款 / 撤销（测试方案 E7，原标记为「风险移交线上」）** —— 客户端路径健全：

- `Transaction.updates` 监听常驻（`EntitlementManager.swift:171`）
- 收到撤销 → `refreshEntitlements()` → 重读 `currentEntitlements`（`:156`），该 API **自动排除已撤销/已过期**的交易
- → `isPro=false`、`jwsString=nil`，服务端随即按免费档

服务端 `sub:<deviceId>` KV 缓存 TTL 上限 15 分钟（`worker.js:1640`）：

```js
const ttl = Math.min(Math.max(60, Math.floor((result.expiresAt - Date.now()) / 1000)), 15 * 60);
```

所以退款后最多 15 分钟仍按 Pro 放行 —— 财务敞口可忽略。**E7 的风险等级可以下调。**

**Pro 用户额度耗尽** —— 正确区分：走 `quotaExhaustedPro` 文案 toast，**不弹付费墙**（`AppCoordinator.swift:1188` / `:1305` 按 tier 分支）。已经付费的人不会再被推销。

**订阅过期** —— `currentEntitlements` 只返回未过期权益，客户端自动回落；即使 App 长时间不重启导致本地 `isPro` 滞后，服务端验签也会因过期而 fail-safe 到免费档。两层互为兜底。

---

## 上线前最小动作清单

1. **重新 `wrangler deploy` AIProxy**（告警层 B/C 修复版）—— P1
2. **按 P0 重新评估 `GLOBAL_DAILY_LIMIT` / `IP_DAILY_LIMIT`**，至少先调到「预期规模 × 3」；有时间就做「闸门认 tier」
3. **L2 沙盒跑 B3 + E4** —— P3
4. **开 D1 遥测**（`docs/telemetry-d1-enablement.md`）—— 否则上线后瞎
5. **配 UptimeRobot + healthchecks.io**（`ALERTING.md` 部署步骤）

第 1、2 条是真正的上线阻塞项。第 4 条不做的话，出了事只能靠猜。

---

# P0 修复 review（2026-09-24）

对 `2c87f33`（反刷闸门认订阅档位）+ `2d874a0`（测试补强）的复核。**P0 主体修好了**，但发现 4 处新问题，其中 2 处是这次改动引入的。

> **本节状态（2026-09-27 复验）：** 新问题 1、2 已由 `1d5316c` 修复；**新问题 3、4 代码逐字未变，仍未修**。
> 详见文末「第三轮 review」——那里还有 5 处新发现，动手前先读。

## 复核结论：P0 主体通过

实施质量高，这些我核过，不用返工：

- **分桶四路独立且三条路径一致**：tripped key（`global-budget-tripped-pro`）/ DO 实例（`global-budget-pro`）/ KV 计数 / 错误码（`global_budget_exceeded_pro`），hot path、DO 增量、KV degraded 三条路径口径统一
- **Step C 对 Pro 跳过 `refundIpDaily` 是对的**：Pro 从未扣减 ip-daily，退款会错减同 IP 免费用户的**共享**计数，反而放松免费档 IP 日限
- **付费侧未配置 / 配错时显式记日志**，不静默跳过
- **免费档语义逐函数等价**，无感知变化
- `QuotaCounter` 无 key 白名单，`global-budget-pro` 可用
- 新错误码不影响客户端（`NetworkClient.swift` 只按状态码分支，不解析 error 字符串）
- 第三个 provider 未破坏 iOS 超时预算不变量（`MAX_ATTEMPTS=2` 使 `min(2,3)=2`，`wrangler-config.test.js` 守着）

## 4 处新问题

> **2026-09-25 状态**：新问题 1、2 已修（随当日部署上线）；新问题 3、4 仍开放。核心矛盾一句话：**豁免的理由「device 侧 `PAID_DAILY_LIMIT` 已是硬顶」只在 extract 路径成立，而豁免被应用到了所有路径。**

### 新问题 1：Pro 在 split/reflect 上现在完全没有任何限流（HIGH，本次引入）

> ✅ **2026-09-25 已修**：split/reflect 分支与 extract 同口径递增本档全局预算（`enforceGlobalBudgetIncrement` 落进 assist 路径）——不计费额度（拍板）不变，计的是成本侧全局桶；持续刷量会打穿本档 trip，assist 请求被本档 503 拦下。回归测试三条（pro 桶递增 / 免费持续刷穿 503 / pro 桶 trip 拦 assist）。

`worker.js:211-217` 的 else 分支只调两道闸门：

```js
await enforceGlobalBudgetHotPath(env, requestContext, isPro);
await enforceIpRateLimit(request, env, requestContext, isPro);
```

对 Pro 这两道全部落空：

- `enforceIpRateLimit` 第一行就是 `if (isPro) return;`（`:1898`）
- `enforceGlobalBudgetHotPath` 只**读** `global-budget-tripped-pro` 标志；而该标志只由 `enforceGlobalBudgetIncrement` 写，后者**只在 `enforceAllQuotas` 内被调用（extract 专属）**→ split/reflect 流量永不计数 → pro 桶永不 trip → 这道读永远放行
- split/reflect 本就不占计费额度（拍板）→ 没有 device 上限

**三重落空 = 一个合法 JWS 换无限模型调用，任何计数器都不记。** 改动前这条路径至少还有 `IP_RATE_PER_MINUTE=10` 兜着。

豁免注释里写的「device 侧 `PAID_DAILY_LIMIT`(100/天) 本身构成单设备速度上限，IP 限速对它冗余」在 extract 上成立，**在 split/reflect 上是空话**——恰恰因为这条路径刻意不扣计费额度。

commit message 里「Pro 的 split/reflect 流量不计任何桶（免费侧同缺口，系预存）」把它说成与免费侧对称的预存缺口，**但并不对称**：免费侧仍有 10/min 的 IP 刹车，Pro 侧一道都不剩。

新测试 `P0: split 模式 Pro 同样豁免免费桶熔断`（`worker.test.js:1425`）断言的正是这个形状，等于把洞固化进回归防线。

**修法（建议都做）：**

1. split/reflect 分支也调 `enforceGlobalBudgetIncrement(env, requestContext, ctx, isPro)`，让 pro 桶对这条路径有牙
2. **只豁免 `enforceIpDailyLimit`**（500/天，CGNAT 误伤的真正来源），**保留 `enforceIpRateLimit` 这道每分钟突发刹车给所有档位**。10/min 对真人足够宽；若担心 CGNAT 下付费用户互相挤，给 Pro 一个更高的每分钟阈值，而不是完全豁免

### 新问题 2：Pro 的 JWS 是无绑定 bearer token，豁免放大了它的价值（HIGH）

> ✅ **2026-09-25 服务端抑制已落地**：新增按订阅限速——以验签 payload 的 `originalTransactionId`（一次购买内跨设备稳定、客户端轮换不掉）为键，`SUBSCRIPTION_DAILY_LIMIT`（默认 500/UTC 日，≈5 台设备打满 `PAID_DAILY_LIMIT`）封顶，超限 429 `subscription_quota_exceeded`。轮换 device ID 无效，滥用上限从「无限」压回常数。**仍开放**（后续项）：缓存掺 JWS 指纹（挡「任意非空 JWS + 缓存热 device」的 15 分钟窗口）、App Attest / DeviceCheck 设备绑定。

`verifySubscriptionJWS` 只校验 bundleId / productId / 过期 / 证书链——**不绑定设备**。所以一个买来的 JWS 可以配任意 `X-Device-ID` 使用，而 device ID 是客户端自填的（`AIProxy/README.md` 自己也写明可伪造）。

| | 改动前 | 改动后 |
|---|---|---|
| 共享 JWS + 轮换 device ID | 被 `IP_DAILY_LIMIT=500/天` + `IP_RATE_PER_MINUTE=10` 挡住 | 两道 IP 闸门都豁免，每设备 100/天靠轮换绕过，**只剩 `GLOBAL_PRO_DAILY_LIMIT=20000/天`** |
| 再走 split/reflect | 同上 | 叠加新问题 1，**连 20000 都不计** |

**$4.99 换到的滥用上限，从 500/天变成了无限。**

还有叠加的第三层：`sub:<deviceId>` 缓存在验签之前就被读（`:1639-1657`）——`if (!jws) return free` 之后**直接查缓存，从不校验这个 jws 是否有效**。所以任意非空 JWS 字符串 + 一个缓存热的 device ID，15 分钟内直接拿 pro。这条是既存问题，但本次改动让它值钱得多。

**修法：** 把 pro 判定与凭证绑定——缓存 key 掺入 JWS 的哈希，或在缓存值里存 JWS 指纹并比对，让「换设备 ID 复用同一 JWS」至少要过一次真实验签。进一步可在验签时把 device ID 纳入，限制单个订阅的并发设备数。

### 新问题 3：tier 解析前置，热路径「零成本」性质被破坏（MEDIUM，本次引入）

`worker.js:194` 把 `resolveSubscriptionTier` 提到了 `enforceGlobalBudgetHotPath` / `enforceIpRateLimit` **之前**（且给 split/reflect 新增了这次解析）。

而 `src/subscription.js:52` 的 `verifyChain` 是**先做完整条链的 `crypto.subtle.verify` + ASN.1 解析，最后才比对根指纹**（`:55-63` 是验签循环，`:68` 才 check anchor）。验签失败也**从不缓存**。

于是：一个伪造的 `X-Subscription-JWS` 能在**每个请求**上强制服务端做 N-1 次 ECDSA/RSA 验证 + 完整证书解析，**即使全局预算已经 trip、该 IP 已经超过每分钟限流**——因为那两道廉价闸门现在排在后面。`:1249` 那句「global-budget：纯读 KV tripped 标志，真正零成本」的注释不再成立。

**修法：** 廉价闸门（读 tripped 标志）保持最前，tier 解析放到它之后；并在 `verifyChain` 里**先比对根指纹再做签名验证**——顺序调换不影响安全性，但把伪造链的成本从 N 次公钥运算降到一次 SHA-256。后者是独立加固，建议一并做。

### 新问题 4：selector 钉头会把 half-open 的 provider 顶到最前（MEDIUM，`2d9f573` 引入）

`src/selector.js:70` 的 pin 在 `combined` 上做 `findIndex` + 前移，而 `combined = [...sortedWarm, ...shuffledCold, ...sortedHalfOpen]` —— **half-open 没有被摘除，只是排在尾部**。

于是被钉的 provider 一旦熔断进 half-open，pin 会把它从「最后试探」提到**每个请求的第一顺位**，正好反转熔断器的意图。

docstring（`:31-33`）写的是「if the pinned provider is disabled / keyless / circuit-open, it already got dropped in step 1 and the pin is a no-op」——**漏了 half-open 这一态**，会误导下一个读代码的人。

叠加 `AI_PROVIDER_MAX_ATTEMPTS="2"`：`combined.slice(0, 2)` 会把健康的第三家直接切掉。当前配置下，被钉的 `ZAI_ANTHROPIC_AIR` 半开 + `ZAI_ANTHROPIC` 正在失败但未熔断 → CLAWTO 完全进不了候选，每个请求都以已知在失败的 provider 打头，且每家 30s 超时。

**修法：** pin 只对 warm/cold 生效（hoist 前确认该 provider 不在 `halfOpen` 里），并同步修正 docstring。

### 附带（非阻塞）：三个 provider 只有两个独立上游

`wrangler.toml` 里 `ZAI_ANTHROPIC_AIR` 与 `ZAI_ANTHROPIC` **共用同一个 url 和同一个 `secretName`**（`PROVIDER_KEY_ZAI_ANTHROPIC`），只有 model 不同。z.ai 故障或密钥轮换会同时打掉三家里的两家。

配合 `MAX_ATTEMPTS=2`，一次请求的两个候选可能全是 z.ai —— 此时「failover 到另一家」是幻觉。别把 provider 数量当成冗余度。

## 验证

```bash
cd AIProxy && npm test
```

新问题 1 本地可复现，最直观：

```bash
npx wrangler dev
# 带合法 Pro JWS,以 mode=split 连打 20 次
# 现状:全部 200,无任何计数器增长、无限流
# 期望(修复后):撞到每分钟刹车,或 pro 桶计数增长
```

## 与告警遗留的优先级关系

> **2026-09-25 收口**：告警 B/C 一轮修复实际已于 09-22 上线（当时本节说「没有部署」是被 `ALERTING.md` 过期状态行误导）；二轮 3 处遗留与新问题 1/2 均已于 09-25 修复并随当日部署上线。剩余开放项：新问题 3（verifyChain 先比根指纹再验签 + 廉价闸门排序）、新问题 4（selector 钉头对 half-open 生效）、「附带」节的 z.ai 双 provider 共用上游。

本节 4 条都不如 **`docs/alerting-layer-bc-review-fixes.md` 的「第二轮 review」** 紧急——那 3 处遗留经 2026-09-24 复验**一处未修**，且告警至今**没有部署**（`ALERTING.md` 实施状态仍是「待重新部署」）。

上线顺序建议：**先部署告警 → 修告警 3 处遗留 → 再处理本节新问题 1/2**（这两条是成本与滥用风险，不影响正常用户体验，但会在有人发现后迅速变成账单问题）。

---

# 第三轮 review（2026-09-27）

对 `1d5316c`（P0 复核新问题 1/2 + 告警二轮 3 遗留）与 `084f94c`（全局预算改小时桶滚动窗口）的复核。

**修得扎实，其中一处比我上轮提的方案更好。** 但有 **2 处我上轮提的问题原封未动**，以及 **5 处新问题**——其中 1 处与公开的隐私政策直接冲突。

> **本节状态（2026-09-29 复验）：** 七处已由 `527d3d5` 收口，其中 **5 处完全正确**；**新发现 3（恢复时长）只修好一半**，**新发现 1（订阅 ID 哈希）的哈希实际可逆**，另带出一处部署过渡窗问题。
> 详见文末「第四轮 review」——动手前先读那一节。

## 先更正我自己的一个错误

上一轮我断言「告警至今没上线」。实施方用 `wrangler deployments list` 核实：**一轮 5 缺陷修复已随 09-22 部署上线（`0157fdee`）**。我的判断来自 `ALERTING.md` 里一行过期的状态文字。

这条我该写成「文档状态行显示未部署，需核实」而不是当成事实断言——**部署状态我在代码仓库这边验证不了，不该用肯定语气。** 记在这里，后续 review 同类判断都按此口径。

## 已确认修好

| 问题 | 修法 | 复核 |
|---|---|---|
| 新问题 1：Pro 在 assist 上零限流 | assist 分支补 `enforceGlobalBudgetIncrement`（`worker.js:227`） | ✅ |
| 新问题 2：JWS 无绑定 bearer | 新增 `enforceSubscriptionDailyLimit`，以 `originalTransactionId` 为键，500/UTC 日 | ✅ **比我提的方案更好** |
| 告警遗留 1：探针 secret 全缺报 200 | 缺 key/adapter 标 `unconfigured` 并计入不健康 | ✅ |
| 告警遗留 3：日志 `level` 键被覆盖 | 改名 `alertLevel` + `log.js` 头部注明保留键 | ✅ |
| 告警遗留 2：恢复消息发送失败永久丢失 | `lastNotifiedLevel` 送达回执 | ⚠️ 重推通了，但**文案有新 bug**（新发现 3） |
| 更早：全局预算 UTC 日锁死 10 小时 | 改 UTC 小时桶滚动窗口 | ✅ |

**新问题 2 的修法值得单独说。** 我上轮建议「缓存 key 掺 JWS 哈希」——那只是让复用 JWS 多过一次验签，治标。实施方改用 `originalTransactionId` 作配额键：这个值跨设备稳定、轮换 device ID 也不掉，**直接把「一个订阅 = 一份额度」变成结构性事实**。这是根因修法，比我提的好。

闸门位置也对：放在 mode 分支**之前**（`worker.js:202`），extract 与 assist 都覆盖；放在所有配额扣减之前，被拒时无需补偿。

## 仍然没修（上轮提过，代码逐字未变）

### 新问题 3：`verifyChain` 仍是先验签、后比对根指纹

`src/subscription.js:52-70` 原样。伪造 JWS 仍能在每个请求上强制 N-1 次公钥运算，且 tier 解析仍排在两道廉价闸门之前（`worker.js:194`）。

**现在更该修**——`enforceSubscriptionDailyLimit` 又在它后面加了一层，伪造 JWS 的浪费路径更长了。把根指纹比对提到验签循环之前，成本从 N 次公钥运算降到一次 SHA-256，安全性不变。

### 新问题 4：selector 钉头仍会把 half-open 顶到最前

`src/selector.js:69-76` 原样，docstring 仍写着「circuit-open 已在 step 1 被摘除所以 pin 是 no-op」——漏了 half-open 这一态。

叠加 `AI_PROVIDER_MAX_ATTEMPTS="2"`，被钉的 provider 一熔断就变成每个请求第一顺位，且把健康的第三家挤出候选。**当前正在灰度 `ZAI_ANTHROPIC_AIR` 作主力，这条现在是活的风险**，不再是理论问题。

## 新发现

### 新发现 1：订阅 ID 明文进 KV key / DO 名 / 每条日志——与隐私政策冲突（HIGH）

代码用**未哈希的** Apple `originalTransactionId`：

- KV key：`sub-quota:<date>:<rawId>`（`worker.js:1802`）
- DO 实例名：`sub-daily:<rawId>`（`:1752`）
- **每个 Pro 请求都记一条日志**带 `subscriptionId` 原值（`:1708` / `:1754` / `:1785`）

而 `PRIVACY_POLICY.md` 是这么向用户承诺的：

> A hashed device identifier is also used to enforce the daily free-tier limit and **to protect the service from abuse**. It is a random/hashed value — **not your Apple ID**, advertising ID, or any permanent hardware serial.
>
> Because we **only hold hashed identifiers**, we may ask for the approximate date and content of your request to locate it.

`originalTransactionId` 是与 Apple 账号绑定的永久订阅标识，正是政策说「不持有」的那一类。而「我们只持有哈希标识」这句，在新代码下**直接变成假的**。

同一个文件里**其它每一个标识符都走了 `safeDeviceId()`**（加盐 SHA-256，`:2335`），唯独这个没走。

**修法是一行的事**：用同一个 `safeDeviceId()` 包一下。哈希后作为限速键**同样稳定、同样抗设备轮换**，功能零损失。

风险不只是合规文书——上架审核与 EEA/GDPR 都盯这个，且隐私政策是对用户的公开承诺。

### 新发现 2：assist 流量吃掉订阅配额，可能把付费用户锁在门外（MEDIUM-HIGH）

`enforceSubscriptionDailyLimit` 在 mode 分支**之前**执行（`:202`），所以 split/reflect 也扣这 500/天。而 Pro 在 assist 上豁免了两道 IP 闸门、又不占 device 额度——**这 500 是它唯一的限制**。

后果：在一台设备上反复点「换一批」约 500 次，会让**该用户所有设备上的 extract 一起 429**，直到 UTC 0 点。国内用户晚上打满 = 锁到次日早 8 点，而界面上只是一句笼统的限速提示。

而 `wrangler.toml` / README 里 500 的定档理由写的是「1–3 台设备 × 100/天 extract」——**没把 assist 流量算进去**。

附带：该计数器在 device 配额**之前**扣且不退还，被下游拒掉的请求照样花掉一次，实际可用额度低于 500。

这正是 P0 那一轮要消灭的那类问题——付费用户被反滥用机制挡在门外——只是这次挡他的是新加的那道闸门。

**修法（择一）：**
- assist 与 extract 分开计（assist 单独一个更宽的订阅侧桶）
- 或把 500 按「extract + assist」重新定档，并同步 `wrangler.toml` / README 的理由
- 至少在 device 配额拒绝时退还订阅计数

### 新发现 3：重推的恢复消息会报出编造的故障时长（MEDIUM）

这是告警遗留 2 修复引入的新 bug。

`buildHealthAlertMessage`（`worker.js:987`）对 `recovered` 用 `previous.since` 算故障时长。而恢复消息发送失败后，`nextRecord` 因为 level 变了（down→ok）已经把 `since` 重置成**恢复时刻**：

1. 故障 `T_outage` → 恢复 `T_recover`，首次发送用 `previous.since = T_outage`，**时长正确**
2. 发送失败 → 落盘 `{ level:"ok", since:T_recover, lastNotifiedLevel:"down" }`
3. 下轮 cron 重推（这部分工作正常，遗留 2 确实修好了）→ 但 `previous.since` 现在是 `T_recover`，算出来的是「距恢复多久」，**不是故障时长**，而且每次重推还在变大

一次 5 分钟的故障，若 Telegram 挂了两小时，重推出来会说「故障总时长: 2 小时」。**告警在说假话，会直接误导事后复盘。**

新测试只断言文案含「恢复」、不校验时长数值，所以没抓住。

**修法：** 记录里单独存故障起点（如 `lastOutageSince`，进入 down/degraded 时置、恢复送达后清），`recovered` 文案用它而不是 `previous.since`。测试要断言时长数值。

### 新发现 4：订阅 DO 失败回退路径重复记日志，且可能记 `used: undefined`（LOW）

`enforceSubscriptionDailyLimit` 的 catch 分支回退 KV 后**没有 `return`**（对比 `enforceDailyLimitViaDO` 的写法），于是 KV 路径记一条 `source:"kv"`，紧接着又记一条同名 `source:"do"`。若 `RATE_LIMIT_KV` 未绑定，helper 返回裸 `{ allowed:true }`，第二条会记 `used: undefined`。

### 新发现 5：配置留空会每请求刷 warn（LOW）

`resolveSubscriptionDailyLimit`（`:1721`）与 `resolveGlobalBudgetWindowHours`（`:1862`）只把 `undefined` 当未配置；留空字符串 `""` → `Number("") === 0` → 走 invalid 分支 → **每个 Pro 请求（/每个 DO 路径请求）刷一条 `logWarn`**，同时静默沿用默认值。

而 `wrangler.toml` 里相邻变量的注释都写着「留空则不启用」——留空正是运维的自然动作。

**修法：** 空串与 `undefined` 同等对待（走「未配置、用默认值」分支，不 warn）。

## 复核确认没问题的（不返工）

滚动窗口数学（`ceil(daily × windowHours/24)` 在默认 6h 下保住每日上限、4 个突发窗口）、`hourBucketsEndingAt` 的 index-0 不变量、alarm 清理 cutoff（保今天 + 昨天对 `windowHours ≤ 24` 足够）、`isValidHour` 挡住 `new Date(NaN)`、trip 标志 TTL ≥ 121s（高于 KV 60s 下限）、存储键日期前缀对 10/13 字符都成立、iOS `classify429` 把 `subscription_quota_exceeded` 映射到 `.rateLimited` 而非付费墙且 `Retry-After` ≈86400s 超过 `retryMaxInterval` 故不会产生重试循环。

## 建议处理顺序

1. **新发现 1（订阅 ID 哈希）** —— 一行改动，涉及公开承诺与上架审核，优先级最高
2. **新发现 3（恢复时长）** —— 告警在说假话，会误导事后复盘
3. **新发现 2（assist 吃订阅配额）** —— 定档理由与实际口径对不上，要么改数要么分桶
4. **新问题 4（selector 钉头）** —— 正在灰度新主力，这条现在是活的
5. 新问题 3、新发现 4/5 —— 加固与清理，可并入下一轮

---

# 第四轮 review（2026-09-29）

对 `527d3d5`（第三轮 review 七处收口）的复核。在临时 worktree 里跑了全量：**312 测试全过**。

逐条核对：**五处修法完全正确**，两处有残留，另有一处是我上轮没看到的部署过渡问题。

> **本节状态（2026-09-29 复验）：** 三处残留已由 `7824ee8` 收口，测试 312→313 全过，红绿双向验证（撤掉修复回归必红）。
> - **残留 1**：终点改 `previous.level === "ok" ? previous.since : now`；回归测试在重推前把 `Date.now` 推进 30 分钟，断言文案仍是真实故障时长
> - **残留 3**：读取分支只认 `sha256:` 前缀，明文条目落 `null` 走既有 `cap_skipped_no_sub_id`；新增测试断言明文不进任何 DO 名 / KV key
> - **残留 2**：**生产实况与本节前提不符**——`LOG_HASH_SALT` 已是现役 secret（`wrangler secret list` 核实，最迟随 09-22 Secret Change 生效，现役版本仍带着），「盐回落 APP_TOKEN、解包即得」的攻击链在生产不成立。本节只看 repo 里 toml 的注释就断言盐未配置，与第三轮「拿文档状态行当部署事实」同款错误。剩余动作：人工确认一次 secret 值不是 APP_TOKEN 的拷贝（wrangler 读不出值，代码无法自证）；两份 toml 的误导注释已改口径
>
> **部署注意：`527d3d5` 与 `7824ee8` 至今未部署（最后部署 09-25 `54e08879`），两者必须同批上线。** 且自 09-25 起生产跑的 `1d5316c` 订阅限速一直在写明文订阅号——DO 名 / KV key / 日志已积累存量（既成事实，代码侧无补救，知情即可）。

## 复核通过（不返工）

| 第三轮条目 | 修法 | 核对 |
|---|---|---|
| 新问题 4 selector 钉头 | `pinnable = warm.length + cold.length`，`index < pinnable` 才钉 | ✅ 与 `combined` 拼接顺序严格对应，half-open 留末尾试探槽 |
| 新问题 3 verifyChain | 根指纹比对（一次 SHA-256）提到 N-1 次验签之前 | ✅ 安全等价（两道都过才放行；根不是信任锚时链内验签本无意义） |
| 新发现 2 assist 吃订阅配额 | 按 mode 分桶：`sub-daily` / `sub-assist`，KV 前缀由桶名派生 | ✅ DO 名、KV 前缀、resolver、README、config test 五处一致 |
| 新发现 4 DO 回退重复日志 | catch 分支补 `return` | ✅ 与 `enforceDailyLimitViaDO` 同形，`used: undefined` 路径消失 |
| 新发现 5 空串配置刷 warn | `isUnsetEnvValue` 统一空串/纯空白 | ✅ 三个 resolver + config test 同口径 |

`nextRecord` 的 `lastOutageSince` 状态机本身也是对的：首次离开 ok 置 `now`、降级↔全挂不重置、恢复**送达**才清、未送达保留。

## 残留 1：recovered 重推的时长仍在膨胀（MEDIUM）

**新发现 3 只修好了一半。**

`worker.js:997`：

```js
const outageSince = previous?.lastOutageSince ?? previous?.since;
if (outageSince) {
  lines.push(`故障总时长: ${formatDuration(now - outageSince)}`);
}
```

`lastOutageSince` 确实不再被重置（原问题的前半截修好了），但 **`now` 在重推路径上是「重推时刻」，不是「恢复时刻」**：

- **首发路径**：`previous.level` 还是 down/degraded，`now` **就是**恢复时刻 → `now - lastOutageSince` 正确
- **重推路径**：`previous.level` 已是 `"ok"`，`now` 是下一轮 cron 的时刻 → 算出的是 **真实故障时长 + 重推延迟**

按 30 分钟 cron：一次 5 分钟的故障，首发失败后重推一次报 **35 分钟**；Telegram 挂两小时则报 **2 小时 5 分钟**，且**每次重推继续变大**——正是那条注释声称已经修掉的失效方式。

**正确的值记录里已经有了**：重推时 `previous.level === "ok"`，而 `nextRecord` 在 down→ok 时把 `since` 置成了恢复时刻。

```js
// previous.level === "ok" → 重推路径,恢复发生在 previous.since
// 否则 → 首发路径,now 即恢复时刻
const recoveredAt = previous?.level === "ok" ? previous.since : now;
lines.push(`故障总时长: ${formatDuration(recoveredAt - outageSince)}`);
```

**测试为什么没抓住：** `worker.test.js:6472` 把 `outageStart` 设成 `Date.now() - 90min`，然后连续跑三次 `handleScheduled`——**三次都在同一毫秒内执行**，`now - outageStart` 始终 ≈ 90 分钟，断言「1 小时 30 分钟」自然通过。生产环境第三跑发生在第二跑的 30 分钟之后，实际会输出「2 小时」。

测试要在第二跑与第三跑之间**推进模拟时钟**（仓库里已有 `withMockedToday` 这类注入手段）才守得住这条。

## 残留 2：哈希是可逆的，隐私修复实质上没成立（MEDIUM-HIGH）

`resolveSubscriptionTier` 现在确实在验签后立刻 `safeDeviceId()`（`worker.js:1719`），缓存值 / 日志 / DO 名 / KV key 全部只见哈希。**但这个哈希拦不住任何人。**

三个事实叠在一起：

1. **`shortHash` 把 SHA-256 截断到 8 字节**（`worker.js:2414` 的 `.slice(0, 8)`）
2. **盐默认回落到 `APP_TOKEN`**（`:2406`：`env.LOG_HASH_SALT || env.APP_TOKEN || "voicetodo"`），而 `LOG_HASH_SALT` 在 `wrangler.toml:80` 与 `.example` 里**都是注释掉的**
3. **`APP_TOKEN` 随 iOS 包分发**（客户端要拿它做 `X-App-Token`），解包即可得

而 `originalTransactionId` 是 Apple 的数字交易号，搜索空间只有 ~10^12 量级。**盐已知 + 空间这么小 + 摘要只有 8 字节 → 拿到日志或 KV dump 的人，几秒就能反推出明文订阅号。**

这跟同一个 helper 用在 device ID 上完全不同：那是随机 UUIDv4（2^122），暴力不可行。**helper 对它原本的输入是够的，对这个新输入不够**——换输入时没有重新评估强度。

于是 `PRIVACY_POLICY.md` 那句 "we only hold hashed identifiers" 实质上仍站不住：对持有 App 包的人来说，这个哈希等价于明文。

**修法主要是配置，不是代码：**

1. **把 `LOG_HASH_SALT` 真正设成 secret**：
   ```bash
   cd AIProxy && npx wrangler secret put LOG_HASH_SALT   # 值用 openssl rand -hex 32
   ```
   盐一旦不在 App 包里，暴力就无从下手——**这一步就足以让问题消失**
2. 改掉 `wrangler.toml` 那行注释的误导性：当前写法让它看起来可选。对 device ID 它近乎可选，**对订阅标识它是承重的**
3. 可选加固：对订阅标识不做 8 字节截断，用完整摘要

> 换盐的副作用与哈希化本身同类：DO 名 / KV 键变化，当日计数器归零（每订阅当天最多多放一轮额度）。**建议与 `527d3d5` 同批部署，只承受一次。**

## 残留 3：部署过渡窗会把明文订阅号写进存储与日志（LOW-MEDIUM）

缓存读取分支（`worker.js:1692`）：

```js
subscriptionId: typeof cached.subscriptionId === "string" && cached.subscriptionId ? cached.subscriptionId : null,
```

注释写的是「旧缓存条目（本次部署前写入，TTL ≤15min）**没有** subscriptionId」。**这个前提与实际部署序列不符：**

- 早于 `1d5316c` 的条目：确实没有该字段
- **当前线上跑的 `1d5316c` 写的条目：有该字段，且是明文**

所以 `527d3d5` 部署后的 ≤15 分钟里，这批明文值会被原样取出，流进 DO 名 `sub-daily:<明文>`、KV key `sub-quota:<date>:<明文>`、以及**每个 Pro 请求的日志**。

影响还不止 15 分钟：那一窗口里创建的 **KV 键存到当日结束、DO 实例长期存在**，Cloudflare 日志也按其保留期留存——明文在存储里活得比过渡窗久得多。

**一行修法：** `safeDeviceId()` 永远返回 `sha256:` 前缀，据此判别即可：

```js
const cachedSubId = typeof cached.subscriptionId === "string" && cached.subscriptionId.startsWith("sha256:")
  ? cached.subscriptionId
  : null;
```

落到 `null` 就走已有的 `cap_skipped_no_sub_id` 分支（跳过订阅限速 + 记日志），下一次完整验签自然写入哈希值。复用现成路径，零新增语义。

## 建议处理顺序

1. **残留 2 第 1 步（配 `LOG_HASH_SALT` secret）** —— 一条命令，是让隐私承诺真正成立的关键；与哈希化同批部署只承受一次计数器归零
2. **残留 3（过渡窗前缀判别）** —— 一行，**赶在 `527d3d5` 部署前加进去最省事**；部署后再加就已经漏过一窗
3. **残留 1（重推时长）** —— 告警仍在说假话；改动小，但测试要补时钟推进才守得住

## 验证

```bash
cd AIProxy && npm test   # 当前 312 通过;补完时钟推进后应仍全过
```

残留 1 的回归要点：第二跑与第三跑之间推进模拟时钟 ≥ 一个 cron 间隔，断言重推文案里的时长**等于真实故障时长**，而不是含重推延迟的值。
