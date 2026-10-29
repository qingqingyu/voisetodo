# 任务书：解析耗时监控——每次解析用了多久、走了哪个模型和哪把 Key

> 2026-10-29 起草，代码对照基线 `main` @ `6b27080`。本文档是**交给执行者的任务书**。
> 完成后把结果写进 `docs/extract-latency-monitoring-results.md`（格式见 §8），交回审查。

---

## 0. 要回答的问题

上线后要能随时查到：

1. 用户**说完话到清单出现**，一共用了多久（P50 / P95）？
2. 每次解析**走的是哪个服务商条目、哪个模型（即哪个网址）、哪把 Key**？
3. 按模型、按 Key 看：成功率、耗时、切换到备用服务商的比例。
4. 耗时或失败率异常时，能**主动收到告警**。

### 现状（起草时核对）

| 能力 | 现状 | 缺口 |
|---|---|---|
| App 端耗时 | `extract_outcome` 记了 AI 解析时长；`recording_outcome` 记了录音时长 | 没有「说完话 → 清单出现」的总时长；录音事件不带解析 ID，两个事件串不起来 |
| 代理端模型 / 耗时 | `proxy.provider.call_success`、`proxy.provider.stream_success` 日志里有 `providerId`、`model`、`durationMs` | 只在 Cloudflare 日志里，保留几天，无法汇总查询 |
| 用了哪把 Key | `keySlot` 只在多 Key 条目、且只在**失败**日志里记 | 成功请求不知道用的哪把 Key |
| App 与代理对上号 | App 每次请求都带 `X-Extract-ID` 头（`Extractor/NetworkClient.swift:296`） | 代理 `makeRequestContext`（`AIProxy/worker.js` 约 `:2692`）没读它 |
| 告警 | cron 每 30 分钟跑 `handleScheduled`，已有 Telegram 推送（`ALERTING.md`） | 没有耗时 / 失败率告警 |

---

## 1. 分两部分，分开发布

| 部分 | 内容 | 发布 |
|---|---|---|
| **A. 代理端**（§2～§4） | 每次解析写一行到 D1 + 读 `X-Extract-ID` + 告警 | `wrangler deploy`，随时上线 |
| **B. App 端**（§5） | 分段计时，补齐「说完话 → 清单出现」 | 随下一版 App 发布 |

**A 和 B 分两个提交**，A 先完成、先验收。B 不依赖 A 也能工作。

---

## 2. 代理端：新表 `extract_requests`

### 2.1 表结构

在 `AIProxy/schema.sql` 末尾追加（同时写一条给存量库执行的迁移注释，参考文件里 `extract_id` 的写法）：

```sql
-- 每次 AI 解析一行(只记 mode=extract;assist 模式不记)。数据保留 90 天,与 telemetry_events 同一个 GC。
CREATE TABLE IF NOT EXISTS extract_requests (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    received_at INTEGER NOT NULL,      -- 代理收到请求的时间(ms since epoch)
    request_id TEXT NOT NULL,          -- 代理 requestId
    extract_id TEXT,                   -- App 带来的 X-Extract-ID;没带 = NULL
    device_id TEXT NOT NULL,           -- 已加盐哈希的设备标识(requestContext.deviceId)
    plan TEXT,                         -- free / pro
    stream INTEGER NOT NULL,           -- 1 = 流式
    provider_id TEXT,                  -- 最终成功(或最后一次尝试)的服务商条目 id,如 ZAI_ANTHROPIC_AIR
    model TEXT,                        -- 该条目的模型名
    key_slot TEXT,                     -- 用的哪把 Key:secret 名,如 PROVIDER_KEY_ZAI_ANTHROPIC。绝不写 Key 的值
    attempts INTEGER NOT NULL,         -- 一共试了几个服务商
    providers_tried TEXT,              -- 尝试顺序,逗号分隔
    failover INTEGER NOT NULL,         -- 1 = 切换过备用服务商
    upstream_first_byte_ms INTEGER,    -- 最终那次上游调用:发出请求到收到响应头
    total_ms INTEGER,                  -- 代理收到请求到响应结束(流式 = 发完 [DONE] 或失败的时刻)
    status INTEGER NOT NULL,           -- 返回给 App 的 HTTP 状态码(流式中途失败记 200 + outcome)
    outcome TEXT NOT NULL,             -- success / empty_todos / unparseable_output / upstream_failed / stream_failed / client_disconnected / quota_rejected / no_provider / cache_hit
    error_type TEXT,                   -- 失败时的 errorType(如 status_429 / timeout / quota_exhausted)
    todos_count INTEGER                -- 解析出几条待办;拿不到就 NULL
);

CREATE INDEX IF NOT EXISTS idx_er_received ON extract_requests(received_at);
CREATE INDEX IF NOT EXISTS idx_er_provider ON extract_requests(provider_id, received_at);
CREATE INDEX IF NOT EXISTS idx_er_extract ON extract_requests(extract_id);
```

### 2.2 字段来源

