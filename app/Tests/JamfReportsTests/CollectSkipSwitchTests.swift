import XCTest
@testable import JamfReports

/// The Data Sources switches: the writer of `jamf_cli.collect_skip`, the per-Mac pin that keeps a
/// peer's edit from turning a source off or on here, and the row state the card draws.
final class CollectSkipSwitchTests: XCTestCase {
    private let fileManager = FileManager.default
    private let profile = "switches"
    private var root: URL!
    private var workspace: URL!

    override func setUpWithError() throws {
        root = fileManager.temporaryDirectory
            .appendingPathComponent("jrc-switch-\(UUID().uuidString)", isDirectory: true)
        workspace = root.appendingPathComponent(profile, isDirectory: true)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        try? fileManager.removeItem(at: root)
    }

    private var configURL: URL { workspace.appendingPathComponent("config.yaml") }

    private func write(_ skip: String?, shared: Bool = true, extra: String = "") throws {
        let list = skip.map { "\n  collect_skip: \($0)" } ?? ""
        let text = (shared ? "shared_workspace:\n  enabled: true\n" : "")
            + "jamf_cli:\n  profile: \"\(profile)\"\(list)\n  use_cached_data: true\n" + extra
        try text.write(to: configURL, atomically: true, encoding: .utf8)
    }

    private func typed() throws -> [String]? {
        try ConfigLoader.load(from: configURL).jamfCli?.collectSkip
    }

    private func effective() throws -> (list: [String], drifted: Bool) {
        let read = SharedConfigPin.collectSkipList(configured: try typed(), profile: profile)
        return (read.effective, read.drifted)
    }

    private func expected() -> Set<String> {
        Set(WorkspaceStore.expectedKinds(profile: profile, jamfCLIVersion: nil, auth: nil))
    }

    private func plan() throws -> CollectSourcesPlan {
        let read = SharedConfigPin.collectSkipList(configured: try typed(), profile: profile)
        return CollectSourcesPlan.build(.init(
            product: .jamfPro, profile: profile, authMethod: "oauth2",
            collectSkipList: read.effective,
            collectSkipInFile: read.drifted ? try typed() ?? [] : nil))
    }

    private func source(_ kind: String, in plan: CollectSourcesPlan) throws
        -> CollectSourcesPlan.Source {
        try XCTUnwrap(plan.sources.first { $0.kind == kind }, kind)
    }

    // MARK: - Writer

    func testTheWriterAddsRemovesSortsAndKeepsTheOtherEntries() throws {
        try write("[update_status, Zeta_Typo]", shared: false)
        try CollectSkipConfigWriter.setCollecting("sofa", false, profile: profile)
        XCTAssertEqual(try typed(), ["Zeta_Typo", "sofa", "update_status"])
        let block = try XCTUnwrap(try ConfigLoader.load(from: configURL).jamfCli)
        XCTAssertEqual(block.useCachedData, true, "the rest of jamf_cli: stays")
        XCTAssertEqual(block.profile, profile)

        try CollectSkipConfigWriter.setCollecting("update-status", true, profile: profile)
        XCTAssertEqual(try typed(), ["Zeta_Typo", "sofa"], "removed by its normalized name")
        try CollectSkipConfigWriter.setCollecting("sofa", false, profile: profile)
        XCTAssertEqual(try typed(), ["Zeta_Typo", "sofa"], "already off: no second copy")
    }

    func testTheWriterRemovesTheKeyWhenTheListEmpties() throws {
        try write("[sofa]", shared: false)
        try CollectSkipConfigWriter.setCollecting("sofa", true, profile: profile)
        XCTAssertNil(try typed())
        XCTAssertFalse(try String(contentsOf: configURL, encoding: .utf8).contains("collect_skip"))
    }

    func testTheWriterRefusesACoreSourceAndAName() throws {
        try write(nil, shared: false)
        XCTAssertThrowsError(
            try CollectSkipConfigWriter.setCollecting("computers", false, profile: profile)
        ) { XCTAssertEqual($0 as? CollectSkipConfigWriter.WriteError, .coreSource("computers")) }
        XCTAssertThrowsError(
            try CollectSkipConfigWriter.setCollecting("not-a-kind", false, profile: profile)
        ) { XCTAssertEqual($0 as? CollectSkipConfigWriter.WriteError, .unknownSource("not-a-kind")) }
        XCTAssertNil(try typed())
    }

