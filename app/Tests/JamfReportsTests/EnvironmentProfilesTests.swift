import XCTest
@testable import JamfReports

/// `EnvironmentProfiles.resolve`: one test per old config shape (environment model spec 3.3),
/// then the `profiles:` block, which wins over the old keys.
@MainActor
final class EnvironmentProfilesTests: XCTestCase {
    private let ws = "ws"

    private func resolve(
        _ yaml: String, auth: ProfileAuthMethod.Resolved? = nil
    ) throws -> EnvironmentProfiles {
        EnvironmentProfiles.resolve(
            config: try ConfigLoader.loadFromString(yaml), workspace: ws, auth: auth)
    }

    // MARK: - Old shapes

    func testProWorkspaceOverOAuthFillsJamfProWithTheWorkspace() throws {
        let environment = try resolve("jamf_cli:\n  data_dir: data\n",
                                      auth: .init(authMethod: "oauth2", isTenantLevel: false))
        XCTAssertEqual(environment, EnvironmentProfiles(jamfPro: ws))
        XCTAssertEqual(EnvironmentProfiles.resolve(config: nil, workspace: ws),
                       EnvironmentProfiles(jamfPro: ws), "no config.yaml is the same shape")
    }

    func testProWorkspaceOnAPlatformProfileFillsJamfProAndPlatform() throws {
        let environment = try resolve("jamf_cli:\n  data_dir: data\n",
                                      auth: .init(authMethod: "platform", isTenantLevel: false))
        XCTAssertEqual(environment.jamfPro, ws)
        XCTAssertEqual(environment.platform, ws)
    }

    func testProtectEnabledNamesItsLogin() throws {
        let on = try resolve("protect:\n  enabled: true\n  profile: \" ws-protect \"\n")
        XCTAssertEqual(on.protect, "ws-protect")
        XCTAssertFalse(on.protectWithoutProfile)
        XCTAssertTrue(on.runsProtect)

        let blank = try resolve("protect:\n  enabled: true\n  profile: \"\"\n")
        XCTAssertNil(blank.protect)
        XCTAssertTrue(blank.protectWithoutProfile, "asked for, with no login: collect says so")
        XCTAssertTrue(blank.runsProtect)

        let off = try resolve("protect:\n  enabled: false\n  profile: ws-protect\n")
        XCTAssertNil(off.protect)
        XCTAssertFalse(off.runsProtect)
    }

    func testPrimarySchoolFillsJamfSchoolAndLeavesJamfProBlank() throws {
        for yaml in ["school_cli:\n  enabled: true\n  profile: ws\n",
                     "school_cli:\n  enabled: true\n"] {
            let environment = try resolve(yaml)
            XCTAssertEqual(environment, EnvironmentProfiles(jamfSchool: ws), yaml)
            XCTAssertTrue(environment.isSchool)
        }
    }

    func testForeignSchoolLoginIsIgnoredAndNamedForDiscovery() throws {
        let environment = try resolve("school_cli:\n  enabled: true\n  profile: other-school\n")
        XCTAssertEqual(environment.jamfPro, ws)
        XCTAssertNil(environment.jamfSchool)
        XCTAssertEqual(environment.foreignSchool, "other-school")
        XCTAssertEqual(environment.connectedProfiles, ["other-school"])
    }

    func testJamfCLIProfileEqualToTheWorkspaceHasNoEffect() throws {
        XCTAssertEqual(
            try resolve("jamf_cli:\n  profile: ws\n"),
            EnvironmentProfiles(jamfPro: ws, namedOwner: ws))
    }

    /// P2: commands run as the workspace whatever `jamf_cli.profile` says; the key is kept only
    /// as the folder's named owner, for the case-variant and copied-folder checks.
    func testJamfCLIProfileNamingAnotherProfileNamesNoCommandProfile() throws {
        let environment = try resolve("jamf_cli:\n  profile: other\n")
        XCTAssertEqual(environment.jamfPro, ws)
        XCTAssertEqual(environment.mdm, ws)
        XCTAssertEqual(environment.namedOwner, "other")
        XCTAssertNil(environment.refusal(workspace: ws))
    }

    func testOldShapesNeverRefuse() throws {
        for yaml in ["jamf_cli:\n  profile: other\n", "school_cli:\n  enabled: true\n",
                     "protect:\n  enabled: true\n"] {
            XCTAssertNil(try resolve(yaml).refusal(workspace: ws), yaml)
        }
    }

    // MARK: - profiles block

