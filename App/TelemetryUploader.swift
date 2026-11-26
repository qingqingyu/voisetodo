import Foundation
#if canImport(BackgroundTasks)
import BackgroundTasks
#endif
#if canImport(UIKit)
import UIKit
#endif

/// 遥测批量上报。负责把 `TelemetryQueue` 中的事件 POST 到 AIProxy `/v1/telemetry/events`。
///
/// 生产模式靠 `BGProcessingTask` 在「充电 + 网络」时触发,App 进后台时经
/// `uploadFromAppBackground()` 用系统后台额度补一次;测试或显式同步直接调
/// `uploadBatch()`。
final class TelemetryUploader {
    static let shared = TelemetryUploader(
        endpoint: TelemetryUploader.makeDefaultEndpoint(),
        appToken: NetworkConfig.proxyAppToken,
        deviceID: NetworkConfig.proxyDeviceIdentifier,
        session: .shared
    )

    /// BGProcessingTask identifier，必须在 Info.plist 的 `BGTaskSchedulerPermittedIdentifiers` 中声明。
    /// 2026-11-14 修正:旧值 `com.voicetodo.app.telemetry-upload` 与 project.yml 声明的
    /// `com.qingqingyu.voicetodo.telemetry-upload` 不一致,BGTaskScheduler 每次调度报
    /// error 3(Unrecognized Identifier),后台上报从未成功——真机日志实锤。
    /// 一致性由 TelemetryUploaderGuardTests 守卫(改任一侧必须同步另一侧)。
    static let backgroundTaskIdentifier = "com.qingqingyu.voicetodo.telemetry-upload"

    /// 调度下一次 BGTask 的最早间隔（秒）。iOS 不保证准时，这只是下限。
    static let earliestScheduleInterval: TimeInterval = 60 * 60  // 1 小时

    private let endpoint: URL?
    private let appToken: String?
    private let deviceID: String
    private let session: URLSession
    private let encoder: JSONEncoder
    /// 遥测开关（设置页「匿名诊断上报」）。默认读 App Group 共享值;测试注入用。
    private let isTelemetryEnabled: () -> Bool

    init(
        endpoint: URL?,
        appToken: String?,
        deviceID: String,
        session: URLSession,
        isTelemetryEnabled: @escaping () -> Bool = { TelemetrySettings.isEnabled() }
    ) {
        self.endpoint = endpoint
        self.appToken = appToken
        self.deviceID = deviceID
        self.session = session
        self.encoder = JSONCoding.makeRequestEncoder()
        self.isTelemetryEnabled = isTelemetryEnabled
    }

    // MARK: - Background task lifecycle

