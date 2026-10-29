-- VoiceTodo 遥测事件表
-- 部署：`wrangler d1 execute voicetodo-telemetry --file=./schema.sql`
-- 数据保留：90 天，由 worker.js scheduled handler 每天 03:00 UTC 清理

CREATE TABLE IF NOT EXISTS telemetry_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    received_at INTEGER NOT NULL,         -- 服务端接收时间戳（ms since epoch）
    event_name TEXT NOT NULL,             -- 事件名（如 recording_started）
    event_timestamp INTEGER NOT NULL,     -- 客户端事件时间戳（ms since epoch）
    session_id TEXT NOT NULL,             -- 客户端会话 ID（每次启动 UUID，不持久化）
    device_id TEXT NOT NULL,              -- sha256 哈希后的设备标识
    app_version TEXT,                     -- 客户端 App 版本
    ios_version TEXT,                     -- iOS 系统版本
    params TEXT,                          -- 事件参数 JSON（已脱敏）
    extract_id TEXT                       -- 客户端 AI 提取关联 ID（X-Extract-ID 同源；"none" = 无提取上下文）
);

CREATE INDEX IF NOT EXISTS idx_device ON telemetry_events(device_id);
CREATE INDEX IF NOT EXISTS idx_event ON telemetry_events(event_name);
CREATE INDEX IF NOT EXISTS idx_received ON telemetry_events(received_at);
CREATE INDEX IF NOT EXISTS idx_session ON telemetry_events(session_id);
CREATE INDEX IF NOT EXISTS idx_extract ON telemetry_events(extract_id);

-- 迁移（已部署的存量库执行一次；SQLite 无 ADD COLUMN IF NOT EXISTS，重复执行会报 duplicate column）：
--   ALTER TABLE telemetry_events ADD COLUMN extract_id TEXT;
--   CREATE INDEX IF NOT EXISTS idx_extract ON telemetry_events(extract_id);

-- 常用查询示例：
--
-- 按 DAU 统计：
--   SELECT date(received_at / 1000, 'unixepoch') AS day,
--          COUNT(DISTINCT device_id) AS dau
--   FROM telemetry_events GROUP BY day ORDER BY day DESC;
--
-- 按事件类型计数（最近 7 天）：
--   SELECT event_name, COUNT(*) AS count
--   FROM telemetry_events
--   WHERE received_at > (strftime('%s','now','-7 days') * 1000)
--   GROUP BY event_name ORDER BY count DESC;
--
-- 某设备的事件流：
--   SELECT event_name, event_timestamp, params
--   FROM telemetry_events
--   WHERE device_id = 'sha256:xxx'
--   ORDER BY received_at DESC LIMIT 50;

-- ─────────────────────────────────────────────────────────────────────────────
-- 每次 AI 解析一行（extract-latency-monitoring 任务书 §2，2026-10-29）
-- 只记 mode=extract；assist（split/reflect/deep-read）不记。
-- 数据保留 90 天，由 handleScheduled 与 telemetry_events 同一个 GC 清理。
-- 隐私红线：不存转写原文、待办标题、模型输出；key_slot 只存 secret 名，绝不存 Key 的值。
--
-- 迁移（已部署的存量库执行一次建表即可，IF NOT EXISTS 可重复执行）：
--   本文件直接 `wrangler d1 execute voicetodo-telemetry --remote --file=./schema.sql`
--   幂等，已有表不会重建。
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
    key_slot TEXT,                     -- 用的哪把 Key:secret 名(单 key 条目)或 条目id#secret名(多 key 条目)。绝不写 Key 的值
    attempts INTEGER NOT NULL,         -- 一共试了几个服务商(同条目内 key 级重试去重后计 1)
    providers_tried TEXT,              -- 尝试顺序,逗号分隔(条目 id,去重保序)
    failover INTEGER NOT NULL,         -- 1 = 切换过备用服务商
    upstream_first_byte_ms INTEGER,    -- 最终那次上游调用:发出请求到收到响应(与 call_success 日志的 durationMs 同值)
    total_ms INTEGER,                  -- 代理收到请求到响应结束(流式 = 流结束时刻)
    status INTEGER NOT NULL,           -- 返回给 App 的 HTTP 状态码(流式中途失败记 200 + outcome)
    outcome TEXT NOT NULL,             -- success / empty_todos / unparseable_output / upstream_failed / stream_failed / client_disconnected / quota_rejected / no_provider / cache_hit / proxy_error
    error_type TEXT,                   -- 失败时的 errorType(如 status_429 / timeout / quota_exhausted)
    todos_count INTEGER                -- 解析出几条待办;拿不到就 NULL
);

CREATE INDEX IF NOT EXISTS idx_er_received ON extract_requests(received_at);
CREATE INDEX IF NOT EXISTS idx_er_provider ON extract_requests(provider_id, received_at);
CREATE INDEX IF NOT EXISTS idx_er_extract ON extract_requests(extract_id);

-- 常用查询示例（extract_requests）：
--
-- 最近 24 小时按模型的成功率和平均耗时：
--   SELECT provider_id, model,
--          COUNT(*) AS requests,
--          ROUND(AVG(CASE WHEN outcome IN ('success','cache_hit','empty_todos') THEN 1.0 ELSE 0 END), 4) AS success_rate,
--          ROUND(AVG(total_ms), 0) AS avg_ms
--   FROM extract_requests
--   WHERE received_at > (strftime('%s','now','-24 hours') * 1000)
--     AND outcome != 'client_disconnected'
--   GROUP BY provider_id, model ORDER BY requests DESC;
--
-- 最近 24 小时按 Key 的 429 次数（终态为上游 429 的行）：
--   SELECT key_slot, COUNT(*) AS requests,
--          SUM(CASE WHEN error_type = 'status_429' THEN 1 ELSE 0 END) AS status_429
--   FROM extract_requests
--   WHERE received_at > (strftime('%s','now','-24 hours') * 1000)
--   GROUP BY key_slot ORDER BY requests DESC;
--
-- 用 extract_id 把代理行和 App 埋点连起来，看同一次解析两端各花多久：
--   SELECT r.total_ms AS proxy_total_ms,
--          r.upstream_first_byte_ms AS proxy_first_byte_ms,
--          json_extract(e.params, '$.speechToRequestMS') AS app_speech_to_request_ms,
--          json_extract(e.params, '$.speechToDoneMS') AS app_speech_to_done_ms
--   FROM extract_requests r
--   JOIN telemetry_events e ON e.extract_id = r.extract_id AND e.event_name = 'extract_outcome'
--   WHERE r.extract_id IS NOT NULL
--   ORDER BY r.received_at DESC LIMIT 20;
