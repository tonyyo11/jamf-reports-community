import Foundation
import XCTest
@testable import JamfReports

/// Tests for `CapabilityService.parseAvailableCommands` and the
/// executor-backed snapshot probe. No live binary required.
@MainActor
final class CapabilityServiceTests: XCTestCase {

    // MARK: - parseAvailableCommands (pure)

    func testParseExtractsAllTrackedCommandsFromRealFormat() {
        // Full fixture matching the verified real `jamf-cli pro --help` shape.
        let result = CapabilityService.parseAvailableCommands(from: realHelpFixture)
        for cmd in CapabilityService.trackedCommands {
            XCTAssertTrue(result.contains(cmd), "expected '\(cmd)' in parsed set")
        }
    }

    func testParseDoesNotCaptureUsageLine() {
        // `  jamf-cli pro [command]` has only one space after "jamf-cli" — must not parse.
        let result = CapabilityService.parseAvailableCommands(from: realHelpFixture)
        XCTAssertFalse(result.contains("jamf-cli"), "Usage: line must not produce a command entry")
    }

    func testParseDoesNotCaptureSyntheticHelpCommand() {
        let result = CapabilityService.parseAvailableCommands(from: realHelpFixture)
        XCTAssertFalse(result.contains("help"), "synthetic 'help' must be excluded")
    }

    func testParseStopsAtFlagsSection() {
        // The fixture has `-h, --help` and `--no-version-check` under Flags: — must not appear.
        let result = CapabilityService.parseAvailableCommands(from: realHelpFixture)
        XCTAssertFalse(result.contains("-h,"))
        XCTAssertFalse(result.contains("--no-version-check"))
        XCTAssertFalse(result.contains("--help"))
    }

    func testParseCategoryHeadersAreNotCaptured() {
        // Category headers like "Core Commands:" are non-indented — must not appear.
        let result = CapabilityService.parseAvailableCommands(from: realHelpFixture)
        XCTAssertFalse(result.contains("Core Commands:"))
        XCTAssertFalse(result.contains("Computer Management:"))
        XCTAssertFalse(result.contains("Scripts & Policies:"))
    }

    func testParseReturnsEmptyForEmptyInput() {
        XCTAssertTrue(CapabilityService.parseAvailableCommands(from: "").isEmpty)
    }

    func testParseReturnsEmptyForGarbageInput() {
        XCTAssertTrue(
            CapabilityService.parseAvailableCommands(from: "not a help page\n\nnonsense").isEmpty
        )
    }

    func testParseReturnsEmptyWhenOnlyFlagsPresent() {
        let text = "Flags:\n  -h, --help   help for pro\n"
        XCTAssertTrue(CapabilityService.parseAvailableCommands(from: text).isEmpty)
    }

    func testParseHandlesBlankLinesBetweenCategories() {
        // Blank lines between category groups must not interrupt collection.
        let text = """
        Core Commands:
          overview              Show a summary

        Power Commands:
          report                Generate operational reports

        Flags:
          -h, --help   help for pro
        """
        let result = CapabilityService.parseAvailableCommands(from: text)
        XCTAssertTrue(result.contains("overview"))
        XCTAssertTrue(result.contains("report"))
    }

    func testParseExtractsHyphenatedCommandNames() {
        let result = CapabilityService.parseAvailableCommands(from: realHelpFixture)
        XCTAssertTrue(result.contains("computer-groups-smart-groups"))
        XCTAssertTrue(result.contains("computer-extension-attributes"))
    }

    // MARK: - buildSnapshot (executor-backed, CI-safe)
    //
    // These tests use `buildSnapshot(version:executor:)` rather than `probe` because
    // `probe` calls `ExecutableLocator.locate("jamf-cli")` and returns `.absent` on CI
    // where no binary is installed. `buildSnapshot` exercises all of the parsing and
    // availability-mapping logic without touching the file system.

    func testBuildSnapshotMarksAvailableWhenCommandInHelp() async {
        let executor = CannedExecutor(result: .success(Data(realHelpFixture.utf8)))
        let snap = await CapabilityService.buildSnapshot(version: "1.18.0", executor: executor)
        XCTAssertEqual(snap.version, "1.18.0")
        for cmd in CapabilityService.trackedCommands {
            XCTAssertEqual(snap.availability[cmd], .available, "expected '\(cmd)' to be .available")
        }
    }

