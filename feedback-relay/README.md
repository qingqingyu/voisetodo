# voicetodo-feedback

VoiceTodo 用户反馈 → Telegram 推送 + D1 归档。Cloudflare Worker。

```
[App FeedbackSheet]
   ↓ POST /v1/feedback (X-App-Token)
[feedback-relay Worker]
   ↓ sendMessage / sendPhoto
[Telegram Bot → 你手机秒推]
   ↓ 同时写一行
[D1 feedback 表(归档)]
```

## 与 AIProxy 的关系

- **独立 worker**,职责隔离(改反馈逻辑不影响核心 AI 路径)
- **复用同一个 `APP_TOKEN`**(客户端是同一个 App,共用身份校验)
- 不依赖 AIProxy 的 KV / D1 / provider 任何 binding

## 部署步骤(你做,约 10 分钟)

### 0. 前置

- 已装 Node.js ≥ 18
- 已 `npm install -g wrangler`(或用 `npx wrangler`)
- 已 `wrangler login`(登录 Cloudflare 账号,与 AIProxy 同一个账号即可)
- 已经有 Telegram bot token 和 chat_id(你已完成)

### 1. 安装依赖

```bash
cd feedback-relay
npm install
```

### 2. 创建 D1 数据库

```bash
npx wrangler d1 create voicetodo-feedback
```

输出会给你一个 `database_id`,复制它。

### 3. 配置 wrangler.toml

复制模板:

```bash
cp wrangler.toml.example wrangler.toml
```

打开 `wrangler.toml`,把 `database_id = "your-d1-database-id-here"` 替换成上一步拿到的 ID。

### 4. 初始化 D1 schema

```bash
npx wrangler d1 execute voicetodo-feedback --remote --file=./schema.sql
```

### 5. 注入 secrets

3 个 secret,逐个执行(会提示你贴值):

```bash
npx wrangler secret put TELEGRAM_BOT_TOKEN
# 贴:你的 bot token（形如 1234567890:AAFf...，从 @BotFather 拿）

npx wrangler secret put TELEGRAM_CHAT_ID
# 贴:你的 chat_id（数字，从 @userinfobot 查）

npx wrangler secret put APP_TOKEN
# 贴:与 AIProxy 的 APP_TOKEN 完全一致的值
# (从 AIProxy 的 wrangler secret 取,或查你本地 ~/.wrangler 配置)
```

### 6. 部署

```bash
npx wrangler deploy
```

输出会给你一个 URL,形如:

```
https://voicetodo-feedback.<你的-account-subdomain>.workers.dev
```

或如果你配了自定义域名:

```
https://feedback.saydo.org
```

复制这个 URL。

### 7. 本地验证(curl)

替换 `<TOKEN>` 为 AIProxy 的 APP_TOKEN,`<URL>` 为上一步的 worker URL:

```bash
curl -X POST https://<URL>/v1/feedback \
  -H "Content-Type: application/json" \
  -H "X-App-Token: <TOKEN>" \
  -d '{
    "type": "bug",
    "description": "测试反馈链路",
    "locale": "zh-Hans",
    "appVersion": "1.0.0 (1)"
  }'
```

期望返回:

```json
{"ok":true,"archiveId":1}
```

同时你的 Telegram 应该秒级收到一条消息。

### 8. 把 worker URL 配进 iOS 工程的两个地方

**Xcode build setting**(给 Archive 用):

打开 `project.yml`,在 `targets.VoiceTodo.settings.config.base-build-settings`(或 `configs` 那块)加:

```yaml
VOICETODO_FEEDBACK_ENDPOINT: $(VOICETODO_FEEDBACK_ENDPOINT)
```

然后真机调试时通过 Xcode scheme 的 Environment Variables 设置:

```
VOICETODO_FEEDBACK_ENDPOINT = https://<URL>
```

(具体注入方式与你给 `VOICETODO_AI_PROXY_ENDPOINT` 的方式一致)

### 9. 上线后(可选):**rotate token**

如果你的 bot token 曾经出现在任何非安全渠道(聊天记录、剪贴板、截图),去 `@BotFather` 发 `/revoke` 拿新 token,再覆盖:

```bash
npx wrangler secret put TELEGRAM_BOT_TOKEN
# 贴新 token,会覆盖旧值
```

旧 token 即刻失效。本仓库的 README/示例从不写入真实 token,所以 git 历史里没有泄露点,这一步只是额外保险。

## 失败行为

- **客户端 → Worker 网络故障**:客户端显示"反馈发送失败",建议稍后重试(用户重试可双倍补单,D1 端会去重靠 `received_at` 窗口)
- **Worker → Telegram 推送失败**:Worker **仍然返 200** 给客户端(反馈已落 D1),日志记录 `feedback.telegram_failed`,你能在 wrangler tail 看到。后续可手动重推(查 D1 + 调 Telegram API)
- **D1 写失败**:Worker 不阻断 Telegram 推送,日志记录 `feedback.archive_failed`,Telegram 推送仍 work

## 后续手动查询(可选)

```bash
# 最近 50 条反馈
npx wrangler d1 execute voicetodo-feedback --remote --command \
  "SELECT id, datetime(received_at/1000, 'unixepoch', 'localtime') AS t, type, substr(description, 1, 80) AS preview, telegram_delivered, handled FROM feedback ORDER BY received_at DESC LIMIT 50;"

# Telegram 推送失败的(需要手动补推)
npx wrangler d1 execute voicetodo-feedback --remote --command \
  "SELECT id, received_at, type, description FROM feedback WHERE telegram_delivered = 0 ORDER BY received_at DESC;"
```

## 监控

```bash
npx wrangler tail voicetodo-feedback
```

实时看 JSON-line 日志,关键事件:

- `feedback.received` - 收到反馈
- `feedback.delivered` - Telegram 推送成功
- `feedback.telegram_failed` - Telegram 推送失败(看 `error` 字段)
- `feedback.archive_failed` - D1 写失败
- `feedback.auth.failed` - APP_TOKEN 校验失败(注意:可能有人在扫端点)

## 没做的事(故意不做的)

- **不存截图到 D1**:Telegram 本身是存储,Worker 端不重复存。如果想做反馈 dashboard 再考虑
- **不做速率限制**:APP_TOKEN 校验已经挡住外部乱灌,App 内的反馈频率上限放在客户端(后续可加)
- **不做 worker.test.js**:第一版跑通主链路,后续再加。AIProxy 的 worker.test.js 模式可参考
- **不做 SMTP 邮件兜底**:Telegram 一条渠道够用