    func testTheBlockWinsAndTheOldKeysAreNotRead() throws {
        let environment = try resolve("""
            jamf_cli:
              profile: legacy
            protect:
              enabled: true
              profile: legacy-protect
            school_cli:
              enabled: true
              profile: ws
            profiles:
              jamf_pro: ws
              platform: " ws-API "
              jamf_school: ""
              protect: ws-protect
              security_cloud: ws-radar
            """)
        XCTAssertEqual(environment, EnvironmentProfiles(
            jamfPro: ws, platform: "ws-API", protect: "ws-protect", securityCloud: "ws-radar",
            namedOwner: ws, source: .profilesBlock))
        XCTAssertFalse(environment.isSchool)
        XCTAssertEqual(environment.protectKey, "profiles.protect")
        XCTAssertEqual(environment.connectedProfiles, ["ws-API", "ws-protect", "ws-radar"])
        XCTAssertNil(environment.refusal(workspace: ws))
    }

    func testABlockWithoutProtectHasNoProtectWhateverTheOldKeysSay() throws {
        let config = try ConfigLoader.loadFromString(
            "protect:\n  enabled: true\n  profile: p\nprofiles:\n  jamf_pro: ws\n")
        XCTAssertFalse(EnvironmentProfiles.runsProtect(config))
        XCTAssertFalse(ProfileProductType.detect(from: config, profile: ws).runsProtect)
    }

    func testABlockNamingJamfSchoolRoutesToSchool() throws {
        let config = try ConfigLoader.loadFromString(
            "profiles:\n  jamf_school: ws\n  protect: ws-protect\n")
        let detected = ProfileProductType.detect(from: config, profile: ws)
        XCTAssertEqual(detected.type, .jamfSchool)
        XCTAssertTrue(detected.runsProtect)
    }

    func testBlockRefusals() throws {
        let both = try resolve("profiles:\n  jamf_pro: ws\n  jamf_school: ws\n")
        XCTAssertTrue(both.refusal(workspace: ws)?.contains("one environment has one MDM") == true)
        let none = try resolve("profiles:\n  protect: ws-protect\n")
        XCTAssertTrue(none.refusal(workspace: ws)?.contains("names neither") == true)
        let other = try resolve("profiles:\n  jamf_pro: tenant-b\n")
        XCTAssertEqual(other.refusal(workspace: ws),
                       "profiles.jamf_pro names 'tenant-b' but this workspace is 'ws', so nothing "
                           + "runs. Set profiles.jamf_pro to 'ws'.")
        let school = try resolve("profiles:\n  jamf_school: tenant-b\n")
        XCTAssertTrue(
            school.refusal(workspace: ws)?.hasPrefix("profiles.jamf_school names") == true)
    }

    func testEntryPointsRefuseABlockThatCannotRun() throws {
        let config = try ConfigLoader.loadFromString("profiles:\n  jamf_pro: tenant-b\n")
        let refusal = try XCTUnwrap(EnvironmentProfiles.resolve(config: config, workspace: ws)
            .refusal(workspace: ws))
        XCTAssertEqual(
            CollectRouter.proRunRefusal(profile: ws, operation: "Collect", config: config), refusal)
        XCTAssertEqual(CollectRouter.backupRefusal(profile: ws, config: config), refusal)
    }

    func testTheRouterRefusesABlockThatCannotRunWithOneErrorLine() async throws {
        let config = try ConfigLoader.loadFromString(
            "profiles:\n  jamf_pro: ws\n  jamf_school: ws\n")
        let calls = EnvCalls()
        do {
            try await CollectRouter.run(
                workspace: WorkspaceID(validating: ws), config: config, now: .testNoon,
                proCollect: { _, _, _, _, _, _, _ in calls.add("pro"); return .collected },
                schoolCollect: { _, _, _, _, _, _ in calls.add("school") },
                protectCollect: { _, _, _ in calls.add("protect") },
                resolved: { _ in nil }, onLine: { calls.add($0.text) })
            XCTFail("two MDMs must not collect")
        } catch CLIBridgeError.wrongProduct(let refusal) {
            XCTAssertTrue(refusal.contains("one environment has one MDM"), refusal)
        }
        XCTAssertEqual(calls.all.count, 1, "\(calls.all)")
        XCTAssertTrue(calls.all.first?.hasPrefix("[error] config.yaml names both") == true)
    }

