import XCTest
@testable import JamfReports

/// The `[plan]` block at the top of a collect's log: what the run will fetch, what it leaves
/// alone and why, and whether the device scan runs. It is built from the decisions the loop
/// then acts on, so the integration tests check it against the run's own log.
final class CollectPlanTests: XCTestCase {

    private let profile = "planprofile"
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func inputs(
        tiers: Set<CollectionTier> = Set(CollectionTier.allCases), force: Bool = false,
        skipExpensive: Bool = false, nonPlatformAuth: String? = nil, tenantLevel: Bool = false,
        collectSkip: Set<String> = [], dashboardSupported: Bool = true
    ) -> ReportEngine.CollectPlanInputs {
        ReportEngine.CollectPlanInputs(
            tiers: tiers, force: force, skipExpensive: skipExpensive,
            nonPlatformAuth: nonPlatformAuth, tenantLevel: tenantLevel, collectSkip: collectSkip,
            dashboardSupported: dashboardSupported, installedVersion: "1.29.0", now: now)
    }

    private var matrix: [(args: [String], kind: String)] {
        ReportEngine.collectCommandMatrix(profile: profile, specNames: true, staleDays: 30)
    }

    private func skip(
        _ kind: String, in plan: [ReportEngine.PlannedKind]
    ) -> ReportEngine.CollectSkipReason? {
        XCTAssertTrue(plan.contains { $0.kind == kind }, "\(kind) is not in the matrix")
        return plan.first { $0.kind == kind }?.skip
    }

