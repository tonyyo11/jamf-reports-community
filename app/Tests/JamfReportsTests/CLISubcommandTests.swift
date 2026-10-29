import Foundation
import XCTest
@testable import JamfReports

/// `check` and `school-check` run through the real `runCheck` / `runSchoolCheck` from
/// `HeadlessRun.swift`, in a workspaces root of their own.
final class CLISubcommandTests: XCTestCase {
    nonisolated(unsafe) private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-subcommand-\(UUID().uuidString)", isDirectory: true)
        let workspaces = root.appendingPathComponent("Jamf-Reports", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaces, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", workspaces.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        try? FileManager.default.removeItem(at: root)
    }

    private func workspace(_ slug: String, config: String) throws {
        let dir = try XCTUnwrap(ProfileService.workspaceURL(for: slug))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try config.write(
            to: dir.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
    }

    // MARK: - check

    func testCheckInvalidProfileExits1() {
        XCTAssertEqual(runCheck(profile: "INVALID PROFILE!!!"), 1)
    }

    func testCheckMissingConfigExits1() {
        XCTAssertEqual(runCheck(profile: "no-such-workspace"), 1)
    }

    // MARK: - school-check

    func testSchoolCheckInvalidProfileExits1() {
        XCTAssertEqual(runSchoolCheck(profile: "INVALID!!!"), 1)
    }

    func testSchoolCheckMissingConfigExits1() {
        XCTAssertEqual(runSchoolCheck(profile: "no-such-workspace"), 1)
    }

    /// Before this, a Jamf Pro workspace printed a [miss] line per School kind and exited 0.
    func testSchoolCheckRefusesAWorkspaceThatIsNotJamfSchool() throws {
        try workspace("pro-ws", config: "jamf_cli:\n  profile: pro-ws\n")
        XCTAssertEqual(runSchoolCheck(profile: "pro-ws"), 1)
    }

    func testSchoolCheckPassesAJamfSchoolWorkspace() throws {
        try workspace("school-ws", config: "school_cli:\n  enabled: true\n  profile: school-ws\n")
        XCTAssertEqual(runSchoolCheck(profile: "school-ws"), 0)
    }
}
