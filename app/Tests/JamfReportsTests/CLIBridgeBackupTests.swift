import XCTest
@testable import JamfReports

@MainActor
final class CLIBridgeBackupTests: XCTestCase {

    // MARK: - Real backup() call tests

    /// Invalid profile slug must cause backup() to return -1 immediately without
    /// attempting any filesystem operations. No jamf-cli needed.
    func test_backup_rejectsInvalidProfile() async {
        let bridge = CLIBridge()
        let collector = LineCollector()
        do {
            _ = try await bridge.backup(profile: "../etc/passwd", label: nil) { line in
                collector.append(line)
            }
            XCTFail("backup must throw for an invalid profile slug")
        } catch let e as CLIBridgeError {
            XCTAssertEqual(e, .invalidProfile("../etc/passwd"), "backup must throw .invalidProfile")
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
        XCTAssertTrue(
            collector.lines.contains(where: { $0.text.contains("invalid profile name") }),
            "expected an [error] invalid profile name line; got: \(collector.lines.map(\.text))"
        )
    }

    /// A label beginning with '-' must be rejected before any subprocess is launched.
    func test_backup_rejectsLeadingDashLabel() async {
        let bridge = CLIBridge()
        let collector = LineCollector()
        do {
            _ = try await bridge.backup(profile: "valid-profile", label: "--evil") { line in
                collector.append(line)
            }
            XCTFail("backup must throw for a leading-dash label")
        } catch let e as CLIBridgeError {
            if case .invalidArgument = e { /* expected */ } else {
                XCTFail("Expected .invalidArgument, got \(e)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
        XCTAssertTrue(
            collector.lines.contains(where: { $0.text.contains("may not start with '-'") }),
            "expected label rejection line; got: \(collector.lines.map(\.text))"
        )
    }

    /// When jamf-cli is absent the backup() path must throw `.executableNotFound`
    /// and emit an error line. Skipped when jamf-cli is installed.
    func test_backup_emitsErrorWhenJamfCLIMissing() async throws {
        guard ExecutableLocator.locate("jamf-cli") == nil else {
            throw XCTSkip("jamf-cli is installed — cannot test the not-found path")
        }
        let bridge = CLIBridge()
        let collector = LineCollector()
        do {
            _ = try await bridge.backup(profile: "test-profile", label: nil) { line in
                collector.append(line)
            }
            XCTFail("backup must throw when jamf-cli is absent")
        } catch let e as CLIBridgeError {
            XCTAssertEqual(e, .executableNotFound,
                           "backup must throw .executableNotFound when jamf-cli is absent")
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
        XCTAssertFalse(collector.lines.isEmpty, "backup must emit at least one log line when jamf-cli is absent")
    }
}

// MARK: - LineCollector

private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [CLIBridge.LogLine] = []

    func append(_ line: CLIBridge.LogLine) {
        lock.lock(); defer { lock.unlock() }
        _lines.append(line)
    }

    var lines: [CLIBridge.LogLine] {
        lock.lock(); defer { lock.unlock() }
        return _lines
    }
}
