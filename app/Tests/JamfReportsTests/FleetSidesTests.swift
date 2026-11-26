import XCTest
@testable import JamfReports

/// Fleet-aware collecting: a side of the Jamf Pro fleet with no devices is not collected until
/// the overview counts one, with a weekly check on its own list. Every device is invented.
final class FleetSidesTests: XCTestCase {
    private var root: URL!
    private var dataDir: URL!

    override func setUpWithError() throws {
        root = GoldenFleetWorkspace.freshRoot()
        dataDir = root.appendingPathComponent("jamf-cli-data", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private let now = Date()

    private func fleetRow(_ resource: String, _ value: Any) -> [String: Any] {
        ["section": "Fleet", "resource": resource, "value": value]
    }

    private func overviewRows(computers: Int, mobile: Int) -> [[String: Any]] {
        [fleetRow("Managed Computers", computers), fleetRow("Unmanaged Computers", 0),
         fleetRow("Managed Devices", mobile), fleetRow("Unmanaged Devices", 0)]
    }

    private func writeOverview(computers: Int, mobile: Int, age: TimeInterval = 3600) throws {
        try GoldenFleetWorkspace.writeSnapshot(
            kind: "overview", dataDir: dataDir, at: now.addingTimeInterval(-age),
            rows: overviewRows(computers: computers, mobile: mobile))
    }

    private func writeList(_ side: FleetSide, rows: Int, age: TimeInterval = 3600) throws {
        let items: [[String: Any]] = (0..<rows).map { ["id": "\($0)", "name": "Device \($0)"] }
        try GoldenFleetWorkspace.writeSnapshot(
            kind: side.listKind, dataDir: dataDir, at: now.addingTimeInterval(-age), rows: items)
    }

    private func load() -> FleetState { FleetState.load(dataDir: dataDir, now: now) }

    // MARK: - Classification

    func testTheCertificateAuthorityIsOnBothSidesSoNoFleetSkipsIt() {
        XCTAssertEqual(ReportEngine.sourceSides["certificate-authority"], SourceSides.both)
    }

    func testEveryJamfProSourceHasASide() {
        let classified = Set(ReportEngine.sourceSides.keys)
        let matrix = Set(ReportEngine.collectCommandMatrix(profile: "p", staleDays: 30).map(\.kind))
        XCTAssertTrue(matrix.isSubset(of: classified), "\(matrix.subtracting(classified))")
        for kind in [ReportEngine.ddmDeviceStatusKind, ReportEngine.mdmCommandHealthKind,
                     ReportEngine.sofaKind, ReportEngine.patchReleaseDatesKind] {
            XCTAssertNotNil(ReportEngine.sourceSides[kind], kind)
        }
        XCTAssertEqual(classified, Set(ReportEngine.knownCollectKinds))
        XCTAssertEqual(ReportEngine.sourceSides["mobile-devices-list"], .mobile)
        XCTAssertEqual(ReportEngine.sourceSides["computers"], .mac)
        XCTAssertEqual(ReportEngine.sourceSides["overview"], .both)
    }

    // MARK: - Presence

    func testPresenceReadsExactFleetRowsAsWholeNumbers() {
        let state = FleetState.presence(overview: [
            fleetRow("Managed Computers", "1,200"), fleetRow("Unmanaged Computers", 3),
            fleetRow("Managed Devices", 0), fleetRow("Unmanaged Devices", "0"),
        ])
        XCTAssertEqual(state.computers, 1203)
        XCTAssertEqual(state.mobileDevices, 0)

        let odd = FleetState.presence(overview: [
            ["section": "fleet", "resource": "Managed Computers", "value": 4],
            fleetRow("Unmanaged Computers", 0),
            fleetRow("Managed Devices", "N/A"), fleetRow("Unmanaged Devices", 0),
        ])
        XCTAssertNil(odd.computers, "the section name is exact")
        XCTAssertNil(odd.mobileDevices, "not a whole number")
        XCTAssertNil(FleetState.presence(overview: [fleetRow("Managed Devices", 2)]).mobileDevices,
                     "a missing addend is unknown")
        XCTAssertNil(FleetState.presence(overview: [
            fleetRow("Managed Devices", 2.5), fleetRow("Unmanaged Devices", 0),
        ]).mobileDevices)
    }

    func testAStaleUnreadableOrMissingOverviewIsUnknown() throws {
        XCTAssertEqual(load(), .unknown, "a new workspace skips nothing")
        try writeOverview(computers: 5, mobile: 0, age: 49 * 3600)
        try writeList(.mobile, rows: 0)
        XCTAssertEqual(load(), .unknown, "older than 48 hours")
        let bad = dataDir.appendingPathComponent("overview")
            .appendingPathComponent("overview_\(GoldenFleetClock.stamp(now)).json")
        try "not json".write(to: bad, atomically: true, encoding: .utf8)
        XCTAssertEqual(load(), .unknown)
    }

    // MARK: - Skip rule

    func testASideIsSkippedOnlyWhenEveryConditionHolds() throws {
        try writeOverview(computers: 5, mobile: 0)
        XCTAssertEqual(load().skipped, [], "no mobile list yet: collect it once")
        try writeList(.mobile, rows: 2)
        XCTAssertEqual(load().skipped, [], "the list still holds devices")
        try writeList(.mobile, rows: 0, age: 60)
        XCTAssertEqual(load().skipped, [.mobile])
        XCTAssertEqual(load().computers, 5)

        try writeOverview(computers: 5, mobile: 1, age: 30)
        XCTAssertEqual(load().skipped, [], "a device in the overview resumes collecting")
    }

    func testAFutureStampedEmptyListSkipsNoSide() throws {
        try writeOverview(computers: 0, mobile: 3)
        try writeList(.mac, rows: 0, age: -SharedWorkspace.clockSkewTolerance * 2)
        XCTAssertEqual(load().skipped, [], "a planted future file must not skip Macs for good")
    }

    func testTheWeeklyRecheckCollectsAnOldEmptyList() throws {
        try writeOverview(computers: 0, mobile: 4)
        try writeList(.mac, rows: 0, age: 8 * 86_400)
        XCTAssertEqual(load().skipped, [])
        try writeList(.mac, rows: 0, age: 6 * 86_400)
        XCTAssertEqual(load().skipped, [.mac])
        XCTAssertTrue(load().isMobileOnly)
    }

    // MARK: - Plan

    func testForcedRunsSkipTheSideAndSayWhy() {
        var inputs = ReportEngine.CollectPlanInputs(
            tiers: Set(CollectionTier.allCases), force: true, skipExpensive: false,
            nonPlatformAuth: nil, tenantLevel: false, collectSkip: [],
            installedVersion: nil, now: now)
        inputs.skippedSides = [.mobile]
        let plan = ReportEngine.planCollect(
            commands: ReportEngine.collectCommandMatrix(profile: "p", staleDays: 30),
            inputs: inputs, lastRun: { _ in nil })
        let skipped = plan.filter { $0.skip == .noDevices(.mobile) }.map(\.kind)
        XCTAssertEqual(Set(skipped), ["mobile-devices-list", "classic-mobile-device-groups",
                                      "advanced-mobile-device-searches", "classic-ios-profiles"])
        XCTAssertNil(plan.first { $0.kind == "computers" }?.skip)
        let lines = ReportEngine.collectPlanLines(profile: "p", plan: plan, deviceScan: .due)
        XCTAssertTrue(lines.contains { $0.hasPrefix(
            "[plan] skipping 4 sources (no mobile devices in Jamf Pro)") }, "\(lines)")
        XCTAssertEqual(ReportEngine.CollectSkipReason.noDevices(.mobile).skipDetail,
                       "no mobile devices in Jamf Pro (overview); checked again weekly")

        XCTAssertEqual(
            ReportEngine.planDeviceScan(tiers: [.scan], skipExpensive: false, force: true,
                                        skippedSides: [.mac], stateStore: nil, now: now),
            .noComputers)
        XCTAssertEqual(
            ReportEngine.sourcesAfterMatrix(
                tiers: [.refresh], collectSkip: [], skippedSides: [.mac]), ["sofa"])
    }

    func testTheFreshnessStripDoesNotExpectASkippedSide() {
        let mobileOff = Set(WorkspaceStore.expectedKinds(
            skipExpensive: false, authMethod: "oauth2", skippedSides: [.mobile]))
        XCTAssertFalse(mobileOff.contains("mobile-devices-list"))
        XCTAssertTrue(mobileOff.contains("computers"))
        let macOff = Set(WorkspaceStore.expectedKinds(
            skipExpensive: false, authMethod: "oauth2", skippedSides: [.mac]))
        XCTAssertFalse(macOff.contains("computers"))
        XCTAssertFalse(macOff.contains(ReportEngine.ddmDeviceStatusKind))
        XCTAssertFalse(macOff.contains(ReportEngine.patchReleaseDatesKind))
        XCTAssertTrue(macOff.contains("overview"))
    }

    // MARK: - Core set

    func testTheCoreSetFollowsTheFleet() {
        XCTAssertTrue(ReportEngine.isCoreKind("security"))
        XCTAssertFalse(ReportEngine.isCoreKind("mobile-devices-list"), "mixed or unknown")
        let mobileOnly = FleetState(computers: 0, mobileDevices: 5, skipped: [.mac])
        XCTAssertTrue(ReportEngine.isCoreKind("mobile-devices-list", fleet: mobileOnly))
        XCTAssertFalse(ReportEngine.isCoreKind("security", fleet: mobileOnly))
        XCTAssertTrue(ReportEngine.isCoreKind("overview", fleet: mobileOnly))
        let macOnly = FleetState(computers: 5, mobileDevices: 0, skipped: [.mobile])
        XCTAssertFalse(ReportEngine.isCoreKind("mobile-devices-list", fleet: macOnly))
        XCTAssertTrue(ReportEngine.isCoreKind("computers", fleet: macOnly))
    }

    func testTheRowStateFollowsTheFleet() throws {
        func plan(_ fleet: FleetState) -> CollectSourcesPlan {
            CollectSourcesPlan.build(.init(
                product: .jamfPro, profile: "p", authMethod: "oauth2", fleet: fleet))
        }
        func state(_ kind: String, _ plan: CollectSourcesPlan) throws
            -> CollectSourcesPlan.SourceSwitch {
            plan.switchState(for: try XCTUnwrap(plan.sources.first { $0.kind == kind })).control
        }
        let macOnly = plan(FleetState(computers: 5, mobileDevices: 0, skipped: [.mobile]))
        XCTAssertEqual(try state("mobile-devices-list", macOnly), .noDevices(.mobile))
        XCTAssertEqual(try state("computers", macOnly), .locked)
        XCTAssertNotNil(macOnly.sources.first { $0.kind == "classic-ios-profiles" }?.skipReason)

        let mobileOnly = plan(FleetState(computers: 0, mobileDevices: 5, skipped: [.mac]))
        XCTAssertEqual(try state("mobile-devices-list", mobileOnly), .locked)
        XCTAssertEqual(try state("security", mobileOnly), .noDevices(.mac))
        XCTAssertEqual(try state(ReportEngine.ddmDeviceStatusKind, mobileOnly), .noDevices(.mac))
        XCTAssertEqual(try state("overview", mobileOnly), .locked)

        XCTAssertEqual(try state("mobile-devices-list", plan(.unknown)), .on)
    }

    /// The writer asks the same question: on a mobile-only fleet the mobile list is core.
    func testTheWriterFollowsTheFleet() throws {
        let profile = "fleetwriter"
        let workspaces = root.appendingPathComponent("ws", isDirectory: true)
        let ws = workspaces.appendingPathComponent(profile, isDirectory: true)
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", workspaces.path, 1)
        defer { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
        try "jamf_cli:\n  profile: \"\(profile)\"\n".write(
            to: ws.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
        dataDir = try WorkspacePaths.dataDir(for: profile)
        try writeOverview(computers: 0, mobile: 3)
        try writeList(.mac, rows: 0)
        XCTAssertThrowsError(
            try CollectSkipConfigWriter.setCollecting("mobile-devices-list", false, profile: profile)
        ) {
            XCTAssertEqual($0 as? CollectSkipConfigWriter.WriteError,
                           .coreSource("mobile-devices-list"))
        }
        try writeOverview(computers: 2, mobile: 3, age: 30)
        XCTAssertNoThrow(
            try CollectSkipConfigWriter.setCollecting("mobile-devices-list", false, profile: profile))
    }

    // MARK: - Summary

    /// A mobile-only fleet writes its summary, and an old Mac snapshot does not count Macs.
    func testAMobileOnlyFleetStillWritesItsSummary() throws {
        try writeOverview(computers: 0, mobile: 3)
        try writeList(.mac, rows: 0)
        try GoldenFleetWorkspace.writeSnapshot(
            kind: "security", dataDir: dataDir, at: now.addingTimeInterval(-86_400),
            rows: GoldenFleetWorkspace.securitySummaryPayload(
                total: 40, filevault: 40, sip: 40, firewall: 40, gatekeeper: 40))
        let mobile: [[String: Any]] = (0..<3).map {
            ["id": "\($0)", "name": "Device \($0)", "serialNumber": "MSER\($0)",
             "deviceType": "iOS", "hardware": ["model": "iPad Air"]]
        }
        try GoldenFleetWorkspace.writeSnapshot(
            kind: MobileFleetService.deviceKind, dataDir: dataDir, at: now, rows: mobile)
        let summaries = root.appendingPathComponent("summaries", isDirectory: true)
        ReportEngine(config: ReportConfig(), dataDir: dataDir).emitSummaryJSON(
            summariesDir: summaries)
        let summary = try XCTUnwrap(SummaryJSONParser.parseDirectory(summaries).first)
        XCTAssertEqual(summary.totalDevices, 0)
        XCTAssertEqual(summary.mobileDeviceCount, 3)
    }

    func testHugeOverviewValueReadsTheSideAsUnknownWithoutTrapping() {
        let state = FleetState.presence(overview: [
            fleetRow("Managed Computers", "9223372036854775807"),
            fleetRow("Unmanaged Computers", 1),
            fleetRow("Managed Devices", NSNumber(value: Int.max)),
            fleetRow("Unmanaged Devices", NSNumber(value: Int.max)),
        ])
        XCTAssertNil(state.computers)
        XCTAssertNil(state.mobileDevices)
    }

    func testTheAdminHygieneSourcesAreOnBothSides() {
        for kind in ReportEngine.serverHealthOptInKinds {
            XCTAssertEqual(ReportEngine.sourceSides[kind], SourceSides.both, kind)
        }
    }
}
