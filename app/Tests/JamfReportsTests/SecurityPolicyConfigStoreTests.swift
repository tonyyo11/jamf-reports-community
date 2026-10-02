import XCTest
@testable import JamfReports

/// The Config → Scoring editor writes `security_policy:` through its own scoped writer, so a
/// save must keep every other key in the file, including what an operator typed by hand.
/// Fixtures are hand-written `config.yaml` text in the shapes `config.example.yaml` documents.
final class SecurityPolicyConfigStoreTests: XCTestCase {

    private let profile = "jrc-policy-writer"

    private func withWorkspacesRoot(_ body: () throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-policy-writer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let saved = ProcessInfo.processInfo.environment["JRC_TEST_WORKSPACES_ROOT"]
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        defer {
            if let saved { setenv("JRC_TEST_WORKSPACES_ROOT", saved, 1) }
            else { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
            try? FileManager.default.removeItem(at: root)
        }
        try body()
    }

    private func configURL() throws -> URL {
        let workspace = try XCTUnwrap(ProfileService.workspaceURL(for: profile))
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return workspace.appendingPathComponent("config.yaml")
    }

    private func write(_ yaml: String) throws {
        try yaml.write(to: try configURL(), atomically: true, encoding: .utf8)
    }

    private func readBack() throws -> String {
        try String(contentsOf: try configURL(), encoding: .utf8)
    }

    // MARK: - Round trip

    func testSaveThenLoadReturnsAnEqualPolicy() throws {
        try withWorkspacesRoot {
            try write("columns:\n  serial_number: \"Serial Number\"\n")
            let policy = SecurityControlPolicy(
                fileVault: .warning, sip: .ignore, firewall: .fail, gatekeeper: .warning,
                fileVaultOffHardwareEncrypted: .fail)

            try SecurityPolicyConfigWriter.save(policy, profile: profile)

            XCTAssertEqual(SecurityPolicyConfigLoader.load(profile: profile), policy)
            XCTAssertEqual(SecurityPolicyConfigLoader.issues(profile: profile), [])
        }
    }

    func testEachLevelRoundTripsForEachControl() throws {
        try withWorkspacesRoot {
            for level in SecurityControlLevel.allCases {
                for control in SecurityControl.allCases {
                    var policy = SecurityControlPolicy.default
                    switch control {
                    case .fileVault: policy.fileVault = level
                    case .sip: policy.sip = level
                    case .firewall: policy.firewall = level
                    case .gatekeeper: policy.gatekeeper = level
                    }
                    try write("security_policy:\n  controls:\n    sip: ignore\n")
                    try SecurityPolicyConfigWriter.save(policy, profile: profile)
                    XCTAssertEqual(SecurityPolicyConfigLoader.load(profile: profile), policy,
                                   "\(control) at \(level)")
                }
            }
        }
    }

    func testSaveCreatesTheConfigWhenAbsent() throws {
        try withWorkspacesRoot {
            try SecurityPolicyConfigWriter.save(
                SecurityControlPolicy(sip: .warning), profile: profile)
            XCTAssertEqual(SecurityPolicyConfigLoader.load(profile: profile),
                           SecurityControlPolicy(sip: .warning))
        }
    }

    // MARK: - What a save keeps

    func testSaveKeepsNotifyChartsAndTheOtherSecurityPolicyKeys() throws {
        try withWorkspacesRoot {
            try write("""
            columns:
              serial_number: "Serial Number"
            notify:
              enabled: true
              provider: "teams"
            security_policy:
              mode: strict
              controls:
                filevault: fail
                sip: fail
                custom_control: warning
              score_weights:
                sip: 5
            charts:
              save_png: false
              os_adoption:
                per_major_charts: false
            """)

            try SecurityPolicyConfigWriter.save(
                SecurityControlPolicy(sip: .warning), profile: profile)

            let text = try readBack()
            for kept in ["Serial Number", "notify:", "provider: \"teams\"", "charts:",
                         "save_png: false", "per_major_charts: false", "mode: strict",
                         "custom_control: warning", "score_weights:", "sip: 5"] {
                XCTAssertTrue(text.contains(kept), "a save dropped \(kept)")
            }
            XCTAssertEqual(SecurityPolicyConfigLoader.load(profile: profile).sip, .warning)
            XCTAssertEqual(
                SecurityPolicyConfigLoader.issues(profile: profile).map(\.keyPath),
                ["security_policy.mode", "security_policy.controls.custom_control"])
        }
    }

    func testANilHardwareLevelRemovesTheKey() throws {
        try withWorkspacesRoot {
            try write("""
            security_policy:
              controls:
                filevault: fail
              filevault_off_hardware_encrypted: warning
            """)

            try SecurityPolicyConfigWriter.save(.default, profile: profile)

            XCTAssertFalse(try readBack().contains("filevault_off_hardware_encrypted"))
            XCTAssertNil(SecurityPolicyConfigLoader.load(profile: profile)
                .fileVaultOffHardwareEncrypted)
        }
    }

    func testAHardwareLevelIsWrittenAndReplaced() throws {
        try withWorkspacesRoot {
            try write("security_policy:\n  filevault_off_hardware_encrypted: warning\n")
            try SecurityPolicyConfigWriter.save(
                SecurityControlPolicy(fileVaultOffHardwareEncrypted: .ignore), profile: profile)
            XCTAssertEqual(SecurityPolicyConfigLoader.load(profile: profile)
                .fileVaultOffHardwareEncrypted, .ignore)
        }
    }

    // MARK: - Hand-typed values

    /// Saving one control must not rewrite the others: a synonym stays as typed, and a typo
    /// the app already treats as fail stays in the file, still reported, until its own row is
    /// changed.
    func testASaveLeavesAnotherControlsTypedValueAsTyped() throws {
        try withWorkspacesRoot {
            try write("""
            security_policy:
              controls:
                firewall: warn
                gatekeeper: strcit
            """)
            let policy = SecurityControlPolicy(
                fileVault: .warning, firewall: .warning, gatekeeper: .fail)

            try SecurityPolicyConfigWriter.save(policy, profile: profile)

            let text = try readBack()
            XCTAssertTrue(text.contains("firewall: warn\n"), "a synonym stays as typed")
            XCTAssertTrue(text.contains("gatekeeper: strcit"), "an unchanged typo stays")
            XCTAssertEqual(SecurityPolicyConfigLoader.load(profile: profile), policy)
            XCTAssertEqual(SecurityPolicyConfigLoader.issues(profile: profile).map(\.keyPath),
                           ["security_policy.controls.gatekeeper"])
        }
    }

    func testChoosingALevelForATypoedControlWritesIt() throws {
        try withWorkspacesRoot {
            try write("""
            security_policy:
              controls:
                sip: wrn
                gatekeeper: strcit
            """)

            try SecurityPolicyConfigWriter.save(
                SecurityControlPolicy(sip: .warning), profile: profile)

            XCTAssertEqual(SecurityPolicyConfigLoader.load(profile: profile).sip, .warning)
            XCTAssertEqual(SecurityPolicyConfigLoader.issues(profile: profile).map(\.keyPath),
                           ["security_policy.controls.gatekeeper"],
                           "only the changed key's issue clears")
        }
    }

    func testASynonymIsReplacedWhenTheLevelChanges() throws {
        try withWorkspacesRoot {
            try write("security_policy:\n  controls:\n    sip: skip\n")
            try SecurityPolicyConfigWriter.save(
                SecurityControlPolicy(sip: .warning), profile: profile)
            XCTAssertEqual(SecurityPolicyConfigLoader.load(profile: profile).sip, .warning)
            XCTAssertFalse(try readBack().contains("skip"))
        }
    }

    /// The decoder keeps the last of a repeated key, so a save has to change that one.
    func testARepeatedControlKeyIsWrittenOnce() throws {
        try withWorkspacesRoot {
            try write("security_policy:\n  controls:\n    sip: ignore\n    sip: fail\n")
            try SecurityPolicyConfigWriter.save(
                SecurityControlPolicy(sip: .warning), profile: profile)
            XCTAssertEqual(SecurityPolicyConfigLoader.load(profile: profile).sip, .warning)
            XCTAssertEqual(try readBack().components(separatedBy: "sip:").count, 2)
        }
    }

    func testASaveReplacesABlockOfTheWrongShapeOnlyWhenALevelChanges() throws {
        try withWorkspacesRoot {
            try write("security_policy:\n  controls: strict\n")
            try SecurityPolicyConfigWriter.save(.default, profile: profile)
            XCTAssertTrue(try readBack().contains("controls: strict"), "nothing to write")

            try SecurityPolicyConfigWriter.save(
                SecurityControlPolicy(sip: .warning), profile: profile)
            XCTAssertEqual(SecurityPolicyConfigLoader.load(profile: profile).sip, .warning)
            XCTAssertEqual(SecurityPolicyConfigLoader.issues(profile: profile), [])
        }
    }

    // MARK: - Errors

    func testAnInvalidProfileThrows() {
        XCTAssertThrowsError(
            try SecurityPolicyConfigWriter.save(.default, profile: "escape\n")
        ) { error in
            XCTAssertEqual(
                error.localizedDescription, "Invalid profile name: escape\n")
        }
    }

    func testARootThatIsNotAMappingThrows() throws {
        try withWorkspacesRoot {
            try write("- one\n- two\n")
            XCTAssertThrowsError(
                try SecurityPolicyConfigWriter.save(.default, profile: profile))
        }
    }
}

/// The store holds the active workspace's policy and the issues in its hand-typed block, and
/// saves through the writer. Demo mode never reads or writes a workspace.
@MainActor
final class SecurityPolicyWorkspaceStoreTests: XCTestCase {

