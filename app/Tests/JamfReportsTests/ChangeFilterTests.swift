import XCTest
@testable import JamfReports

/// Opening the Macs behind a "Since last collect" count (wave B2c): the filter, the resolver
/// that rebuilds the list from the same two snapshots, the match rule and the demo lists.
@MainActor
final class ChangeFilterTests: XCTestCase {

    private let anchor = GoldenFleetClock.anchorNoon()
    private func at(_ day: Int) -> Date {
        GoldenFleetClock.timestamp(dayOffset: day, hour: 6, minute: 0, relativeTo: anchor)
    }
    private func stamp(_ day: Int) -> String { GoldenFleetClock.stamp(at(day)) }

    private func dataDir() -> URL {
        let root = GoldenFleetWorkspace.freshRoot()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent("data", isDirectory: true)
    }

    @discardableResult
    private func write(_ kind: String, day: Int, _ data: Data, in dir: URL, name: String? = nil)
        throws -> URL {
        let folder = dir.appendingPathComponent(kind, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name ?? "\(kind)_\(stamp(day)).json")
        try data.write(to: url)
        return url
    }

    private func json(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    private func mac(_ id: String, checkIn: Int, fileVault: Bool?, os: String) -> [String: Any] {
        let date = ISO8601DateFormatter().string(from: at(checkIn))
        var item: [String: Any] = [
            "id": id,
            "general": ["name": "Mac-\(id)", "lastCheckIn": date, "reportDate": date],
            "hardware": ["serialNumber": "S\(id)"],
            "operatingSystem": ["version": os],
        ]
        if let fileVault { item["diskEncryption"] = ["fileVault2Enabled": fileVault] }
        return item
    }

    private let rule = StaleRule(days: 20)
    private let policy = SecurityControlPolicy()

    /// Every computer kind has at least one Mac: 2 joined, 7 left, 1 macOS changed, 3 FileVault
    /// off, 4 stopped reporting, 5 went stale, 6 checking in again.
    private func seedComputers(in dir: URL) throws {
        try write("computers", day: -10, json([
            mac("1", checkIn: -11, fileVault: true, os: "15.3"),
            mac("3", checkIn: -11, fileVault: true, os: "15.4"),
            mac("4", checkIn: -11, fileVault: true, os: "15.4"),
            mac("5", checkIn: -25, fileVault: true, os: "15.4"),
            mac("6", checkIn: -40, fileVault: true, os: "15.4"),
            mac("7", checkIn: -11, fileVault: true, os: "15.4"),
        ]), in: dir)
        try write("computers", day: 0, json([
            mac("1", checkIn: -1, fileVault: true, os: "15.4"),
            mac("2", checkIn: -1, fileVault: true, os: "15.4"),
            mac("3", checkIn: -1, fileVault: false, os: "15.4"),
            mac("4", checkIn: -1, fileVault: nil, os: "15.4"),
            mac("5", checkIn: -25, fileVault: true, os: "15.4"),
            mac("6", checkIn: -1, fileVault: true, os: "15.4"),
        ]), in: dir)
    }

    private func storedComputerChanges(in dir: URL) throws -> ComputerChanges {
        let url = dir.appendingPathComponent("computers/computers_\(stamp(0)).json")
        let snapshot = try XCTUnwrap(ComputerDates.decodeComputerSnapshot(Data(contentsOf: url)))
        return try XCTUnwrap(ReportEngine.computerChanges(
            landed: .init(stamp: stamp(0), date: at(0), snapshot: snapshot), dataDir: dir,
            rule: rule, policy: policy))
    }

    private let computerKinds: [ChangeKind] = [.joined, .left, .becameStale, .noLongerStale,
                                               .fileVaultOff, .fileVaultStoppedReporting, .osChanged]

    // MARK: - The filter

    func testFromGivesNilForZeroNotMeasuredOrABadStamp() {
        let part = ComputerChanges(
            currentStamp: "20261102T060000", baselineStamp: "20261101T060000",
            joined: 2, left: 0)
        XCTAssertNotNil(ChangeFilter.from(part, kind: .joined))
        XCTAssertNil(ChangeFilter.from(part, kind: .left), "0")
        XCTAssertNil(ChangeFilter.from(part, kind: .osChanged), "not measured")
        var missing = part
        missing.baselineStamp = nil
        XCTAssertNil(ChangeFilter.from(missing, kind: .joined))
        var traversal = part
        traversal.currentStamp = "../x"
        XCTAssertNil(ChangeFilter.from(traversal, kind: .joined))
        var garbled = part
        garbled.baselineStamp = "20261301T999999"
        XCTAssertNil(ChangeFilter.from(garbled, kind: .joined))
        var unreadable = part
        unreadable.baselineUnreadable = true
        XCTAssertNil(ChangeFilter.from(unreadable, kind: .joined))
        XCTAssertNil(ChangeFilter.from(part, kind: .patchStarted), "a patch kind needs a patch part")
    }

    func testPatchFilterNeedsTheComputersStamp() {
        var part = PatchChanges(
            currentStamp: "20261102T060000", baselineStamp: "20261026T060000", startedFailing: 3)
        XCTAssertNil(ChangeFilter.from(part, kind: .patchStarted), "a summary from before B2c")
        part.computersStamp = "20261102T050000"
        XCTAssertEqual(ChangeFilter.from(part, kind: .patchStarted)?.computersStamp,
                       "20261102T050000")
        XCTAssertNil(ChangeFilter.from(part, kind: .patchNoLongerListed), "count not measured")
    }

    func testJSONRoundTripsThroughUserInfo() throws {
        let filter = ChangeFilter(
            kind: .becameStale, currentStamp: "20261102T060000",
            baselineStamp: "20261101T060000", fileVaultRule: "abcd", staleDays: 30,
            staleBasis: ["check_in"])
        let info: [AnyHashable: Any] = filter.navigationUserInfo()
        XCTAssertEqual(info["tab"] as? String, Tab.devices.rawValue)
        let raw = try XCTUnwrap(ChangeFilter.pending(from: info, destination: .devices))
        XCTAssertEqual(ChangeFilter(json: raw), filter)
        XCTAssertNil(ChangeFilter.pending(from: info, destination: .overview))
        XCTAssertNil(ChangeFilter(json: #"{"kind":"joined","currentStamp":"../x","baselineStamp":"20261101T060000"}"#))
    }

    func testASerialIsRefusedWhenTheJamfIDsDiffer() {
        let match = ChangeMatch([MacKey(jamfID: "9", serial: "S1")])
        var record = DeviceInventoryRecord.empty(id: "a", source: "computers.json")
        record.serial = "S1"
        record.jamfID = "5"
        XCTAssertFalse(match.contains(record))
        record.jamfID = nil
        record.serial = " s1 "
        XCTAssertTrue(match.contains(record), "trimmed and case-folded")
        record.jamfID = "9"
        record.serial = "other"
        XCTAssertTrue(match.contains(record), "the Jamf ID first")
        record.jamfID = nil
        record.serial = ""
        record.name = "S1"
        XCTAssertFalse(match.contains(record), "never by name")
    }

    // MARK: - The resolver

    /// The list each count opens is the set the count was taken from.
    func testEveryComputerKindResolvesToTheStoredCount() throws {
        let dir = dataDir()
        try seedComputers(in: dir)
        let stored = try storedComputerChanges(in: dir)
        for kind in computerKinds {
            let count = try XCTUnwrap(kind.count(in: stored), "\(kind)")
            XCTAssertGreaterThan(count, 0, "\(kind) has a Mac in the seed")
            let filter = try XCTUnwrap(ChangeFilter.from(stored, kind: kind))
            let result = ChangeFilterResolver.resolve(filter, dataDir: dir, rule: rule, policy: policy)
            XCTAssertFalse(result.ruleChanged, "\(kind)")
            switch result.outcome {
            case .macs(let keys): XCTAssertEqual(keys.count, count, "\(kind)")
            case .left(let macs):
                XCTAssertEqual(kind, .left)
                XCTAssertEqual(macs.map(\.jamfID), ["7"], "the baseline's Mac")
            default: XCTFail("\(kind): \(result.outcome)")
            }
        }
    }

    func testBothPatchKindsResolveToTheStoredCounts() throws {
        let dir = dataDir()
        try write("computers", day: 0, json([["id": "1"], ["id": "2"], ["id": "3"]]), in: dir)
        try write(PatchFailureDrift.kind, day: 0, json([
            ["device_id": "1", "policy_id": "11"], ["device_id": "1", "policy_id": "12"],
            ["device_id": "2", "policy_id": "11"],
        ]), in: dir)
        try write(PatchFailureDrift.kind, day: -7, json([
            ["device_id": "2", "policy_id": "11"], ["device_id": "3", "policy_id": "13"],
            ["device_id": "99", "policy_id": "13"],
        ]), in: dir)
        let stored = try XCTUnwrap(ReportEngine.patchChanges(
            dataDir: dir, landedStamp: at(0), landed: nil))
        XCTAssertEqual(stored.computersStamp, stamp(0))
        let started = try XCTUnwrap(ChangeFilter.from(stored, kind: .patchStarted))
        let result = ChangeFilterResolver.resolve(started, dataDir: dir, rule: rule, policy: policy)
        XCTAssertEqual(result.outcome, .macs([MacKey(jamfID: "1")]), "Mac 1 once")
        XCTAssertEqual(result.failures, stored.startedFailing, "two policy failures")
        XCTAssertEqual(result.failures, 2)
        let dropped = try XCTUnwrap(ChangeFilter.from(stored, kind: .patchNoLongerListed))
        let gone = ChangeFilterResolver.resolve(dropped, dataDir: dir, rule: rule, policy: policy)
        XCTAssertEqual(gone.outcome, .macs([MacKey(jamfID: "3")]))
        XCTAssertEqual(gone.failures, stored.stoppedFailing)
        XCTAssertFalse(gone.ruleChanged, "patch kinds never set it")
    }

    func testMissingUndecodableAndConflictCopyFiles() throws {
        let dir = dataDir()
        try seedComputers(in: dir)
        let filter = try XCTUnwrap(ChangeFilter.from(try storedComputerChanges(in: dir), kind: .joined))
        let baseline = dir.appendingPathComponent("computers/computers_\(stamp(-10)).json")

        try Data("{bad".utf8).write(to: baseline)
        XCTAssertEqual(ChangeFilterResolver.resolve(filter, dataDir: dir, rule: rule, policy: policy)
            .outcome, .unreadable(.undecodable))

        try FileManager.default.removeItem(at: baseline)
        XCTAssertEqual(ChangeFilterResolver.resolve(filter, dataDir: dir, rule: rule, policy: policy)
            .outcome, .fileGone)

        try write("computers", day: -10, json([mac("7", checkIn: -11, fileVault: true, os: "15.4")]),
                  in: dir, name: "computers_\(stamp(-10)) 2.json")
        XCTAssertEqual(ChangeFilterResolver.resolve(filter, dataDir: dir, rule: rule, policy: policy)
            .outcome, .fileGone, "a sync-conflict copy is never read")
    }

    func testOverTheReadLimitIsTooLarge() throws {
        let dir = dataDir()
        let url = try write("computers", day: 0, Data(), in: dir)
        try write("computers", day: -1, json([["id": "1"]]), in: dir)
        // A sparse file one byte past the inventory limit, so the test writes almost nothing.
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(BoundedFile.inventoryLimit) + 1)
        try handle.close()
        let filter = ChangeFilter(kind: .joined, currentStamp: stamp(0), baselineStamp: stamp(-1))
        XCTAssertEqual(ChangeFilterResolver.resolve(filter, dataDir: dir, rule: rule, policy: policy)
            .outcome, .unreadable(.tooLarge))
    }

    func testRuleChangedOnlyForTheKindsTheRuleAffects() {
        var filter = ChangeFilter(
            kind: .joined, currentStamp: "20261102T060000", baselineStamp: "20261101T060000",
            fileVaultRule: "not-today", staleDays: 30, staleBasis: ["check_in"])
        let today = StaleRule(days: 30)
        func changed(_ kind: ChangeKind, rule: StaleRule = today,
                     policy: SecurityControlPolicy = SecurityControlPolicy()) -> Bool {
            ChangeFilterResolver.ruleChanged(filter.with(kind: kind), rule: rule, policy: policy)
        }
        XCTAssertTrue(changed(.fileVaultOff))
        XCTAssertTrue(changed(.fileVaultStoppedReporting))
        for kind in [ChangeKind.joined, .left, .osChanged, .becameStale, .noLongerStale,
                     .patchStarted, .patchNoLongerListed] {
            XCTAssertFalse(changed(kind), "\(kind)")
        }
        XCTAssertTrue(changed(.becameStale, rule: StaleRule(days: 20)))
        XCTAssertTrue(changed(.noLongerStale, rule: StaleRule(days: 20)))
        XCTAssertFalse(changed(.joined, rule: StaleRule(days: 20)))

        filter.fileVaultRule = SecurityControlPolicy().fileVaultFingerprint
        XCTAssertFalse(changed(.fileVaultOff))
        XCTAssertTrue(changed(.fileVaultOff,
                              policy: SecurityControlPolicy(onValues: [.fileVault: ["Pass"]])),
                      "on_values changed")
        filter.fileVaultRule = nil
        filter.staleDays = nil
        filter.staleBasis = nil
        XCTAssertFalse(changed(.fileVaultOff), "unknown, not changed")
        XCTAssertFalse(changed(.becameStale, rule: StaleRule(days: 20)))
    }

    func testAPreCancelledResolveReturnsCancelled() async throws {
        let dir = dataDir()
        try seedComputers(in: dir)
        let filter = try XCTUnwrap(ChangeFilter.from(try storedComputerChanges(in: dir), kind: .joined))
        let (rule, policy) = (rule, policy)
        let result = await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return ChangeFilterResolver.resolve(filter, dataDir: dir, rule: rule, policy: policy)
        }.value
        XCTAssertEqual(result.outcome, .cancelled)
    }

    func testACancelledStoreResolveIsNotCached() async {
        let store = WorkspaceStore(
            demoMode: false, jamfCLIProfileNames: { [] }, discoverProfiles: { [] },
            jamfCLIInstallation: { nil })
        let filter = ChangeFilter(kind: .joined, currentStamp: stamp(0), baselineStamp: stamp(-1))
        let (rule, policy) = (rule, policy)
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await store.resolveChangeFilter(filter, rule: rule, policy: policy)
        }
        let result = await task.value
        XCTAssertEqual(result.outcome, .cancelled)
        XCTAssertTrue(store.changeFilterCache.isEmpty)
    }

