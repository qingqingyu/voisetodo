import XCTest
@testable import VoiceTodo

final class TelemetryUploaderTests: XCTestCase {
    func testTelemetryEndpointReplacesTodoExtractionPath() throws {
        let endpoint = try XCTUnwrap(TelemetryUploader.telemetryEndpoint(
            fromProxyEndpoint: "https://proxy.example.com/v1/todo-extractions"
        ))

        XCTAssertEqual(endpoint.absoluteString, "https://proxy.example.com/v1/telemetry/events")
    }

    func testTelemetryEndpointHandlesTrailingSlashOnTodoExtractions() throws {
        let endpoint = try XCTUnwrap(TelemetryUploader.telemetryEndpoint(
            fromProxyEndpoint: "https://proxy.example.com/v1/todo-extractions/"
        ))

        XCTAssertEqual(endpoint.absoluteString, "https://proxy.example.com/v1/telemetry/events")
    }

    func testTelemetryEndpointAppendsPathForProxyRoot() throws {
        let endpoint = try XCTUnwrap(TelemetryUploader.telemetryEndpoint(
            fromProxyEndpoint: "https://proxy.example.com"
        ))

        XCTAssertEqual(endpoint.absoluteString, "https://proxy.example.com/v1/telemetry/events")
    }

    func testTelemetryEndpointAppendsPathForProxyRootWithTrailingSlash() throws {
        let endpoint = try XCTUnwrap(TelemetryUploader.telemetryEndpoint(
            fromProxyEndpoint: "https://proxy.example.com/"
        ))

        XCTAssertEqual(endpoint.absoluteString, "https://proxy.example.com/v1/telemetry/events")
    }

    func testTelemetryEndpointHandlesCustomPathPrefix() throws {
        // 部署在子路径下的场景：proxy 配成 `/internal/v1/todo-extractions`
        let endpoint = try XCTUnwrap(TelemetryUploader.telemetryEndpoint(
            fromProxyEndpoint: "https://proxy.example.com/internal/v1/todo-extractions"
        ))

        XCTAssertEqual(endpoint.absoluteString, "https://proxy.example.com/internal/v1/telemetry/events")
    }

    func testTelemetryEndpointReturnsNilForEmptyProxyEndpoint() {
        XCTAssertNil(TelemetryUploader.telemetryEndpoint(fromProxyEndpoint: "  "))
    }

    func testTelemetryEndpointReturnsNilForInvalidURL() {
        XCTAssertNil(TelemetryUploader.telemetryEndpoint(fromProxyEndpoint: "not a url"))
    }

    // MARK: - 遥测关闭短路

    /// 关闭时 uploadBatch 必须在 drain 之前短路:返回成功、不发任何网络请求、
    /// 队列原样保留。这是隐私政策「turn off at any time」的执行点——
    /// 若先 drain 再失败回滚,一次网络故障就会把回滚语义和禁用语义混在一起。
    func testUploadBatchDisabledSkipsNetworkAndKeepsQueue() async throws {
        // 测试跑在 app host 进程内,直接构造同一 App Group suite 即与生产
        // TelemetryQueue.sharedDefaults() 指向同一存储。
        let shared = try XCTUnwrap(UserDefaults(suiteName: WidgetConfig.appGroupIdentifier))
        let payload = TelemetryPayload(
            name: "test_event",
            timestamp: Date(),
            sessionID: "s",
            deviceID: "d",
            appVersion: "0",
            iosVersion: "0",
            params: [:]
        )
        TelemetryQueue.clear(defaults: shared)
        TelemetryQueue.enqueue(payload, defaults: shared)

        // 端点不可达(127.0.0.1:1 立即拒连):若禁用短路失效,这次上传必然
        // transport 失败 → restore → 返回 false,测试即红。
        let uploader = TelemetryUploader(
            endpoint: URL(string: "https://127.0.0.1:1/v1/telemetry/events"),
            appToken: "test-token",
            deviceID: "test-device",
            session: .shared,
            isTelemetryEnabled: { false }
        )

        let success = await uploader.uploadBatch()

        XCTAssertTrue(success, "禁用时应直接成功,不发起上传")
        XCTAssertEqual(
            TelemetryQueue.count(defaults: shared),
            1,
            "禁用时队列必须原样保留(不 drain、不 restore)"
        )

        TelemetryQueue.clear(defaults: shared)
    }

    /// 调度入口在禁用时必须无副作用返回(不向 BGTaskScheduler 提交请求)。
    /// 测试环境里未注册的 task identifier 提交会抛错;禁用路径不触达提交,
    /// 因此「不抛、不崩」即为通过信号。
    func testScheduleNextRunDisabledIsNoOp() {
        let uploader = TelemetryUploader(
            endpoint: nil,
            appToken: nil,
            deviceID: "",
            session: .shared,
            isTelemetryEnabled: { false }
        )

        uploader.scheduleNextRun()
    }
}
