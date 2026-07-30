# VoiceTodo Xcode 项目配置清单

## 必需配置

### Targets
- [ ] VoiceTodo (iOS App)
- [ ] VoiceTodoTests (Unit Tests)
- [ ] VoiceTodoUITests (UI Tests)
- [ ] VoiceTodoWidget (Widget Extension)

### Capabilities
- [ ] App Groups (VoiceTodo): group.com.voicetodo.shared
- [ ] App Groups (VoiceTodoWidget): group.com.voicetodo.shared

### Build Settings
- [ ] iOS Deployment Target: 17.0
- [ ] Swift Language Version: 5
- [ ] Enable Testability: Yes (Debug)

### Frameworks
- [ ] SwiftData.framework
- [ ] Speech.framework
- [ ] AVFoundation.framework
- [ ] WidgetKit.framework (Widget only)
- [ ] SwiftData.framework (Widget only)

### File Target Memberships
- [ ] 主应用文件 → VoiceTodo
- [ ] 单元测试文件 → VoiceTodoTests
- [ ] UI 测试文件 → VoiceTodoUITests
- [ ] Widget 文件 → VoiceTodoWidget
- [ ] 共享协议文件 → VoiceTodo + VoiceTodoWidget + VoiceTodoTests

### Schemes
- [ ] VoiceTodo (包含测试)
- [ ] VoiceTodoWidget

## 可选配置

### Debug Settings
- [ ] Code Coverage: Enabled
- [ ] Thread Sanitizer: Enabled (Debug)
- [ ] Address Sanitizer: Enabled (Debug)

### CI/CD
- [ ] GitHub Actions 配置
- [ ] 自动化测试运行
- [ ] 代码覆盖率报告

## 验证步骤

1. [ ] 编译通过（无错误）
2. [ ] 运行单元测试
3. [ ] 运行 UI 测试
4. [ ] 测试 Widget 显示
5. [ ] 验证 App Group 数据共享

## 上线前必做：AI 代理额度配置

`AIProxy/wrangler.toml` 的 `[vars]` 里这两个值目前是**测试阶段**值，上线前必须改：

- [ ] `DAILY_REQUEST_LIMIT`：`100` → `2`（免费档每设备每天）
- [ ] `PAID_DAILY_LIMIT`：`1000` → `100`（Pro 档每设备每天）
- [ ] 改完跑 `cd AIProxy && npm test`，配置断言会校验两个值都存在且 `PAID > FREE`
- [ ] `wrangler deploy` 后用 curl 确认：不带 JWS → `X-Quota-Plan: free`、
      带合法 JWS → `X-Quota-Plan: pro` 且 `X-Quota-Limit` 是 Pro 值
- [ ] `wrangler secret put LOG_HASH_SALT` 配独立 salt（不复用 `APP_TOKEN`，
      否则轮换 token 会让所有设备的额度计数 key 变化、全员额度静默重置）

⚠️ **把免费档降到 2 之前，必须先处理这两个已知问题**，否则它们会立刻从 P1 变 P0：

- [ ] **上游抖动会烧额度**：代理在调 AI 之前就扣费，而客户端对网络/超时/5xx 会重试到
      `NetworkConfig.retryCount = 2`（单次提取最多 3 个请求）。免费档只有 2 条时，
      provider 抖动一次就把用户当天额度打光，且一条都没解析成功。
      修法：worker 在「所有 provider 都失败」时调用现成的 `refundDeviceQuota`。
- [ ] **Siri 路径超额时静默丢词**：`App/Intents/AddTodoIntent.swift` 用的是默认
      `NetworkClient()`（`subscriptionJWSProvider: { nil }`），所以 Siri 请求不带订阅
      凭证、Pro 用户被当免费档；且 `.quotaExhausted` 不在 fallback 白名单里，
      落到 `default:` 直接返回失败，**transcript 不会离线保存**，用户说的话直接消失。

## 注意事项

⚠️ 确保 Widget Extension 的 Bundle ID 是主应用 Bundle ID 的子集
   例如: com.voicetodo.app.widget

⚠️ 所有 targets 使用相同的 App Group ID
   group.com.voicetodo.shared

⚠️ SwiftData ModelContainer 配置使用共享容器路径