    /// The dependents follow `patch-status` at read time and are never written.
    func testTheWriterNeverWritesTheDependents() throws {
        try write(nil, shared: false)
        try CollectSkipConfigWriter.setCollecting("patch-status", false, profile: profile)
        XCTAssertEqual(try typed(), ["patch-status"])
        let kinds = expected()
        XCTAssertFalse(kinds.contains("patch-status"))
        XCTAssertFalse(kinds.contains("patch-release-dates"))
        XCTAssertFalse(kinds.contains("patch-device-failures"))
    }

    // MARK: - Pin

    func testALocalWorkspaceIsNotPinned() throws {
        try write("[sofa]", shared: false)
        XCTAssertEqual(try effective().list, ["sofa"])
        XCTAssertFalse(try effective().drifted)
        XCTAssertFalse(SharedConfigPin.hasPin(profile: profile))
    }

    func testFirstSightPinsTheListAsFound() throws {
        try write("[SOFA, update_status, computers]")
        XCTAssertEqual(try effective().list, ["computers", "sofa", "update-status"])
        XCTAssertEqual(
            SharedConfigPin.collectSkip(configured: try typed(), profile: profile),
            ["sofa", "update-status"], "narrowed to the optional kinds when read")
        XCTAssertFalse(try effective().drifted)
        XCTAssertTrue(SharedConfigPin.hasPin(profile: profile))
    }

    /// A peer turning a source off turns nothing off here until Confirm, in every reader.
    func testAPeerTurningASourceOffWaitsForConfirm() throws {
        try write("[sofa]")
        _ = try effective()
        try write("[sofa, policies]")
        XCTAssertEqual(try effective().list, ["sofa"])
        XCTAssertTrue(try effective().drifted)
        XCTAssertEqual(
            SharedConfigPin.collectSkip(configured: try typed(), profile: profile), ["sofa"])
        XCTAssertTrue(expected().contains("policies"))
        let plan = try plan()
        XCTAssertNil(try source("policies", in: plan).skipReason)
        XCTAssertEqual(plan.switchState(for: try source("policies", in: plan)),
                       .init(control: .on, changedOnAnotherMac: true))
        XCTAssertEqual(plan.switchState(for: try source("sofa", in: plan)),
                       .init(control: .off, changedOnAnotherMac: false))
        XCTAssertTrue(plan.changedOnAnotherMac)
        XCTAssertThrowsError(
            try CollectSkipConfigWriter.setCollecting("dashboard", false, profile: profile)
        ) { XCTAssertEqual($0 as? CollectSkipConfigWriter.WriteError, .changedOnAnotherMac) }

        let row = try XCTUnwrap(ConfigDoctorService.sharedConfigRows(profile: profile).first)
        let item = try XCTUnwrap(row.items.first { $0.id == "jamf_cli.collect_skip" })
        XCTAssertTrue(item.text.contains("\"sofa\""), item.text)
        XCTAssertTrue(item.text.contains("\"policies, sofa\""), item.text)
        guard case .confirmSharedConfig(let drifts)? = item.action else {
            return XCTFail("the block has its own Confirm")
        }
        try SharedConfigPin.confirm(profile: profile, drifts: drifts)
        XCTAssertEqual(try effective().list, ["policies", "sofa"])
        XCTAssertFalse(try effective().drifted)
        XCTAssertFalse(expected().contains("policies"))
    }

    /// A peer turning a source back on does not collect it here until Confirm.
    func testAPeerTurningASourceOnWaitsForConfirm() throws {
        try write("[sofa, policies]")
        _ = try effective()
        try write("[sofa]")
        XCTAssertEqual(try effective().list, ["policies", "sofa"])
        XCTAssertFalse(expected().contains("policies"))
        let plan = try plan()
        XCTAssertEqual(plan.switchState(for: try source("policies", in: plan)),
                       .init(control: .off, changedOnAnotherMac: true))
    }

