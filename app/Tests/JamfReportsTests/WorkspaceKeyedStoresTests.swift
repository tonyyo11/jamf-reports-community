import XCTest
@testable import JamfReports

/// The stores that key on a workspace since 2.12 read what 2.11 wrote, to the same values, and
/// write the same keys and names back, so nothing on disk moves and an older build still reads
/// them. Each file and name below is the literal text a 2.11 build wrote.
final class WorkspaceKeyedStoresTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-ws-stores-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testA211SchedulesFileDecodesToTheSameWorkspacesAndKeepsItsKeys() throws {
        let url = dir.appendingPathComponent("schedules.json")
        try Data("""
            [{"label":"com.github.tonyyo11.jamf-reports-community.acme%20prod.nightly",
              "name":"nightly","profile":"acme prod","allProfiles":false,"excludedProfiles":[],
              "mode":"jamf-cli-full","schedule":"Daily 06:20","enabled":true},
             {"label":"com.github.tonyyo11.jamf-reports-community.multi.fleet","name":"fleet",
              "profile":"","allProfiles":true,"excludedProfiles":["dummy"],
              "mode":"snapshot-only","schedule":"Mon 07:00","enabled":true}]
            """.utf8).write(to: url)
        let store = ScheduleStore(url: url)
        let records = store.load()

        XCTAssertEqual(records.map(\.workspace), ["acme prod", ""])
        XCTAssertEqual(records.map(\.allWorkspaces), [false, true])
        XCTAssertEqual(records.last?.excludedWorkspaces, ["dummy"])
        XCTAssertEqual(records.first?.toSchedule().profile, "acme prod")

        try store.save(records)
        let written = try String(contentsOf: url, encoding: .utf8)
        for key in ["\"profile\"", "\"allProfiles\"", "\"excludedProfiles\""] {
            XCTAssertTrue(written.contains(key), key)
        }
        XCTAssertFalse(written.contains("orkspace"), written)
        XCTAssertEqual(store.load().map(\.workspace), ["acme prod", ""])
    }

    func testA211PolicyDecodesToTheSameExclusionsAndGroupsAndKeepsItsKeys() throws {
        let policy = AutomationPolicy.parse("""
            {"isManaged":true,"excludedProfiles":["dummy"],
             "reportGroups":[{"name":"Fleet","profiles":["prod","dev"]}]}
            """)
        XCTAssertTrue(policy.isManaged)
        XCTAssertEqual(policy.excludedWorkspaces, ["dummy"])
        XCTAssertEqual(
            policy.reportGroups, [ReportGroup(name: "Fleet", workspaces: ["prod", "dev"])])

        let written = policy.serialize()
        XCTAssertTrue(written.contains("\"excludedProfiles\":[\"dummy\"]"), written)
        XCTAssertTrue(written.contains("\"profiles\":[\"prod\",\"dev\"]"), written)
        XCTAssertFalse(written.contains("orkspace"), written)
        XCTAssertEqual(AutomationPolicy.parse(written), policy)
    }

    /// A 2.11 pin is `shared-config-pin-<ProfileName.pathComponent>.json`; the workspace with
    /// that name reads it.
    func testA211PinFileIsTheWorkspacesPin() throws {
        try Data("{}".utf8).write(to: dir.appendingPathComponent("shared-config-pin-%2Eacme.json"))
        guard case .pin = SharedConfigPin.read(profile: ".acme", appSupport: dir) else {
            return XCTFail("the 2.11 pin file was not read")
        }
        XCTAssertEqual(
            SharedConfigPin.storeURL(workspace: ".acme", appSupport: dir)?.lastPathComponent,
            "shared-config-pin-%2Eacme.json")
        XCTAssertTrue(SharedConfigPin.hasPin(profile: ".acme", appSupport: dir))
        XCTAssertNil(SharedConfigPin.storeURL(workspace: "", appSupport: dir))
    }

    /// Run History logs and status files are named by label; a schedule's label and a CLI run's
    /// label are the names 2.11 gave them.
    func testRunLabelsAreThe211Labels() throws {
        let schedule = Schedule(
            name: "nightly", profile: "acme prod", schedule: "Daily 06:20", cadence: "daily",
            mode: .jamfCLIFull, next: "—", last: "—", lastStatus: .ok, artifacts: [],
            enabled: true)
        XCTAssertEqual(
            LaunchAgentWriter.label(for: schedule),
            "com.github.tonyyo11.jamf-reports-community.acme%20prod.nightly")
        XCTAssertEqual(
            CLIRunSignals.cliLabel(
                workspace: try XCTUnwrap(WorkspaceID("acme prod")), kind: .collect),
            "com.github.tonyyo11.jamf-reports-community.acme%20prod.cli-collect")
        XCTAssertEqual(
            ProfileName.name(fromLabelComponent: try XCTUnwrap(WorkspaceID("acme prod"))
                .labelComponent),
            "acme prod")
    }
}
