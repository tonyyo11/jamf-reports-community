import Foundation
import XCTest
@testable import JamfReports

/// A Platform API profile that names neither an environment nor a tenant is an
/// organization-level integration: it reaches Jamf Account only, so no Jamf Pro report can come
/// back. It is refused at adoption, collect stops at one `[error]` line, and Config Doctor fails
/// the workspace.
@MainActor
final class OrganizationLevelProfileTests: XCTestCase {
    private let profile = "orgprofile"
    nonisolated(unsafe) private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("org-level-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        ProfileAuthMethod.invalidateCache()
    }

    override func tearDownWithError() throws {
        ProfileAuthMethod.invalidateCache()
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        try? FileManager.default.removeItem(at: root)
    }

    private func list(_ rows: String) -> Data { Data("[\(rows)]".utf8) }

    // MARK: - Level from `config list`

    func testScopeLevelIsEnvironmentTenantOrOrganization() {
        let data = list("""
        {"name":"e","auth-method":"platform","environment-id":"e1"},
        {"name":"t","auth-method":"platform","tenant-id":"t1"},
        {"name":"o","auth-method":"platform"},
        {"name":"b","auth-method":"platform","environment-id":"e1","tenant-id":"t1"},
        {"name":"p","auth-method":"oauth2"}
        """)
        func level(_ name: String) -> PlatformScopeLevel? {
            JamfCLIConfigList.scopeLevel(data: data, profile: name)
        }
        XCTAssertEqual(level("e"), .environment)
        XCTAssertEqual(level("t"), .tenant)
        XCTAssertEqual(level("o"), .organization)
        XCTAssertEqual(level("b"), .environment, "environment wins, as in the tenant-level rule")
        XCTAssertNil(level("p"), "an oauth2 profile has no platform level")
        XCTAssertNil(level("absent"))
    }

    // MARK: - Resolve

