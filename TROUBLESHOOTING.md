# Troubleshooting

录音 → AI 解析链路出问题时的现场排查手册。出问题时按本文件顺序搜日志,
不要凭现象猜。

---

## 场景 1:用户说「远端连不上」「网络问题」「AI 不稳定」「录完没反应」

UI 上能看到的 toast 文案有 4 条都可能被口语化成"远端连不上":

| Toast 文案 | 抛出的错误 | 含义 |
|---|---|---|
| 网络连接失败,请检查网络后重试 | `.networkUnavailable` | 设备断网 / DNS / TCP / TLS 失败 |
| 请求超时,请稍后重试 | `.apiTimeout` | 55s 内没有字节回来 |
| 服务繁忙,请稍后重试 | `.serviceUnavailable` | Worker 返 503 |
| AI 服务近期不稳定,已离线保存,请稍后重试 | `.circuitOpen` | **客户端熔断器在冷却**(15s) |

### 第一步:Console 里搜这两条关键字(任一命中即定位)

```
extract.stream.circuit_open          ← 熔断器(本次请求根本没出门)
proxy.stream.transport_failed        ← 网络层失败(本次出门了但没回来)
proxy.stream.http_failed             ← Worker 返了非 2xx
```

### 第二步:按字段读

**`extract.stream.circuit_open`** → 这次失败不是本次请求的问题。
往前翻 **最多 15 秒** 的日志,找 `extract.circuit.opened` 那一行,看 `reason=`
字段。reason 是前 5 次失败累积的根因(networkUnavailable / apiTimeout /
apiServerError / serviceUnavailable 之一),修那个才治本。

**`proxy.stream.transport_failed stage=xxx`** → 看 `stage` 字段一眼定位挂在哪段:

| stage | 含义 | 下一步 |
|---|---|---|
| `offline` | 设备真没网 | 看 WiFi/蜂窝,不是 app 问题 |
| `dns` | 域名解析失败 | 换 DNS(1.1.1.1 / 8.8.8.8)再试;Worker 域名被污染过 |
| `tcp_connect` | TCP 连不上 Worker | 路由器/防火墙/VPN;换网络试 |
| `tls` | TLS 握手失败 | 证书过期 / 中间人代理 / 时间不对 |
| `timeout_total` | 55s 超时 | Worker 端 provider 都挂了,看 Worker 日志 |
| `mid_stream` | 连上后中断 | 连接不稳;偶发可忽略,持续就是网络质量问题 |
| `cancelled` | 用户取消 | 不是 bug,正常路径 |

**`proxy.stream.http_failed status=XXX`** → 看 `status`:

| status | 含义 | 下一步 |
|---|---|---|
| 401 | X-App-Token 不对 | `Config/Secrets.xcconfig` 的 `VOICETODO_AI_PROXY_APP_TOKEN` 与 Worker `wrangler secret put APP_TOKEN` 是否一致 |
| 429 | 限流/配额 | 看 `X-RateLimit-Type` 头:`quota`→免费额度,`ip_daily`→IP 当日,空→velocity |
| 503 | 全局预算耗尽 / 无可用 provider | Worker 端的事,看 Cloudflare logs |
| 5xx 其他 | Worker 异常 | 看 Worker 日志 |

### 第三步:从 Mac 上直接探活 Worker

```bash
# 应该返 401(没带 token 的预期响应),说明 Worker 活着、路由匹配、CDN 通
curl -X POST -H "Content-Type: application/json" \
  -d '{"transcript":"test","locale":"zh-CN","stream":false}' \
  -w "\nHTTP %{http_code} total=%{time_total}s\n" \
  https://ai.saydo.org/v1/todo-extractions
```

返回 401 → Worker 正常,问题在客户端 → 回到第一步看 Console。
超时 / connection refused / 解析失败 → Worker 这边的事。

---

## 已知历史坑

- **`workers.dev` 域名在国内被 DNS 污染**(`wrangler.toml` 注释里有)。
  Secrets.xcconfig 必须用 `https://ai.saydo.org/...`,不能用 `*.workers.dev`。
  DNS 污染表现为 `stage=dns` 或解析到一个非 Cloudflare 的 IP 后 TCP 失败。

- **熔断器阈值 5、冷却 15s**(`NetworkConfig.circuitBreakerFailureThreshold`、
  `circuitBreakerCooldown`)。表现是「能用 → 突然不行 → 一会儿又行」。
  自恢复是设计行为,不是 bug;但如果反复触发,根因在前 5 次失败。

- **客户端超时 55s**(`NetworkConfig.apiTimeout`)。这个值是按
  `(MAX_ATTEMPTS - 1) × workerProviderTimeout + tailAllowance` 推的,
  改 `wrangler.toml` 的 `AI_PROVIDER_MAX_ATTEMPTS` 或 `timeoutMs` 必须同步改这边,
  否则客户端会在 Worker 还在 failover 时就放弃,记成一次服务故障喂给熔断器。