    /// The kinds a block lists under the line that starts with `header`, continuation lines
    /// included.
    private func kinds(under header: String, in lines: [String]) -> [String]? {
        guard let start = lines.firstIndex(where: { $0.hasPrefix(header) }) else { return nil }
        var payload = ""
        for (offset, line) in lines[start...].enumerated() {
            if offset > 0, !line.hasPrefix("[plan]   ") { break }
            let text = offset == 0
                ? line.range(of: "): ").map { String(line[$0.upperBound...]) }
                    ?? line.range(of: " sources: ").map { String(line[$0.upperBound...]) } ?? ""
                : String(line.dropFirst("[plan]   ".count))
            payload += text + " "
        }
        return payload.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Decisions

    func testEachSkipHasItsOwnReasonInTheLoopsOrder() {
        let plan = ReportEngine.planCollect(
            commands: matrix,
            inputs: inputs(
                tiers: [.refresh, .inventory], nonPlatformAuth: "oauth2",
                collectSkip: ["update-status", "security"], dashboardSupported: false),
            lastRun: { $0 == "security" || $0 == "overview" ? self.now : nil })

        XCTAssertEqual(skip("update-status", in: plan), .collectSkip)
        XCTAssertEqual(skip("security", in: plan), .collectSkip,
                       "collect_skip is reported ahead of cadence")
        XCTAssertEqual(skip("compliance-rules", in: plan), .platformOnly(authMethod: "oauth2"))
        XCTAssertEqual(skip("dashboard", in: plan),
                       .dashboardUnsupported(installedVersion: "1.29.0"))
        XCTAssertEqual(skip("patch-device-failures", in: plan), .tierNotSelected(.scan))
        XCTAssertEqual(skip("overview", in: plan),
                       .notDue(lastRun: now, cadence: .seconds(43_200)))
        XCTAssertNil(skip("computers", in: plan), "never collected: due")
    }

    func testForceBypassesCadenceButNotCollectSkipOrTheTierSet() {
        let plan = ReportEngine.planCollect(
            commands: matrix,
            inputs: inputs(
                tiers: [.refresh], force: true, collectSkip: ["update-status"]),
            lastRun: { _ in self.now })
        XCTAssertNil(skip("overview", in: plan))
        XCTAssertEqual(skip("update-status", in: plan), .collectSkip)
        XCTAssertEqual(skip("computers", in: plan), .tierNotSelected(.inventory))
    }

    func testSettingsSkipsThePerDeviceKinds() {
        let plan = ReportEngine.planCollect(
            commands: matrix, inputs: inputs(skipExpensive: true), lastRun: { _ in nil })
        let skipped = plan.filter { $0.skip == .settingsSkipExpensive }.map(\.kind)
        XCTAssertEqual(
            Set(skipped),
            ReportEngine.expensivePerDeviceKinds.intersection(matrix.map(\.kind)))
        XCTAssertFalse(skipped.isEmpty)
    }

    func testTheSkipLineKeepsItsWording() {
        XCTAssertEqual(
            ReportEngine.CollectSkipReason.notDue(lastRun: nil, cadence: .seconds(60)).skipDetail,
            "not due (last: never, cadence: 60s)")
        XCTAssertEqual(
            ReportEngine.CollectSkipReason.platformOnly(authMethod: "oauth2").skipDetail,
            "requires a Platform API profile (auth-method is oauth2)")
        XCTAssertEqual(ReportEngine.CollectSkipReason.collectSkip.skipDetail,
                       "listed in jamf_cli.collect_skip")
        XCTAssertEqual(ReportEngine.CollectSkipReason.tierNotSelected(.scan).skipDetail,
                       "tier scan not selected")
        XCTAssertNil(ReportEngine.CollectSkipReason.settingsSkipExpensive.skipDetail,
                     "one aggregate line already names these")
    }

    // MARK: - Lines

    func testThePlanNamesWhatRunsAndGroupsWhatDoesNot() {
        let plan = ReportEngine.planCollect(
            commands: matrix,
            inputs: inputs(
                tiers: [.refresh, .inventory], nonPlatformAuth: "oauth2",
                collectSkip: ["update-status"], dashboardSupported: false),
            lastRun: { $0 == "overview" ? self.now : nil })
        let lines = ReportEngine.collectPlanLines(
            profile: profile, plan: plan, deviceScan: .tierNotSelected)

        let running = plan.filter { $0.skip == nil }.map(\.kind)
        let header = "[plan] profile \(profile) — collecting \(running.count) sources: security"
        XCTAssertTrue(lines[0].hasPrefix(header), lines[0])
        XCTAssertEqual(kinds(under: "[plan] profile", in: lines), running)
        XCTAssertEqual(kinds(under: "[plan] skipping 1 source (jamf_cli.collect_skip)", in: lines),
                       ["update-status"])
        XCTAssertEqual(kinds(under: "[plan] skipping 1 source (not due)", in: lines), ["overview"])
        let platformOnly = plan.filter {
            $0.skip == .platformOnly(authMethod: "oauth2")
        }.map(\.kind)
        XCTAssertEqual(platformOnly.count, ReportEngine.platformOnlyKinds.count)
        XCTAssertEqual(
            kinds(under: "[plan] skipping \(platformOnly.count) sources (requires a Platform API "
                  + "profile, auth-method is oauth2)", in: lines),
            platformOnly)
        XCTAssertEqual(
            lines.last, "[plan] device scan: not selected (tier scan is not in this run)")
    }

    func testALongListWrapsUnderTheLimitAndLosesNothing() {
        let longProfile = String(repeating: "p", count: 60)
        let plan = ReportEngine.planCollect(
            commands: matrix, inputs: inputs(), lastRun: { _ in nil })
        let lines = ReportEngine.collectPlanLines(
            profile: longProfile, plan: plan, deviceScan: .due)

        XCTAssertGreaterThan(lines.count, 3, "37 kinds do not fit on one line")
        for line in lines {
            XCTAssertLessThanOrEqual(line.count, 200, line)
            XCTAssertTrue(line.hasPrefix("[plan]"), line)
        }
        XCTAssertEqual(kinds(under: "[plan] profile", in: lines), plan.map(\.kind))
        XCTAssertEqual(lines.last, "[plan] device scan: due")
    }

    /// SOFA and the patch release dates are fetched after the matrix on the tier set alone,
    /// so the plan names them or the log would show two sources it never announced.
    func testTheSourcesFetchedAfterTheMatrixAreInThePlan() {
        XCTAssertEqual(ReportEngine.sourcesAfterMatrix(tiers: [.refresh], collectSkip: []),
                       ["sofa", "patch-release-dates"])
        XCTAssertEqual(
            ReportEngine.sourcesAfterMatrix(tiers: [.inventory, .scan], collectSkip: []), [])

        let plan = ReportEngine.planCollect(
            commands: matrix, inputs: inputs(tiers: [.refresh]), lastRun: { _ in nil })
        let lines = ReportEngine.collectPlanLines(
            profile: profile, plan: plan, afterMatrix: ["sofa", "patch-release-dates"],
            deviceScan: .tierNotSelected)
        let running = plan.filter { $0.skip == nil }.map(\.kind) + ["sofa", "patch-release-dates"]
        XCTAssertEqual(kinds(under: "[plan] profile", in: lines), running)
        XCTAssertTrue(lines[0].contains("collecting \(running.count) sources"), lines[0])
    }

    func testCountsAreSingularOrZeroWithoutAnEmptyList() {
        XCTAssertEqual(
            ReportEngine.collectPlanLines(profile: "a", running: ["school-overview"]),
            ["[plan] profile a — collecting 1 source: school-overview"])
        XCTAssertEqual(
            ReportEngine.collectPlanLines(profile: "a", running: []),
            ["[plan] profile a — collecting 0 sources"])
    }

    func testSchoolAndProtectListTheirKinds() {
        let protect = ["protect-overview", "protect-alerts", "protect-computers"]
        XCTAssertEqual(
            ReportEngine.collectPlanLines(profile: "prot", running: protect),
            ["[plan] profile prot — collecting 3 sources: "
                + "protect-overview, protect-alerts, protect-computers"])
    }

    // MARK: - Device scan

    func testTheDeviceScanPlanFollowsTheTierSettingsAndCadence() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-plan-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let store = StateFileStore(directory: dir)
        let all = Set(CollectionTier.allCases)
        func plan(
            _ tiers: Set<CollectionTier> = all, skipExpensive: Bool = false, force: Bool = false
        ) -> DeviceScanPlan {
            ReportEngine.planDeviceScan(
                tiers: tiers, skipExpensive: skipExpensive, force: force,
                stateStore: store, now: now)
        }

        XCTAssertEqual(plan([.refresh]), .tierNotSelected)
        XCTAssertEqual(plan(skipExpensive: true), .turnedOff)
        XCTAssertEqual(plan(), .due, "never attempted")

        let recent = now.addingTimeInterval(-3600)
        store.record(.landed, report: ReportEngine.ddmDeviceStatusKind, at: recent)
        XCTAssertEqual(plan(), .due, "one scan kind still has no attempt")
        store.record(.landed, report: ReportEngine.mdmCommandHealthKind, at: recent)
        XCTAssertEqual(plan(), .notDue(lastAttempt: recent))
        XCTAssertEqual(plan(force: true), .due, "force bypasses the cadence floor")
        XCTAssertEqual(DeviceScanPlan.notDue(lastAttempt: nil).planText,
                       "device scan: not due (last attempt: never)")
        XCTAssertEqual(DeviceScanPlan.turnedOff.planText,
                       "device scan: turned off (Settings: Skip expensive collections)")
    }

