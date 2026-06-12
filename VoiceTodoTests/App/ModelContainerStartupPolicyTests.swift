import XCTest
@testable import VoiceTodo

final class ModelContainerStartupPolicyTests: XCTestCase {
    func testProductionSharedContainerFailureDoesNotAllowLocalFallback() {
        XCTAssertFalse(ModelContainerStartupPolicy.allowsLocalFallback(
            isUITesting: false,
            attemptedSharedContainer: true,
            sharedContainerAvailable: true,
            isDebugBuild: true
        ))
    }

    func testUITestSharedContainerFailureAllowsFallback() {
        XCTAssertTrue(ModelContainerStartupPolicy.allowsLocalFallback(
            isUITesting: true,
            attemptedSharedContainer: true,
            sharedContainerAvailable: true,
            isDebugBuild: false
        ))
    }

    func testDebugDevelopmentWithoutSharedContainerAllowsLocalFallback() {
        XCTAssertTrue(ModelContainerStartupPolicy.allowsLocalFallback(
            isUITesting: false,
            attemptedSharedContainer: false,
            sharedContainerAvailable: false,
            isDebugBuild: true
        ))
    }

    func testReleaseWithoutSharedContainerBlocksStartup() {
        XCTAssertTrue(ModelContainerStartupPolicy.shouldBlockForMissingSharedContainer(
            isUITesting: false,
            sharedContainerAvailable: false,
            isDebugBuild: false
        ))
    }

    func testDebugWithoutSharedContainerDoesNotBlockStartup() {
        XCTAssertFalse(ModelContainerStartupPolicy.shouldBlockForMissingSharedContainer(
            isUITesting: false,
            sharedContainerAvailable: false,
            isDebugBuild: true
        ))
    }
}
