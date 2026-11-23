import ArgumentParser
import Foundation
import XCTest
@testable import JamfReports

/// The included CLI's 2.11 product rules: the commands that call a Jamf Pro API refuse another
/// product's profile with one reason, before anything is created in its workspace. `run()`
/// ends a refusal with `CLIRun.fail`, which exits the process, so these call the `refusal`
/// each command passes to it.
final class CLIProductGuardTests: XCTestCase {
    nonisolated(unsafe) private var root: URL!
    private let protect = "protect-only"
    private let school = "school-ws"
    private let pro = "pro-ws"
    private let schoolProtect = "school-protect-ws"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-guard-\(UUID().uuidString)", isDirectory: true)
        let workspaces = root.appendingPathComponent("Jamf-Reports", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaces, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", workspaces.path, 1)
        ProfileAuthMethod.invalidateCache()
        try workspace(protect, config: "jamf_cli:\n  profile: \(protect)\n")
        try workspace(pro, config: "jamf_cli:\n  profile: \(pro)\n")
        try workspace(schoolProtect, config: "school_cli:\n  enabled: true\n"
            + "protect:\n  enabled: true\n  profile: school-protect-login\n")
        try workspace(school, config: """
            school_cli:
              enabled: true
              profile: \(school)
            html:
              with_workbook: true

            """)
    }

    override func tearDownWithError() throws {
        ProfileAuthMethod.invalidateCache()
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        try? FileManager.default.removeItem(at: root)
    }

    private func workspace(_ slug: String, config: String) throws {
        let dir = try XCTUnwrap(ProfileService.workspaceURL(for: slug))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try config.write(
            to: dir.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
    }

    private func automation(_ slug: String) throws -> URL {
        try XCTUnwrap(ProfileService.workspaceURL(for: slug)).appendingPathComponent("automation")
    }

    // MARK: - collect, backup, device

    func testCollectRefusesAProtectProfileBeforeAnyRunRecord() throws {
        try ProductGuardSeed.seed(profile: protect, product: "protect", in: root)
        let refusal = try XCTUnwrap(Collect.refusal(
            profile: protect, config: collectRoutingConfig(profile: protect)))
        XCTAssertTrue(refusal.contains("'\(protect)' is a Jamf Protect profile"), refusal)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try automation(protect).path),
                       "a refusal must leave no Run History record")
    }

    func testCollectDoesNotRefuseAJamfProOrSchoolWorkspace() throws {
        try ProductGuardSeed.seed(profile: pro, product: "pro", in: root)
        XCTAssertNil(Collect.refusal(profile: pro, config: collectRoutingConfig(profile: pro)))
        XCTAssertNil(Collect.refusal(
            profile: school, config: collectRoutingConfig(profile: school)))
    }

    func testBackupAndDeviceRefuseAProtectProfile() async throws {
        try ProductGuardSeed.seed(profile: protect, product: "protect", in: root)
        let backup = try XCTUnwrap(Backup.refusal(profile: protect))
        XCTAssertTrue(backup.hasPrefix("Backup is a Jamf Pro command; '\(protect)' is"), backup)
        let device = await Device.refusal(profile: protect)
        XCTAssertTrue(try XCTUnwrap(device).hasPrefix("Device lookup is a Jamf Pro command"))
    }

    func testBackupAndDeviceLetAJamfProProfileThrough() async throws {
        try ProductGuardSeed.seed(profile: pro, product: "pro", in: root)
        XCTAssertNil(Backup.refusal(profile: pro))
        let device = await Device.refusal(profile: pro)
        XCTAssertNil(device)
    }

    /// The School reason comes from config.yaml, so it holds where jamf-cli is not installed
    /// (no resolvable auth method), instead of "jamf-cli not found".
    func testBackupRefusesAJamfSchoolWorkspaceWithoutJamfCLI() throws {
        XCTAssertEqual(
            Backup.refusal(profile: school), CollectRouter.schoolBackupReason(profile: school))
    }

    /// With a Protect profile, `backup` takes a School workspace and backs up Protect alone.
    func testBackupTakesAJamfSchoolWorkspaceWithProtect() throws {
        XCTAssertNil(Backup.refusal(profile: schoolProtect))
    }

    // MARK: - html and generate

    func testHtmlRefusesAJamfSchoolWorkspace() throws {
        let schoolConfig = try XCTUnwrap(collectRoutingConfig(profile: school))
        let refusal = try XCTUnwrap(Html.refusal(config: schoolConfig, profile: school))
        XCTAssertTrue(refusal.contains("jamf-reports generate"), refusal)
        let proConfig = try XCTUnwrap(collectRoutingConfig(profile: pro))
        XCTAssertNil(Html.refusal(config: proConfig, profile: pro))
    }

    /// The School workbook, whatever the template, and no HTML beside it although
    /// `html.with_workbook` is on.
    func testGenerateOnAJamfSchoolWorkspaceWritesTheSchoolWorkbookOnly() async throws {
        // The default folder: --output under the temp directory is a refused sensitive path.
        let cmd = try Generate.parse(["--profile", school, "--template", "executive"])
        try await cmd.run()
        let reports = try XCTUnwrap(ProfileService.workspaceURL(for: school))
            .appendingPathComponent("Generated Reports")
        let files = try FileManager.default.contentsOfDirectory(atPath: reports.path)
        XCTAssertEqual(files.filter { $0.hasSuffix(".xlsx") }.count, 1, "\(files)")
        XCTAssertTrue(files.filter { $0.hasSuffix(".html") }.isEmpty, "\(files)")
    }

    // MARK: - schedules

    func testSchedulesListPrintsTheEffectiveMode() throws {
        func record(_ mode: String) throws -> ScheduleRecord {
            try JSONDecoder().decode(
                ScheduleRecord.self,
                from: Data(#"{"label":"l","mode":"\#(mode)"}"#.utf8))
        }
        XCTAssertEqual(Schedules.List.effectiveMode(of: try record("csv-assisted")),
                       "jamf-cli-full (was csv-assisted)")
        XCTAssertEqual(Schedules.List.effectiveMode(of: try record("backup")), "backup")
        XCTAssertEqual(Schedules.List.effectiveMode(of: try record("from-the-future")),
                       "from-the-future")
    }

    func testSchedulesAddRefusesBackupForAJamfSchoolWorkspace() throws {
        func add(_ mode: String, all: Bool = false) throws -> ScheduleRecord {
            try Schedules.Add.record(
                name: "x", profile: school, allProfiles: all, exclude: nil,
                mode: mode, cadence: "Daily 06:20", tiers: nil, disabled: false)
        }
        // The same rule and words as the `backup` command.
        XCTAssertThrowsError(try add("backup")) {
            XCTAssertEqual("\($0)", Backup.refusal(profile: school))
        }
        // School collects and generates; an all-profiles schedule skips per profile at run time.
        XCTAssertNoThrow(try add("snapshot-only"))
        XCTAssertNoThrow(try add("backup", all: true))
    }
}