    // MARK: - A real run

    /// A stub jamf-cli (not named `jamf-cli`: the codesign gate refuses that) that logs its
    /// argv and answers every command with an empty list.
    private func makeRun() throws -> (stub: URL, calls: URL, state: StateFileStore) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("JRC-Plan-\(UUID().uuidString)", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("Jamf-Reports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspacesRoot.appendingPathComponent(profile, isDirectory: true),
            withIntermediateDirectories: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", workspacesRoot.path, 1)
        addTeardownBlock {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: root)
        }
        let calls = root.appendingPathComponent("calls.log")
        let stub = bin.appendingPathComponent("stub-cli")
        try "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"\(calls.path)\"\nprintf '[]'\nexit 0\n"
            .write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let workspace = try XCTUnwrap(ProfileService.workspaceURL(for: profile))
        try "jamf_cli:\n  profile: \"\(profile)\"\n  collect_skip: [update_status]\n".write(
            to: workspace.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
        let state = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
        return (stub, calls, state)
    }

    private func run(
        _ stub: URL, tiers: Set<CollectionTier> = Set(CollectionTier.allCases),
        skipExpensive: Bool = false, force: Bool = false
    ) async -> [String] {
        let lines = LineCollector()
        _ = try? await ReportEngine.collect(
            profile: profile, workspacePaths: WorkspacePaths.self, tiers: tiers,
            skipExpensive: skipExpensive, force: force,
            authConfirmationProbe: { _, _ in false }, locateJamfCLI: { stub },
            onLine: lines.append)
        return lines.texts
    }

    /// A matrix with a collect_skip entry and a not-due kind: the plan comes first, names the
    /// kinds that then run, in order, and the skips with their reasons; the run's own
    /// `collecting` and `[skip]` lines say the same, and jamf-cli is never asked for a skipped
    /// kind. The Refresh tier is left out so no SOFA feed is fetched.
    func testThePlanIsWhatTheRunThenDoes() async throws {
        let (stub, calls, state) = try makeRun()
        state.record(.landed, report: "computers", at: Date())
        let lines = await run(stub, tiers: [.inventory, .scan])

        let firstCollect = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("[info] collecting ") })
        let planLines = lines.filter { $0.hasPrefix("[plan]") }
        XCTAssertEqual(lines.firstIndex { $0.hasPrefix("[plan]") }, 0, "the plan opens the log")
        XCTAssertFalse(lines[firstCollect...].contains { $0.hasPrefix("[plan]") },
                       "all of the plan comes before the first command")

