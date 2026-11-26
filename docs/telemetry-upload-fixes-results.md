# 结果文档:遥测上报 M1 + M2 修复

> 来源:`docs/behavior-funnel-and-p0-activation.md` §6 步 0(2026-11-26 事实核查轮定的
> 两个上报机制缺陷),用户 2026-11-26 指派实施(「然后做修复」)。
> 分支:`task/telemetry-upload-fixes`,基线 `main` @ `d0e7082`(merge-base;即 eab36cb 再加 1 个营销 docs 提交,不触本分支文件)。

## 1. 修的是什么

### M1:只在「充电 + 联网」时上报 → cohort 系统性偏活跃人群

- 根因:`BGProcessingTask`(`requiresExternalPower + requiresNetworkConnectivity`)是唯一
  自动触发路径;首日装完就走、当场删 App 的用户,本地队列随 App 删除而消失,永远进不了
  D1 —— R1 偏高、R3「未激活」组失真(与「关闭遥测」的幸存者偏差是两回事)。
- 修法:`VoiceTodoApp` 进后台分支(`.background`)在 `scheduleNextRun()` 之后新增
  `TelemetryUploader.uploadFromAppBackground()` —— `beginBackgroundTask` 拿 ~30s 系统额度
  立刻补一次 `uploadBatch`。
- 细节:
  - 过期处理器只结束后台任务标记、**不 cancel 在途请求**(批内事件已 drain,cancel 与否
    进程挂起都只丢本批;强 cancel 反而把本可完成的一批变失败);
  - end-once 令牌 + box 衔接 expiration handler,防「过期 + 完成」双 end;
  - 与 BGTask / 手动触发并发安全:`uploadBatch` 入口新增防重入闸(inFlight,NSLock),
    已在跑就跳过(队列留给下次)。

### M2:批量上报静默丢数据(两处)

- **M2a 超批丢弃**:客户端 `drain()` 全量(最多 500 条)一发,服务端每批只收前 100 条
  (`worker.js` `MAX_TELEMETRY_EVENTS_PER_BATCH`,超出部分 200 后静默丢)。
  修法:`uploadBatch` 改循环分批 —— 每轮 `drain` 后只取前 100 条,**剩余先 `restore`
  回持久层再发送**:任何时刻内存里只暴露「本批」,进程中途被杀最多丢本批
  (与旧单批实现同窗口,不扩大暴露面)。
- **M2b 429 丢整批**:配额耗尽时旧实现直接丢批(`return true` 不 restore)。
  修法:429 整批放回队列(7 天 GC 兜底),返回 true 不让 BGTask 反复失败;当天后续
  触发会再撞一次 429(至多每小时一次,可忽略),明天配额重置后自然发出。
- **顺带补精确协议**:服务端 200 响应体带 `{accepted, dropped}`(配额可批中途耗尽,
  `validEvents.slice(0, quotaResult.acceptable)`;`dropped` 也包含被服务端判无效的
  事件条目,两种成因处理相同)。客户端现在解析它:`dropped > 0` 时
  记日志停发、**不 restore**——被丢部分服务端已定位丢弃、无法从响应还原是哪几条,
  restore 整批会把已接受的事件重发入库成重复。这是本修复明知保留的丢弃路径
  (边界:仅配额耗尽当天的最后一批尾巴,量级 ≤100 条)。

## 2. 改动文件

| 文件 | 改动 |
|---|---|
| `App/TelemetryUploader.swift` | `uploadBatch` 重写为分批循环 + `send(_:endpoint:)` 单批函数 + `{accepted,dropped}` 解析;新增 inFlight 防重入闸、`uploadFromAppBackground()`(UIKit 条件编译);`import UIKit` 条件导入 |
| `App/VoiceTodoApp.swift` | `.background` 分支补 `uploadFromAppBackground()` 调用(4 行 + 注释) |
| `VoiceTodoTests/App/TelemetryUploaderTests.swift` | 新增文件内 `URLProtocol` stub(FIFO 响应 + 可选信号量门控 + 请求记录)与 5 条用例 |

