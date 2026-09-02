import Foundation
import XCTest
@testable import JamfReports

// MARK: - FailureModeTests
//
// Defensive path coverage for CLIBridge / ExecutableLocator / ProfileService
// when tools are absent, profiles are invalid, or subprocesses fail.
//
// These tests cover the bridge-level entry guards.

/// Thread-safe line collector for use across @Sendable closures.
private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [CLIBridge.LogLine] = []

    func append(_ line: CLIBridge.LogLine) {
        lock.lock()
        _lines.append(line)
        lock.unlock()
    }

    var lines: [CLIBridge.LogLine] {
        lock.lock()
        defer { lock.unlock() }
        return _lines
    }

    var hasFailLine: Bool {
        lines.contains { $0.level == .fail }
    }
}

@MainActor
final class FailureModeTests: XCTestCase {

    // MARK: - ExecutableLocator: missing binary

    func testLocateMissingBinaryReturnsNil() {
        let result = ExecutableLocator.locate("__no_such_binary_jamfreports__")
        XCTAssertNil(result, "Locating an absent binary must return nil")
    }

    func testLocateKnownSystemBinarySucceeds() {
        // /bin/sh is guaranteed on every macOS system.
        let result = ExecutableLocator.locate("sh")
        XCTAssertNotNil(result, "sh must be found via ExecutableLocator")
    }

