# 任务书:A 场景代码修复轮(3 项)

> 2026-10-22 起草。本文档是**交给执行者的任务书**。修复对象是分支 `claude/capacity-scenario-a`
> (A 场景容量实现,`f9ddb6a`)审查时发现的问题。完成后把结果追加到
> `docs/capacity-scenario-a-results.md` 末尾的新章节「修复轮」(格式见 §6),交回审查。

---

## 0. 范围

| # | 问题 | 严重度 | 位置 |
|---|---|---|---|
| 1 | 选中的 key 在「读在途数」和「申请名额」之间被抢满时,直接把整个条目判为已满,不试同条目里其他有空位的 key | 中 | `AIProxy/src/keyGate.js` `acquireEntrySlot` |
| 2 | 名额全满时返回 **503**,客户端会当作「服务不可用」:不按 `Retry-After` 重试,而且**计入客户端熔断** | 中 | `AIProxy/src/provider.js:136` 附近 |
| 3 | key 的身份用它在 `secretNames` 里的**序号**(`条目id#0`),调整列表顺序或删掉中间某个 key,熔断状态和在途计数会对错 key | 低 | `keyGate.js` `keySlotId`、健康记录 id 的生成处 |
| 附 | 补一条测试:流式传输**中途**客户端断开,名额要及时释放 | 低 | `AIProxy/worker.test.js` |

在 `claude/capacity-scenario-a` 分支上继续提交。**不改客户端 Swift 代码,不部署,不合 main。**

---

## 1. 修复 1:被抢满时改试其他 key

### 1.1 现状

```
读所有 key 的在途数 → 选最少的那个 → 申请名额
                                   └─ 被拒(期间被别的请求抢满)
                                        ├─ wait=false(后面还有条目):返回 full → 立刻切到下一个条目
                                        └─ wait=true(最后一个条目):等 pollMs 后整轮重来
```

被拒时,同条目里**其他 key 可能还有空位**,但代码没有去试。多条目时会白白切走;单条目时多等一个 `pollMs`。
压测只配了一个条目,所以没测出来。

### 1.2 改法

1. 读完在途数后,把 key 按在途数**从少到多**排序(在途数相同的随机打乱,保持现有 R2 的均衡性)。
2. 跳过在途数已经 ≥ 上限的 key。
3. 按顺序**依次**申请名额:第一个成功就用它;被拒就试下一个。
4. 全部被拒(或全部已满)才进入现有的「已满」逻辑(`wait=false` → full;`wait=true` → 等待后整轮重来)。
5. 任何一次 DO 调用失败,仍按现有规则 fail-open。

DO 调用次数:常规路径不变(N 次 count + 1 次 acquire + 1 次 release);只有发生被抢的情况才会多几次 acquire,
最坏是 N 次。在结果文档里写明。

### 1.3 测试(先在改前代码上跑出失败,再改代码跑通过)

1. **单条目**:fake 闸门 DO 让 count 报告 A=0、B=1,但 A 的 acquire 被拒、B 的 acquire 成功。
   断言:请求由 B 服务、HTTP 200、**没有等待**(没有触发 `pollMs` 休眠)。
2. **多条目**:条目 E1(key A、B)+ 条目 E2。count 报 A=0、B=1,A 被拒、B 有空位。
   断言:请求由 E1 的 B 服务,**E2 一次都没被调用**。
3. **全部被拒**:E1 的所有 key 都被拒 → 和现在一样切到 E2(回归,证明没改坏原有行为)。

---

## 2. 修复 2:名额全满改返回 429

### 2.1 为什么

客户端代码(只读,不改):

- `Extractor/NetworkClient.swift` 收到 **503** 一律映射为 `.serviceUnavailable`,不读响应体里的 `retryAfter`。
- `Extractor/TodoExtractorService.swift` 的 `countsAsServiceFailure` 把 `.serviceUnavailable` 计入客户端熔断:
  **连续 5 次失败熔断 15 秒**(`Protocols/Constants.swift` 的 `circuitBreakerFailureThreshold` / `circuitBreakerCooldown`),
  熔断期间这个用户的所有解析都直接落「待解析」。
- 收到 **429** 时走 `NetworkClient.classify429`:只要错误码不是 `quota_exceeded`、`X-RateLimit-Type` 不是 `quota` 或 `ip_daily`,
  就是 `.rateLimited(retryAfter:)`。`retryAfter ≤ 8 秒`(`NetworkConfig.retryMaxInterval`)时客户端**按它等待后重试**,
  而且 `.rateLimited` **不计入**熔断,也**不会弹付费墙**。

所以「名额满」应该用 429:语义上是「此刻忙,2 秒后再试」,和客户端已有的处理完全对上,**不需要改 App**。

结果文档 `docs/capacity-scenario-a-results.md` §2.2 里「客户端按 `.rateLimited(retryAfter≤8s)` 语义可重试」这句,
在返回 503 时是**不成立**的,修复后才成立,请一并更正。

### 2.2 改法