- `provider_id` / `model`：`executeWithFailover` 已把结果写进 `requestContext.providerUsed`、`providerAttempts`、`providersTried`、`failoverCount`（`AIProxy/src/provider.js` `recordAttempts` 一带），`model` 取对应条目。
- `key_slot`：**单 Key 和多 Key 条目都要记**。多 Key 条目现在只在失败日志里有 `keySlot`；改成在选定 Key 时就写进 attempt（单 Key 条目写它的 `secretName`），成功、失败都带上。
  只写 secret **名字**，**任何地方都不许出现 Key 的值**（日志、D1、响应头）。
- `upstream_first_byte_ms`：取最终那次 attempt 的 `durationMs`（现有 `call_success` 日志里的同一个值）。
- `total_ms`：
  - 非流式：`finishRequest` 时 `Date.now() - requestContext.startedAt`；
  - 流式：现在 `finishRequest` 在流开始时就调用了（记 `streamingBodyContinues: true`），那个时间只是首字节。
    要在流的结束回调里算（`src/stream.js` 的 `stream_success` 一带，以及 `worker.js` 里流式的 `onSuccess` / `onFailure`）。
- `todos_count`：非流式从解析结果取；流式用结束回调里的 `stats.emittedCount`。
- `outcome`：沿用代码里已有的分类（空结果 `empty_todos` / `unparseable_output`、`client_disconnected` 等），对不上的写最接近的一个，在结果文档里列出映射。
- 被额度、IP 限流等**在调用上游之前**拒掉的请求：也写一行（`provider_id` 为 NULL，`outcome = quota_rejected`），这样才能算真实的失败率。缓存命中写 `outcome = cache_hit`。

### 2.3 写入方式

- 用 `ctx.waitUntil(...)` 异步写，**不能拖慢响应**，也不能因为写库失败让请求失败：写库出错只 `logWarn("proxy.extract_metrics.write_failed", …)`。
- `TELEMETRY_DB` 没配置时直接跳过（和现有 telemetry 写入同样的判断）。
- 每个请求**只写一行**：流式在流结束时写，非流式在返回前写，提前拒掉的在拒绝处写。注意 failover 时不要每次尝试写一行。

### 2.4 读 `X-Extract-ID`

- `makeRequestContext` 读 `X-Extract-ID`，写进 `requestContext.extractId`，这样所有日志都会带上它。
- 只接受最长 64 个字符、只含字母数字和 `-_.:` 的值，其他一律当作没带，防止有人往日志里注入内容。

### 2.5 数据保留

`handleScheduled` 里删 `telemetry_events` 旧数据的地方（`worker.js` 约 `:1164`），同样删 `extract_requests` 中 90 天前的行。

### 2.6 隐私

- 表里不存任何用户内容：不存转写原文、不存待办标题、不存模型输出。
- `device_id` 用已哈希的值。
- 与 `PRIVACY_POLICY.md`、`TELEMETRY.md` 现有口径一致，不需要改隐私政策；在 `TELEMETRY.md` 里补一节说明这张表。

---

## 3. 查询入口

### 3.1 管理接口

新增 `GET /v1/admin/extract-metrics?hours=24`，鉴权**复用现有 `/v1/admin/*` 的方式**，返回 JSON：

- 整体：请求数、成功率、`total_ms` 的 P50 / P95、failover 比例；
- 按 `provider_id + model` 分组：请求数、成功率、P50 / P95；
- 按 `key_slot` 分组：请求数、成功率、P95、`status_429` 次数；
- 按 `outcome` 分组计数。

`hours` 默认 24，最大 168（7 天）。D1 没有百分位函数，P50 / P95 可以取出该窗口的 `total_ms` 在 Worker 里排序算；单次查询行数设上限（比如 20000 行），超出时在返回里标明是抽样。

### 3.2 常用 SQL

在 `AIProxy/schema.sql` 末尾的「常用查询示例」里补几条，至少包括：

- 最近 24 小时按模型的成功率和平均耗时；
- 最近 24 小时按 Key 的 429 次数；
- 用 `extract_id` 把 `extract_requests` 和 `telemetry_events` 连起来，看某次解析在 App 端和代理端各花了多久。

---

## 4. 告警

在 `handleScheduled`（每 30 分钟）里加一项检查，复用现有的 Telegram 推送和告警状态去重（`src/alertState.js`，避免同一问题反复推送）：

| 条件（最近 30 分钟） | 告警 |
|---|---|
| 解析请求 ≥ 20 次，且 `total_ms` P95 > `ALERT_EXTRACT_P95_MS`（默认 20000） | 「解析变慢」，附 P95 和最慢的模型 |
| 解析请求 ≥ 20 次，且成功率 < `ALERT_EXTRACT_SUCCESS_MIN`（默认 0.9） | 「解析失败率高」，附按模型的失败分布 |

- 阈值放在 `wrangler.toml` 的 `[vars]` 里，带注释说明含义；请求数不到 20 次不告警（量太小没有意义）。
- 情况恢复后推一条「已恢复」，与现有的全挂 / 恢复告警同一模式。
- 告警出错不能影响 cron 里的其他任务（GC、健康检查、心跳）。

---

## 5. App 端：分段计时

### 5.1 要记的时间点