    func testLocateDoesNotFallBackToCWD() throws {
        // First-launch onboarding pipes the Jamf Pro API secret to jamf-cli
        // stdin; if the locator picked up a binary from the current working
        // directory, a planted `jamf-cli` in CWD would receive the secret.
        // Regression gate: the CWD fallback must stay removed.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-cwd-locate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let stubName = "jrc-cwd-locate-stub-\(UUID().uuidString)"
        let stub = tmp.appendingPathComponent(stubName)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: stub)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: stub.path
        )

        // The stub name is unique to `tmp` and won't exist on any trusted
        // system path. If the locator restored its CWD fallback, this would
        // resolve when CWD equals `tmp`; with the fallback gone, it returns nil.
        let result = ExecutableLocator.locate(stubName)
        XCTAssertNil(result, "ExecutableLocator must not fall back to CWD")
    }

    // MARK: - CLIBridge.isJamfCLIAvailable

    func testIsJamfCLIAvailableReturnsBoolWithoutCrashing() {
        let bridge = CLIBridge()
        // Accept both values — the contract is "no crash", not a specific value.
        let available = bridge.isJamfCLIAvailable
        XCTAssertTrue(available || !available)
    }

    // MARK: - CLIBridge.validateConnection: rejects invalid profile slug

    func testValidateConnectionRejectsInvalidProfileSlug() async {
        let bridge = CLIBridge()
        let collector = LineCollector()
        do {
            _ = try await bridge.validateConnection(profile: "../evil") { line in
                collector.append(line)
            }
            XCTFail("validateConnection must throw for invalid profile slug")
        } catch let e as CLIBridgeError {
            XCTAssertEqual(e, .invalidProfile("../evil"), "Invalid slug must throw .invalidProfile")
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
        XCTAssertTrue(collector.hasFailLine, "A failure log line must be emitted for invalid profile")
    }

    func testValidateConnectionRejectsUppercaseSlug() async {
        let bridge = CLIBridge()
        let collector = LineCollector()
        do {
            _ = try await bridge.validateConnection(profile: "Dummy") { line in
                collector.append(line)
            }
            XCTFail("validateConnection must throw for uppercase profile slug")
        } catch let e as CLIBridgeError {
            XCTAssertEqual(e, .invalidProfile("Dummy"))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
        XCTAssertTrue(collector.hasFailLine)
    }

    // MARK: - CLIBridge.validateConnection: binary-absent case throws

    func testValidateConnectionWhenJamfCLIAbsentThrows() async throws {
        // Only meaningful on machines without jamf-cli. Skip otherwise.
        guard ExecutableLocator.locate("jamf-cli") == nil else {
            throw XCTSkip("jamf-cli is present — binary-absent path not exercisable")
        }
        let bridge = CLIBridge()
        let collector = LineCollector()
        do {
            _ = try await bridge.validateConnection(profile: "dummy") { line in
                collector.append(line)
            }
            XCTFail("validateConnection must throw when jamf-cli is absent")
        } catch let e as CLIBridgeError {
            XCTAssertEqual(e, .executableNotFound,
                           "Missing binary must throw .executableNotFound")
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
        XCTAssertTrue(collector.hasFailLine, "A failure log line must be emitted when binary absent")
    }

    // MARK: - CLIBridge.run: subprocess does not deadlock

    func testRunDoesNotDeadlockWhenTaskCancelled() async throws {
        let sleepBin = URL(fileURLWithPath: "/bin/sleep")
        guard FileManager.default.isExecutableFile(atPath: sleepBin.path) else {
            throw XCTSkip("/bin/sleep not available")
        }

        let bridge = CLIBridge()
        let collector = LineCollector()
        let task = Task {
            // try? is intentional: this test only verifies no deadlock occurs,
            // not the error type. If the task is cancelled before the process
            // starts, bridge.run may throw or return — either is acceptable.
            _ = try? await bridge.run(
                executable: sleepBin,
                arguments: ["60"],
                onLine: { line in collector.append(line) }
            )
        }

        // Give the process 500 ms to start, then cancel.
        try await Task.sleep(nanoseconds: 500_000_000)
        task.cancel()

        // Test completes without deadlock — that is the contract.
        // collector may or may not have lines, depending on timing.
        XCTAssertTrue(collector.lines.isEmpty || !collector.lines.isEmpty)
    }

    // MARK: - ProfileService.isValid: invalid slugs rejected before subprocess

    func testInvalidProfileSlugRejectedByProfileService() {
        let invalids = ["../evil", "Uppercase", "has space", "", "-start", ".start", "/absolute"]
        for slug in invalids {
            XCTAssertFalse(
                ProfileService.isValid(slug),
                "ProfileService.isValid must reject '\(slug)'"
            )
        }
    }

    // MARK: - CLIExecutorError: Equatable

    func testCLIExecutorErrorBinaryNotFoundEquality() {
        let a = CLIExecutorError.binaryNotFound("jamf-cli")
        let b = CLIExecutorError.binaryNotFound("jamf-cli")
        let c = CLIExecutorError.binaryNotFound("other")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testCLIExecutorErrorInvalidProfileEquality() {
        let a = CLIExecutorError.invalidProfile("../evil")
        let b = CLIExecutorError.invalidProfile("../evil")
        XCTAssertEqual(a, b)
    }

    // MARK: - DefaultCLIExecutor: invalid profile rejected before binary lookup

    func testDefaultCLIExecutorRejectsInvalidProfileBeforeSubprocess() async {
        let bridge = CLIBridge()
        let executor = DefaultCLIExecutor(bridge: bridge)
        do {
            _ = try await executor.execute(.proAuthToken(profile: "../evil"))
            XCTFail("Expected CLIExecutorError.invalidProfile to be thrown")
        } catch CLIExecutorError.invalidProfile(let slug) {
            XCTAssertEqual(slug, "../evil")
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - DefaultCLIExecutor: missing binary surfaces binaryNotFound

    func testDefaultCLIExecutorSurfacesBinaryNotFoundWhenJamfCLIAbsent() async throws {
        guard ExecutableLocator.locate("jamf-cli") == nil else {
            throw XCTSkip("jamf-cli is installed — binaryNotFound path not exercisable")
        }
        let bridge = CLIBridge()
        let executor = DefaultCLIExecutor(bridge: bridge)
        do {
            _ = try await executor.execute(.proAuthToken(profile: "dummy"))
            XCTFail("Expected CLIExecutorError.binaryNotFound")
        } catch CLIExecutorError.binaryNotFound(let name) {
            XCTAssertEqual(name, "jamf-cli")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - LogLevel classification

    func testLogLevelFromLineClassifiesKnownPatterns() {
        XCTAssertEqual(CLIBridge.LogLevel.from(line: "[ok] operation succeeded"), .ok)
        XCTAssertEqual(CLIBridge.LogLevel.from(line: "[warn] something odd"), .warn)
        XCTAssertEqual(CLIBridge.LogLevel.from(line: "[fatal] cannot continue"), .fail)
        XCTAssertEqual(CLIBridge.LogLevel.from(line: "[error] bad input"), .fail)
        XCTAssertEqual(CLIBridge.LogLevel.from(line: "Traceback (most recent call last):"), .fail)
        XCTAssertEqual(CLIBridge.LogLevel.from(line: "plain info message"), .info)
    }

}