    /// App 启动时调用一次，注册 BGProcessingTask handler。
    func registerBackgroundTask() {
        #if canImport(BackgroundTasks)
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.backgroundTaskIdentifier,
            using: nil
        ) { [weak self] task in
            guard let self,
                  let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self.handleBackgroundTask(processingTask)
        }
        VoiceTodoLog.app.info("telemetry.upload.registered")
        #else
        VoiceTodoLog.app.debug("telemetry.upload.register_skipped reason=no_background_tasks_module")
        #endif
    }

    /// 调度下一次 BGTask。App 进入后台 / 上报完成后调用。
    /// 遥测关闭时不调度(TELEMETRY.md「关闭遥测」);重新开启后下次进后台即恢复调度。
    func scheduleNextRun() {
        guard isTelemetryEnabled() else {
            VoiceTodoLog.app.info("telemetry.upload.schedule_skipped reason=disabled")
            return
        }
        #if canImport(BackgroundTasks)
        let request = BGProcessingTaskRequest(identifier: Self.backgroundTaskIdentifier)
        request.requiresExternalPower = true           // 仅充电
        request.requiresNetworkConnectivity = true      // 需要联网
        request.earliestBeginDate = Date(timeIntervalSinceNow: Self.earliestScheduleInterval)
        do {
            try BGTaskScheduler.shared.submit(request)
            VoiceTodoLog.app.info("telemetry.upload.scheduled earliestIntervalSeconds=\(Self.earliestScheduleInterval)")
        } catch {
            VoiceTodoLog.app.warning("telemetry.upload.schedule_failed error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
        }
        #else
        VoiceTodoLog.app.debug("telemetry.upload.schedule_skipped reason=no_background_tasks_module")
        #endif
    }

    /// 系统触发 BGTask 时的入口。
    func handleBackgroundTask(_ task: BGProcessingTask) {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                task.setTaskCompleted(success: false)
                return
            }
            // 用 semaphore 把 async uploadBatch 包装成同步（DispatchWorkItem 是同步）。
            // BGProcessingTask 通常在 background queue 上调用，阻塞是允许的。
            let semaphore = DispatchSemaphore(value: 0)
            var success = false
            Task {
                success = await self.uploadBatch()
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .distantFuture)
            task.setTaskCompleted(success: success)
            self.scheduleNextRun()
        }

        // 系统给的任务超时窗口到了会调 expirationHandler
        task.expirationHandler = {
            workItem.cancel()
            VoiceTodoLog.app.warning("telemetry.upload.expired reason=bg_task_timeout")
            task.setTaskCompleted(success: false)
        }

        DispatchQueue.global(qos: .background).async(execute: workItem)
    }

    // MARK: - Upload

    /// 单批发送的结果。
    private enum SendOutcome {
        /// 200。accepted / dropped 来自服务端 JSON。dropped > 0 时停发(见 `uploadBatch`)。
        /// 注意 worker.js 的 dropped = 发送条数 - 入库条数,成因有两种:配额批中途耗尽,
        /// 或事件被 `isValidTelemetryEvent` 判无效。两种成因「停发 + 不 restore」都正确
        /// ——无效事件重发永远无效,留在队列里只会堵住后面的批。
        case sent(accepted: Int, dropped: Int)
        /// 429:整批被拒、未入库 —— 放回队列,明天配额重置后自然重试。
        case quotaExceeded
        /// 其他失败(网络 / 非 2xx / 坏响应):放回队列。
        case failed
    }

    /// 防重入闸:`uploadBatch` 可能被 BGProcessingTask、App 进后台补报(M1)、
    /// 手动触发并发调用。drain/restore 是原子配对,但两个并发批次会把同一队列
    /// 拆成交错的两半,日志与批数都不可读。串行化:已在跑就跳过(队列留给下次)。
    private let inFlightLock = NSLock()
    private var inFlight = false

    private func tryBeginUpload() -> Bool {
        inFlightLock.lock()
        defer { inFlightLock.unlock() }
        if inFlight { return false }
        inFlight = true
        return true
    }

    private func endUpload() {
        inFlightLock.lock()
        inFlight = false
        inFlightLock.unlock()
    }

    /// 上传队列中的全部事件,按 `TelemetryQueue.maxBatchSize` 分批发送。
    ///
    /// 2026-11-26 M2(行为漏斗规格事实核查 §6 步 0,审计轮 M2):
    /// - **分批**:服务端每批只收前 100 条(`worker.js` `MAX_TELEMETRY_EVENTS_PER_BATCH`
    ///   之外的条目 200 后静默丢)。旧实现 drain 全量(最多 500)一发,401..500 条必丢。
    ///   现在每轮只取一批,**剩余先 restore 回持久层再发送** —— 任何时刻内存里只暴露
    ///   「本批」,进程中途被杀最多丢本批(与旧单批实现同窗口);
    /// - **429 不丢批**:配额耗尽整批放回(7 天 GC 兜底),返回 true 不让 BGTask 反复
    ///   失败;当天后续触发会再撞一次 429(至多每小时一次,可忽略);
    /// - **200 且 dropped > 0**(成因见 `SendOutcome.sent`:配额批中途耗尽,或事件被
    ///   服务端判无效):被 drop 的部分服务端已丢且无法从响应定位是哪几条,不 restore
    ///   (防已接受事件重发入库成重复),记日志停发。
    ///
    /// 遥测关闭时直接返回成功:队列原样保留(不 drain、不 restore、零请求)——
    /// 这是隐私政策「turn off at any time」承诺的执行点。
    /// - Returns: 是否成功(用于 BGTask 完成 + 测试断言)
    @discardableResult
    func uploadBatch() async -> Bool {
        guard isTelemetryEnabled() else {
            VoiceTodoLog.app.info("telemetry.upload.disabled queuedEvents=\(TelemetryQueue.count())")
            return true
        }
        guard tryBeginUpload() else {
            VoiceTodoLog.app.info("telemetry.upload.skipped reason=in_flight queuedEvents=\(TelemetryQueue.count())")
            return true
        }
        defer { endUpload() }

        guard let endpoint else {
            VoiceTodoLog.app.warning("telemetry.upload.no_endpoint events=\(TelemetryQueue.count())")
            return false
        }

        var totalAccepted = 0
        var totalDropped = 0
        let startedAt = Date()  // 2026-11-26 R1:补回总耗时(旧单批日志有 durationMS,改循环时丢了)
        batchLoop: while true {
            let all = TelemetryQueue.drain()
            guard !all.isEmpty else { break }
            let chunk = Array(all.prefix(TelemetryQueue.maxBatchSize))
            let remainder = Array(all.dropFirst(TelemetryQueue.maxBatchSize))
            if !remainder.isEmpty {
                // 发本批之前,先把不发的落回持久层(见函数头注释「分批」条)
                TelemetryQueue.restore(remainder)
            }
            switch await send(chunk, endpoint: endpoint) {
            case let .sent(accepted, dropped):
                totalAccepted += accepted
                totalDropped += dropped
                if dropped > 0 {
                    // 服务端丢弃了批内部分事件(成因见 SendOutcome.sent 注释):再发只会
                    // 全 drop 或永远无效,停(不 restore,防已接受事件重发入库成重复)
                    VoiceTodoLog.app.warning("telemetry.upload.quota_partial accepted=\(accepted) dropped=\(dropped) acceptedSoFar=\(totalAccepted)")
                    break batchLoop
                }
                continue batchLoop
            case .quotaExceeded:
                TelemetryQueue.restore(chunk)
                VoiceTodoLog.app.warning("telemetry.upload.quota_exceeded restored=\(chunk.count) acceptedSoFar=\(totalAccepted)")
                return true  // 视为成功,否则 BGTask 会反复失败
            case .failed:
                TelemetryQueue.restore(chunk)
                return false
            }
        }
        // 2026-11-26 R2:droppedByServer 而非 droppedByQuota —— dropped 的成因除配额
        // 中途耗尽外还包括事件被服务端判无效(见 SendOutcome.sent 注释),按成因命名
        // 会误导排障方向。
        VoiceTodoLog.app.info("telemetry.upload.success accepted=\(totalAccepted) droppedByServer=\(totalDropped) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
        return true
    }

    /// 发送单批并归类结果。请求构造、鉴权头与超时沿用旧 `uploadBatch` 的实现。
    private func send(_ events: [TelemetryPayload], endpoint: URL) async -> SendOutcome {
        let payload = TelemetryUploadPayload(events: events)
        do {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let appToken, !appToken.isEmpty {
                request.setValue(appToken, forHTTPHeaderField: "X-App-Token")
            }
            if !deviceID.isEmpty {
                request.setValue(deviceID, forHTTPHeaderField: "X-Device-ID")
            }
            request.httpBody = try encoder.encode(payload)
            request.timeoutInterval = 30

            let startedAt = Date()
            let (data, response) = try await session.data(for: request)

            guard let http = response as? HTTPURLResponse else {
                VoiceTodoLog.app.error("telemetry.upload.invalid_response events=\(events.count)")
                return .failed
            }

            if http.statusCode == 429 {
                return .quotaExceeded
            }

            guard (200...299).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? ""
                VoiceTodoLog.app.error("telemetry.upload.http_failed status=\(http.statusCode) bodyChars=\(body.count) events=\(events.count) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
                return .failed
            }

            // 服务端 200 响应带 {accepted, dropped}(worker.js telemetry.events.accepted);
            // 坏体按「全收」处理,保持与旧实现同级的乐观语义(200 即视为送达)。
            // max(0,…) 钳制:真实 worker 恒返回非负,这里是防异常响应把负数
            // 灌进 totalAccepted/totalDropped 的日志统计。
            if let body = try? JSONDecoder().decode(TelemetryAcceptanceResponse.self, from: data) {
                return .sent(accepted: max(0, body.accepted), dropped: max(0, body.dropped))
            }
            // 2026-11-26 R1:解码失败不静默(错误显式传播原则),记日志留痕后再走回退。
            VoiceTodoLog.app.warning("telemetry.upload.acceptance_unparsed bodyBytes=\(data.count) events=\(events.count)")
            return .sent(accepted: events.count, dropped: 0)
        } catch {
            VoiceTodoLog.app.error("telemetry.upload.transport_failed events=\(events.count) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            return .failed
        }
    }

    // MARK: - App 后台一次性补报(M1)

    /// App 进后台时立刻补一次上报(2026-11-26 M1,行为漏斗规格事实核查 §6 步 0)。
    ///
    /// 背景:`BGProcessingTask` 只在「充电 + 联网」时触发,首日装完就走、当场删 App 的
    /// 用户本地队列随 App 删除而消失,永远进不了 D1 —— cohort 系统性偏活跃人群
    /// (R1 偏高、R3「未激活」组失真)。进后台用 `beginBackgroundTask` 拿 ~30s 系统
    /// 额度补一发;分批与回滚语义同 `uploadBatch`(未发送事件始终留在持久层)。
    ///
    /// - 过期处理器只结束后台任务标记,不 cancel 在途请求:批内事件已 drain,
    ///   cancel 与否进程挂起都只丢本批;强 cancel 反而把本可完成的一批变失败。
    /// - 与 BGTask / 手动触发并发安全:`uploadBatch` 入口的防重入闸兜底。
    func uploadFromAppBackground() {
        // 2026-11-26 R1:禁用时提前短路,不白拿系统后台任务额度、不起空转 Task
        // (隐私兜底仍在 uploadBatch 入口,这里只是省资源;双重检查容忍开关竞态)。
        guard isTelemetryEnabled() else {
            VoiceTodoLog.app.debug("telemetry.upload.app_background_skipped reason=disabled")
            return
        }
        #if canImport(UIKit)
        // expiration handler 在 begin 时就要给,而 end-once 令牌创建在其后 —— 用 box
        // 衔接。竞态窗口内(赋值前触发 expiration)handler 为 nil:后果是任务标记未
        // end,进程随后照常挂起,无泄漏面。
        final class ExpirationBox: @unchecked Sendable {
            private let lock = NSLock()
            private var handler: (() -> Void)?
            func set(_ handler: (() -> Void)?) {
                lock.lock(); defer { lock.unlock() }
                self.handler = handler
            }
            func fire() {
                lock.lock(); defer { lock.unlock() }
                handler?()
            }
        }
        final class TaskToken: @unchecked Sendable {
            private let lock = NSLock()
            private var id: UIBackgroundTaskIdentifier
            private var ended = false
            init(_ id: UIBackgroundTaskIdentifier) { self.id = id }
            /// end-once:过期处理器与完成路径都调,不双 end。
            func end() {
                lock.lock(); defer { lock.unlock() }
                guard !ended else { return }
                ended = true
                UIApplication.shared.endBackgroundTask(id)
                id = .invalid
            }
        }

        let box = ExpirationBox()
        let taskID = UIApplication.shared.beginBackgroundTask(withName: "telemetry.upload.app_background") {
            box.fire()
        }
        guard taskID != .invalid else {
            VoiceTodoLog.app.warning("telemetry.upload.background_task_denied")
            return
        }
        let token = TaskToken(taskID)
        box.set { [weak token] in token?.end() }
        Task { [weak self] in
            defer { token.end() }
            await self?.uploadBatch()
        }
        #else
        // 非 UIKit 环境(本文件当前只编入主 App 目标,此分支为防御性兜底):
        // 无后台任务 API 可用,入口为 no-op
        VoiceTodoLog.app.debug("telemetry.upload.app_background_skipped reason=no_uikit")
        #endif
    }

    // MARK: - Default endpoint

    /// 从 `NetworkConfig.proxyEndpoint` 推导 telemetry endpoint。
    /// 若 proxyEndpoint 未配置则返回 nil（开发环境常见，可跳过上报）。
    static func makeDefaultEndpoint() -> URL? {
        telemetryEndpoint(fromProxyEndpoint: NetworkConfig.proxyEndpoint)
    }

    /// 从指定 AI proxy endpoint 推导 telemetry endpoint。
    ///
    /// 支持两种配置形态：
    /// - 完整提取端点（推荐）：`https://proxy/v1/todo-extractions`（带或不带尾斜杠）
    ///   → `https://proxy/v1/telemetry/events`
    /// - 仅 origin 或任意非 `/v1/todo-extractions` 结尾的根端点：
    ///   `https://proxy` → `https://proxy/v1/telemetry/events`
    ///
    /// 注意：若配置成 `https://proxy/v1`（仅到版本前缀），会得到
    /// `https://proxy/v1/v1/telemetry/events`，应避免此类配置。
    static func telemetryEndpoint(fromProxyEndpoint proxyEndpoint: String) -> URL? {
        let trimmed = proxyEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let base = URL(string: trimmed) else { return nil }
        guard let scheme = base.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              base.host?.isEmpty == false else {
            return nil
        }
        // 规范化 path：去掉尾斜杠后再做后缀匹配与路径操作，
        // 避免 `https://proxy/v1/todo-extractions/` 被误判并拼出错误路径。
        let normalizedBase = normalizedPathURL(base)
        if normalizedBase.path.hasSuffix("/v1/todo-extractions") {
            return normalizedBase
                .deletingLastPathComponent()
                .appendingPathComponent("telemetry/events")
        }
        return normalizedBase
            .appendingPathComponent("v1")
            .appendingPathComponent("telemetry/events")
    }

    /// 返回去掉 path 尾斜杠的 URL（根路径 `/` 保留）。
    private static func normalizedPathURL(_ url: URL) -> URL {
        guard url.path.count > 1, url.path.hasSuffix("/") else { return url }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = components?.path ?? ""
        components?.path = String(path.dropLast())
        return components?.url ?? url
    }
}

// MARK: - Upload payload

struct TelemetryUploadPayload: Codable {
    let events: [TelemetryPayload]
}

/// 服务端 200 响应体 `{accepted, dropped}`(见 worker.js telemetry ingest):
/// accepted = 实际入库条数,dropped = 被服务端丢弃的条数(配额中途耗尽或事件判无效,双成因)。
private struct TelemetryAcceptanceResponse: Decodable {
    let accepted: Int
    let dropped: Int
}
