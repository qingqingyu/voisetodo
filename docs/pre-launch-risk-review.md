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
- **还有 3 处遗留缺陷未修**（`docs/alerting-layer-bc-review-fixes.md` 第二轮 review）。其中遗留 1 让 secret 全缺时 `/v1/health` 仍报 200 ok。
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