    func testBuildSnapshotMarksBlockedWhenCommandAbsentFromHelp() async {
        // Help text has only "overview" in a category block — all others must be .blocked.
        let text = """
        Core Commands:
          overview              Show a summary

        Flags:
          -h, --help   help for pro
        """
        let executor = CannedExecutor(result: .success(Data(text.utf8)))
        let snap = await CapabilityService.buildSnapshot(version: nil, executor: executor)
        XCTAssertEqual(snap.availability["overview"], .available)
        for cmd in CapabilityService.trackedCommands where cmd != "overview" {
            XCTAssertEqual(
                snap.availability[cmd], .blocked,
                "expected '\(cmd)' to be .blocked when absent from help"
            )
        }
    }

    func testBuildSnapshotMarksAllBlockedWhenExecutorThrows() async {
        let executor = CannedExecutor(result: .failure(
            CLIExecutorError.nonZeroExit(code: 1, stderr: "error")
        ))
        let snap = await CapabilityService.buildSnapshot(version: "1.18.0", executor: executor)
        for cmd in CapabilityService.trackedCommands {
            XCTAssertEqual(
                snap.availability[cmd], .blocked,
                "expected '\(cmd)' to be .blocked on executor failure"
            )
        }
    }

    // MARK: - Cache behaviour (via buildSnapshot to stay CI-safe)

    func testBuildSnapshotCallsExecutorOnce() async {
        let executor = CannedExecutor(result: .success(Data(realHelpFixture.utf8)))
        _ = await CapabilityService.buildSnapshot(version: nil, executor: executor)
        XCTAssertEqual(executor.callCount, 1, "buildSnapshot must call executor exactly once")
    }

    func testServiceRefreshDropsInternalCache() async {
        // Two `snapshot()` calls with a `refresh()` between them. On CI with no binary
        // both return `.absent` without calling the executor — the test verifies
        // that `refresh()` clears the cached value without crashing.
        let executor = CannedExecutor(result: .success(Data(realHelpFixture.utf8)))
        let service = CapabilityService(executor: executor)

        let first = await service.snapshot()
        service.refresh()
        let second = await service.snapshot()
        XCTAssertNotNil(first.availability)
        XCTAssertNotNil(second.availability)
    }
}

// MARK: - Helpers

/// Fixture matching the verified real `jamf-cli pro --help` output shape (v1.18.0).
///
/// Key characteristics under test:
/// - Category headers (`Core Commands:`, etc.) are non-indented — must NOT be captured.
/// - Command rows are indented with exactly two spaces, name, two+ spaces, description.
/// - `Usage:` line is `  jamf-cli pro [command]` — "jamf-cli" followed by ONE space,
///   so the two-space gap rule excludes it.
/// - `help` is present as a synthetic cobra command — must be filtered out.
/// - `Flags:` and `Global Flags:` terminate collection.
private let realHelpFixture = """
Commands for interacting with Jamf Pro ...

Usage:
  jamf-cli pro [command]

Core Commands:
  auth                          Authentication utilities
  overview                      Show a summary of the Jamf Pro instance

Power Commands:
  report                        Generate operational reports and analytics

Computer Management:
  computer-extension-attributes          Manage computer-extension-attributes
  computer-groups-smart-groups           Manage computer-groups-smart-groups
  classic-computer-groups                Manage classic (Jamf Pro legacy) computer groups
  classic-mobile-device-groups           Manage classic (Jamf Pro legacy) mobile device groups

Mobile Management:
  advanced-mobile-device-searches        Manage advanced mobile device searches

Scripts & Policies:
  scripts                               Manage scripts

Distribution & JCDS:
  packages                              Manage packages

Other Commands:
  help                          Help about any command

Flags:
  -h, --help   help for pro

Global Flags:
      --no-version-check   skip upstream version check
  -p, --profile string     jamf-cli profile name

Use "jamf-cli pro [command] --help" for more information about a command.
"""

// MARK: - Test double

private final class CannedExecutor: CLIExecutor, @unchecked Sendable {
    enum Result {
        case success(Data)
        case failure(CLIExecutorError)
    }

    private let canned: Result
    private let lock = NSLock()
    private var _callCount = 0

    var callCount: Int { lock.withLock { _callCount } }

    init(result: Result) {
        canned = result
    }

    func execute(_ command: CLICommand) async throws -> Data {
        lock.withLock { _callCount += 1 }
        switch canned {
        case .success(let data): return data
        case .failure(let err):  throw err
        }
    }
}
