import Foundation
import XCTest
@testable import JamfReports

/// Tests for the once-per-day collect guard added to `ReportEngine.collect`.
///
/// The guard short-circuits the jamf-cli collection loop (which requires the
/// binary and live credentials) when a valid `summary_<today>.json` already
/// exists and `force` is false. Tests verify the guard fires / does not fire
/// based on the filesystem state alone. The workspace is under a temporary root,
/// and jamf-cli is never found (`locateJamfCLI`), so a collect the guard lets
/// through stops at the binary check instead of running jamf-cli.
final class CollectOncePerdayGuardTests: XCTestCase {

    // MARK: - Setup

    /// A profile slug that is valid per `ProfileService.isValid` (test-only prefix).
    private let testProfile = "testonly-collect-guard"

    private var summariesDir: URL!
    private var root: URL!
    private var savedRoot: String?

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-collect-guard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        savedRoot = ProcessInfo.processInfo.environment["JRC_TEST_WORKSPACES_ROOT"]
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        guard let workspaceURL = ProfileService.workspaceURL(for: testProfile) else {
            throw XCTSkip("ProfileService could not resolve workspace URL — check home directory")
        }
        // Build the summaries path matching WorkspacePaths.summariesDir logic:
        // historicalDir defaults to <workspace>/snapshots; summaries appended.
        summariesDir = workspaceURL
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent("summaries", isDirectory: true)
        try FileManager.default.createDirectory(at: summariesDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let savedRoot { setenv("JRC_TEST_WORKSPACES_ROOT", savedRoot, 1) }
        else { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    /// A collect the guard lets through reaches the jamf-cli check and stops there.
    private func assertTheGuardLetItThrough(
        tiers: Set<CollectionTier> = Set(CollectionTier.allCases), force: Bool,
        onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void = { _ in }
    ) async {
        do {
            try await ReportEngine.collect(
                profile: testProfile, workspacePaths: WorkspacePaths.self, tiers: tiers,
                force: force, locateJamfCLI: { nil }, onLine: onLine)
            XCTFail("with no jamf-cli a collect past the guard throws jamfCLINotFound")
        } catch ReportEngineError.jamfCLINotFound {
        } catch {
            XCTFail("expected jamfCLINotFound, got \(error)")
        }
    }

    // MARK: - Helpers

    /// Write a minimal valid `summary_<today>.json` to the test summaries dir.
    private func writeTodaySummary() throws {
        let today = SummaryJSONParser.dateFormatter.string(from: Date())
        let file = summariesDir.appendingPathComponent("summary_\(today).json")
        let payload: [String: Any] = [
            "date": today,
            "totalDevices": 100,
            "source": "test"
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: file)
    }

    // MARK: - Tests

    /// When a valid today's summary exists and `force` is false, `collect` must
    /// return early and emit the skip log line — no jamf-cli invocation occurs
    /// (verified implicitly: the call completes without throwing
    /// `jamfCLINotFound` even when the binary is absent).
    func testSkipsWhenTodaySummaryExistsAndForceIsFalse() async throws {
        try writeTodaySummary()

        let collector = LogLineTextCollector()
        // collect(force: false) should return without reaching the jamf-cli
        // binary check. If it did reach the binary check and jamf-cli is absent,
        // it would throw ReportEngineError.jamfCLINotFound. Catching that error
        // would be a test failure. The test passes when no error is thrown.
        let disposition = try await ReportEngine.collect(
            profile: testProfile,
            workspacePaths: WorkspacePaths.self,
            force: false,
            locateJamfCLI: { nil }
        ) { line in
            collector.append(line.text)
        }

        XCTAssertTrue(
            collector.texts.contains { $0.contains("already collected today") },
            "Expected skip log line; got: \(collector.texts)"
        )
        XCTAssertEqual(disposition, .alreadyCollected,
                       "CollectRouter must be able to tell the guard's skip from a collect")
    }

    /// When `force` is true, `collect` must proceed past the once-per-day guard.
    func testProceedsWhenForceIsTrue() async throws {
        try writeTodaySummary()
        await assertTheGuardLetItThrough(force: true)
    }

    /// When no today's summary exists, `collect(force: false)` must proceed
    /// past the guard (same behavior as `force: true` for a fresh workspace).
    func testProceedsWhenNoTodaySummaryExists() async throws {
        await assertTheGuardLetItThrough(force: false)
    }

    /// Regression: a tier-scoped collect (e.g. the weekly `managed-scan` run with
    /// tiers `[.scan]`) must NOT be intercepted by the once-per-day guard just
    /// because the daily `managed-freshness` run (tiers `[.refresh, .inventory]`)
    /// already wrote today's summary. The guard applies only to a FULL collect;
    /// tier-scoped collects fall through to the per-kind cadence check, otherwise
    /// the scan tier (`patch-device-failures`/`update-device-failures`) would never
    /// be collected by automation. Asserts the skip line is absent.
    func testProceedsForTierScopedCollectEvenIfTodaySummaryExists() async throws {
        try writeTodaySummary()

        let collector = LogLineTextCollector()
        await assertTheGuardLetItThrough(tiers: [.scan], force: false) { line in
            collector.append(line.text)
        }

        XCTAssertFalse(
            collector.texts.contains { $0.contains("already collected today") },
            "Tier-scoped collect must not be skipped by the once-per-day guard; got: \(collector.texts)"
        )
    }
}

// MARK: - Test helper

/// Thread-safe collector for streamed log-line text. The `onLine` closure runs
/// in concurrently-executing code, so a plainly captured `var` is not Sendable.
private final class LogLineTextCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _texts: [String] = []

    func append(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        _texts.append(text)
    }

    var texts: [String] {
        lock.lock(); defer { lock.unlock() }
        return _texts
    }
}