    func testTheRouterCollectsProtectWithTheBlocksLogin() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EnvProfiles-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(ws, isDirectory: true),
            withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        addTeardownBlock {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: root)
        }
        let config = try ConfigLoader.loadFromString(
            "protect:\n  enabled: false\nprofiles:\n  jamf_pro: ws\n  protect: ws-protect\n")
        let calls = EnvCalls()
        try await CollectRouter.run(
            workspace: WorkspaceID(validating: ws), config: config, now: .testNoon,
            proCollect: { _, profile, _, _, _, _, _ in
                calls.add("pro \(profile)"); return .collected
            },
            schoolCollect: { _, _, _, _, _, _ in calls.add("school") },
            protectCollect: { profile, _, _ in calls.add("protect \(profile)") },
            resolved: { _ in nil }, onLine: { _ in })
        XCTAssertEqual(calls.all, ["pro ws", "protect ws-protect"])
    }

    func testAnEmptyBlockIsRefused() throws {
        let environment = try resolve("profiles: {}\n")
        XCTAssertEqual(environment.source, .profilesBlock)
        XCTAssertTrue(environment.refusal(workspace: ws)?.contains("names neither") == true)
    }

    func testANonTextSlotFailsTheDecodeAndANumberReadsAsItsDigits() throws {
        XCTAssertThrowsError(try ConfigLoader.loadFromString("profiles:\n  jamf_pro: [a, b]\n"))
        XCTAssertEqual(try resolve("profiles:\n  jamf_pro: 2024\n").jamfPro, "2024")
        XCTAssertEqual(try resolve("profiles:\n  jamf_pro: ws\n  protect: \"true\"\n").protect,
                       "true", "a profile may be named like a boolean")
    }

    func testTheRouterCollectsSchoolForASchoolBlock() async throws {
        let config = try ConfigLoader.loadFromString("profiles:\n  jamf_school: ws\n")
        let calls = EnvCalls()
        try await CollectRouter.run(
            workspace: WorkspaceID(validating: ws), config: config, now: .testNoon,
            proCollect: { _, _, _, _, _, _, _ in calls.add("pro"); return .collected },
            schoolCollect: { _, profile, _, _, _, _ in calls.add("school \(profile)") },
            protectCollect: { _, _, _ in calls.add("protect") },
            resolved: { _ in nil }, onLine: { _ in })
        XCTAssertEqual(calls.all, ["school ws"])
    }

    func testProtectBackupPlanReadsTheBlock() throws {
        func plan(_ yaml: String) throws -> ProtectBackup.Plan {
            ProtectBackup.plan(
                config: try ConfigLoader.loadFromString(yaml), workspaceProfile: ws,
                pinAllows: { true }, sharedStorage: { nil })
        }
        XCTAssertEqual(try plan("profiles:\n  jamf_pro: ws\n  protect: ws-protect\n"),
                       .run(profile: "ws-protect"))
        XCTAssertEqual(
            try plan("protect:\n  enabled: true\n  profile: p\nprofiles:\n  jamf_pro: ws\n"),
            .notConnected, "protect.* is not read under the block")
        XCTAssertEqual(try plan("profiles:\n  jamf_school: ws\n  protect: ws-protect\n"),
                       .notConnected, "a School workspace has no backup")
        let drifted = ProtectBackup.plan(
            config: try ConfigLoader.loadFromString("profiles:\n  jamf_pro: ws\n  protect: p\n"),
            workspaceProfile: ws, pinAllows: { false }, sharedStorage: { nil })
        XCTAssertEqual(drifted, .skip(reason: "profiles.protect changed in the shared config.yaml "
            + "and is not confirmed on this Mac (Config Doctor)"))
    }

    // MARK: - Schema and pin

    func testConfigSchemaKnowsEverySlot() throws {
        let root = try ConfigLoader.rawMapping(fromYAML: """
            profiles:
              jamf_pro: a
              platform: b
              jamf_school: ""
              protect: c
              security_cloud: d
              jamf_protect: e
            """)
        XCTAssertEqual(ConfigSchema.unknownKeys(in: root).map(\.keyPath), ["profiles.jamf_protect"])
    }

    func testThePinReadsTheBlocksProtectLoginOnceTheBlockExists() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("EnvPin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: workspace) }
        let config = workspace.appendingPathComponent("config.yaml")

        try "protect:\n  enabled: true\n  profile: old-protect\n"
            .write(to: config, atomically: true, encoding: .utf8)
        XCTAssertEqual(SharedConfigPin.current(workspace: workspace)?.protectProfile, "old-protect")

        try "protect:\n  enabled: true\n  profile: old-protect\n"
            .appending("profiles:\n  protect: peer-protect\n")
            .write(to: config, atomically: true, encoding: .utf8)
        XCTAssertEqual(
            SharedConfigPin.current(workspace: workspace)?.protectProfile, "peer-protect",
            "a peer that adds the block changes the pinned value, which reads as drift")
    }
}

private final class EnvCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []

    func add(_ call: String) {
        lock.lock(); defer { lock.unlock() }
        calls.append(call)
    }

    var all: [String] {
        lock.lock(); defer { lock.unlock() }
        return calls
    }
}
