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
    params TEXT                           -- 事件参数 JSON（已脱敏）
);

CREATE INDEX IF NOT EXISTS idx_device ON telemetry_events(device_id);
CREATE INDEX IF NOT EXISTS idx_event ON telemetry_events(event_name);
CREATE INDEX IF NOT EXISTS idx_received ON telemetry_events(received_at);
CREATE INDEX IF NOT EXISTS idx_session ON telemetry_events(session_id);

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