    private func withWorkspacesRoot(_ body: () async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-policy-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let saved = ProcessInfo.processInfo.environment["JRC_TEST_WORKSPACES_ROOT"]
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        defer {
            if let saved { setenv("JRC_TEST_WORKSPACES_ROOT", saved, 1) }
            else { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
            try? FileManager.default.removeItem(at: root)
        }
        try await body()
    }

    private func store(demo: Bool, profile: String? = nil) -> WorkspaceStore {
        let store = WorkspaceStore(
            demoMode: demo, jamfCLIProfileNames: { [] }, discoverProfiles: { [] },
            jamfCLIInstallation: { nil })
        if let profile { store.profile = profile }
        return store
    }

    private func configURL(_ profile: String) throws -> URL {
        let workspace = try XCTUnwrap(ProfileService.workspaceURL(for: profile))
        return workspace.appendingPathComponent("config.yaml")
    }

    private func writeConfig(_ yaml: String, profile: String) throws {
        let url = try configURL(profile)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try yaml.write(to: url, atomically: true, encoding: .utf8)
    }

    func testLoadingTheConfigReadsThePolicyAndItsIssues() async throws {
        try await withWorkspacesRoot {
            try writeConfig("""
            security_policy:
              mode: strict
              controls:
                sip: wrn
                firewall: warning
            """, profile: "policy-store")
            let store = store(demo: false, profile: "policy-store")

            try await store.loadConfig()

            XCTAssertEqual(store.securityPolicy, SecurityControlPolicy(firewall: .warning))
            XCTAssertEqual(store.securityPolicyIssues, [
                SecurityPolicyIssue(keyPath: "security_policy.mode", value: "", used: ""),
                SecurityPolicyIssue(
                    keyPath: "security_policy.controls.sip", value: "wrn", used: "fail"),
            ])
        }
    }

    func testSavingAValidLevelForTheBadKeyClearsOnlyThatIssue() async throws {
        try await withWorkspacesRoot {
            try writeConfig("""
            security_policy:
              mode: strict
              controls:
                sip: wrn
            """, profile: "policy-store")
            let store = store(demo: false, profile: "policy-store")
            try await store.loadConfig()
            XCTAssertEqual(store.securityPolicyIssues.count, 2)

            let saved = SecurityControlPolicy(sip: .warning)
            try store.saveSecurityPolicy(saved)

            XCTAssertEqual(store.securityPolicy, saved)
            XCTAssertEqual(store.securityPolicyIssues.map(\.keyPath), ["security_policy.mode"])
            XCTAssertEqual(SecurityPolicyConfigLoader.load(profile: "policy-store"), saved)
        }
    }

    func testAFailedSaveThrowsAndKeepsTheLoadedPolicy() async throws {
        try await withWorkspacesRoot {
            let store = store(demo: false, profile: "escape\n")

            XCTAssertThrowsError(
                try store.saveSecurityPolicy(SecurityControlPolicy(sip: .warning)))

            XCTAssertEqual(store.securityPolicy, .default)
        }
    }

    func testALoadWithNoConfigGivesTheDefaultPolicy() async throws {
        try await withWorkspacesRoot {
            try writeConfig("security_policy:\n  controls:\n    sip: warning\n",
                            profile: "policy-store-a")
            let store = store(demo: false, profile: "policy-store-a")
            try await store.loadConfig()
            XCTAssertEqual(store.securityPolicy.sip, .warning)

            store.profile = "policy-store-none"
            try await store.loadConfig()

            XCTAssertEqual(store.securityPolicy, .default)
            XCTAssertEqual(store.securityPolicyIssues, [])
        }
    }

    func testDemoModeReadsNoWorkspace() async throws {
        try await withWorkspacesRoot {
            let demoProfile = DemoData.org.profile
            try writeConfig("security_policy:\n  controls:\n    sip: ignore\n  mode: x\n",
                            profile: demoProfile)
            let store = store(demo: true)

            try await store.loadConfig()

            XCTAssertEqual(store.securityPolicy, .default)
            XCTAssertEqual(store.securityPolicyIssues, [])
        }
    }

    func testDemoModeSaveWritesNothing() async throws {
        try await withWorkspacesRoot {
            let store = store(demo: true)
            let url = try configURL(store.profile)

            try store.saveSecurityPolicy(SecurityControlPolicy(sip: .warning))
            let folder = url.deletingLastPathComponent().path
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder),
                           "no workspace folder is created for the demo profile")

            let text = "security_policy:\n  controls:\n    sip: ignore\n"
            try writeConfig(text, profile: store.profile)
            try store.saveSecurityPolicy(SecurityControlPolicy(sip: .warning))
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), text)
            XCTAssertEqual(store.securityPolicy, .default)
        }
    }
}
