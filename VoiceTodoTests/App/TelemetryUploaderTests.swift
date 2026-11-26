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

    // MARK: - 分批 / 429 / 配额部分接受(M2,2026-11-26)

    private func makeStubSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TelemetryStubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makePayload(_ i: Int) -> TelemetryPayload {
        TelemetryPayload(
            name: "test_event_\(i)",
            timestamp: Date(),
            sessionID: "s",
            deviceID: "d",
            appVersion: "0",
            iosVersion: "0",
            params: [:]
        )
    }

    private func enqueue(_ n: Int, to defaults: UserDefaults) {
        for i in 0..<n {
            TelemetryQueue.enqueue(makePayload(i), defaults: defaults)
        }
    }

    private func ok(_ accepted: Int, _ dropped: Int) -> TelemetryStubURLProtocol.StubResponse {
        .init(status: 200, body: #"{"accepted":\#(accepted),"dropped":\#(dropped)}"#)
    }

    /// 250 条按 100/100/50 分三批发;发本批前剩余已落回持久层,全部成功后队列清空。
    func testUploadBatchSplitsQueueIntoBatchesOf100() async throws {
        let shared = try XCTUnwrap(UserDefaults(suiteName: WidgetConfig.appGroupIdentifier))
        TelemetryQueue.clear(defaults: shared)
        TelemetryStubURLProtocol.reset()
        TelemetryStubURLProtocol.responses = [ok(100, 0), ok(100, 0), ok(50, 0)]
        enqueue(250, to: shared)

        let uploader = TelemetryUploader(
            endpoint: URL(string: "https://stub.test/v1/telemetry/events"),
            appToken: "test-token",
            deviceID: "test-device",
            session: makeStubSession(),
            isTelemetryEnabled: { true }
        )
        let success = await uploader.uploadBatch()

        XCTAssertTrue(success)
        XCTAssertEqual(TelemetryStubURLProtocol.receivedRequests.count, 3, "250 条应拆 100+100+50 三批(服务端每批只收 100)")
        XCTAssertEqual(TelemetryStubURLProtocol.receivedRequests.map { eventCount(in: $0) }, [100, 100, 50])
        XCTAssertEqual(TelemetryQueue.count(defaults: shared), 0, "全部发出后队列清空")
        TelemetryQueue.clear(defaults: shared)
    }

    /// 429 整批被拒:该批放回队列(不丢),返回 true,后续批不再发。
    func testUploadBatch429RestoresChunkAndStops() async throws {
        let shared = try XCTUnwrap(UserDefaults(suiteName: WidgetConfig.appGroupIdentifier))
        TelemetryQueue.clear(defaults: shared)
        TelemetryStubURLProtocol.reset()
        TelemetryStubURLProtocol.responses = [ok(100, 0), .init(status: 429, body: "{}")]
        enqueue(150, to: shared)

        let uploader = TelemetryUploader(
            endpoint: URL(string: "https://stub.test/v1/telemetry/events"),
            appToken: "test-token",
            deviceID: "test-device",
            session: makeStubSession(),
            isTelemetryEnabled: { true }
        )
        let success = await uploader.uploadBatch()

        XCTAssertTrue(success, "429 视为成功,否则 BGTask 会反复失败")
        XCTAssertEqual(TelemetryStubURLProtocol.receivedRequests.count, 2, "429 后停发")
        XCTAssertEqual(TelemetryQueue.count(defaults: shared), 50, "被 429 拒的 50 条放回队列,等明天配额重置")
        TelemetryQueue.clear(defaults: shared)
    }

    /// 200 且 dropped > 0(配额批中途耗尽,或事件被服务端判无效——两种成因 worker.js
    /// 都计入 dropped):被丢部分不 restore,防已接受事件重发成重复。
    func testUploadBatchQuotaPartialDropsTailWithoutRestore() async throws {
        let shared = try XCTUnwrap(UserDefaults(suiteName: WidgetConfig.appGroupIdentifier))
        TelemetryQueue.clear(defaults: shared)
        TelemetryStubURLProtocol.reset()
        TelemetryStubURLProtocol.responses = [ok(30, 70)]
        enqueue(100, to: shared)

        let uploader = TelemetryUploader(
            endpoint: URL(string: "https://stub.test/v1/telemetry/events"),
            appToken: "test-token",
            deviceID: "test-device",
            session: makeStubSession(),
            isTelemetryEnabled: { true }
        )
        let success = await uploader.uploadBatch()

        XCTAssertTrue(success)
        XCTAssertEqual(TelemetryStubURLProtocol.receivedRequests.count, 1, "配额中途耗尽后停发")
        XCTAssertEqual(TelemetryQueue.count(defaults: shared), 0, "服务端已定位丢弃的尾巴无法精确还原,不 restore 防重复入库")
        TelemetryQueue.clear(defaults: shared)
    }

    /// 中途批失败:失败批与后续未发批全部回队列,返回 false。
    func testUploadBatchMidFailureRestoresUnsent() async throws {
        let shared = try XCTUnwrap(UserDefaults(suiteName: WidgetConfig.appGroupIdentifier))
        TelemetryQueue.clear(defaults: shared)
        TelemetryStubURLProtocol.reset()
        TelemetryStubURLProtocol.responses = [ok(100, 0), .init(status: 500, body: "boom")]
        enqueue(250, to: shared)

        let uploader = TelemetryUploader(
            endpoint: URL(string: "https://stub.test/v1/telemetry/events"),
            appToken: "test-token",
            deviceID: "test-device",
            session: makeStubSession(),
            isTelemetryEnabled: { true }
        )
        let success = await uploader.uploadBatch()

        XCTAssertFalse(success)
        XCTAssertEqual(TelemetryStubURLProtocol.receivedRequests.count, 2)
        XCTAssertEqual(TelemetryQueue.count(defaults: shared), 150, "失败批(100)+ 未发批(50)都回队列")
        TelemetryQueue.clear(defaults: shared)
    }

    /// 防重入闸:第一批在途时,并发调用的 uploadBatch 应立即跳过 —— 不发请求、
    /// 不动队列。(2026-11-26 R2)区分「闸生效 / 闸失效」的观测点在第二次调用返回、
    /// 放行第一批**之前**:闸生效时第一发仍被门控挂起在请求 1 上(请求数 1、队列剩
    /// 150);闸失效时第二次调用会把 150 条消耗完(请求数 3、队列 0),且事后总请求
    /// 数仍恰好是 3 —— 所以只在收尾断言总数抓不住闸失效,必须用中途快照。
    func testUploadBatchConcurrentCallSkipsWhenInFlight() async throws {
        let shared = try XCTUnwrap(UserDefaults(suiteName: WidgetConfig.appGroupIdentifier))
        TelemetryQueue.clear(defaults: shared)
        TelemetryStubURLProtocol.reset()
        // 第一批的响应被 gate 挂起,制造稳定的在途窗口;后两个响应供放行后的
        // 第 2、3 批消费。精确备 3 个:任何多出的请求会落到 stub 的缺省响应,
        // 请求数断言直接抓红,不需要额外缓冲。
        let gate = DispatchSemaphore(value: 0)
        TelemetryStubURLProtocol.responses = [
            .init(status: 200, body: #"{"accepted":100,"dropped":0}"#, gate: gate),
            ok(100, 0), ok(50, 0),
        ]
        enqueue(250, to: shared)

        let uploader = TelemetryUploader(
            endpoint: URL(string: "https://stub.test/v1/telemetry/events"),
            appToken: "test-token",
            deviceID: "test-device",
            session: makeStubSession(),
            isTelemetryEnabled: { true }
        )

        async let firstUpload: Bool = uploader.uploadBatch()
        // 等第 1 个请求真正进入在途(stub 已记录、响应被挂起)再发起并发调用
        try await waitUntil { TelemetryStubURLProtocol.receivedRequests.count >= 1 }
        let secondResult = await uploader.uploadBatch()

        XCTAssertTrue(secondResult, "在途跳过应视为成功(队列留给在跑的那次)")
        // 中途快照:第一发被挂起、第二发被跳过 —— 除请求 1 外不得有任何新请求,
        // 剩余 150 条(第一发 restore 的)必须原封不动留在队列里。
        XCTAssertEqual(
            TelemetryStubURLProtocol.receivedRequests.count, 1,
            "并发调用被跳过:不得发出任何请求(闸失效时此处会是 3)"
        )
        XCTAssertEqual(
            TelemetryQueue.count(defaults: shared), 150,
            "剩余 150 条由在途的那次持有排程,并发调用不得动队列(闸失效时此处会是 0)"
        )

        gate.signal()  // 放行第一批,让首轮 uploadBatch 走完 3 批
        let firstResult = await firstUpload
        XCTAssertTrue(firstResult)

        XCTAssertEqual(
            TelemetryStubURLProtocol.receivedRequests.count, 3,
            "放行后首轮走完 100+100+50 三批,总请求数恰为 3"
        )
        XCTAssertEqual(TelemetryQueue.count(defaults: shared), 0)
        TelemetryQueue.clear(defaults: shared)
    }

    /// 轮询等待条件成立(带超时),给「请求已发出但响应被挂起」这类异步对齐用。
    private func waitUntil(
        _ condition: () -> Bool,
        timeout: TimeInterval = 5,
        _ message: String = "等待条件超时"
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(condition(), message)
    }

    /// 读出请求体里的事件条数(URLSession 会把 httpBody 转成 stream)。
    private func eventCount(in request: URLRequest) -> Int {
        func decode(_ data: Data) -> Int {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970  // 与 JSONCoding.makeRequestEncoder 同口径
            return (try? decoder.decode(TelemetryUploadPayload.self, from: data))?.events.count ?? -1
        }
        if let body = request.httpBody { return decode(body) }
        guard let stream = request.httpBodyStream else { return -1 }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return decode(data)
    }
}

/// URLProtocol stub:按 FIFO 返回预设响应并记录收到的请求。测试类内串行执行,
/// 静态队列无并发问题。文件私有,不污染其他测试。
private final class TelemetryStubURLProtocol: URLProtocol {
    struct StubResponse {
        let status: Int
        let body: String
        /// 可选信号量:响应前先等它(制造「请求在途」窗口,测防重入闸用)。
        /// (2026-11-26 R2)带超时,防测试失败时把 URLSession 工作线程挂死整个测试进程。
        let gate: DispatchSemaphore?

        init(status: Int, body: String, gate: DispatchSemaphore? = nil) {
            self.status = status
            self.body = body
            self.gate = gate
        }
    }

    static var responses: [StubResponse] = []
    static var receivedRequests: [URLRequest] = []
    /// 响应用尽时的缺省:按「全收」回(测试里通常精确给足条数,这里只是兜底)。
    private static let defaultResponse = StubResponse(status: 200, body: #"{"accepted":1,"dropped":0}"#)

    static func reset() {
        responses = []
        receivedRequests = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.receivedRequests.append(request)
        let stub = Self.responses.isEmpty ? Self.defaultResponse : Self.responses.removeFirst()
        // 先记录再等门:调用方轮询 receivedRequests 就知道请求已进入在途状态
        if let gate = stub.gate {
            _ = gate.wait(timeout: .now() + 10)
        }
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://stub.test")!,
            statusCode: stub.status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(stub.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
