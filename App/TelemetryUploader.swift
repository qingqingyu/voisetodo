import Foundation
#if canImport(BackgroundTasks)
import BackgroundTasks
#endif

/// 遥测批量上报。负责把 `TelemetryQueue` 中的事件 POST 到 AIProxy `/v1/telemetry/events`。
///
/// 生产模式靠 `BGProcessingTask` 在「充电 + 网络」时触发；调用方可通过 `uploadNow()` 在测试或
/// 显式同步时手动触发。
final class TelemetryUploader {
    static let shared = TelemetryUploader(
        endpoint: TelemetryUploader.makeDefaultEndpoint(),
        appToken: NetworkConfig.proxyAppToken,
        deviceID: NetworkConfig.proxyDeviceIdentifier,
        session: .shared
    )

    /// BGProcessingTask identifier，必须在 Info.plist 的 `BGTaskSchedulerPermittedIdentifiers` 中声明。
    static let backgroundTaskIdentifier = "com.voicetodo.app.telemetry-upload"

    /// 调度下一次 BGTask 的最早间隔（秒）。iOS 不保证准时，这只是下限。
    static let earliestScheduleInterval: TimeInterval = 60 * 60  // 1 小时

    private let endpoint: URL?
    private let appToken: String?
    private let deviceID: String
    private let session: URLSession
    private let encoder: JSONEncoder

    init(endpoint: URL?, appToken: String?, deviceID: String, session: URLSession) {
        self.endpoint = endpoint
        self.appToken = appToken
        self.deviceID = deviceID
        self.session = session
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        self.encoder = encoder
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
    func scheduleNextRun() {
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

    /// 上传一批事件。成功则丢弃队列内容；失败则回滚。
    /// - Returns: 是否成功（用于 BGTask 完成 + 测试断言）
    @discardableResult
    func uploadBatch() async -> Bool {
        let events = TelemetryQueue.drain()
        guard !events.isEmpty else {
            VoiceTodoLog.app.debug("telemetry.upload.empty_queue")
            return true
        }

        guard let endpoint else {
            VoiceTodoLog.app.warning("telemetry.upload.no_endpoint events=\(events.count)")
            TelemetryQueue.restore(events)
            return false
        }

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
                TelemetryQueue.restore(events)
                return false
            }

            if http.statusCode == 429 {
                // 配额耗尽：丢弃这批（避免下次又触发 429），不再 restore
                VoiceTodoLog.app.warning("telemetry.upload.quota_exceeded dropped=\(events.count)")
                return true  // 视为成功，否则 BGTask 会反复失败
            }

            guard (200...299).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? ""
                VoiceTodoLog.app.error("telemetry.upload.http_failed status=\(http.statusCode) bodyChars=\(body.count) events=\(events.count) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
                TelemetryQueue.restore(events)
                return false
            }

            VoiceTodoLog.app.info("telemetry.upload.success events=\(events.count) status=\(http.statusCode) durationMS=\(VoiceTodoLog.durationMS(since: startedAt))")
            return true
        } catch {
            VoiceTodoLog.app.error("telemetry.upload.transport_failed events=\(events.count) error=\(VoiceTodoLog.errorSummary(error), privacy: .public)")
            TelemetryQueue.restore(events)
            return false
        }
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