    /// A pin that cannot be read turns nothing off and holds every switch: fails toward
    /// collecting, as an unreadable list in config.yaml does.
    func testAnUnreadablePinTurnsNothingOffAndHoldsTheSwitches() throws {
        try write("[sofa]")
        _ = try effective()
        let pin = try XCTUnwrap(
            SharedConfigPin.storeURL(workspace: profile, appSupport: AppSupport.directory()))
        try Data("not json".utf8).write(to: pin)
        XCTAssertEqual(try effective().list, [])
        XCTAssertTrue(try effective().drifted)
        XCTAssertThrowsError(
            try CollectSkipConfigWriter.setCollecting("policies", false, profile: profile)
        ) { XCTAssertEqual($0 as? CollectSkipConfigWriter.WriteError, .changedOnAnotherMac) }
    }

    /// The writer applies the Protect-only lock the screen shows.
    func testTheWriterKeepsAProtectOnlyComputerList() throws {
        try write(nil, shared: false, extra: "profiles:\n  protect: \"\(profile)\"\n")
        XCTAssertThrowsError(
            try CollectSkipConfigWriter.setCollecting("protect-computers", false, profile: profile)
        ) { XCTAssertEqual($0 as? CollectSkipConfigWriter.WriteError, .coreSource("protect-computers")) }
        try CollectSkipConfigWriter.setCollecting("protect-alerts", false, profile: profile)
        XCTAssertEqual(try typed(), ["protect-alerts"])
    }

    func testTheAppsOwnWriteIsConfirmed() throws {
        try write("[sofa]")
        _ = try effective()
        try CollectSkipConfigWriter.setCollecting("policies", false, profile: profile)
        XCTAssertEqual(try effective().list, ["policies", "sofa"])
        XCTAssertFalse(try effective().drifted)
        try CollectSkipConfigWriter.setCollecting("sofa", true, profile: profile)
        XCTAssertEqual(try effective().list, ["policies"])
        XCTAssertFalse(try effective().drifted)
    }

    // MARK: - Row state

    func testTheRowStateOfEachKindOfSource() throws {
        try write("[patch-status, sofa]", shared: false)
        let plan = try plan()
        func state(_ kind: String) throws -> CollectSourcesPlan.SourceSwitch {
            plan.switchState(for: try source(kind, in: plan)).control
        }
        XCTAssertEqual(try state("computers"), .locked)
        XCTAssertEqual(try state("policies"), .on)
        XCTAssertEqual(try state("sofa"), .off)
        XCTAssertEqual(try state("patch-status"), .off)
        XCTAssertEqual(try state("patch-release-dates"), .followsPatchStatus)
        XCTAssertEqual(try state("compliance-devices"), .hidden, "needs a Platform API profile")
        XCTAssertFalse(plan.changedOnAnotherMac)

        let expensive = CollectSourcesPlan.build(.init(
            product: .jamfPro, profile: profile, skipExpensive: true, authMethod: "oauth2"))
        XCTAssertEqual(
            expensive.switchState(for: try source("ddm-device-status", in: expensive)).control,
            .hidden, "Settings' switch decides, not this one")

        let protectOnly = CollectSourcesPlan.build(.init(
            product: .jamfPro, profile: profile, protectProfile: "p", protectOnly: true))
        XCTAssertEqual(
            protectOnly.switchState(for: try source("protect-computers", in: protectOnly)).control,
            .locked)
        XCTAssertEqual(
            protectOnly.switchState(for: try source("protect-alerts", in: protectOnly)).control,
            .on)
    }

    // MARK: - Every product honours it

    func testASchoolWorkspaceDoesNotExpectATurnedOffSource() throws {
        try write("[school-users]", shared: false, extra: "school_cli:\n  enabled: true\n")
        let kinds = expected()
        XCTAssertFalse(kinds.contains("school-users"))
        XCTAssertTrue(kinds.contains("school-devices"))
    }

    func testTheDeviceScanSkipsOnlyWhatIsTurnedOff() throws {
        let both: Set<String> = [ReportEngine.ddmDeviceStatusKind, ReportEngine.mdmCommandHealthKind]
        XCTAssertEqual(
            ReportEngine.planDeviceScan(
                tiers: [.scan], skipExpensive: false, force: true, collectSkip: both,
                stateStore: nil, now: Date()),
            .listedInCollectSkip)
        // History landed now, DDM never: due only while DDM is on.
        let state = root.appendingPathComponent("scan-state", isDirectory: true)
        try fileManager.createDirectory(at: state, withIntermediateDirectories: true)
        let store = StateFileStore(directory: state)
        let now = Date()
        store.record(.landed, report: ReportEngine.mdmCommandHealthKind, at: now)
        func plan(_ skip: Set<String>) -> DeviceScanPlan {
            ReportEngine.planDeviceScan(
                tiers: [.scan], skipExpensive: false, force: false, collectSkip: skip,
                stateStore: store, now: now)
        }
        XCTAssertEqual(plan([]), .due)
        guard case .notDue = plan([ReportEngine.ddmDeviceStatusKind]) else {
            return XCTFail("with DDM off, only the history kind's cadence counts")
        }
    }

