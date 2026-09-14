import XCTest
@testable import JamfReports

final class ScheduleImportTests: XCTestCase {

    private let prefix = LaunchAgentWriter.labelPrefix

    private func schedule(_ label: String, profile: String, multi: Bool = false) -> Schedule {
        Schedule(
            name: label.components(separatedBy: ".").last ?? label, profile: profile,
            schedule: "Daily 06:20", cadence: "custom", mode: .jamfCLIFull, next: "—",
            last: "—", lastStatus: .ok, artifacts: [], enabled: true, launchAgentLabel: label,
            multiTarget: multi ? MultiTarget(scope: .all) : nil)
    }

    func testPlanImportsHandBuiltSkipsManagedReportsUnparseable() {
        let managed = schedule("\(prefix).multi.managed-scan", profile: "", multi: true)
        let user = schedule("\(prefix).alpha.nightly", profile: "alpha")
        let userMulti = schedule("\(prefix).multi.fleet", profile: "", multi: true)
        let result = ScheduleImport.plan(
            installed: [managed, user, userMulti], unparseable: ["broken.plist"])
        XCTAssertEqual(result.imported.map(\.label), [
            "\(prefix).alpha.nightly", "\(prefix).multi.fleet"])
        XCTAssertEqual(result.managedLabels, ["\(prefix).multi.managed-scan"])
        XCTAssertEqual(result.unparseable, ["broken.plist"])
        XCTAssertEqual(result.imported.first?.profile, "alpha")
        XCTAssertEqual(result.imported.last?.allProfiles, true)
    }

    func testRunIfNeededImportsOnceAndSetsTheFlag() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let store = ScheduleStore(url: dir.appendingPathComponent("schedules.json"))
        let defaults = UserDefaults(suiteName: "ScheduleImportTests-\(UUID().uuidString)")!
        let user = schedule("\(prefix).alpha.nightly", profile: "alpha")

        let first = ScheduleImport.runIfNeeded(
            store: store, defaults: defaults, installed: { ([user], []) })
        XCTAssertEqual(first?.imported.count, 1)
        XCTAssertEqual(store.load().map(\.label), ["\(prefix).alpha.nightly"])

        let second = ScheduleImport.runIfNeeded(
            store: store, defaults: defaults, installed: { ([user], []) })
        XCTAssertNil(second, "a second launch must not re-import")
    }

    func testRunIfNeededNeverOverwritesAnExistingRecord() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let store = ScheduleStore(url: dir.appendingPathComponent("schedules.json"))
        var existing = try XCTUnwrap(ScheduleRecord(
            schedule: schedule("\(prefix).alpha.nightly", profile: "alpha")))
        existing.enabled = false
        try store.save([existing])
        let defaults = UserDefaults(suiteName: "ScheduleImportTests-\(UUID().uuidString)")!
        _ = ScheduleImport.runIfNeeded(
            store: store, defaults: defaults,
            installed: { ([self.schedule("\(self.prefix).alpha.nightly", profile: "alpha")], []) })
        XCTAssertEqual(store.load().first?.enabled, false)
    }

    @MainActor
    func testLoadSchedulesDerivesManagedFromPolicyAndReadsStore() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let store = ScheduleStore(url: dir.appendingPathComponent("schedules.json"))
        try store.save([try XCTUnwrap(ScheduleRecord(
            schedule: schedule("\(prefix).alpha.nightly", profile: "alpha")))])
        var policy = AutomationPolicy(); policy.isManaged = true
        policy.backupsEnabled = true
        let all = WorkspaceStore.loadSchedules(policy: policy, store: store, baseProfile: "alpha")
        XCTAssertEqual(all.filter { ManagedAutomation.owns($0.launchAgentLabel ?? "") }.count, 4)
        XCTAssertEqual(all.last?.launchAgentLabel, "\(prefix).alpha.nightly")
        policy.isManaged = false
        XCTAssertEqual(WorkspaceStore.loadSchedules(
            policy: policy, store: store, baseProfile: "alpha").count, 1)
    }

    func testWantsTickerWhenManagedOrAnyHandBuiltSchedule() {
        var managed = AutomationPolicy(); managed.isManaged = true
        XCTAssertTrue(WorkspaceStore.wantsTicker(policy: managed, hasHandBuilt: false))
        XCTAssertTrue(WorkspaceStore.wantsTicker(policy: AutomationPolicy(), hasHandBuilt: true))
        XCTAssertFalse(WorkspaceStore.wantsTicker(policy: AutomationPolicy(), hasHandBuilt: false))
    }
}
