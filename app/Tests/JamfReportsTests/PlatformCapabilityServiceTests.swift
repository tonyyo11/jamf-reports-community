import Foundation
import XCTest
@testable import JamfReports

/// Tests the Platform API capability probe used by v2.1.0's experimental
/// toggle. Mocks the executor so the real `jamf-cli` binary isn't required.
@MainActor
final class PlatformCapabilityServiceTests: XCTestCase {

    // MARK: - parseAuthMethod (pure)

    func testParseReturnsTrueForPlatformProfile() {
        let json = """
        [
          {"name": "lighthouse", "url": "https://gw", "auth-method": "platform", "default": true}
        ]
        """
        let result = PlatformCapabilityService.parseAuthMethod(
            data: Data(json.utf8), profile: "lighthouse"
        )
        XCTAssertTrue(result)
    }

    func testParseReturnsFalseForOAuth2Profile() {
        let json = """
        [
          {"name": "dummy", "url": "https://x", "auth-method": "oauth2", "default": true}
        ]
        """
        let result = PlatformCapabilityService.parseAuthMethod(
            data: Data(json.utf8), profile: "dummy"
        )
        XCTAssertFalse(result)
    }

    func testParseReturnsFalseWhenProfileNotFound() {
        let json = """
        [
          {"name": "other", "url": "https://x", "auth-method": "platform", "default": true}
        ]
        """
        let result = PlatformCapabilityService.parseAuthMethod(
            data: Data(json.utf8), profile: "missing"
        )
        XCTAssertFalse(result)
    }

    func testParseFallsBackToDefaultProfileWhenProfileEmpty() {
        let json = """
        [
          {"name": "one", "auth-method": "oauth2", "default": false},
          {"name": "two", "auth-method": "platform", "default": true}
        ]
        """
        let result = PlatformCapabilityService.parseAuthMethod(
            data: Data(json.utf8), profile: ""
        )
        XCTAssertTrue(result)
    }

    func testParseReturnsFalseOnMalformedJSON() {
        let result = PlatformCapabilityService.parseAuthMethod(
            data: Data("not-json".utf8), profile: "lighthouse"
        )
        XCTAssertFalse(result)
    }

    func testParseReturnsFalseWhenAuthMethodMissing() {
        let json = """
        [
          {"name": "lighthouse", "default": true}
        ]
        """
        let result = PlatformCapabilityService.parseAuthMethod(
            data: Data(json.utf8), profile: "lighthouse"
        )
        XCTAssertFalse(result)
    }

    // MARK: - isAvailable (executor-backed)

    func testIsAvailableReturnsTrueForPlatformProfile() async {
        let json = """
        [{"name": "lighthouse", "auth-method": "platform", "default": true}]
        """
        let executor = CountingExecutor(canned: .success(Data(json.utf8)))
        let service = PlatformCapabilityService(executor: executor)

        let available = await service.isAvailable(for: "lighthouse")
        XCTAssertTrue(available)
        XCTAssertEqual(executor.callCount, 1)
    }

    func testIsAvailableReturnsFalseOnExecutorError() async {
        let executor = CountingExecutor(canned: .failure(
            CLIExecutorError.nonZeroExit(code: 2, stderr: "unknown command")
        ))
        let service = PlatformCapabilityService(executor: executor)

        let available = await service.isAvailable(for: "lighthouse")
        XCTAssertFalse(available)
    }

    func testIsAvailableCachesPerProfile() async {
        let json = """
        [{"name": "lighthouse", "auth-method": "platform", "default": true}]
        """
        let executor = CountingExecutor(canned: .success(Data(json.utf8)))
        let service = PlatformCapabilityService(executor: executor)

        _ = await service.isAvailable(for: "lighthouse")
        _ = await service.isAvailable(for: "lighthouse")
        XCTAssertEqual(executor.callCount, 1, "repeat lookups should hit the cache")
    }

    func testRefreshDropsCachedResult() async {
        let json = """
        [{"name": "lighthouse", "auth-method": "platform", "default": true}]
        """
        let executor = CountingExecutor(canned: .success(Data(json.utf8)))
        let service = PlatformCapabilityService(executor: executor)

        _ = await service.isAvailable(for: "lighthouse")
        service.refresh()
        _ = await service.isAvailable(for: "lighthouse")
        XCTAssertEqual(executor.callCount, 2, "refresh() must force a re-probe")
    }
}

// MARK: - Counting executor

/// Test double that records how many times `execute` ran. Single canned outcome
/// is enough because `PlatformCapabilityService` only ever issues `.configList`.
private final class CountingExecutor: CLIExecutor, @unchecked Sendable {
    enum Outcome {
        case success(Data)
        case failure(CLIExecutorError)
    }

    private let canned: Outcome
    private let lock = NSLock()
    private var _callCount = 0

    var callCount: Int {
        lock.withLock { _callCount }
    }

    init(canned: Outcome) {
        self.canned = canned
    }

    func execute(_ command: CLICommand) async throws -> Data {
        lock.withLock { _callCount += 1 }
        switch canned {
        case .success(let data): return data
        case .failure(let err):  throw err
        }
    }
}