        let planned = try XCTUnwrap(kinds(under: "[plan] profile", in: planLines))
        let ran = lines.compactMap { line -> String? in
            guard line.hasPrefix("[info] collecting "),
                  line.hasSuffix(" for \(profile)") else { return nil }
            return String(line.dropFirst("[info] collecting ".count)
                .dropLast(" for \(profile)".count))
        }
        XCTAssertFalse(ran.isEmpty)
        XCTAssertEqual(planned, ran, "the kinds the plan names are the kinds that ran, in order")
        XCTAssertFalse(planned.contains("computers"))
        XCTAssertFalse(planned.contains("update-status"))
        XCTAssertEqual(kinds(under: "[plan] skipping 1 source (not due)", in: planLines),
                       ["computers"])
        XCTAssertEqual(
            kinds(under: "[plan] skipping 1 source (jamf_cli.collect_skip)", in: planLines),
            ["update-status"])
        XCTAssertEqual(
            kinds(under: "[plan] skipping 1 source (needs jamf-cli 1.31.0 or later)",
                  in: planLines), ["dashboard"])

        let skippedByTheRun = lines.compactMap { line -> String? in
            guard line.hasPrefix("[skip] "), !line.hasPrefix("[skip] device scan") else {
                return nil
            }
            return line.dropFirst("[skip] ".count).components(separatedBy: ":").first
        }
        let plannedSkips = planLines.filter { $0.hasPrefix("[plan] skipping") }
            .flatMap { kinds(under: $0, in: planLines) ?? [] }
        XCTAssertEqual(Set(skippedByTheRun), Set(plannedSkips),
                       "every skip the run logs is in the plan, and the plan adds none")
        XCTAssertTrue(skippedByTheRun.contains("computers"))

        XCTAssertTrue(planLines.contains("[plan] device scan: due"), "\(planLines)")
        let matrix = ReportEngine.collectCommandMatrix(
            profile: profile, specNames: false, staleDays: 30)
        let asked = ((try? String(contentsOf: calls, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
        // jamf-cli is given the matrix's arguments, then `--no-hints --no-version-check`.
        func wasAsked(_ args: [String]) -> Bool {
            let argv = args.joined(separator: " ")
            return asked.contains { $0 == argv || $0.hasPrefix(argv + " ") }
        }
        // The two benchmark reports ask `compliance-benchmarks list` first and run per title.
        for command in matrix where !ReportEngine.benchmarkReportKinds.contains(command.kind) {
            if ran.contains(command.kind) {
                XCTAssertTrue(wasAsked(command.args), "\(command.kind) was planned, not asked for")
                let left = state.lastRun(report: command.kind)
                    ?? state.failures(report: command.kind)?.last
                XCTAssertNotNil(left, "\(command.kind) ran, so it left state behind")
            } else {
                XCTAssertFalse(wasAsked(command.args), "\(command.kind) was asked for, unplanned")
            }
        }
    }

    /// A forced, tier-narrowed run with the per-device switch on says so in the plan.
    func testThePlanSaysWhySettingsAndTiersLeaveKindsOut() async throws {
        let (stub, _, _) = try makeRun()
        let lines = await run(stub, tiers: [.inventory, .scan], skipExpensive: true, force: true)
        let planLines = lines.filter { $0.hasPrefix("[plan]") }

        let perDevice = ReportEngine.expensivePerDeviceKinds
            .intersection(matrix.map(\.kind)).count
        XCTAssertGreaterThan(perDevice, 0)
        XCTAssertTrue(
            planLines.contains {
                $0.hasPrefix("[plan] skipping \(perDevice) sources (Settings: Skip expensive")
            }, "\(planLines)")
        XCTAssertTrue(lines.contains { $0.hasPrefix("[info] skipping per-device commands (") })
        XCTAssertTrue(
            planLines.contains(
                "[plan] device scan: turned off (Settings: Skip expensive collections)"),
            "\(planLines)")
        XCTAssertTrue(planLines.contains { $0.contains("(tier refresh not selected)") })
        let planned = try XCTUnwrap(kinds(under: "[plan] profile", in: planLines))
        XCTAssertFalse(planned.contains("ea-results"))
        XCTAssertFalse(planned.contains("patch-device-failures"))
    }

    /// A collect that does not inject `refreshSOFA` must not reach sofafeed.macadmins.io under
    /// XCTest: the default returns at once and creates nothing, where the real refresh would
    /// create `sofa/` before fetching.
    func testTheDefaultSOFARefreshDoesNothingUnderXCTest() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("JRC-SOFADefault-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let (snapshot, warnings) = await ReportEngine.defaultSOFARefresh(dir)
        XCTAssertTrue(snapshot.rows.isEmpty)
        XCTAssertTrue(warnings.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("sofa").path))
    }
}

private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    var append: @Sendable (CLIBridge.LogLine) -> Void {
        { line in self.lock.lock(); defer { self.lock.unlock() }; self.lines.append(line.text) }
    }
    var texts: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}
