import XCTest
@testable import JamfReports

/// Consecutive-failure bookkeeping in `StateFileStore`.
///
/// Before this, `ReportEngine.collect`'s per-kind failure existed only as a log
/// warning inside one run — nothing on disk distinguished "this kind failed
/// tonight" from "this kind has failed every night since May". These pin the
/// two properties that make the count meaningful: it accumulates across runs,
/// and a success resets it (so it always describes the present).
final class StateFileFailureTests: XCTestCase {

    private let fileManager = FileManager.default
    private var tempDir: URL!
    private var store: StateFileStore!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = fileManager.temporaryDirectory
            .appendingPathComponent("sff-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = StateFileStore(directory: tempDir)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    func testNoRecordMeansNoKnownFailures() {
        XCTAssertNil(store.failures(report: "security"))
    }

    func testFailuresAccumulateAcrossRuns() throws {
        try store.recordFailure(report: "security", at: t0)
        try store.recordFailure(report: "security", at: t0.addingTimeInterval(86_400))
        try store.recordFailure(report: "security", at: t0.addingTimeInterval(172_800))

        let record = try XCTUnwrap(store.failures(report: "security"))
        XCTAssertEqual(record.count, 3)
        XCTAssertEqual(record.last, t0.addingTimeInterval(172_800))
    }

    func testSuccessResetsTheCountSoItMeansConsecutive() throws {
        try store.recordFailure(report: "computers", at: t0)
        try store.recordFailure(report: "computers", at: t0)
        store.clearFailures(report: "computers")

        XCTAssertNil(store.failures(report: "computers"))

        try store.recordFailure(report: "computers", at: t0)
        XCTAssertEqual(store.failures(report: "computers")?.count, 1,
                       "A post-recovery failure must start a new streak, not resume the old one")
    }

    func testFailuresAreScopedPerKind() throws {
        try store.recordFailure(report: "security", at: t0)
        try store.recordFailure(report: "security", at: t0)
        XCTAssertNil(store.failures(report: "computers"))
    }

    /// A nonsense count must not be able to silence an alarm. Without the
    /// `count > 0` guard a negative value is read back verbatim and then
    /// incremented by one per failed run, so a source broken every night would
    /// take seven runs to cross the reporting threshold — the counter would be
    /// suppressing exactly the alarm it exists to raise. (Zero behaves
    /// identically with or without the guard; negatives are what it earns.)
    func testNonsenseCountCannotSuppressTheAlarm() throws {
        try "-5 2026-08-25T12:00:00Z".write(
            to: tempDir.appendingPathComponent("security.fail"),
            atomically: true, encoding: .utf8
        )
        XCTAssertNil(store.failures(report: "security"))

        store.record(.failed, report: "security", at: t0)
        store.record(.failed, report: "security", at: t0)

        XCTAssertEqual(store.failures(report: "security")?.count, 2,
                       "Counting must restart from a sane base, not from the corrupt value")
    }

    func testMalformedRecordReadsAsNoFailures() throws {
        try "garbage".write(
            to: tempDir.appendingPathComponent("security.fail"),
            atomically: true, encoding: .utf8
        )
        XCTAssertNil(store.failures(report: "security"),
                     "Reads must never throw — a corrupt counter degrades to 'no known failures'")
    }

    func testFailureFilesAreExcludedFromTheStateManifest() throws {
        try store.recordRun(report: "overview", at: t0)
        try store.recordFailure(report: "security", at: t0)
        try store.rewriteManifest()

        let data = try Data(contentsOf: tempDir.appendingPathComponent("manifest.json"))
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let files = try XCTUnwrap(json["files"] as? [String: String])
        // The manifest is a tamper check over cadence state; failure counters are
        // advisory bookkeeping and must not churn its hash on every failed night.
        XCTAssertTrue(files.keys.contains("overview.last"))
        XCTAssertFalse(files.keys.contains { $0.hasSuffix(".fail") })
    }

    // MARK: - Outcome application
    //
    // These pin the rules that used to live inline in `ReportEngine.collect`'s
    // five per-kind branches, where nothing could reach them: `collect`
    // resolves jamf-cli through `ExecutableLocator`, which has no injectable
    // seam by design, so the loop cannot run in the suite. A mutation run
    // deleting the streak-clearing survived until the bookkeeping moved here.

    func testLandingRecordsSuccessAndClearsTheStreakTogether() throws {
        try store.recordFailure(report: "security", at: t0)
        try store.recordFailure(report: "security", at: t0)
        XCTAssertEqual(store.failures(report: "security")?.count, 2)

        store.record(.landed, report: "security", at: t0.addingTimeInterval(3600))

        XCTAssertEqual(store.lastRun(report: "security"), t0.addingTimeInterval(3600),
                       "A landing must advance the cadence boundary")
        XCTAssertNil(store.failures(report: "security"),
                     "A landing must clear the streak, or a recovered kind alarms forever")
    }

    func testFailedOutcomeIncrementsWithoutAdvancingTheCadenceBoundary() throws {
        store.record(.landed, report: "computers", at: t0)
        store.record(.failed, report: "computers", at: t0.addingTimeInterval(86_400))
        store.record(.failed, report: "computers", at: t0.addingTimeInterval(172_800))

        XCTAssertEqual(store.failures(report: "computers")?.count, 2)
        // The unchanged boundary is what keeps a broken kind permanently "due",
        // so every subsequent run retries it instead of waiting out its cadence.
        XCTAssertEqual(store.lastRun(report: "computers"), t0,
                       "A failure must not advance the cadence boundary")
    }

    func testOutcomeApplicationNeverThrowsIntoTheCollectLoop() {
        // The store's directory is deleted underneath it: a state-write failure
        // must never undo a snapshot already written to disk.
        try? fileManager.removeItem(at: tempDir)
        let readOnly = StateFileStore(directory: URL(fileURLWithPath: "/dev/null/nope"))
        readOnly.record(.landed, report: "security", at: t0)
        readOnly.record(.failed, report: "security", at: t0)
    }

    func testRepeatedLandingsKeepTheStreakAtZero() {
        store.record(.landed, report: "overview", at: t0)
        store.record(.landed, report: "overview", at: t0.addingTimeInterval(43_200))
        XCTAssertNil(store.failures(report: "overview"))
    }

    func testCollectionStatesReportBothHalves() throws {
        try store.recordRun(report: "overview", at: t0)
        try store.recordFailure(report: "security", at: t0)
        try store.recordFailure(report: "security", at: t0)

        let states = store.collectionStates(for: ["overview", "security", "computers"])
        XCTAssertEqual(states.count, 3)
        XCTAssertEqual(states[0].lastSuccess, t0)
        XCTAssertEqual(states[0].consecutiveFailures, 0)
        XCTAssertNil(states[1].lastSuccess)
        XCTAssertEqual(states[1].consecutiveFailures, 2)
        // A kind with neither record still yields a state — a never-collected
        // kind must be visible to the evaluator, not silently absent.
        XCTAssertNil(states[2].lastSuccess)
        XCTAssertEqual(states[2].consecutiveFailures, 0)
    }
}