    /// A round started with another set of scan kinds turned off is not continued.
    func testAScanRoundIsContinuedOnlyWithTheSameKindsTurnedOff() {
        let round = DeviceScanRound(
            started: Date(), lastPass: Date(), attempted: ["1"], remaining: 3,
            turnedOff: [ReportEngine.mdmCommandHealthKind])
        XCTAssertNotNil(ReportEngine.continuedRound(
            round, collectSkip: [ReportEngine.mdmCommandHealthKind]))
        XCTAssertNil(ReportEngine.continuedRound(round, collectSkip: []))
        var older = round
        older.turnedOff = nil
        XCTAssertNotNil(ReportEngine.continuedRound(older, collectSkip: []))
        XCTAssertNil(ReportEngine.continuedRound(
            older, collectSkip: [ReportEngine.ddmDeviceStatusKind]))
    }

    // MARK: - Review fixes

    /// A peer's edit landing between this Mac's check and its write is neither overwritten nor
    /// confirmed.
    func testAPeerEditDuringTheWriteIsNotConfirmed() throws {
        try write("[sofa]")
        _ = try effective()
        XCTAssertThrowsError(
            try CollectSkipConfigWriter.setCollecting(
                "policies", false, profile: profile,
                beforeWrite: { try? self.write("[sofa, dashboard]") })
        ) { XCTAssertEqual($0 as? CollectSkipConfigWriter.WriteError, .changedOnAnotherMac) }
        XCTAssertEqual(try typed(), ["sofa", "dashboard"], "the peer's file is left as it is")
        XCTAssertEqual(try effective().list, ["sofa"])
        XCTAssertTrue(try effective().drifted)
    }

    /// config.yaml unreadable on a pinned workspace: the pin's list holds, in every reader.
    func testAnUnreadableConfigKeepsThePinnedList() throws {
        try write("[policies, school-device-detail]")
        _ = try effective()
        try fileManager.removeItem(at: configURL)
        let read = SharedConfigPin.collectSkipList(configured: nil, profile: profile)
        XCTAssertEqual(read.effective, ["policies", "school-device-detail"])
        XCTAssertTrue(read.drifted)
        XCTAssertTrue(ReportEngine.schoolScanTurnedOff(profile: profile))
        XCTAssertFalse(expected().contains("policies"))
    }

    /// A pin from before the key takes only what earlier builds honoured; the rest is drift.
    func testAnUpgradedPinTakesOnlyTheEntriesEarlierBuildsHonoured() throws {
        try write("[sofa]")
        _ = try effective()
        let support = AppSupport.directory()
        var pin = try XCTUnwrap(SharedConfigPin.load(profile: profile, appSupport: support))
        pin.pinnedKeys.removeAll { $0 == SharedConfigPin.Key.collectSkip.rawValue }
        pin.collectSkip = ""
        try SharedConfigPin.save(pin, profile: profile, appSupport: support)
        try write("[sofa, policies, update_status]")
        XCTAssertEqual(try effective().list, ["sofa", "update-status"])
        XCTAssertTrue(try effective().drifted, "policies waits for a Confirm")
    }

    /// The pin holds every typed name; a name that turns nothing off today is no drift.
    func testThePinHoldsEveryTypedName() throws {
        try write("[sofa, Not_A_Kind, computers]")
        _ = try effective()
        XCTAssertEqual(
            SharedConfigPin.load(profile: profile, appSupport: AppSupport.directory())?
                .collectSkip, "computers, not-a-kind, sofa")
        XCTAssertFalse(try effective().drifted)
    }