一次语音解析里记 4 个时间点（单调时钟，如 `ContinuousClock`，不要用系统时间相减）：

| 时间点 | 含义 |
|---|---|
| T0 | 用户说完：录音结束（手动停止或静音自动结束） |
| T1 | 解析请求发出 |
| T2 | 第一条待办出现在确认面板（流式第一条到达并显示） |
| T3 | 解析完成（流结束或非流式响应返回） |

### 5.2 上报

`extract_outcome` 事件加 3 个可选参数（毫秒，整数）：

- `speechToRequestMS` = T1 − T0
- `speechToFirstTodoMS` = T2 − T0（没有出现任何待办就不带）
- `speechToDoneMS` = T3 − T0

- 现有的 `durationMS`、`attempts` 等参数保留不变，老版本的数据照常能用。
- 只有**刚录完马上解析**的路径有 T0。离线后补解析、Siri、键盘输入这些没有 T0 的路径不带这 3 个参数，并加一个参数 `path`（`live_voice` / `pending_recovery` / `siri` / `keyboard`）区分来源，避免把补解析的长等待算进「说完话到出清单」。
- `recording_outcome` 补上 `extractID`，让录音事件和解析事件能对上。
- 在 `TELEMETRY.md` 的事件表里同步更新这两个事件的参数说明。

### 5.3 位置提示

`extract_outcome` 在 `Extractor/TodoExtractorService.swift` 里有几处调用（约 `:76`、`:92`、`:154`、`:471`）；录音结束到发起解析的流程在 `App/TranscriptProcessingFlow.swift` 和 `Voice/VoiceInputManager.swift`。执行者自己找最合适的位置挂时间点，在结果文档里写明每个时间点挂在哪里。

---

## 6. 测试

### 6.1 代理端（`AIProxy/worker.test.js`，沿用现有 fake D1 / fake env 写法）

1. 非流式成功：写入一行，`provider_id`、`model`、`key_slot`、`attempts=1`、`failover=0`、`outcome=success`、`todos_count` 都正确。
2. 主力失败、备用成功：只写**一行**，`attempts=2`、`failover=1`、`providers_tried` 顺序正确、`provider_id` 是备用。
3. 流式成功：`total_ms` 在流结束时计算（用可控的假时钟或延迟，断言它大于首字节时间），`todos_count` = `emittedCount`。
4. 流式中途客户端断开：`outcome=client_disconnected`。
5. 额度拒绝：写一行，`provider_id` 为 NULL，`outcome=quota_rejected`。
6. 带合法 `X-Extract-ID`：行里和日志里都有；带非法值（超长、含空格或换行）：当作没带。
7. **全表和全部日志里不出现 Key 的值**：用一个可识别的假 Key 字符串，断言它不出现在 D1 写入参数和任何日志输出里。
8. D1 写入抛错：请求照常成功返回。
9. `TELEMETRY_DB` 未配置：请求照常，不报错。
10. 管理接口：未鉴权返回 401；有数据时分组和百分位正确；`hours` 超过 168 时按 168 处理。
11. 告警：构造慢请求和失败请求的数据，触发一次告警；再跑一次不重复推送；恢复后推送「已恢复」；请求数不到 20 次不告警。

`cd AIProxy && npm test` 全部通过，报告改前改后的通过数。

### 6.2 App 端

- 给计时逻辑写单元测试：4 个时间点的差值计算、缺 T0 或 T2 时不带对应参数、`path` 取值正确。
- 真机录一次音，在 Xcode 日志里核对 3 个新参数的数值大致合理（如说完到出第一条在几秒量级）。

---

## 7. 上线步骤（写进结果文档，由人执行）

1. 对线上 D1 执行一次建表语句（`npx wrangler d1 execute voicetodo-telemetry --remote --file=./schema.sql`，或只执行新增的建表部分），先在本地库试一遍。
2. `npx wrangler deploy`。
3. 用 App 解析几次，调 `/v1/admin/extract-metrics?hours=1` 确认有数据、`key_slot` 是 secret 名而不是 Key。

执行者**不部署**、**不对线上 D1 执行任何语句**，只在结果文档里写清步骤。

---

## 8. 结果格式（`docs/extract-latency-monitoring-results.md`）

1. 改动摘要：改了哪些文件，每处一句话；A、B 两个提交的哈希。
2. `outcome` 各取值与代码里已有分类的对应关系。
3. 测试：改前改后 `npm test` 通过数；§6.1 每条测试的名字。
4. 管理接口的一份示例返回（用测试数据）。
5. App 端 4 个时间点各挂在哪个函数里。
6. 上线步骤（§7）。
7. 偏离任务书的地方及理由（没有就写「无」）。

---

## 9. 执行约束

- 从最新 `main` 拉新分支（名字自定），**不要直接在 main 上改**；提交、推送分支后交回审查，**不合 main**。
- 不部署，不对线上 D1 执行语句，不改线上 secret。
- 不改服务商选择、熔断、额度的逻辑；本次只加记录、查询和告警。
- 任何地方都不许记录 Key 的值、转写原文、待办标题、模型输出。
- 提交信息里不要出现模型名称。
