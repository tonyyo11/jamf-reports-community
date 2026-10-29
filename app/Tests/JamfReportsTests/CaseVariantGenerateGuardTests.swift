import XCTest
@testable import JamfReports

/// Paths that only generate have no product check, so the folder rule refuses a case variant
/// there too: the CLI before any command runs, a scheduled run before it writes a record, a
/// report or an attention item into the other spelling's folder.
final class CaseVariantGenerateGuardTests: XCTestCase {
    nonisolated(unsafe) private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("case-variant-gen-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("prod", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "jamf_cli:\n  profile: prod\n".write(
            to: folder.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        try? FileManager.default.removeItem(at: root)
    }

    func testTheCLIRefusesACaseVariantBeforeAnyCommandRuns() throws {
        let refusal = try XCTUnwrap(CLIRun.profileRefusal("Prod"))
        XCTAssertTrue(refusal.contains("'prod'"), refusal)
        XCTAssertNil(CLIRun.profileRefusal("prod"))
        XCTAssertEqual(CLIRun.profileRefusal("bad\nname"), "invalid profile 'badname'")
    }

    private func schedule(_ mode: Schedule.RunMode) -> Schedule {
        Schedule(
            name: "variant", profile: "Prod", schedule: "Mon 07:00", cadence: "custom",
            mode: mode, next: "—", last: "—", lastStatus: .ok, artifacts: [], enabled: true,
            launchAgentLabel: "com.github.tonyyo11.jamf-reports-community.Prod.variant",
            multiTarget: nil, tiers: nil, excludedProfiles: nil)
    }

    /// The refused-run convention, in every mode: exit 0 and nothing a retry could fetch.
    /// `prod/` is the other spelling's workspace, so no record, report or attention item is
    /// written there (only a folder named `Prod` exactly, its own, would get the record).
    func testAScheduledRunOfACaseVariantIsRefusedAndWritesNothingIntoTheFolder() async throws {
        for mode in [Schedule.RunMode.jamfCLIOnly, .snapshotOnly, .jamfCLIFull, .backup] {
            let outcome = await runSchedule(schedule(mode), verbose: false)
            XCTAssertEqual(outcome.exitCode, 0, "\(mode)")
            XCTAssertFalse(outcome.retryCouldHelp, "\(mode)")
            XCTAssertTrue(outcome.endsRetries, "\(mode)")
        }
        let folder = root.appendingPathComponent("prod")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path),
                       ["config.yaml"])
    }

    /// The tick reads the refusal as a run that ends its retries, not a failure.
    func testTheTickDoesNotRetryARefusedCaseVariantRun() async throws {
        let run = TickScheduler.DueRun(schedule: schedule(.snapshotOnly), reason: .fire)
        let fire = Date(timeIntervalSince1970: 1_788_000_000)
        let saved = SavedTickState()
        _ = await TickLoop.runDue(
            [run], state: TickState(), runNowLabels: [], clock: { fire },
            save: { saved.state = $0 }, clearRunNowMarker: { _ in },
            perform: { await runSchedule($0.schedule, verbose: false) },
            recordFailure: { _, message in XCTFail(message) }, notifyOverdue: {})
        let state = try XCTUnwrap(saved.state)
        for hours in [1.0, 3.0, 9.0] {
            XCTAssertTrue(TickScheduler.due(
                schedules: [run.schedule], state: state, runNowLabels: [],
                now: fire.addingTimeInterval(hours * 3600)).isEmpty, "retry after \(hours) h")
        }
    }
}

private final class SavedTickState: @unchecked Sendable {
    var state: TickState?
}
