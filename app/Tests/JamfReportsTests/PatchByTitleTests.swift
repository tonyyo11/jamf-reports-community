import XCTest
@testable import JamfReports

/// When Jamf Pro never answers the patch report, `patch-status` is collected one title at a
/// time, from the Classic title list and the per-title summary, into the same snapshot shape.
final class PatchByTitleTests: XCTestCase {

    private var root: URL!
    private let profile = "bytitle"

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func add(_ line: CLIBridge.LogLine) { lock.withLock { stored.append(line.text) } }
        var all: [String] { lock.withLock { stored } }
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("JRC-ByTitle-\(UUID().uuidString)", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("Jamf-Reports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspacesRoot.appendingPathComponent(profile, isDirectory: true),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", workspacesRoot.path, 1)
        addTeardownBlock { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
        try "jamf_cli:\n  profile: \"\(profile)\"\n".write(
            to: try XCTUnwrap(ProfileService.workspaceURL(for: profile))
                .appendingPathComponent("config.yaml"),
            atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private var calls: URL { root.appendingPathComponent("calls") }

    /// The report times out as jamf-cli words it; the title list and summaries answer, except
    /// title `failing` when given.
    private func makeStub(failing: String? = nil) throws -> URL {
        let stub = root.appendingPathComponent("bin/stub-cli")
        try """
        #!/bin/sh
        [ "$1 $2" = "config list" ] && { printf '%s' '[{"name":"\(profile)"}]'; exit 0; }
        echo "$*" >> '\(calls.path)'
        case "$*" in
          *"report patch-status"*)
            printf '%s' '{"error":"error","message":"fetching patch title configurations: \
        the server did not answer in time: http2: timeout awaiting response headers"}'
            exit 1 ;;
          *"classic-patch-titles list"*)
            printf '%s' '[{"id":"7","name":"A"},{"id":"8","name":"B"},{"id":"9","name":"C"}]' ;;
          *"patch-summary \(failing ?? "none") "*) exit 4 ;;
          *"patch-summary 7 "*)
            printf '%s' '{"title":"A","latestVersion":"1.2","upToDate":2,"outOfDate":1}' ;;
          *"patch-summary 8 "*)
            printf '%s' '{"title":"B","latestVersion":"3.0","upToDate":0,"outOfDate":0}' ;;
          *"patch-summary 9 "*)
            printf '%s' '{"title":"C","latestVersion":"9","upToDate":5,"outOfDate":0}' ;;
          *) printf '[]' ;;
        esac
        """.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        return stub
    }

    private func collect(_ stub: URL, force: Bool = true) async -> [String] {
        let lines = Lines()
        _ = try? await ReportEngine.collect(
            workspace: WorkspaceID(validating: profile),
            profile: profile, workspacePaths: WorkspacePaths.self, tiers: [.refresh],
            force: force, authConfirmationProbe: { _, _ in false },
            locateJamfCLI: { stub }, refreshSOFA: { _ in (.empty, []) }, onLine: lines.add)
        return lines.all
    }

    private func reportCalls() -> Int {
        ((try? String(contentsOf: calls, encoding: .utf8)) ?? "")
            .split(separator: "\n").filter { $0.contains("report patch-status") }.count
    }

    private func snapshot() throws -> [PatchStatusRow]? {
        let dir = try WorkspacePaths.dataDir(for: profile).appendingPathComponent("patch-status")
        guard let file = FileManager.newestJSONFile(in: dir) else { return nil }
        return try JSONDecoder().decode([PatchStatusRow].self, from: Data(contentsOf: file))
    }

    func testAReportThatTimesOutIsCollectedTitleByTitleInTheSameShape() async throws {
        let stub = try makeStub()
        let lines = await collect(stub)
        let rows = try XCTUnwrap(snapshot(), "\(lines)")
        XCTAssertEqual(rows.map(\.id), ["7", "8", "9"])
        let first = rows[0]
        XCTAssertEqual(first.title, "A")
        XCTAssertEqual(first.latest, "1.2")
        XCTAssertEqual([first.onLatest, first.onOther, first.total], [2, 1, 3])
        XCTAssertEqual(first.compliancePct, "67%", "rounded as the report rounds it")
        XCTAssertEqual(rows[1].compliancePct, "N/A", "no devices is not 0%")
        XCTAssertEqual(rows[2].compliancePct, "100%")

        let store = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
        XCTAssertNotNil(store.lastRun(report: "patch-status"))
        XCTAssertNil(store.failures(report: "patch-status"), "it landed")
        XCTAssertEqual(store.consecutiveTimeouts(for: "patch-status"), 0)
        XCTAssertFalse(lines.contains { $0.contains(ReportEngine.unlandedSourcesMarker) },
                       "\(lines)")
        XCTAssertEqual(reportCalls(), 1)

        // The next runs go straight to titles, and the failures scan is not sent to wait on
        // the same request.
        let until = try XCTUnwrap(store.patchByTitleUntil())
        XCTAssertEqual(store.timeoutHoldUntil(report: "patch-device-failures"), until)
        let again = await collect(stub)
        XCTAssertEqual(reportCalls(), 1, "the report is not tried again inside the period")
        XCTAssertTrue(again.contains { $0.hasPrefix("[info] patch-status: the patch report timed out") })
        XCTAssertEqual(store.patchByTitleUntil(), until,
                       "a walk inside the period does not renew it")

        // After the period the report gets one more try; landing it would end title mode.
        store.recordPatchByTitle(at: Date().addingTimeInterval(-ReportEngine.patchByTitlePeriod - 60))
        _ = await collect(stub)
        XCTAssertEqual(reportCalls(), 2)
    }

    func testATitleThatDoesNotAnswerLeavesTheSnapshotUnwritten() async throws {
        let stub = try makeStub(failing: "8")
        let lines = await collect(stub)
        XCTAssertNil(try snapshot(), "a snapshot missing a title would change the fleet figure")
        XCTAssertTrue(lines.contains {
            $0 == "[warn] patch-status title by title: 1 of 3 titles did not answer — not written"
        }, "\(lines)")
        let store = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
        XCTAssertNotNil(store.failures(report: "patch-status"))
        XCTAssertNil(store.patchByTitleUntil(), "title mode starts only once it has worked")
    }

    /// A server where no title answers either: jamf-cli gives up on each with exit 1 and its
    /// "did not answer in time" message, before the app's own limit. The walk must stop after
    /// three, not wait out every title.
    private func makeHungStub(titles: Int) throws -> URL {
        let stub = root.appendingPathComponent("bin/stub-cli")
        let list = (1...titles).map { #"{"id":"\#($0)","name":"T\#($0)"}"# }.joined(separator: ",")
        try """
        #!/bin/sh
        [ "$1 $2" = "config list" ] && { printf '%s' '[{"name":"\(profile)"}]'; exit 0; }
        echo "$*" >> '\(calls.path)'
        case "$*" in
          *"classic-patch-titles list"*) printf '%s' '[\(list)]' ;;
          *"report patch-status"*|*"patch-summary"*)
            printf '%s' '{"error":"error","message":"the server did not answer in time"}'
            exit 1 ;;
          *) printf '[]' ;;
        esac
        """.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        return stub
    }

    private func calls(containing text: String) -> Int {
        ((try? String(contentsOf: calls, encoding: .utf8)) ?? "")
            .split(separator: "\n").filter { $0.contains(text) }.count
    }

    func testAWalkOnAServerThatAnswersNoTitleStopsAndTheHoldStillEngages() async throws {
        let stub = try makeHungStub(titles: 40)
        let store = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))

        let first = await collect(stub, force: false)
        XCTAssertNil(try snapshot())
        XCTAssertLessThanOrEqual(
            calls(containing: "patch-summary"), 3 + ReportEngine.patchByTitleConcurrency,
            "three timeouts in a row end the walk; the calls already started finish: \(first)")
        // The report and the titles both timed out: two timeouts on the server's patch
        // requests in one run, so the hold starts now.
        XCTAssertEqual(store.consecutiveTimeouts(for: "patch-status"), 2)
        XCTAssertNotNil(store.timeoutHoldUntil(report: "patch-status"))
        XCTAssertNil(store.patchByTitleUntil())
        let before = (calls(containing: "report patch-status"), calls(containing: "patch-summary"))
        let second = await collect(stub, force: false)
        XCTAssertEqual(calls(containing: "report patch-status"), before.0, "held: \(second)")
        XCTAssertEqual(calls(containing: "patch-summary"), before.1)
    }

    /// The reported server: the title list hangs too. One run is enough to hold the source.
    func testATitleListThatTimesOutToo_HoldsAfterOneRun() async throws {
        let stub = root.appendingPathComponent("bin/stub-cli")
        try """
        #!/bin/sh
        [ "$1 $2" = "config list" ] && { printf '%s' '[{"name":"\(profile)"}]'; exit 0; }
        echo "$*" >> '\(calls.path)'
        case "$*" in
          *"report patch-status"*|*"classic-patch-titles list"*)
            printf '%s' '{"error":"general","message":"the server did not answer in time"}'
            exit 1 ;;
          *) printf '[]' ;;
        esac
        """.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let store = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
        _ = await collect(stub, force: false)
        XCTAssertEqual(calls(containing: "classic-patch-titles list"), 1)
        XCTAssertEqual(calls(containing: "patch-summary"), 0)
        XCTAssertNotNil(store.timeoutHoldUntil(report: "patch-status"))
        XCTAssertNotNil(store.timeoutHoldUntil(report: "patch-device-failures"),
                        "the failures scan starts with the same request")
        _ = await collect(stub, force: false)
        XCTAssertEqual(calls(containing: "report patch-status"), 1, "nothing more is asked")
    }

    /// A source that has timed out four times in a row is tried weekly, not daily.
    func testAChronicTimeoutIsHeldForAWeek() throws {
        let store = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        for _ in 1...3 {
            store.record(.failed(exitCode: CLIBridge.exitCodeTimedOut), report: "ea-results", at: at)
        }
        XCTAssertEqual(store.timeoutHoldUntil(report: "ea-results"),
                       at.addingTimeInterval(StateFileStore.timeoutHold))
        store.record(.failed(exitCode: CLIBridge.exitCodeTimedOut), report: "ea-results", at: at)
        XCTAssertEqual(store.timeoutHoldUntil(report: "ea-results"),
                       at.addingTimeInterval(StateFileStore.chronicTimeoutHold))
    }

    /// The state of a workspace upgrading from rc2: the failures scan timed out twice. Once
    /// titles are being walked, that must not hold `patch-status`, which no longer makes the
    /// shared request.
    func testTheFailuresScansTimeoutsDoNotHoldPatchStatusInTitleMode() throws {
        let store = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
        let now = Date()
        store.record(.failed(exitCode: CLIBridge.exitCodeTimedOut),
                     report: "patch-device-failures", at: now)
        store.record(.failed(exitCode: CLIBridge.exitCodeTimedOut),
                     report: "patch-device-failures", at: now)
        XCTAssertNotNil(store.timeoutHoldUntil(report: "patch-status"), "before title mode")
        store.recordPatchByTitle(at: now)
        XCTAssertNil(store.timeoutHoldUntil(report: "patch-status"))
        XCTAssertNotNil(store.timeoutHoldUntil(report: "patch-device-failures"))
    }

    func testAWalkStoppedForARefreshIsNotAFailure() async throws {
        let stub = try makeStub()
        let store = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
        store.recordPatchByTitle(at: Date())
        let lines = Lines()
        let summaryCalls = calls
        // Lets the run reach the walk, then asks it to stop before its first title.
        _ = try? await ReportEngine.$runStop.withValue({
            let text = (try? String(contentsOf: summaryCalls, encoding: .utf8)) ?? ""
            return text.contains("classic-patch-titles") ? .manualRefresh : nil
        }) {
            try await ReportEngine.collect(
                workspace: WorkspaceID(validating: profile),
                profile: profile, workspacePaths: WorkspacePaths.self, tiers: [.refresh],
                force: true, authConfirmationProbe: { _, _ in false },
                locateJamfCLI: { stub }, refreshSOFA: { _ in (.empty, []) }, onLine: lines.add)
        }
        XCTAssertNil(try snapshot())
        XCTAssertNil(store.failures(report: "patch-status"), "stopped, not failed")
        XCTAssertTrue(lines.all.contains { $0.hasPrefix(ReportEngine.stoppedEarlyMarker) },
                      "\(lines.all)")
        XCTAssertFalse(lines.all.contains { $0.contains(ReportEngine.unlandedSourcesMarker) },
                       "\(lines.all)")
    }

    func testTheRowIsBuiltFromASummary() {
        let row = ReportEngine.patchStatusRow(
            id: "4", summary: ["title": "T", "latestVersion": "2", "upToDate": 1, "outOfDate": 1])
        XCTAssertEqual(row?["compliance_pct"] as? String, "50%")
        XCTAssertEqual(row?["total"] as? Int, 2)
        XCTAssertNil(ReportEngine.patchStatusRow(id: "4", summary: ["title": "T"]),
                     "missing counts are not zero")
        XCTAssertNil(ReportEngine.patchStatusRow(
            id: "4", summary: ["upToDate": -1, "outOfDate": 0]))
        XCTAssertEqual(
            ReportEngine.patchTitleIDs(from: Data(#"[{"id":"3"},{"id":"-x"},{"id":5}]"#.utf8)),
            ["3", "5"], "an id that could be read as a flag is left out")
        XCTAssertNil(ReportEngine.patchTitleIDs(from: Data("{}".utf8)))
    }
}
