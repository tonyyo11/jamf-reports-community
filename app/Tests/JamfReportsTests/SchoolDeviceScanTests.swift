import XCTest
@testable import JamfReports

/// The Jamf School per-device scan (design: 2026-11-15-school-device-scan-design.md). The step
/// runs against a stub jamf-cli (NOT named `jamf-cli`, the codesign gate keys on that name) that
/// answers `school devices get <udid>` from files in a temp dir. Test names carry the row of the
/// design's test matrix they cover.
final class SchoolDeviceScanTests: XCTestCase {

    private var root: URL!
    private var binDir: URL!
    private var answers: URL!
    private let profile = "schoolscan"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("JRC-SchoolScan-\(UUID().uuidString)", isDirectory: true)
        let workspaces = root.appendingPathComponent("Jamf-Reports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspaces.appendingPathComponent(profile, isDirectory: true),
            withIntermediateDirectories: true)
        binDir = root.appendingPathComponent("bin", isDirectory: true)
        answers = root.appendingPathComponent("answers", isDirectory: true)
        for dir in [binDir!, answers!] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        setenv("JRC_TEST_WORKSPACES_ROOT", workspaces.path, 1)
        addTeardownBlock { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    /// `answers/dev-<udid>` is the body, `.exit` its exit code, `.delay` seconds to wait,
    /// `.sleep` a call that never answers; `all.exit` is every call's exit. A device with no
    /// answer file returns a full object that also carries a name, which must not reach disk.
    private func makeStub() throws -> URL {
        let url = binDir.appendingPathComponent("stub-cli")
        let script = """
        #!/bin/sh
        [ "$1 $2" = "config list" ] && { printf '%s' '[{"name":"\(profile)"}]'; exit 0; }
        A="\(answers.path)"
        printf '%s\\n' "$*" >> "$A/calls.log"
        case "$*" in
          *" devices list "*) [ -f "$A/list" ] && cat "$A/list" || printf '[]'; exit 0 ;;
          *" devices get "*)
            W="\(try XCTUnwrap(ProfileService.workspaceURL(for: profile)).path)"
            [ -f "$W/automation/.workspace-claim.json" ] && echo held >> "$A/claim-held"
            ls "$W"/automation/hosts/*.json >/dev/null 2>&1 && echo yes >> "$A/activity-seen"
            u=$(echo "$*" | sed -E 's/.* devices get ([^ ]+).*/\\1/'); f="$A/dev-$u"
            [ -f "\(try dataDir.path)/state/school-device-detail.last" ] && echo yes >> "$A/stamped"
            [ -f "$f.sleep" ] && exec sleep 30
            [ -f "$f.delay" ] && sleep "$(cat "$f.delay")"
            code=0; [ -f "$A/all.exit" ] && code=$(cat "$A/all.exit")
            [ -f "$f.exit" ] && code=$(cat "$f.exit")
            if [ -f "$f" ]; then cat "$f"; else printf \
              '{"UDID":"%s","name":"Secret Name","serialNumber":"S-%s","batteryLevel":55,"deviceEnrollType":"dep","totalCapacity":64}' "$u" "$u"; fi
            exit "$code" ;;
          *) printf '[]'; exit 0 ;;
        esac
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func answer(_ name: String, _ body: String) throws {
        try body.write(to: answers.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func calls() -> [String] {
        ((try? String(contentsOf: answers.appendingPathComponent("calls.log"), encoding: .utf8))
            ?? "").split(separator: "\n").map(String.init)
    }

    private func deviceList(_ udids: [String], extra: [[String: Any]] = []) throws -> Data {
        let rows: [[String: Any]] = udids.map {
            ["udid": $0, "serialNumber": "S-\($0)", "name": "Name \($0)", "inTrash": false]
        } + extra
        return try JSONSerialization.data(withJSONObject: rows)
    }

    private func udids(_ count: Int) -> [String] { (1...max(count, 1)).map { "u\($0)" } }

    private var dataDir: URL { get throws { try WorkspacePaths.dataDir(for: profile) } }
    private var stateStore: StateFileStore {
        get throws { StateFileStore(directory: try dataDir.appendingPathComponent("state")) }
    }

    private func snapshotRows() throws -> [[String: Any]]? {
        let dir = try dataDir.appendingPathComponent(ReportEngine.schoolDeviceDetailKind)
        guard let file = FileManager.newestSnapshotFile(in: dir) else { return nil }
        return try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]]
    }

    private func runStep(
        _ list: Data?, tiers: Set<CollectionTier> = [.scan], collectSkip: Set<String> = [],
        limits: ReportEngine.SchoolDeviceScanLimits = .init(concurrency: 1)
    ) async throws -> [String] {
        let stub = try makeStub()
        let lines = LineBox()
        let plan = ReportEngine.planSchoolDeviceScan(
            tiers: tiers, collectSkip: collectSkip,
            stateStore: ReportEngine.schoolScanStateStore(dataDir: try dataDir), now: now)
        await ReportEngine.runSchoolDeviceScanStep(
            workspace: try WorkspaceID(validating: profile), school: profile,
            workspacePaths: WorkspacePaths.self, plan: plan,
            devicesData: list, locateJamfCLI: { stub }, limits: limits, now: now,
            onLine: { lines.append($0.text) })
        XCTAssertFalse(lines.texts.contains { $0.contains("[partial]") }, "the scan never emits [partial]")
        return lines.texts
    }

    private func has(_ lines: [String], _ prefix: String) -> Bool {
        lines.contains { $0.hasPrefix(prefix) }
    }

    // MARK: - When it runs

    /// Row: tiers without .scan.
    func testTiersWithoutScanDoNotScan() async throws {
        let lines = try await runStep(deviceList(["u1"]), tiers: [.refresh, .inventory])
        XCTAssertTrue(calls().isEmpty)
        XCTAssertNil(try stateStore.lastRun(report: ReportEngine.schoolDeviceDetailKind))
        XCTAssertEqual(
            ReportEngine.planSchoolDeviceScan(
                tiers: [.refresh], collectSkip: [], stateStore: nil, now: now).planText,
            "device scan: not selected (tier scan not selected)")
        XCTAssertTrue(lines.isEmpty)
    }

    /// Rows: last attempt 2 days old with any forced collect; a peer's stamp in the future.
    func testTwoDayOldAttemptIsNotDueAndAFutureStampReadsAsAbsent() async throws {
        let store = try stateStore
        let kind = ReportEngine.schoolDeviceDetailKind
        try store.recordRun(report: kind, at: now.addingTimeInterval(-2 * 86_400))
        // `force` is not an input of the plan: nothing bypasses the cadence.
        XCTAssertEqual(
            ReportEngine.planSchoolDeviceScan(
                tiers: [.scan], collectSkip: [], stateStore: store, now: now),
            .notDue(lastAttempt: Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 - 172_800))))
        _ = try await runStep(deviceList(["u1"]))
        XCTAssertTrue(calls().isEmpty)

        try store.recordRun(report: kind, at: now.addingTimeInterval(86_400))
        XCTAssertEqual(
            ReportEngine.planSchoolDeviceScan(
                tiers: [.scan], collectSkip: [], stateStore: store, now: now), .due)
        _ = try await runStep(deviceList(["u1"]))
        XCTAssertEqual(calls().count, 1)
    }

    /// Row: collect_skip lists the kind.
    func testCollectSkipTurnsItOffAndRecordsNothing() async throws {
        _ = try await runStep(deviceList(["u1"]), collectSkip: [ReportEngine.schoolDeviceDetailKind])
        XCTAssertTrue(calls().isEmpty)
        XCTAssertNil(try stateStore.lastRun(report: ReportEngine.schoolDeviceDetailKind))
        XCTAssertEqual(
            ReportEngine.planSchoolDeviceScan(
                tiers: [.scan], collectSkip: [ReportEngine.schoolDeviceDetailKind],
                stateStore: nil, now: now).planText,
            "device scan: turned off (jamf_cli.collect_skip)")
        XCTAssertTrue(ReportEngine.collectSkipKinds(["school_device_detail"])
            .contains(ReportEngine.schoolDeviceDetailKind))
    }

    /// Row: school-devices did not land.
    func testNoLandedDeviceListSkipsAndRecordsNothing() async throws {
        let lines = try await runStep(nil)
        XCTAssertTrue(has(lines, "[skip] school-device-detail: school-devices did not land this run"))
        XCTAssertNil(try stateStore.lastRun(report: ReportEngine.schoolDeviceDetailKind))
        XCTAssertNil(try stateStore.failures(report: ReportEngine.schoolDeviceDetailKind))
    }

    /// Rows: device in trash; row with no UDID.
    func testTrashedAndUDIDlessDevicesAreNotCalled() async throws {
        let list = try deviceList(["u1"], extra: [
            ["udid": "trashed", "inTrash": true], ["name": "no udid"], ["udid": "-bad"],
        ])
        _ = try await runStep(list)
        XCTAssertEqual(calls().count, 1)
        XCTAssertTrue(calls()[0].contains(" devices get u1 "))
    }

    // MARK: - Results

    /// Rows rows on disk hold only the allow-list; All respond.
    func testAllRespondLandsRowsWithOnlyTheAllowList() async throws {
        let lines = try await runStep(deviceList(udids(3)))
        XCTAssertTrue(has(lines, "[ok] school-device-detail: 3 device(s)"))
        XCTAssertTrue(has(lines, "[info] school-device-detail took "))
        let rows = try XCTUnwrap(snapshotRows())
        XCTAssertEqual(rows.count, 3)
        for row in rows {
            XCTAssertEqual(
                Set(row.keys),
                ["udid", "serialNumber", "batteryLevel", "deviceEnrollType", "totalCapacity"])
        }
        XCTAssertFalse(try String(contentsOf: FileManager.newestSnapshotFile(
            in: dataDir.appendingPathComponent("school-device-detail"))!).contains("Secret"))
        XCTAssertNotNil(try stateStore.lastRun(report: ReportEngine.schoolDeviceDetailKind))
    }

    /// Row: wrong-type field.
    func testWrongTypeFieldsAreDroppedPerField() throws {
        let target = ReportEngine.SchoolScanTarget(udid: "u1", serial: "S1")
        let body = #"{"batteryLevel":"80","deviceEnrollType":7,"totalCapacity":128,"name":"x"}"#
        let row = try XCTUnwrap(ReportEngine.reduceSchoolDeviceDetail(Data(body.utf8), target: target))
        XCTAssertEqual(row, .init(udid: "u1", serialNumber: "S1", batteryLevel: nil,
                                  deviceEnrollType: nil, totalCapacity: 128))
        let bool = #"{"batteryLevel":true,"totalCapacity":-1}"#
        XCTAssertEqual(
            ReportEngine.reduceSchoolDeviceDetail(Data(bool.utf8), target: target)?.batteryLevel, nil)
        XCTAssertNil(ReportEngine.reduceSchoolDeviceDetail(Data("[]".utf8), target: target))
        // A device that reported none of the fields still gets a row.
        XCTAssertNotNil(ReportEngine.reduceSchoolDeviceDetail(Data("{}".utf8), target: target))
    }

    /// Rows: 25% do not respond lands with the info line; 26% stops, nothing written.
    func testGapsAtTheBudgetLandAndPastItStop() async throws {
        try answer("all.exit", "0")
        try answer("dev-u2.exit", "1")
        var lines = try await runStep(deviceList(udids(4)))
        XCTAssertTrue(has(lines, "[ok] school-device-detail: 3 device(s)"))
        XCTAssertTrue(has(lines, "[info] school-device-detail: 1 of 4 devices did not respond"))

        for u in ["u3", "u5"] { try answer("dev-\(u).exit", "1") }
        try FileManager.default.removeItem(at: dataDir.appendingPathComponent("school-device-detail"))
        try FileManager.default.removeItem(at: dataDir.appendingPathComponent("state"))
        lines = try await runStep(deviceList(udids(8)))
        XCTAssertTrue(has(lines, "[warn] school-device-detail not written: 3 of 8 devices did not respond"))
        XCTAssertNil(try snapshotRows())
        XCTAssertEqual(try stateStore.failures(report: ReportEngine.schoolDeviceDetailKind)?.count, 1)
    }

    /// Row: 200 targets, first 20 calls all exit 1.
    func testTwentyFailuresInARowStopAMuchLargerScan() async throws {
        try answer("all.exit", "1")
        let lines = try await runStep(deviceList(udids(200)))
        XCTAssertEqual(calls().count, 20)
        XCTAssertTrue(has(lines, "[warn] school-device-detail not written: the first 20 device calls all failed"))
    }

    /// Row: 15 targets, every call fails.
    func testFifteenTargetsAllFailingStopAtTheFourthFailure() async throws {
        try answer("all.exit", "1")
        let lines = try await runStep(deviceList(udids(15)))
        XCTAssertEqual(calls().count, 4)
        XCTAssertTrue(has(lines, "[warn] school-device-detail not written: 4 of 15"))
    }

    /// Four at a time: the calls already in flight when the stop is seen may still run.
    func testFourAtATimeStopsWithinTheInFlightCalls() async throws {
        try answer("all.exit", "1")
        _ = try await runStep(deviceList(udids(15)), limits: .init(concurrency: 4))
        XCTAssertLessThanOrEqual(calls().count, 4 + 3)
    }

    /// Row: alternating timeout and success.
    func testAlternatingTimeoutsStopAtTheBudget() async throws {
        for u in ["u1", "u3", "u5", "u7"] { try answer("dev-\(u).sleep", "") }
        var limits = ReportEngine.SchoolDeviceScanLimits(concurrency: 1)
        limits.calls = .init(timeout: 0.5)
        let lines = try await runStep(deviceList(udids(8)), limits: limits)
        XCTAssertTrue(has(lines, "[warn] school-device-detail not written: 3 of 8 devices did not respond"))
        XCTAssertNil(try snapshotRows())
    }

    /// Row: the 60-minute deadline (a short one injected) records exit -2.
    func testTheDeadlineStopsTheScanAndRecordsATimeout() async throws {
        for u in udids(10) { try answer("dev-\(u).delay", "0.3") }
        var limits = ReportEngine.SchoolDeviceScanLimits(concurrency: 1)
        limits.deadline = 0.5
        let lines = try await runStep(deviceList(udids(10)), limits: limits)
        XCTAssertTrue(has(lines, "[warn] school-device-detail not written: stopped after"))
        XCTAssertEqual(
            try stateStore.lastFailureExitCode(for: ReportEngine.schoolDeviceDetailKind),
            CLIBridge.exitCodeTimedOut)
        XCTAssertLessThan(calls().count, 10)
    }

    /// Row: exit 3 on a device.
    func testExitThreeStopsWithTheExitRecordedAndNoTokenProbe() async throws {
        try answer("dev-u2.exit", "3")
        let lines = try await runStep(deviceList(udids(10)))
        XCTAssertEqual(calls().count, 2)
        XCTAssertFalse(calls().contains { $0.contains("auth token") })
        XCTAssertEqual(try stateStore.lastFailureExitCode(for: ReportEngine.schoolDeviceDetailKind), 3)
        XCTAssertTrue(has(lines, "[warn] school-device-detail not written: a device call exited 3"))
    }

    /// Row: zero devices.
    func testZeroDevicesLandsAnEmptySnapshot() async throws {
        let lines = try await runStep(Data("[]".utf8))
        XCTAssertEqual(try snapshotRows()?.count, 0)
        XCTAssertTrue(has(lines, "[ok] school-device-detail: 0 device(s)"))
        XCTAssertTrue(calls().isEmpty)
    }

    /// Row: peer Mac starts while this scan runs. The stub sees the stamp on its first call.
    func testTheAttemptStampIsWrittenWhenTheScanStarts() async throws {
        _ = try await runStep(deviceList(["u1"]))
        let seen = try String(contentsOf: answers.appendingPathComponent("stamped"), encoding: .utf8)
        XCTAssertEqual(seen, "yes\n")
        XCTAssertEqual(
            ReportEngine.planSchoolDeviceScan(
                tiers: [.scan], collectSkip: [], stateStore: try stateStore, now: now),
            .notDue(lastAttempt: Date(timeIntervalSince1970: floor(now.timeIntervalSince1970))))
    }

    // MARK: - The plan

    /// Rows: scan-only School run, scan not due; scan-only run, scan due, school-devices
    /// collected 2 hours ago.
    func testScanOnlyRunCollectsSchoolDevicesOnlyWhenTheScanIsDue() {
        let twoHoursAgo = now.addingTimeInterval(-7_200)
        let notDue = ReportEngine.planSchoolCollect(
            profile: "p", tiers: [.scan], force: false, now: now, scanDue: false) { _ in twoHoursAgo }
        XCTAssertTrue(notDue.allSatisfy { $0.skip != nil }, "collects nothing, as before")
        let due = ReportEngine.planSchoolCollect(
            profile: "p", tiers: [.scan], force: false, now: now, scanDue: true) { _ in twoHoursAgo }
        XCTAssertEqual(due.filter { $0.skip == nil }.map(\.kind), ["school-devices"])
        let withoutScanTier = ReportEngine.planSchoolCollect(
            profile: "p", tiers: [.refresh], force: false, now: now, scanDue: true) { _ in twoHoursAgo }
        XCTAssertTrue(withoutScanTier.allSatisfy { $0.skip != nil }, "the 12-hour cadence still holds")
    }

    func testPlanTextsAndSourceListing() {
        XCTAssertEqual(
            ReportEngine.SchoolDeviceScanPlan.due.planText, "device scan: due")
        XCTAssertEqual(
            ReportEngine.SchoolDeviceScanPlan.notDue(lastAttempt: nil).planText,
            "device scan: not due (last attempt: never)")
        let plan = CollectSourcesPlan.build(.init(
            product: .jamfSchool, profile: "p", collectSkip: [ReportEngine.schoolDeviceDetailKind]))
        let source = plan.sources.first { $0.kind == ReportEngine.schoolDeviceDetailKind }
        XCTAssertEqual(source?.product, .school)
        XCTAssertNotNil(source?.skipReason)
        XCTAssertFalse(ReportEngine.knownCollectKinds.contains(ReportEngine.schoolDeviceDetailKind))
    }

    // MARK: - Through the router

    private func routed(
        school: Bool, force: Bool = false, tiers: Set<CollectionTier> = Set(CollectionTier.allCases),
        schoolThrows: Error? = nil, list: Data?
    ) async throws -> (events: [String], thrown: Error?) {
        let stub = try makeStub()
        let config = try ConfigLoader.loadFromString(
            (school ? "school_cli:\n  enabled: true\n" : "")
                + "protect:\n  enabled: true\n  profile: \"my-protect\"\n")
        let events = LineBox()
        var thrown: Error?
        do {
            try await CollectRouter.run(
                workspace: try WorkspaceID(validating: profile), tiers: tiers, force: force,
                config: config, workspacePaths: WorkspacePaths.self, now: now,
                proCollect: { _, _, _, _, _, _, _ in .collected },
                schoolCollect: { _, _, _, _, _, _ in
                    events.append("school")
                    ReportEngine.landedSources?.schoolDevices = list
                    if let schoolThrows { throw schoolThrows }
                },
                protectCollect: { _, _, _ in events.append("protect"); return ["protect-alerts"] },
                resolved: { _ in nil },
                gate: { _, _, _, _, _, _ in .proceed(holdsClaim: false, coordinating: false) },
                locateJamfCLI: { stub }, schoolScanLimits: .init(concurrency: 1),
                onLine: { events.append($0.text) })
        } catch { thrown = error }
        return (events.texts, thrown)
    }

    /// Rows: scan fails mid-run; scan not written on a tick schedule; force: true on a
    /// 2-day-old attempt. The add-ons ran first and the router's result is untouched.
    func testAFailingScanRunsAfterTheAddOnsAndChangesNothing() async throws {
        try answer("all.exit", "1")
        let (events, thrown) = try await routed(school: true, list: deviceList(udids(8)))
        XCTAssertNil(thrown)
        let protect = try XCTUnwrap(events.firstIndex(of: "protect"))
        let warn = try XCTUnwrap(events.firstIndex { $0.hasPrefix("[warn] school-device-detail not written") })
        XCTAssertLessThan(protect, warn)
        XCTAssertFalse(events.contains { $0.contains("[partial]") })
        XCTAssertNil(try snapshotRows())
    }

    func testForceDoesNotBypassTheCadence() async throws {
        try stateStore.recordRun(
            report: ReportEngine.schoolDeviceDetailKind, at: now.addingTimeInterval(-2 * 86_400))
        let (_, thrown) = try await routed(school: true, force: true, list: deviceList(["u1"]))
        XCTAssertNil(thrown)
        XCTAssertTrue(calls().isEmpty)
    }

    func testARunThatThrowsAVerdictNeverScans() async throws {
        let (_, thrown) = try await routed(
            school: true, schoolThrows: ReportEngineError.authExpired(profile: profile, failedCount: 1),
            list: deviceList(["u1"]))
        XCTAssertNotNil(thrown)
        XCTAssertTrue(calls().isEmpty)
    }

    /// Row: Jamf Pro workspace.
    func testAJamfProWorkspaceNeverScans() async throws {
        _ = try await routed(school: false, list: deviceList(["u1"]))
        XCTAssertTrue(calls().isEmpty)
    }

    func testASuccessfulRoutedScanLands() async throws {
        let (events, thrown) = try await routed(school: true, list: deviceList(udids(2)))
        XCTAssertNil(thrown)
        XCTAssertTrue(events.contains("[ok] school-device-detail: 2 device(s)"))
        XCTAssertEqual(try snapshotRows()?.count, 2)
    }
    // MARK: - Review round

    /// Class 1: the resolver's tolerance applies, so a schedule that starts a little early on
    /// day 7 is due; day 6 is not.
    func testCadenceUsesTheResolverTolerance() throws {
        let store = try stateStore
        let kind = ReportEngine.schoolDeviceDetailKind
        try store.recordRun(report: kind, at: now.addingTimeInterval(-(7 * 86_400 - 120)))
        XCTAssertEqual(
            ReportEngine.planSchoolDeviceScan(
                tiers: [.scan], collectSkip: [], stateStore: store, now: now), .due)
        try store.recordRun(report: kind, at: now.addingTimeInterval(-6 * 86_400))
        if case .notDue = ReportEngine.planSchoolDeviceScan(
            tiers: [.scan], collectSkip: [], stateStore: store, now: now) {} else {
            XCTFail("six days is not due")
        }
    }

    /// A refused state folder plans as not due and says why; no scan, no stamp.
    func testAnUnavailableStateFolderIsNotDue() async throws {
        let plan = ReportEngine.planSchoolDeviceScan(
            tiers: [.scan], collectSkip: [], stateStore: nil, now: now)
        XCTAssertEqual(plan, .stateUnavailable)
        XCTAssertEqual(plan.planText, "device scan: not due (the state folder is not available)")
        let stub = try makeStub()
        let lines = LineBox()
        await ReportEngine.runSchoolDeviceScanStep(
            workspace: try WorkspaceID(validating: profile), school: profile,
            workspacePaths: WorkspacePaths.self, plan: plan, devicesData: try deviceList(["u1"]),
            locateJamfCLI: { stub }, limits: .init(), now: now, onLine: { lines.append($0.text) })
        XCTAssertTrue(lines.texts.isEmpty)
        XCTAssertTrue(calls().isEmpty)
    }

    /// Class 14: a cancelled scan admits no more calls, writes nothing, records no failure and
    /// leaves the next run due.
    func testCancellationStopsQuietlyAndLeavesTheScanDue() async throws {
        for u in udids(10) { try answer("dev-\(u).delay", "0.3") }
        let stub = try makeStub()
        let id = try WorkspaceID(validating: profile)
        let list = try deviceList(udids(10))
        let plan = ReportEngine.planSchoolDeviceScan(
            tiers: [.scan], collectSkip: [],
            stateStore: ReportEngine.schoolScanStateStore(dataDir: try dataDir), now: now)
        let when = now
        let lines = LineBox()
        let task = Task {
            await ReportEngine.runSchoolDeviceScanStep(
                workspace: id, school: "schoolscan", workspacePaths: WorkspacePaths.self,
                plan: plan, devicesData: list, locateJamfCLI: { stub },
                limits: .init(concurrency: 1), now: when, onLine: { lines.append($0.text) })
        }
        try await Task.sleep(nanoseconds: 700_000_000)
        task.cancel()
        await task.value
        XCTAssertLessThan(calls().count, 10)
        XCTAssertEqual(lines.texts.filter { $0.contains("cancelled") },
                       ["[info] school-device-detail: cancelled"])
        XCTAssertFalse(lines.texts.contains { $0.hasPrefix("[warn]") || $0.contains("did not respond") })
        XCTAssertNil(try snapshotRows())
        let store = try stateStore
        XCTAssertNil(store.failures(report: ReportEngine.schoolDeviceDetailKind))
        XCTAssertNil(store.lastRun(report: ReportEngine.schoolDeviceDetailKind))
        XCTAssertEqual(
            ReportEngine.planSchoolDeviceScan(
                tiers: [.scan], collectSkip: [], stateStore: store, now: now), .due)
    }

    /// The deadline reason names the limit in use.
    func testTheDeadlineReasonNamesTheInjectedLimit() async throws {
        for u in udids(10) { try answer("dev-\(u).delay", "0.3") }
        var limits = ReportEngine.SchoolDeviceScanLimits(concurrency: 1)
        limits.deadline = 0.5
        let lines = try await runStep(deviceList(udids(10)), limits: limits)
        XCTAssertTrue(has(lines, "[warn] school-device-detail not written: stopped after 0.5 seconds"))
    }

    /// The not-written lines are neither incomplete nor a reason to retry.
    func testNotWrittenLinesLeaveTheHonestyWatcherQuiet() async throws {
        try answer("all.exit", "1")
        let lines = try await runStep(deviceList(udids(8)))
        let watcher = CollectHonestyWatcher()
        for line in lines { watcher.observe(line) }
        XCTAssertFalse(lines.isEmpty)
        XCTAssertFalse(watcher.incomplete)
        XCTAssertFalse(watcher.retryCouldHelp(lastFailureRepeats: { _ in false }))
    }

    private func schoolCollectThroughTheStub(_ stub: URL) -> CollectRouter.SchoolCollect {
        { workspace, profile, paths, tiers, force, onLine in
            try await ReportEngine.schoolCollect(
                workspace: workspace, profile: profile, workspacePaths: paths, tiers: tiers,
                force: force, locateJamfCLI: { stub }, onLine: onLine)
        }
    }

    /// End to end: a due scan-only School run collects school-devices, then scans; the claim is
    /// released and this Mac's activity recorded before the first device call.
    func testAScanOnlyRunCollectsTheListThenScansAfterTheClaimIsReleased() async throws {
        try answer("list", String(decoding: try deviceList(udids(3)), as: UTF8.self))
        let stub = try makeStub()
        let config = try ConfigLoader.loadFromString("school_cli:\n  enabled: true\n")
        let lines = LineBox()
        let name = profile
        try await CollectRouter.run(
            workspace: try WorkspaceID(validating: profile), tiers: [.scan], config: config,
            workspacePaths: WorkspacePaths.self, now: now,
            schoolCollect: schoolCollectThroughTheStub(stub),
            protectCollect: { _, _, _ in [] }, resolved: { _ in nil },
            gate: { _, _, _, _, _, _ in
                SharedWorkspace.acquire(profile: name, operation: "collect", ttl: 3_600)
                return .proceed(holdsClaim: true, coordinating: true)
            },
            locateJamfCLI: { stub }, schoolScanLimits: .init(concurrency: 1),
            onLine: { lines.append($0.text) })
        let log = calls()
        XCTAssertEqual(log.filter { $0.contains(" devices list ") }.count, 1)
        XCTAssertEqual(log.filter { $0.contains(" devices get ") }.count, 3)
        XCTAssertFalse(log.contains { $0.contains(" overview ") }, "only the scan's input is collected")
        XCTAssertTrue(has(lines.texts, "[plan] device scan: due"))
        XCTAssertTrue(has(lines.texts, "[ok] school-device-detail: 3 device(s)"))
        let held = (try? String(contentsOf: answers.appendingPathComponent("claim-held"))) ?? ""
        XCTAssertEqual(held, "", "the claim is released before the scan")
        XCTAssertNotNil(try? String(contentsOf: answers.appendingPathComponent("activity-seen")))
    }

    /// A run whose `now` was captured before midnight keeps one day: the stamp is that instant.
    func testTheStampKeepsTheRunsOwnInstantAcrossMidnight() async throws {
        let beforeMidnight = Calendar.current.date(
            bySettingHour: 23, minute: 59, second: 58, of: now) ?? now
        let stub = try makeStub()
        let plan = ReportEngine.planSchoolDeviceScan(
            tiers: [.scan], collectSkip: [],
            stateStore: ReportEngine.schoolScanStateStore(dataDir: try dataDir), now: beforeMidnight)
        await ReportEngine.runSchoolDeviceScanStep(
            workspace: try WorkspaceID(validating: profile), school: profile,
            workspacePaths: WorkspacePaths.self, plan: plan, devicesData: try deviceList(["u1"]),
            locateJamfCLI: { stub }, limits: .init(concurrency: 1), now: beforeMidnight,
            onLine: { _ in })
        XCTAssertEqual(
            try stateStore.lastRun(report: ReportEngine.schoolDeviceDetailKind),
            Date(timeIntervalSince1970: floor(beforeMidnight.timeIntervalSince1970)))
    }
}

private final class LineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    var texts: [String] { lock.withLock { lines } }
    func append(_ text: String) { lock.withLock { lines.append(text) } }
}