    @MainActor
    func testTheLaunchAuditSweepLeavesATurnedOffAuditAlone() async throws {
        let calls = CallCount()
        for (list, expectsAudit) in [("[]", true), ("[audit]", false)] {
            try write(list, shared: false)
            let store = WorkspaceStore(demoMode: false)
            store.profile = profile
            calls.reset()
            await store.autoRefreshAuditIfStale(audit: { _ in calls.hit(); return 0 })
            XCTAssertEqual(calls.value > 0, expectsAudit, list)
        }
    }

    func testTheDashboardLeavesProtectOutWhenEveryProtectSourceIsOff() async {
        let lines = SwitchLines()
        let bin = URL(fileURLWithPath: "/nonexistent/stub-cli")
        let all = Set(ReportEngine.protectReportKinds)
        let left = await ReportEngine.dashboardProtect(
            "p", bin: bin, collectSkip: all, onLine: lines.append)
        XCTAssertNil(left)
        XCTAssertTrue(lines.texts.contains { $0.hasPrefix("[warn] dashboard: Protect left out:") })
        let kept = await ReportEngine.dashboardProtect(
            "p", bin: bin, collectSkip: ["protect-alerts"], onLine: { _ in })
        XCTAssertEqual(kept, "p")
    }

    /// A real School collect on a pinned workspace skips the pinned source, not the file's.
    func testASchoolCollectOnAPinnedWorkspaceFollowsThePin() async throws {
        try write("[school-users]")
        _ = try effective()
        try write("[school-apps]")
        let bin = root.appendingPathComponent("stub-cli")
        try "#!/bin/sh\nexit 1\n".write(to: bin, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        let stub: URL = bin
        let seen = SwitchLines()
        _ = try? await ReportEngine.schoolCollect(
            workspace: WorkspaceID(validating: profile), profile: profile,
            workspacePaths: WorkspacePaths.self, force: true, locateJamfCLI: { stub },
            onLine: seen.append)
        XCTAssertTrue(seen.texts.contains("[skip] school-users: listed in jamf_cli.collect_skip"))
        XCTAssertTrue(seen.texts.contains("[info] collecting school-apps for \(profile)"))
    }

    /// School and Protect collect through planners that honour the list: a plan line, a skip
    /// line, no command and no record for the turned-off source.
    func testTheSchoolAndProtectCollectsSkipATurnedOffSource() async throws {
        try write("[school-users]", shared: false)
        let bin = root.appendingPathComponent("stub-cli")
        try "#!/bin/sh\nexit 1\n".write(to: bin, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        let stub: URL = bin
        let data = try WorkspacePaths.dataDir(for: profile)
        try fileManager.createDirectory(at: data, withIntermediateDirectories: true)
        let seen = SwitchLines()

        _ = try await ReportEngine.protectCollect(
            profile: profile, dataDir: data, collectSkip: ["protect-alerts"],
            locateJamfCLI: { stub }, readVersion: { _ in "1.38.0" }, onLine: seen.append)
        _ = try? await ReportEngine.schoolCollect(
            workspace: WorkspaceID(validating: profile), profile: profile,
            workspacePaths: WorkspacePaths.self, force: true, locateJamfCLI: { stub },
            onLine: seen.append)

        let lines = seen.texts
        for kind in ["protect-alerts", "school-users"] {
            XCTAssertTrue(
                lines.contains("[plan] skipping 1 source (jamf_cli.collect_skip): \(kind)"),
                "\(lines)")
            XCTAssertTrue(lines.contains("[skip] \(kind): listed in jamf_cli.collect_skip"))
            XCTAssertFalse(lines.contains("[info] collecting \(kind) for \(profile)"))
        }
        let store = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
        XCTAssertNil(store.failures(report: "protect-alerts"))
        XCTAssertNil(store.failures(report: "school-users"))
        XCTAssertNotNil(store.failures(report: "protect-overview"), "the others still ran")
        XCTAssertNotNil(store.failures(report: "school-devices"))
    }
}

private final class CallCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func hit() { lock.lock(); count += 1; lock.unlock() }
    func reset() { lock.lock(); count = 0; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private final class SwitchLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    var append: @Sendable (CLIBridge.LogLine) -> Void {
        { line in
            self.lock.lock(); defer { self.lock.unlock() }
            self.lines.append(line.text)
        }
    }

    var texts: [String] {
        lock.lock(); defer { lock.unlock() }
        return lines
    }
}