## 3. 测试

- 聚焦:`TelemetryUploaderTests` **14/14**(原 9 + 新 5):
  ①250 条拆 100/100/50 三批、批序与队列清空;②429 整批放回(剩 50)且停发;
  ③200+dropped>0 不 restore 防重复;④中途 500 失败批与未发批全部回队列;
  ⑤防重入闸:第一批在途(门控 stub 挂起)时并发调用被跳过,总请求数恰为 3 批。
- 全量:`xcodebuild test -only-testing:VoiceTodoTests`(iPhone 17 Pro / iOS 26.5):
  **526 执行 / 0 失败 / 2 跳过**(上轮基线 521 + 本轮新增 5;跳过 = VoiceInputTests
  两条权限弹窗用例,自带 skip)。
- 既有禁用语义不变:关闭时零请求、零 drain/restore(原用例仍绿)。

## 4. 已知边界 / 取舍(记档)

1. 配额批中途耗尽的服务端丢弃尾巴(≤100 条/天,仅打满 500/天配额的重度设备)——
   不 restore 是防重复入库的取舍,见 §1 M2「顺带补精确协议」;
2. 批内(drain 后、restore 前)进程被杀丢本批 —— 与旧实现同窗口,未扩大;
3. `uploadFromAppBackground` 的 expiration 竞态窗口(handler 赋值前触发)后果仅为
   任务标记未 end,进程随后照常挂起,无泄漏面(代码注释记明);
4. 真机走查项:进后台 30s 内完成补报的实际表现(BGTask 与 beginBackgroundTask 双路径
   并存不互相干扰);
5. `TelemetryQueue.restore` 为追加语义(既有行为,非本轮引入):多批失败回滚后,
   失败批(较老)排在未发批(较新)之后,下轮发送顺序局部颠倒;队列打满 500 时
   `trim` 的 `removeFirst` 会先驱逐较新事件。事件自带 timestamp、服务端另记
   received_at,分析口径不受影响;修它要动 `Protocols/TelemetryQueue.swift`
   (本轮 diff 之外),记档不修。

## 5. 双 review 循环(2026-11-26)

**5 轮收敛,状态 DONE**(第 5 轮双 skill 均 0 发现;上限 10 轮),累计发现 13 /
修复 12 / 记档不修 1,无 skill 冲突(途中两次网关 503 中断后恢复)。修复要点:

1. **[P2 最有价值] 防重入闸并发测试的主断言空洞**:原「总请求数 == 3」在闸失效的
   反事实下照样通过(第二次调用会把剩余 150 条消耗完,总数恰为 3)。改为在放行
   门控之前取中途快照 —— 闸生效 = 请求 1 / 队列 150,闸失效 = 请求 3 / 队列 0,
   两个世界互斥,测试才真正具备闸回归检测力;
2. `{accepted,dropped}` 解码失败由静默回退改为 warning 日志 + 负值钳制;
   success 日志补回 durationMS;`uploadFromAppBackground` 禁用预检(不白拿
   系统后台断言);新增防重入闸确定性测试(上述第 5 条);
3. 成因口径统一:worker.js 的 `dropped` 含「配额中途耗尽 + 事件被判无效」双成因,
   六处(枚举注释/类头/内联注释/日志字段 droppedByServer/测试注释/本文档 §1)对齐;
4. 注释规范:决策注释补 2026-11-26 日期标记;类头指向不存在的 uploadNow() 改为
   真实方法;删除任何执行路径都不会消费的第 4 个 stub 响应及不实注释。

**记档不修(留待后续任务)**:`TelemetryQueue.restore` 的追加语义 —— 多批回滚后
失败批(较老)排在未发批(较新)之后、队列打满 500 时 `trim` 会先驱逐较新事件;
修需动 `Protocols/TelemetryQueue.swift`(本 diff 范围外)。非阻塞观察:Swift 6
严格并发下 `uploadFromAppBackground` 需补 `@MainActor`(全仓迁移事项)。