    // MARK: - Demo

    func testDemoListsFollowTheirRulesAndMatchTheCounts() throws {
        let computers = try XCTUnwrap(DemoData.fleetChanges.computers)
        let patch = try XCTUnwrap(DemoData.fleetChanges.patch)
        func serials(_ kind: ChangeKind) -> [String] { DemoData.demoChangeMacs(kind).map(\.serial) }
        XCTAssertEqual(serials(.becameStale), ["C02YK1N6P3Q8"], "the one Mac over 14 days")
        XCTAssertEqual(serials(.fileVaultOff), ["FVFXJ8L2R4M7"], "the one Mac not encrypted")
        XCTAssertEqual(serials(.osChanged).count, 4, "the Macs on 15.4")
        XCTAssertEqual(serials(.noLongerStale), ["FVFXK7H8Q6L4"])
        XCTAssertEqual(serials(.joined), ["FVFYK2N5P8R3"])
        XCTAssertEqual(serials(.fileVaultStoppedReporting), [])
        XCTAssertEqual(serials(.patchStarted).count, 4)
        XCTAssertEqual(serials(.patchNoLongerListed), ["C02XK9PHJG5J"])

        let devices = DemoData.deviceSnapshot.devices
        for kind in computerKinds where kind != .left {
            let result = DemoData.changeFilterResult(for: kind)
            guard case .macs(let keys) = result.outcome else { return XCTFail("\(kind)") }
            XCTAssertEqual(keys.count, kind.count(in: computers), "\(kind)")
            XCTAssertEqual(ChangeMatch(keys).unmatchedCount(in: devices), 0, "\(kind)")
            let shown = devices.filter(ChangeMatch(keys).contains)
            XCTAssertEqual(shown.count, keys.count, "\(kind) rows")
        }
        XCTAssertEqual(DemoData.changeFilterResult(for: .left).outcome,
                       .left(DemoData.demoLeftMacs))
        XCTAssertEqual(computers.left, 1)
        XCTAssertFalse(DemoData.fleetMacs.contains { $0.name == DemoData.demoLeftMacs[0].name })
        XCTAssertEqual(DemoData.changeFilterResult(for: .patchStarted).failures,
                       patch.startedFailing)
        XCTAssertEqual(DemoData.changeFilterResult(for: .patchNoLongerListed).failures,
                       patch.stoppedFailing)
        XCTAssertNotNil(ChangeFilter.from(patch, kind: .patchStarted), "the demo row is a button")
    }

    func testADemoStoreResolvesWithoutDisk() async {
        let store = WorkspaceStore(
            demoMode: true, jamfCLIProfileNames: { [] }, discoverProfiles: { [] },
            jamfCLIInstallation: { nil })
        let filter = ChangeFilter(kind: .osChanged, currentStamp: stamp(0), baselineStamp: stamp(-1))
        let result = await store.resolveChangeFilter(filter, rule: rule, policy: policy)
        XCTAssertEqual(result, DemoData.changeFilterResult(for: .osChanged))
        XCTAssertTrue(store.changeFilterCache.isEmpty, "demo results are not cached")
    }
}
