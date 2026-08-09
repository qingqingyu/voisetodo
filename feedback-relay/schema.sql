-- VoiceTodo 用户反馈归档表
-- 部署:`wrangler d1 execute voicetodo-feedback --file=./schema.sql`
--
-- 表用途:
--   1. Telegram 推送失败时,Worker 端靠这个表手动补查(防 Telegram 丢消息)
--   2. 后期做 dashboard / 反馈趋势分析
--
-- 截图本身不存 D1(走 Telegram sendPhoto,Telegram 是截图存储);
-- 此表只记文本字段 + 是否带截图的标记。

CREATE TABLE IF NOT EXISTS feedback (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    received_at INTEGER NOT NULL,          -- 服务端接收时间戳(ms since epoch)
    type TEXT NOT NULL,                    -- translation / ai_output / bug / suggestion
    description TEXT NOT NULL,             -- 用户描述
    locale TEXT,                           -- 客户端 Locale(如 ja-JP)
    app_version TEXT,
    os_version TEXT,
    device_model TEXT,
    transcript TEXT,                       -- 仅 ConfirmSheet 入口:用户原话
    extracted_todo_title TEXT,             -- 仅 ConfirmSheet 入口:AI 提取出的待办标题
    has_screenshot INTEGER NOT NULL DEFAULT 0,
    telegram_delivered INTEGER NOT NULL DEFAULT 0,  -- 0=未推/失败 1=已推
    telegram_error TEXT,                  -- 推送失败时的错误描述
    handled INTEGER NOT NULL DEFAULT 0    -- 0=未处理 1=已处理(你手动 mark)
);

CREATE INDEX IF NOT EXISTS idx_feedback_received ON feedback(received_at DESC);
CREATE INDEX IF NOT EXISTS idx_feedback_unhandled ON feedback(handled, received_at DESC);
CREATE INDEX IF NOT EXISTS idx_feedback_undelivered ON feedback(telegram_delivered, received_at DESC);

-- 常用查询:
--
-- 最近 50 条反馈:
--   SELECT id, received_at, type, substr(description, 1, 60) AS preview, telegram_delivered, handled
--   FROM feedback ORDER BY received_at DESC LIMIT 50;
--
-- Telegram 推送失败的需要补推:
--   SELECT id, received_at, type, description, locale FROM feedback
--   WHERE telegram_delivered = 0 ORDER BY received_at DESC;
--
-- 按类型聚合(最近 30 天):
--   SELECT type, COUNT(*) AS count
--   FROM feedback
--   WHERE received_at > (strftime('%s','now','-30 days') * 1000)
--   GROUP BY type ORDER BY count DESC;
