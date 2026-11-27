import XCTest
@testable import JamfReports

/// Change-filter edges the 2.13 mutation sweep left unpinned: which Macs each FileVault kind
/// lists, the rule check per kind, trimmed patch IDs and a linked snapshot file.
@MainActor
final class ChangeFilterBoundaryTests: XCTestCase {

    private let anchor = GoldenFleetClock.anchorNoon()
    private func at(_ day: Int) -> Date {
        GoldenFleetClock.timestamp(dayOffset: day, hour: 6, minute: 0, relativeTo: anchor)
    }
    private func stamp(_ day: Int) -> String { GoldenFleetClock.stamp(at(day)) }
    private let rule = StaleRule(days: 20)
    private let policy = SecurityControlPolicy()

    private func dataDir() -> URL {
        let root = GoldenFleetWorkspace.freshRoot()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent("data", isDirectory: true)
    }

    @discardableResult
    private func write(_ kind: String, day: Int, _ object: Any, in dir: URL) throws -> URL {
        let folder = dir.appendingPathComponent(kind, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(kind)_\(stamp(day)).json")
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        return url
    }

    private func mac(_ id: String, fileVault: Bool?) -> [String: Any] {
        let date = ISO8601DateFormatter().string(from: at(-1))
        var item: [String: Any] = [
            "id": id, "general": ["name": "Mac-\(id)", "lastCheckIn": date, "reportDate": date],
            "hardware": ["serialNumber": "S\(id)"], "operatingSystem": ["version": "15.4"],
        ]
        if let fileVault { item["diskEncryption"] = ["fileVault2Enabled": fileVault] }
        return item
    }

    /// Mac 3 turns FileVault off, Mac 4 stops reporting it.
    private func seed(in dir: URL) throws {
        try write("computers", day: -10, [mac("3", fileVault: true), mac("4", fileVault: true)],
                  in: dir)
        try write("computers", day: 0, [mac("3", fileVault: false), mac("4", fileVault: nil)],
                  in: dir)
    }

    private func filter(_ kind: ChangeKind) -> ChangeFilter {
        ChangeFilter(kind: kind, currentStamp: stamp(0), baselineStamp: stamp(-10),
                     fileVaultRule: policy.fileVaultFingerprint, staleDays: rule.days,
                     staleBasis: rule.basis.map(\.rawValue))
    }

    func testEachFileVaultKindListsItsOwnMacs() throws {
        let dir = dataDir()
        try seed(in: dir)
        let all = ChangeFilterResolver.resolveAll(filter(.joined), dataDir: dir, rule: rule,
                                                  policy: policy)
        XCTAssertEqual(all[.fileVaultOff]?.outcome, .macs([MacKey(jamfID: "3", serial: "S3")]))
        XCTAssertEqual(all[.fileVaultStoppedReporting]?.outcome,
                       .macs([MacKey(jamfID: "4", serial: "S4")]))
    }

    func testEachKindIsCheckedAgainstItsOwnRule() throws {
        let dir = dataDir()
        try seed(in: dir)
        let all = ChangeFilterResolver.resolveAll(filter(.joined), dataDir: dir,
                                                  rule: StaleRule(days: 25), policy: policy)
        XCTAssertEqual(all[.becameStale]?.ruleChanged, true, "opened from Joined, judged as stale")
        XCTAssertEqual(all[.joined]?.ruleChanged, false)
    }

    func testAStaleBasisChangeAloneIsARuleChange() {
        XCTAssertTrue(ChangeFilterResolver.ruleChanged(
            filter(.becameStale), rule: StaleRule(days: 20, basis: [.checkIn, .inventory]),
            policy: policy))
    }

    func testPatchMacsAreKeyedByTheTrimmedJamfID() throws {
        let dir = dataDir()
        try write("computers", day: 0, [["id": "1"]], in: dir)
        try write(PatchFailureDrift.kind, day: 0, [["device_id": " 1 ", "policy_id": "11"]],
                  in: dir)
        try write(PatchFailureDrift.kind, day: -7, [] as [Any], in: dir)
        let patch = ChangeFilter(kind: .patchStarted, currentStamp: stamp(0),
                                 baselineStamp: stamp(-7), computersStamp: stamp(0))
        let result = ChangeFilterResolver.resolveAll(patch, dataDir: dir, rule: rule,
                                                     policy: policy)[.patchStarted]
        XCTAssertEqual(result?.outcome, .macs([MacKey(jamfID: "1")]))
    }

    func testALinkedSnapshotFileIsUnreadable() throws {
        let dir = dataDir()
        try seed(in: dir)
        let baseline = dir.appendingPathComponent("computers/computers_\(stamp(-10)).json")
        let moved = dir.appendingPathComponent("elsewhere.json")
        try FileManager.default.moveItem(at: baseline, to: moved)
        try FileManager.default.createSymbolicLink(at: baseline, withDestinationURL: moved)
        let result = ChangeFilterResolver.resolveAll(filter(.joined), dataDir: dir, rule: rule,
                                                     policy: policy)[.joined]
        XCTAssertEqual(result?.outcome, .unreadable(.readError))
    }
}