    private func stub(_ rows: String, log: URL? = nil) throws -> URL {
        let url = root.appendingPathComponent("stub-cli")
        var script = "#!/bin/sh\n"
        if let log { script += "printf '%s\\n' \"$*\" >> \"\(log.path)\"\n" }
        script += "if [ \"$1\" = config ]; then\ncat <<'EOF'\n[\(rows)]\nEOF\n"
        script += "else\nprintf '[]'\nfi\n"
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func configFile(_ text: String) throws -> URL {
        let url = root.appendingPathComponent("config.yaml")
        try Data(text.utf8).write(to: url)
        return url
    }

    func testResolveFlagsAnOrganizationProfile() throws {
        let bin = try stub(#"{"name":"orgprofile","auth-method":"platform"}"#)
        let resolved = ProfileAuthMethod.resolve(profile: profile, binary: bin, configFile: nil)
        XCTAssertEqual(resolved?.isOrganizationLevel, true)
        XCTAssertEqual(resolved?.isTenantLevel, false)
    }

    func testResolveDoesNotFlagAProfileTheFileGivesAnID() throws {
        let bin = try stub(#"{"name":"orgprofile","auth-method":"platform"}"#)
        let file = try configFile("""
        profiles:
            orgprofile:
                auth-method: platform
                environment-id: abc
        """)
        let resolved = ProfileAuthMethod.resolve(profile: profile, binary: bin, configFile: file)
        XCTAssertEqual(resolved?.isOrganizationLevel, false,
                       "a jamf-cli that leaves the ID out of config list must not block a profile")
    }

    func testResolveKeepsEnvironmentTenantAndOAuth2Unflagged() throws {
        let bin = try stub("""
        {"name":"orgprofile","auth-method":"platform","tenant-id":"t1"}
        """)
        let tenant = ProfileAuthMethod.resolve(profile: profile, binary: bin, configFile: nil)
        XCTAssertEqual(tenant?.isOrganizationLevel, false)
        XCTAssertEqual(tenant?.isTenantLevel, true)
        ProfileAuthMethod.invalidateCache()
        let oauth = try stub(#"{"name":"orgprofile","auth-method":"oauth2"}"#)
        XCTAssertEqual(
            ProfileAuthMethod.resolve(profile: profile, binary: oauth, configFile: nil)?
                .isOrganizationLevel, false)
    }

    // MARK: - Collect

    private func prepareWorkspace() throws {
        let workspaces = root.appendingPathComponent("Jamf-Reports", isDirectory: true)
        let folder = workspaces.appendingPathComponent(profile, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", workspaces.path, 1)
        try "jamf_cli:\n  profile: \"\(profile)\"\n".write(
            to: folder.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
    }

    private func route(_ bin: URL, sink: Sink, calls: Counter) async throws {
        try await CollectRouter.run(
            workspace: WorkspaceID(validating: profile), tiers: [.scan], force: true, config: nil,
            proCollect: { _, _, _, _, _, _, _ in calls.bump(); return .collected },
            resolved: { ProfileAuthMethod.resolve(profile: $0, binary: bin, configFile: nil) },
            onLine: sink.append)
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func bump() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    func testCollectStopsWithOneErrorLineAndRunsNoCommand() async throws {
        try prepareWorkspace()
        let bin = try stub(#"{"name":"orgprofile","auth-method":"platform"}"#)
        let sink = Sink()
        let calls = Counter()
        do {
            try await route(bin, sink: sink, calls: calls)
            XCTFail("an organization-level profile must not collect")
        } catch CLIBridgeError.wrongProduct {
            // expected
        }
        let errors = sink.texts.filter { $0.hasPrefix("[error]") }
        XCTAssertEqual(errors.count, 1, "\(sink.texts)")
        XCTAssertTrue(errors[0].contains("organization-level"))
        XCTAssertTrue(errors[0].contains(PlatformScopeLevel.organizationLevelReason))
        XCTAssertFalse(errors[0].lowercased().contains("correct"), "no ID to correct")
        XCTAssertEqual(calls.value, 0, "no Jamf Pro command was sent")
    }

    func testCollectOnAnEnvironmentProfileIsNotRefused() async throws {
        try prepareWorkspace()
        let bin = try stub("""
        {"name":"orgprofile","auth-method":"platform","environment-id":"e1"}
        """)
        let calls = Counter()
        try await route(bin, sink: Sink(), calls: calls)
        XCTAssertEqual(calls.value, 1)
    }

    // MARK: - Adoption and Doctor

    func testAdoptionRefusesAnOrganizationProfileWithTheReason() async {
        func make(_ name: String, _ level: PlatformScopeLevel) -> JamfCLIProfile {
            JamfCLIProfile(
                name: name, url: "", schedules: 0, status: .idle, authMethod: "platform",
                product: .pro, platformLevel: level)
        }
        let flow = ExistingCLISetupFlow(profiles: [
            make("env", .environment), make("tenant", .tenant), make("org", .organization),
        ])
        XCTAssertEqual(flow.selected, ["env", "tenant"])
        XCTAssertEqual(flow.refusals["org"], PlatformScopeLevel.organizationLevelReason)
        XCTAssertTrue(PlatformScopeLevel.organizationLevelReason.contains(
            "An organization-level integration reaches only Jamf Account"))
        flow.selected.insert("org")
        var initialized: [String] = []
        await flow.run(initialize: { initialized.append($0); return 0 }, collect: { _, _ in 0 })
        XCTAssertEqual(initialized.sorted(), ["env", "tenant"])
    }

    func testDoctorFailsAnOrganizationLevelWorkspaceOnly() {
        let org = ProfileAuthMethod.Resolved(
            authMethod: "platform", isTenantLevel: false, isOrganizationLevel: true)
        let rows = ConfigDoctorService.organizationLevelRows(profile: profile, auth: org)
        XCTAssertEqual(rows.map(\.id), ["platform.organization_level"])
        XCTAssertEqual(rows.first?.severity, .fail)
        XCTAssertFalse((rows.first?.hint ?? "").lowercased().contains("correct"))
        XCTAssertTrue(ConfigDoctorService.organizationLevelRows(
            profile: profile,
            auth: .init(authMethod: "platform", isTenantLevel: true)).isEmpty)
        XCTAssertTrue(
            ConfigDoctorService.organizationLevelRows(profile: profile, auth: nil).isEmpty)
    }

    func testRunnableProfilesLeaveAnOrganizationProfileOutUntilItHasAFolder() {
        let org = JamfCLIProfile(
            name: "org", url: "", schedules: 0, status: .idle, authMethod: "platform",
            platformLevel: .organization)
        XCTAssertTrue(ProfileService.runnableProfiles(
            [org], excluding: [], hasWorkspace: { _ in false }).isEmpty)
        XCTAssertEqual(ProfileService.runnableProfiles(
            [org], excluding: [], hasWorkspace: { _ in true }).count, 1)
    }

    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        var append: @Sendable (CLIBridge.LogLine) -> Void {
            { line in self.lock.lock(); defer { self.lock.unlock() }; self.lines.append(line.text) }
        }
        var texts: [String] { lock.lock(); defer { lock.unlock() }; return lines }
    }
}
