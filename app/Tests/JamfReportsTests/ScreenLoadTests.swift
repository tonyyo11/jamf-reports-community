import XCTest
@testable import JamfReports

/// Records what a `ScreenLoad` read did; the read runs on another thread.
private final class ReadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _ran = false, _onMain = false, _stale = false
    var ran: Bool { lock.withLock { _ran } }
    var ranOnMain: Bool { lock.withLock { _onMain } }
    var stale: Bool { lock.withLock { _stale } }
    func didRun() { lock.withLock { _ran = true; _onMain = Thread.isMainThread } }
    /// The profile (or demo mode) changing under a read in flight.
    func switchSource() { lock.withLock { _stale = true } }
}

/// The snapshot screens (Mobile Devices, Extension Attributes, Protect, Patch, OS Updates,
/// Groups, Policy & Profile Health, Compliance Benchmarks, DDM, Audit, Security Posture,
/// Compliance Posture, School Devices, School Overview) decode through
/// `ScreenLoad.paint` in their `.task(id:)`: off the main thread, and a result whose profile
/// went out of date, or whose task was cancelled, is dropped.
@MainActor
final class ScreenLoadTests: XCTestCase {
    /// A data dir holding each `kind` folder with the named files. `from` names the fixture
    /// folder when it differs from the kind (the compliance fixtures carry a benchmark suffix).
    private func dataDir(
        _ files: [String: [String]], from fixtureFolders: [String: String] = [:]
    ) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenLoad-\(UUID().uuidString)", isDirectory: true)
        for (kind, names) in files {
            let dir = root.appendingPathComponent(kind, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for name in names {
                try TestFixtures.copyFile(
                    TestFixtures.dir("jamf-cli-data/\(fixtureFolders[kind] ?? kind)/\(name)"),
                    to: dir.appendingPathComponent(name))
            }
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// A temp data dir whose `kind` folder holds the given files.
    private func tempDataDir(_ kind: String, _ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenLoad-\(UUID().uuidString)", isDirectory: true)
        let dir = root.appendingPathComponent(kind, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, text) in files {
            try Data(text.utf8).write(to: dir.appendingPathComponent(name))
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// Two ea-results days: FileVault coverage falls from both Macs to one.
    private func driftDataDir() throws -> URL {
        func rows(_ values: [String]) -> String {
            let items = values.enumerated().map {
                #"{"definition_id": "1", "device": "Mac\#($0.offset)", "ea_name": "FileVault", "#
                    + #""value": "\#($0.element)"}"#
            }
            return "[" + items.joined(separator: ",") + "]"
        }
        return try tempDataDir("ea-results", [
            "ea-results_20260601T080000.json": rows(["Encrypted", "Encrypted"]),
            "ea-results_20260602T080000.json": rows(["Encrypted", ""]),
        ])
    }

    /// Two patch-status days for one title, adoption rising.
    private func velocityDataDir() throws -> URL {
        func row(_ onLatest: Int) -> String {
            #"[{"title": "Firefox", "id": "1", "on_latest": \#(onLatest), "on_other": "#
                + #"\#(100 - onLatest), "total": 100, "latest": "1.0", "compliance_pct": "x%"}]"#
        }
        return try tempDataDir("patch-status", [
            "patch-status_20260101T100000.json": row(20),
            "patch-status_20260105T100000.json": row(60),
        ])
    }

    /// A workspace `match` whose `computers` snapshot holds one Mac with `serial`.
    private func workspaceWithComputer(serial: String) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenLoad-\(UUID().uuidString)", isDirectory: true)
        let dir = root.appendingPathComponent("match/jamf-cli-data/computers", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let row = #"{"id": "7", "general": {"name": "Mac-7"}, "#
            + #""hardware": {"serialNumber": "\#(serial)"}}"#
        try Data("[\(row)]".utf8)
            .write(to: dir.appendingPathComponent("computers_20260601T080000.json"))
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        addTeardownBlock {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// A workspace `profile` whose data dir holds each `kind` folder with the named fixtures.
    private func workspace(_ profile: String, _ files: [String: [String]]) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenLoad-\(UUID().uuidString)", isDirectory: true)
        for (kind, names) in files {
            let dir = root.appendingPathComponent("\(profile)/jamf-cli-data/\(kind)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for name in names {
                try TestFixtures.copyFile(
                    TestFixtures.dir("jamf-cli-data/\(kind)/\(name)"),
                    to: dir.appendingPathComponent(name))
            }
        }
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        addTeardownBlock {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// The load runs off the main thread and reaches the screen; a source that changed while
    /// it read, or a task cancelled before it started, paints nothing.
    private func assertScreenLoad<T: Sendable>(
        _ screen: String, loaded: (T) -> Bool, read: @escaping @Sendable () -> T
    ) async {
        let probe = ReadProbe()
        let value = await ScreenLoad.paint(stillCurrent: { true }) {
            probe.didRun()
            return read()
        }
        XCTAssertTrue(value.map(loaded) ?? false, "\(screen): the fixture did not load")
        XCTAssertFalse(probe.ranOnMain, "\(screen): the read ran on the main thread")

        let midLoad = ReadProbe()
        let dropped = await ScreenLoad.paint(stillCurrent: { !midLoad.stale }) {
            midLoad.switchSource()
            return read()
        }
        XCTAssertNil(dropped, "\(screen): a result for a source that changed mid-load painted")

        let cancelledProbe = ReadProbe()
        let cancelled = await Task { @MainActor () -> T? in
            withUnsafeCurrentTask { $0?.cancel() }
            return await ScreenLoad.paint(stillCurrent: { true }) {
                cancelledProbe.didRun()
                return read()
            }
        }.value
        XCTAssertNil(cancelled, "\(screen): a cancelled load painted")
        XCTAssertFalse(cancelledProbe.ran, "\(screen): a cancelled load still read the snapshot")
    }

    func testMobileDevicesLoadOffMain() async throws {
        let dir = try dataDir(["mobile-devices-list": ["mobile-devices-list.json"]])
        await assertScreenLoad("Mobile Devices", loaded: { $0.totalDevices > 0 }) {
            MobileFleetService.load(dataDir: dir)
        }
    }

    func testExtensionAttributesLoadOffMain() async throws {
        let dir = try dataDir([
            "ea-results": ["ea-results.json"],
            "computer-extension-attributes": ["computer-extension-attributes.json"],
        ])
        await assertScreenLoad("Extension Attributes", loaded: { $0.reportingEAs > 0 }) {
            ExtensionAttributeService.load(dataDir: dir)
        }
        // The second phase, coverage drift, compares the two newest ea-results days.
        let driftDir = try driftDataDir()
        await assertScreenLoad("Extension Attributes drift", loaded: { $0.count == 1 }) {
            EAParseHealthService.coverageDrift(dataDir: driftDir)
        }
    }

    func testProtectLoadsOffMain() async throws {
        let dir = try dataDir([
            "protect-alerts": ["alerts_happy.json"],
            "protect-computers": ["computers_happy.json"],
        ])
        await assertScreenLoad("Protect", loaded: { $0.isDetected && !$0.computers.isEmpty }) {
            ProtectDashboardService.load(dataDir: dir)
        }
        // The second phase, the Jamf Pro match, reads the profile's `computers` snapshot.
        let protect = ProtectDashboardService.load(dataDir: dir).computers
        try workspaceWithComputer(serial: try XCTUnwrap(protect.first?.serial))
        await assertScreenLoad("Protect match", loaded: { $0?.matched == 1 }) {
            ProtectProCorrelation.load(protect: protect, profile: "match", demoMode: false)
        }
    }

    func testPatchLoadsOffMain() async throws {
        let dir = try dataDir([
            "patch-status": ["patch-status.json"],
            "patch-device-failures": ["patch-device-failures.json"],
        ])
        await assertScreenLoad("Patch", loaded: { $0.totalTitles > 0 }) {
            PatchStatusService.load(dataDir: dir)
        }
        // The second phase, adoption velocity, walks the dated patch-status snapshots.
        let history = try velocityDataDir()
        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        await assertScreenLoad(
            "Patch velocity", loaded: { $0.count == 1 && $0[0].series.count == 2 }
        ) {
            PatchVelocityBuilder.compute(dataDir: history, releaseRows: [], now: fixedNow)
        }
    }

    func testOSUpdatesLoadOffMain() async throws {
        let dir = try dataDir([
            "update-status": ["update-status.json"],
            "update-device-failures": ["update-device-failures.json"],
        ])
        await assertScreenLoad("OS Updates", loaded: { !$0.planStateBreakdown.isEmpty }) {
            UpdateStatusService.load(dataDir: dir)
        }
    }

    func testGroupsLoadOffMain() async throws {
        let dir = try dataDir([
            "classic-computer-groups": ["classic-computer-groups_2026-04-13T121845801514.json"],
            "classic-mobile-device-groups": [
                "classic-mobile-device-groups_2026-04-13T121845801514.json",
            ],
        ])
        await assertScreenLoad("Groups", loaded: { $0.isDetected }) {
            GroupInventoryService.load(dataDir: dir)
        }
    }

    func testPolicyAndProfileHealthLoadOffMain() async throws {
        let dir = try dataDir([
            "policy-status": ["policy-status.json"],
            "profile-status": ["profile-status.json"],
        ])
        await assertScreenLoad("Policy & Profile Health", loaded: { $0.summary != nil }) {
            PolicyHealthService.load(dataDir: dir)
        }
    }

    func testComplianceBenchmarksLoadOffMain() async throws {
        let suffix = "-nist-800-53r5-moderate"
        let dir = try dataDir([
            "compliance-rules": ["platform_compliance_rules_happy.json"],
            "compliance-devices": ["platform_compliance_devices_happy.json"],
        ], from: [
            "compliance-rules": "compliance-rules" + suffix,
            "compliance-devices": "compliance-devices" + suffix,
        ])
        await assertScreenLoad("Compliance Benchmarks", loaded: { $0.totalRules > 0 }) {
            ComplianceBenchmarksService.load(dataDir: dir)
        }
    }

    func testDeclarativeDeviceManagementLoadsOffMain() async throws {
        let dir = try dataDir([
            "blueprint-status": ["platform_blueprint_status_happy.json"],
            "ddm-status": ["platform_ddm_status_happy.json"],
        ])
        // The screen's three reads are one task; the device scan and the fleet count ride along.
        await assertScreenLoad("DDM & Blueprints", loaded: { $0.0.totalBlueprints > 0 }) {
            (DDMBlueprintService.load(dataDir: dir),
             DDMDeviceStatusService.load(dataDir: dir),
             DDMDeviceStatusService.fleetDDMCounts(dataDir: dir))
        }
    }

    func testAuditIntegrityReadsLoadOffMain() async throws {
        let dir = try dataDir(["duplicate-serials": ["duplicate-serials_20260710T090000.json"]])
        await assertScreenLoad("Audit", loaded: { $0.0.isDetected }) {
            (DuplicateSerialService.load(dataDir: dir), MDMCommandHealthService.load(dataDir: dir))
        }
    }

    func testSecurityPostureLoadsOffMain() async throws {
        try workspace("posture", ["security": ["security.json"]])
        await assertScreenLoad("Security Posture", loaded: { $0.totalDevices > 0 }) {
            SecurityPostureService.load(profile: "posture")
        }
    }

    func testCompliancePostureLoadsOffMain() async throws {
        try workspace("posture", ["security": ["security.json"]])
        await assertScreenLoad("Compliance Posture", loaded: { $0.0.totalDevices > 0 }) {
            (CompliancePostureService.load(profile: "posture"),
             CompliancePostureView.loadBaselineOutcome(profile: "posture"))
        }
    }

    private func schoolDataDir() throws -> URL {
        try tempDataDir("school-devices", [
            "school-devices_20261019T080000.json": SchoolRows.json([SchoolRows.device(1)]),
        ])
    }

    func testSchoolDevicesLoadOffMain() async throws {
        let dir = try schoolDataDir()
        await assertScreenLoad("School Devices", loaded: { $0.devices.count == 1 }) {
            SchoolFleetService.load(dataDir: dir)
        }
    }

    /// The Overview reads the same service, beside the schedule and report checks.
    func testSchoolOverviewLoadsOffMain() async throws {
        let dir = try schoolDataDir()
        await assertScreenLoad("School Overview", loaded: { $0.isDetected }) {
            SchoolFleetService.load(dataDir: dir)
        }
    }

    /// Trends and the Overview share one store that outlives both screens: a screen waits for
    /// the data of the profile it shows, through a switch away and back before a read lands.
    func testTrendsWaitForTheProfileTheyShow() {
        let store = TrendStore()
        XCTAssertFalse(store.isLoaded(for: "a"), "nothing has loaded yet")

        let snapshot = TrendStore.TrendSnapshot(
            summaries: [DailySummary(
                date: "2026-07-01", totalDevices: 3, fileVaultPct: 98, compliancePct: 90,
                staleCount: 1, osCurrentPct: 80, crowdstrikePct: 95, patchPct: 88)],
            latestSnapshotDate: nil, hasEverFetchedLive: true, bandSeries: [:], baselineNames: [])
        store.apply(snapshot, profile: "a", range: .all, generation: store.beginLoading())
        XCTAssertTrue(store.isLoaded(for: "a"))
        XCTAssertFalse(store.isLoaded(for: "b"), "a's data is not b's")

        // a, then b, then a again before b's scan lands.
        store.clearForProfileSwitch(to: "b")
        let bScan = store.beginLoading()
        store.clearForProfileSwitch(to: "a")
        let aScan = store.beginLoading()
        XCTAssertFalse(store.isLoaded(for: "a"), "the loading card shows, not a's empty state")
        XCTAssertTrue(store.isEmpty)

        store.apply(snapshot, profile: "b", range: .all, generation: bScan)
        XCTAssertFalse(store.isLoaded(for: "b"), "b's late scan was dropped")
        store.apply(snapshot, profile: "a", range: .all, generation: aScan)
        XCTAssertTrue(store.isLoaded(for: "a"))
    }

    /// The Overview shows its loading overlay until the shared store holds its profile's data,
    /// and a profile with no summaries at all still ends the wait (an empty scan is a load).
    func testOverviewTrendsOverlayEndsWhenAnEmptyProfileLoads() {
        let store = TrendStore()
        XCTAssertFalse(store.isLoaded(for: "new"), "the first frame waits")
        let empty = TrendStore.TrendSnapshot(
            summaries: [], latestSnapshotDate: nil, hasEverFetchedLive: false,
            bandSeries: [:], baselineNames: [])
        let scan = store.beginLoading()
        store.setRange(.w12)
        store.apply(empty, profile: "new", range: .w12, generation: scan)
        XCTAssertTrue(store.isLoaded(for: "new"))
        XCTAssertFalse(store.isLoading)
        XCTAssertEqual(store.currentRange, .w12, "the range chosen during the scan stands")
    }

    func testFleetOverviewIsReadOffMainAndTaggedWithItsProfile() async {
        let live = WorkspaceStore(
            demoMode: false, tickerRegistrar: StubTickerRegistrar(), jamfCLIProfileNames: { [] })
        let demo = WorkspaceStore(
            demoMode: true, tickerRegistrar: StubTickerRegistrar(), jamfCLIProfileNames: { [] })
        live.profile = "alpha"
        demo.profile = "alpha"
        XCTAssertNotEqual(live.fleetOverviewLoadKey, demo.fleetOverviewLoadKey,
                          "demo mode under the same profile name reloads")

        let probe = ReadProbe()
        let overview = await live.loadFleetOverview(readSummaries: { _ in
            probe.didRun()
            return []
        })
        XCTAssertTrue(probe.ran)
        XCTAssertFalse(probe.ranOnMain, "the summaries were read on the main thread")
        XCTAssertEqual(overview.profile, "alpha")
        XCTAssertNotNil(overview.shown(for: "alpha"))
        XCTAssertNil(overview.shown(for: "beta"), "a late load does not show under another profile")
    }

    /// The Scoring card writes the whole default list on an edit: until this profile's read has
    /// landed, the previous profile's baselines must not shape it.
    func testScoreFactorsCardIgnoresAnotherProfilesRead() {
        let read = ScoreFactorsSnapshot(agents: ["Falcon"], baselines: ["cis_lvl1"])
        func defaults(_ shown: ScoreFactorsSnapshot) -> [SecurityScoreFactor] {
            SecurityScoreFactor.defaults(agents: [], hasBaseline: !shown.baselines.isEmpty)
        }
        let own = ScoreFactorsCard.visible(read, loadedProfile: "a", for: "a")
        XCTAssertEqual(own.baselines, ["cis_lvl1"])
        XCTAssertTrue(defaults(own).contains { $0.kind == .mscp })

        for profile in ["b", "a"] {
            let before = ScoreFactorsCard.visible(read, loadedProfile: nil, for: profile)
            XCTAssertEqual(before, ScoreFactorsSnapshot(), "nothing is read for \(profile) yet")
        }
        let other = ScoreFactorsCard.visible(read, loadedProfile: "a", for: "b")
        XCTAssertTrue(other.baselines.isEmpty)
        XCTAssertFalse(defaults(other).contains { $0.kind == .mscp })
    }

    func testBackupsLoadOffMain() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenLoad-\(UUID().uuidString)", isDirectory: true)
        let backup = root.appendingPathComponent("saves/backups/20260601T214020")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        addTeardownBlock {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: root)
        }
        await assertScreenLoad("Backups", loaded: { $0.count == 1 }) {
            BackupLibrary().list(profile: "saves")
        }
    }

    /// The Computers screen sends every load phase through `ScreenLoad.paint`, so this is the
    /// drop it uses: off main, a source change mid-load, a cancelled task.
    func testComputersLoadOffMain() async throws {
        try workspaceWithComputer(serial: "C02TEST0001")
        await assertScreenLoad("Computers", loaded: { !$0.devices.isEmpty }) {
            DeviceInventoryService.load(profile: "match", demoMode: false)
        }
    }

    func testDeviceLookupIndexLoadsOffMain() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenLoad-\(UUID().uuidString)", isDirectory: true)
        let kindDir = root.appendingPathComponent("lookup/jamf-cli-data/computers-list")
        try FileManager.default.createDirectory(at: kindDir, withIntermediateDirectories: true)
        try Data(#"[{"id": "101", "general": {"name": "Lab-Mac-01"}}]"#.utf8)
            .write(to: kindDir.appendingPathComponent("computers-list.json"))
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        addTeardownBlock {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: root)
        }
        await assertScreenLoad("Device Lookup", loaded: { !$0.candidates.isEmpty }) {
            DeviceLookupIndex.read(profile: "lookup")
        }

        // The index itself: a load whose task is cancelled leaves it empty.
        let index = DeviceLookupIndex()
        await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await index.load(profile: "lookup")
        }.value
        XCTAssertTrue(index.candidates.isEmpty, "a cancelled load filled the index")
    }
}