- 把 `provider.js` 里名额全满时抛出的错误状态码从 503 改为 **429**,其余保持:
  - 响应头 `Retry-After: 2`;
  - 响应体 `{"error": "key_pool_full", "retryAfter": 2, "message": "..."}`;
  - 显式加响应头 `X-RateLimit-Type: key_pool_full`。**绝对不能是 `quota` 或 `ip_daily`**:前者会让客户端弹付费墙,后者会让客户端当天不再重试。
- 确认设备额度仍然退还:起草时已核对,`worker.js` 在 `executeWithFailover` 抛错后的 `catch` 里调用
  `refundDeviceQuotaOnUpstreamFailure`,与状态码无关。用测试锁住这一点。
- 同步更新 `wrangler-config.test.js` 里和这个 503 相关的注释或断言(如果有)。
- 同步更新压测脚本 `loadtest/run.mjs` 的模拟客户端,让它和真实客户端一致:
  - 429 且不是 quota / ip_daily:等 `retryAfter` 秒后重试(`retryAfter ≤ 8` 时),**不计入**模拟的熔断;
  - 503:按现有的 1 秒、2 秒退避重试,计入熔断;
  - 如果模拟客户端目前没有实现熔断,这次补上(阈值 5、冷却 15 秒,与客户端常量一致,按压测的时间缩放比例换算)。

### 2.3 测试(先红后绿)

1. **非流式**请求在名额全满时:状态码 429、`Retry-After: 2`、响应体 `error` 为 `key_pool_full`、
   `X-RateLimit-Type` 不是 `quota` 也不是 `ip_daily`。
2. **流式**请求(`stream: true`)同样断言上面四项。流式时客户端只看响应头分类,所以响应头必须齐全。
3. 名额全满被拒后,这个设备的当日额度**没有被扣**(请求前后的额度计数一致)。

### 2.4 压测重跑

修复后重跑 A5 矩阵中的这三组,并新增一组「严重不足」:

| 场景 | 目的 |
|---|---|
| 130 名额,闸门开 | 回归,结论应与修复前一致 |
| 100 名额,闸门开 | 回归 |
| **60 名额,闸门开**(新增) | 让「名额全满」真正大量发生,验证 429 + 客户端重试的效果 |
| 60 名额,闸门关 | 对照 |

报告每组的即时成功率、最终成功率、P95、名额满 429 的次数、模拟客户端熔断触发的次数。

---

## 3. 修复 3:key 的身份改用 secret 名称

### 3.1 改法

- 多 key 条目里,每个 key 的身份从 `条目id#序号` 改为 **`条目id#<secretName>`**(例如 `GLM_AIR_POOL#PROVIDER_KEY_POOL_3`)。
  secret 名称不是密钥本身,可以出现在日志、健康接口、DO 名字里。
- 影响范围:健康记录 id、闸门 DO 名字(`gate:<身份>`)、`/v1/health` 和 `/v1/admin/providers` 的逐 key 明细、相关日志字段。
- **单 key 的旧配置(`secretName`)保持用纯条目 id**,与现在一致,不迁移。
- 配置校验:同一条目的 `secretNames` 里出现重复名字时报配置错误(否则两个 key 会共享同一份状态)。
- 线上目前没有任何多 key 条目,不存在旧数据迁移问题。在结果文档里写明这一点。

### 3.2 测试

1. 一个条目配 `[K1, K2, K3]`,让 K2 余额耗尽并熔断。把配置改成 `[K3, K2, K1]` 后重新加载:
   **K2 仍然是熔断状态,K1、K3 仍然正常**。
2. 删掉中间的 K2(改为 `[K1, K3]`):K3 的在途计数和健康状态不受影响。
3. `secretNames` 有重复名字 → 加载配置时报错。
4. 回归:单 key 旧配置的健康记录 id 仍是纯条目 id。

---

## 4. 附:补测流式中途断开

现有测试 §2.3-3 覆盖的是「收到响应之前」断开(499)。补一条:**流式传输已经开始、传到一半时客户端断开**,
断言该 key 的在途数在短时间内回到原值(**不是**靠租约到期回收)。如果测出来释放不了,就修复释放逻辑,并在结果文档里写明原因。

---

## 5. 约束

- 只改 `AIProxy/`(`src/`、测试、`loadtest/`)和结果文档;不改客户端 Swift 代码;不改线上 `wrangler.toml` 的配置值。
- 每项修复都要在改前代码上先跑出失败的测试,再改代码跑通过。
- `npm test` 全部通过;报告修复前后的通过数。
- 在 `claude/capacity-scenario-a` 上提交、推送,**不合 main**,等审查。

---

## 6. 结果格式(追加到 `docs/capacity-scenario-a-results.md`,新章节「修复轮」)

1. 每项修复:改了哪些文件、核心逻辑一句话。
2. 测试:修复前后 `npm test` 通过数;§1.3、§2.3、§3.2 中先红后绿的关键输出。
3. §2.4 的压测结果表。
4. 对原结果文档中不准确表述的更正(至少包括 §2.2 关于客户端重试语义的那句)。
5. 偏离任务书的地方及理由(没有就写「无」)。
