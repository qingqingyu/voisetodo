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
}
