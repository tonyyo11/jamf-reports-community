import XCTest
@testable import JamfReports

/// A workspace whose jamf-cli profile does not exist (a setup left part way, or a profile removed
/// in Terminal): collect stops before any command with "jamf-cli has no profile named", and
/// scheduled runs skip the workspace. "Could not ask" never counts as missing.
final class MissingJamfCLIProfileTests: XCTestCase {
    private var root: URL!
    private let profile = "leftover"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-profile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        ProfileAuthMethod.invalidateCache()
    }

    override func tearDownWithError() throws {
        ProfileAuthMethod.invalidateCache()
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        try? FileManager.default.removeItem(at: root)
    }

    /// Answers `config list` with `rows`, `--version` with 1.33.0, anything else with `[]`.
    /// Not named `jamf-cli`, so the codesign gate leaves it alone.
    private func stub(_ rows: String, log: URL? = nil) throws -> URL {
        let url = root.appendingPathComponent("stub-cli")
        var script = "#!/bin/sh\n"
        if let log { script += "printf '%s\\n' \"$*\" >> \"\(log.path)\"\n" }
        script += "case \"$1\" in\nconfig) printf '%s' '[\(rows)]' ;;\n"
        script += "--version) echo 'jamf-cli version 1.33.0' ;;\n*) printf '[]' ;;\nesac\n"
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func testNamesReadsEveryListedProfileAndNilForUnreadable() {
        XCTAssertEqual(
            JamfCLIConfigList.names(data: Data(#"[{"name":"a"},{"name":"b"}]"#.utf8)), ["a", "b"])
        XCTAssertEqual(JamfCLIConfigList.names(data: Data("[]".utf8)), [])
        XCTAssertNil(JamfCLIConfigList.names(data: Data("not json".utf8)))
    }

    func testIsAbsentOnlyWhenTheListWasReadAndLacksTheProfile() throws {
        XCTAssertTrue(ProfileAuthMethod.isAbsent(
            profile: profile, binary: try stub(#"{"name":"other","auth-method":"oauth2"}"#)))
        ProfileAuthMethod.invalidateCache()
        XCTAssertFalse(ProfileAuthMethod.isAbsent(
            profile: profile, binary: try stub(#"{"name":"leftover","auth-method":"oauth2"}"#)))
        XCTAssertFalse(ProfileAuthMethod.isAbsent(profile: profile, binary: nil),
                       "no jamf-cli is 'could not ask', not missing")
        let broken = root.appendingPathComponent("broken-cli")
        try "#!/bin/sh\nexit 1\n".write(to: broken, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: broken.path)
        XCTAssertFalse(ProfileAuthMethod.isAbsent(profile: profile, binary: broken))
    }

    func testMissingWorkspacesNeedAReadableList() throws {
        for name in ["kept", profile] {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "jamf_cli:\n  profile: \"\(name)\"\n".write(
                to: folder.appendingPathComponent("config.yaml"), atomically: true,
                encoding: .utf8)
        }
        XCTAssertEqual(
            ProfileService.workspacesMissingJamfCLIProfile(listed: ["kept"], under: root),
            [profile])
        XCTAssertEqual(
            ProfileService.workspacesMissingJamfCLIProfile(listed: nil, under: root), [],
            "an unreadable list must not stop every workspace collecting")
    }

    func testCollectStopsBeforeAnyCommandAndSaysProfileNotFound() async throws {
        let workspaces = root.appendingPathComponent("Jamf-Reports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspaces.appendingPathComponent(profile, isDirectory: true),
            withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", workspaces.path, 1)
        let log = root.appendingPathComponent("calls.log")
        let bin = try stub(#"{"name":"other","auth-method":"oauth2"}"#, log: log)
        let lines = LineSink()
        do {
            _ = try await ReportEngine.collect(
                workspace: WorkspaceID(validating: profile),
                profile: profile, workspacePaths: WorkspacePaths.self, tiers: [.refresh],
                force: true, authConfirmationProbe: { _, _ in false },
                locateJamfCLI: { bin }, refreshSOFA: { _ in (.empty, []) },
                onLine: lines.append)
            XCTFail("a profile jamf-cli does not have must not collect")
        } catch ReportEngineError.profileNotFound(let name) {
            XCTAssertEqual(name, profile)
        }
        let errors = lines.texts.filter { $0.hasPrefix("[error]") }
        XCTAssertEqual(errors.count, 1, "\(lines.texts)")
        XCTAssertTrue(errors[0].contains("jamf-cli has no profile named 'leftover'"), errors[0])
        XCTAssertFalse(errors[0].contains("unreachable"))
        let calls = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        XCTAssertFalse(calls.contains("pro "), "no Jamf Pro command ran: \(calls)")
    }

    func testTheAttentionItemPointsAtAutomation() {
        XCTAssertEqual(AttentionCode.jamfCLIProfileMissing.destination, .automation)
    }
}

private final class LineSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var texts: [String] { lock.withLock { storage } }
    func append(_ line: CLIBridge.LogLine) { lock.withLock { storage.append(line.text) } }
}
