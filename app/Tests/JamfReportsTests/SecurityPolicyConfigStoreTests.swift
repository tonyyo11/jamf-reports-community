import SwiftUI
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

    private func save(_ setting: SecurityPolicyConfigWriter.Setting) throws {
        try SecurityPolicyConfigWriter.save(setting, profile: profile)
    }

    private let custom: [SecurityScoreFactor] = [
        SecurityScoreFactor(.fileVault, weight: 30), SecurityScoreFactor(.sip, weight: 12.5),
        SecurityScoreFactor(.osCurrent, weight: 15, graceDays: 45),
        SecurityScoreFactor(.agent, weight: 5, target: "Falcon"),
        SecurityScoreFactor(.mscp, weight: 10, target: "STIG"),
    ]

    // MARK: - Round trip

    func testEachSettingRoundTripsThroughTheLoader() throws {
        try withWorkspacesRoot {
            try write("columns:\n  serial_number: \"Serial Number\"\n")
            let policy = SecurityControlPolicy(
                fileVault: .warning, sip: .ignore, firewall: .fail, gatekeeper: .warning,
                fileVaultOffHardwareEncrypted: .fail, scoreFactors: custom)

            for control in SecurityControl.allCases {
                try save(.level(policy.level(for: control), for: control))
            }
            try save(.hardwareLevel(policy.fileVaultOffHardwareEncrypted))
            try save(.scoreFactors(policy.scoreFactors))

            XCTAssertEqual(SecurityPolicyConfigLoader.load(profile: profile), policy)
            XCTAssertEqual(SecurityPolicyConfigLoader.issues(profile: profile), [])
        }
    }

    func testEachLevelRoundTripsForEachControl() throws {
        try withWorkspacesRoot {
            for level in SecurityControlLevel.allCases {
                for control in SecurityControl.allCases {
                    try write("security_policy:\n  controls:\n    sip: ignore\n")
                    try save(.level(level, for: control))
                    XCTAssertEqual(
                        SecurityPolicyConfigLoader.load(profile: profile),
                        SecurityControlPolicy(sip: .ignore).setting(level, for: control),
                        "\(control) at \(level)")
                }
            }
        }
    }

    func testSaveCreatesTheConfigWhenAbsent() throws {
        try withWorkspacesRoot {
            try save(.level(.warning, for: .sip))
            XCTAssertEqual(SecurityPolicyConfigLoader.load(profile: profile),
                           SecurityControlPolicy(sip: .warning))
        }
    }

    /// config.example.yaml documents the block in comments, which a rewrite of the block does
    /// not keep: the save keeps a copy of the file that holds them.
    func testASaveThatDropsTheBlocksCommentsKeepsACopy() throws {
        try withWorkspacesRoot {
            let typed = "security_policy:\n  # what counts as a gap\n  controls:\n    sip: fail\n"
            try write(typed)

            let saved = try SecurityPolicyConfigWriter.save(
                .level(.warning, for: .sip), profile: profile)

            XCTAssertTrue(saved.report.droppedComments)
            let name = try XCTUnwrap(saved.report.backupName)
            let copy = try configURL().deletingLastPathComponent().appendingPathComponent(name)
            XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), typed)
            XCTAssertEqual(try readBack(), "security_policy:\n  controls:\n    sip: warning\n")
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
              score_factors:
                - factor: sip
                  weight: 5
            charts:
              save_png: false
              os_adoption:
                per_major_charts: false
            """)

            try save(.level(.warning, for: .sip))

            let text = try readBack()
            for kept in ["Serial Number", "notify:", "provider: \"teams\"", "charts:",
                         "save_png: false", "per_major_charts: false", "mode: strict",
                         "custom_control: warning", "score_factors:", "factor: sip", "weight: 5"] {
                XCTAssertTrue(text.contains(kept), "a save dropped \(kept)")
            }
            XCTAssertEqual(SecurityPolicyConfigLoader.load(profile: profile).sip, .warning)
            XCTAssertEqual(
                SecurityPolicyConfigLoader.issues(profile: profile).map(\.keyPath),
                ["security_policy.mode", "security_policy.controls.custom_control"])
        }
    }

    /// A level write names one key, so the on and off values an operator typed stay as typed,
    /// in their order and spelling, and keep working. A comment inside the rewritten block
    /// does not survive a save: the writer says so and keeps a copy of the file.
    func testALevelWriteKeepsTheOnAndOffValues() throws {
        try withWorkspacesRoot {
            let typed = """
            # Fleet notes, above the block
            security_policy:
              # org words, written by the compliance team
              on_values:
                firewall: ["Pass", "Compliant"]
                sip: Protected
              controls:
                firewall: warning
              off_values:
                firewall:
                  - Fail
                  - Non-Compliant
            """
            try write(typed)

            let saved = try SecurityPolicyConfigWriter.save(
                .level(.ignore, for: .sip), profile: profile)

            let text = try readBack()
            XCTAssertTrue(text.hasPrefix("# Fleet notes, above the block\n"))
            for kept in ["on_values:\n    firewall:", "- Pass", "- Compliant", "sip: Protected",
                         "off_values:\n    firewall:", "- Fail", "- Non-Compliant",
                         "firewall: warning"] {
                XCTAssertTrue(text.contains(kept), "a save dropped or rewrote \(kept)")
            }
            let policy = SecurityPolicyConfigLoader.load(profile: profile)
            XCTAssertEqual(policy.sip, .ignore)
            XCTAssertEqual(policy.firewall, .warning)
            XCTAssertEqual(policy.onValues, [.firewall: ["pass", "compliant"], .sip: ["protected"]])
            XCTAssertEqual(policy.offValues, [.firewall: ["fail", "non compliant"]])
            XCTAssertEqual(SecurityPolicyConfigLoader.issues(profile: profile), [])
            XCTAssertTrue(saved.report.droppedComments)
            let name = try XCTUnwrap(saved.report.backupName)
            let copy = try configURL().deletingLastPathComponent().appendingPathComponent(name)
            XCTAssertTrue(try String(contentsOf: copy, encoding: .utf8)
                .contains("# org words, written by the compliance team"))
        }
    }

    /// With no comment inside the block a save says nothing and keeps the values.
    func testALevelWriteWithoutCommentsLeavesTheVocabularyBlocksAlone() throws {
        try withWorkspacesRoot {
            try write("""
            security_policy:
              controls:
                sip: fail
              on_values:
                firewall: [Pass, Compliant]
              off_values:
                firewall: Fail
            """)

            let saved = try SecurityPolicyConfigWriter.save(
                .level(.warning, for: .sip), profile: profile)

            XCTAssertFalse(saved.report.droppedComments)
            XCTAssertNil(saved.report.backupName)
            XCTAssertTrue(try readBack().contains(
                "  on_values:\n    firewall:\n      - Pass\n      - Compliant\n"
                    + "  off_values:\n    firewall: Fail"),
                "the same values in the same order; the writer spells a list as a block")
            let policy = SecurityPolicyConfigLoader.load(profile: profile)
            XCTAssertEqual(policy.sip, .warning)
            XCTAssertEqual(policy.onValues, [.firewall: ["pass", "compliant"]])
            XCTAssertEqual(policy.offValues, [.firewall: ["fail"]])
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

            try save(.hardwareLevel(nil))

            XCTAssertFalse(try readBack().contains("filevault_off_hardware_encrypted"))
            XCTAssertNil(SecurityPolicyConfigLoader.load(profile: profile)
                .fileVaultOffHardwareEncrypted)
        }
    }

    func testAHardwareLevelIsWrittenAndReplaced() throws {
        try withWorkspacesRoot {
            try write("security_policy:\n  filevault_off_hardware_encrypted: warning\n")
            try save(.hardwareLevel(.ignore))
            XCTAssertEqual(SecurityPolicyConfigLoader.load(profile: profile)
                .fileVaultOffHardwareEncrypted, .ignore)
        }
    }

    // MARK: - Hand-typed values

    /// A save names one key and writes that key from the file, so every other key stays as
    /// typed: a synonym, and a typo the app treats as fail that is still reported.
    func testASaveLeavesEveryOtherKeyAsTyped() throws {
        try withWorkspacesRoot {
            let typed = """
            security_policy:
              controls:
                firewall: warn
                gatekeeper: strcit
              filevault_off_hardware_encrypted: maybe
            """
            try write(typed)

            try save(.level(.warning, for: .fileVault))

            let text = try readBack()
            for kept in ["firewall: warn\n", "gatekeeper: strcit\n",
                         "filevault_off_hardware_encrypted: maybe"] {
                XCTAssertTrue(text.contains(kept), "a save rewrote \(kept)")
            }
            XCTAssertEqual(
                SecurityPolicyConfigLoader.load(profile: profile),
                SecurityControlPolicy(fileVault: .warning, firewall: .warning))
            XCTAssertEqual(SecurityPolicyConfigLoader.issues(profile: profile).map(\.keyPath), [
                "security_policy.controls.gatekeeper",
                "security_policy.filevault_off_hardware_encrypted",
            ])
        }
    }

    /// Something else in config.yaml does not decode, so `load` falls back to the default
    /// policy and the caller's copy says `fail` for a key the file sets to `warning`.
    func testASaveIsNotBuiltFromTheCallersCopyOfThePolicy() throws {
        try withWorkspacesRoot {
            try write("""
            security_policy:
              controls:
                filevault: warning
                firewall: ignore
            custom_eas: "not a list"
            """)
            XCTAssertEqual(SecurityPolicyConfigLoader.load(profile: profile), .default,
                           "the precondition: the whole file falls back")

            try save(.level(.warning, for: .sip))

            let text = try readBack()
            XCTAssertTrue(text.contains("filevault: warning\n"))
            XCTAssertTrue(text.contains("firewall: ignore\n"))
            XCTAssertTrue(text.contains("sip: warning"))
            XCTAssertTrue(text.contains("custom_eas: \"not a list\""))
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

            try save(.level(.warning, for: .sip))

            XCTAssertEqual(SecurityPolicyConfigLoader.load(profile: profile).sip, .warning)
            XCTAssertEqual(SecurityPolicyConfigLoader.issues(profile: profile).map(\.keyPath),
                           ["security_policy.controls.gatekeeper"],
                           "only the changed key's issue clears")
        }
    }

    /// The level a typo already reads as is still written when asked for: that is how the
    /// card's "Write fail" clears the issue.
    func testWritingTheLevelATypoAlreadyReadsAsClearsItsIssue() throws {
        try withWorkspacesRoot {
            try write("""
            security_policy:
              controls:
                filevault: faill
              filevault_off_hardware_encrypted: maybe
            """)
            XCTAssertEqual(SecurityPolicyConfigLoader.issues(profile: profile).count, 2)

            try save(.level(.fail, for: .fileVault))
            XCTAssertEqual(SecurityPolicyConfigLoader.issues(profile: profile).map(\.keyPath),
                           ["security_policy.filevault_off_hardware_encrypted"])
            XCTAssertFalse(try readBack().contains("faill"))

            try save(.hardwareLevel(nil))
            XCTAssertEqual(SecurityPolicyConfigLoader.issues(profile: profile), [])
        }
    }

    func testASynonymIsReplacedWhenTheLevelChanges() throws {
        try withWorkspacesRoot {
            try write("security_policy:\n  controls:\n    sip: skip\n")
            try save(.level(.warning, for: .sip))
            XCTAssertEqual(SecurityPolicyConfigLoader.load(profile: profile).sip, .warning)
            XCTAssertFalse(try readBack().contains("skip"))
        }
    }

    /// The decoder keeps the last of a repeated key, so a save has to change that one.
    func testARepeatedControlKeyIsWrittenOnce() throws {
        try withWorkspacesRoot {
            try write("security_policy:\n  controls:\n    sip: ignore\n    sip: fail\n")
            try save(.level(.warning, for: .sip))
            XCTAssertEqual(SecurityPolicyConfigLoader.load(profile: profile).sip, .warning)
            XCTAssertEqual(try readBack().components(separatedBy: "sip:").count, 2)
        }
    }

    /// The decoder reads the last `security_policy:` block, and in it the last `controls:`.
    func testARepeatedBlockOrControlsKeyIsReadAndWrittenAsTheDecoderReadsIt() throws {
        try withWorkspacesRoot {
            try write("""
            security_policy:
              controls:
                sip: ignore
            security_policy:
              controls:
                firewall: warning
            """)
            XCTAssertEqual(SecurityPolicyConfigLoader.load(profile: profile),
                           SecurityControlPolicy(firewall: .warning))

            try save(.level(.warning, for: .sip))

            XCTAssertEqual(SecurityPolicyConfigLoader.load(profile: profile),
                           SecurityControlPolicy(sip: .warning, firewall: .warning))
            XCTAssertEqual(SecurityPolicyConfigLoader.issues(profile: profile), [])
        }
        try withWorkspacesRoot {
            try write("""
            security_policy:
              controls:
                sip: ignore
              controls:
                firewall: warning
              filevault_off_hardware_encrypted: fail
            """)

            try save(.level(.warning, for: .gatekeeper))

            XCTAssertEqual(
                SecurityPolicyConfigLoader.load(profile: profile),
                SecurityControlPolicy(
                    firewall: .warning, gatekeeper: .warning,
                    fileVaultOffHardwareEncrypted: .fail))
            XCTAssertEqual(try readBack().components(separatedBy: "controls:").count, 2)
        }
    }

    func testALevelReplacesAControlsEntryOfTheWrongShape() throws {
        try withWorkspacesRoot {
            try write("security_policy:\n  controls: strict\n")
            try save(.scoreFactors(nil))
            XCTAssertTrue(try readBack().contains("controls: strict"), "nothing to write")

            try save(.level(.warning, for: .sip))
            XCTAssertEqual(SecurityPolicyConfigLoader.load(profile: profile).sip, .warning)
            XCTAssertEqual(SecurityPolicyConfigLoader.issues(profile: profile), [])
        }
    }

    // MARK: - Errors

    func testAnInvalidProfileThrows() {
        XCTAssertThrowsError(
            try SecurityPolicyConfigWriter.save(.level(.fail, for: .sip), profile: "escape\n")
        ) { error in
            XCTAssertEqual(
                error.localizedDescription, "Invalid profile name: escape\n")
        }
    }

    /// `YAMLCodec.decode` is where a non-mapping root is refused, so that is the error.
    func testARootThatIsNotAMappingThrows() throws {
        try withWorkspacesRoot {
            try write("- one\n- two\n")
            XCTAssertThrowsError(try save(.level(.fail, for: .sip))) { error in
                XCTAssertEqual(error as? YAMLCodec.CodecError, .invalidTopLevel)
            }
        }
    }
}

/// A temporary workspaces root for a test that drives the store; restored in a `defer`.
@MainActor
private func withPolicyWorkspacesRoot(_ body: () async throws -> Void) async throws {
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

@MainActor
private func policyTestStore(demo: Bool, profile: String? = nil) -> WorkspaceStore {
    let store = WorkspaceStore(
        demoMode: demo, jamfCLIProfileNames: { [] }, discoverProfiles: { [] },
        jamfCLIInstallation: { nil })
    if let profile { store.profile = profile }
    return store
}

@MainActor
private func writePolicyConfig(_ yaml: String, profile: String) throws -> URL {
    let workspace = try XCTUnwrap(ProfileService.workspaceURL(for: profile))
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    let url = workspace.appendingPathComponent("config.yaml")
    try yaml.write(to: url, atomically: true, encoding: .utf8)
    return url
}

/// The store holds the active workspace's policy and the issues in its hand-typed block, and
/// saves through the writer. Demo mode never reads or writes a workspace.
@MainActor
final class SecurityPolicyWorkspaceStoreTests: XCTestCase {

    func testLoadingTheConfigReadsThePolicyAndItsIssues() async throws {
        try await withPolicyWorkspacesRoot {
            _ = try writePolicyConfig("""
            security_policy:
              mode: strict
              controls:
                sip: wrn
                firewall: warning
            """, profile: "policy-store")
            let store = policyTestStore(demo: false, profile: "policy-store")

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
        try await withPolicyWorkspacesRoot {
            _ = try writePolicyConfig("""
            security_policy:
              mode: strict
              controls:
                sip: wrn
            """, profile: "policy-store")
            let store = policyTestStore(demo: false, profile: "policy-store")
            try await store.loadConfig()
            XCTAssertEqual(store.securityPolicyIssues.count, 2)

            let saved = SecurityControlPolicy(sip: .warning)
            try store.saveSecurityLevel(.warning, for: .sip)

            XCTAssertEqual(store.securityPolicy, saved)
            XCTAssertEqual(store.securityPolicyIssues.map(\.keyPath), ["security_policy.mode"])
            XCTAssertEqual(SecurityPolicyConfigLoader.load(profile: "policy-store"), saved)
        }
    }

    func testTheStoreLoadsSavesAndResetsTheFactors() async throws {
        try await withPolicyWorkspacesRoot {
            _ = try writePolicyConfig("""
            security_policy:
              score_factors:
                - factor: filevault
                  weight: 30
                - factor: sip
                  weight: 150
            """, profile: "policy-store-w")
            let store = policyTestStore(demo: false, profile: "policy-store-w")

            try await store.loadConfig()

            XCTAssertEqual(store.securityPolicy.scoreFactors,
                           [SecurityScoreFactor(.fileVault, weight: 30)])
            XCTAssertEqual(store.securityPolicyIssues.map(\.keyPath),
                           ["security_policy.score_factors[1]"])

            var factors = try XCTUnwrap(store.securityPolicy.scoreFactors)
            factors.append(SecurityScoreFactor(.sip, weight: 25))
            try store.saveScoreFactors(factors)
            XCTAssertEqual(store.securityPolicy.scoreFactors, factors)
            XCTAssertEqual(store.securityPolicyIssues, [],
                           "the saved list no longer holds the skipped entry")
            XCTAssertEqual(
                SecurityPolicyConfigLoader.load(profile: "policy-store-w").scoreFactors, factors)

            try store.saveScoreFactors(nil)
            XCTAssertNil(store.securityPolicy.scoreFactors)
            XCTAssertNil(SecurityPolicyConfigLoader.load(profile: "policy-store-w").scoreFactors)
        }
    }

    /// A save that drops a comment inside the block backs the file up, and the store hands
    /// the report's notes to the card that saved, which shows them as its status line.
    func testASaveThatDropsACommentReturnsTheBackupNote() async throws {
        try await withPolicyWorkspacesRoot {
            _ = try writePolicyConfig("""
            security_policy:
              # Factors agreed with the security team
              score_factors:
                - factor: filevault
                  weight: 30
            """, profile: "policy-store-notes")
            let store = policyTestStore(demo: false, profile: "policy-store-notes")
            try await store.loadConfig()

            let report = try store.saveScoreFactors(SecurityScoreFactor.nativeDefaults)

            let backup = try XCTUnwrap(report.backupName)
            XCTAssertTrue(report.droppedComments)
            XCTAssertEqual(report.statusLine, report.notes.joined(separator: " "))
            XCTAssertTrue(report.statusLine?.contains(backup) ?? false)
            let again = try store.saveSecurityLevel(.warning, for: .sip)
            XCTAssertNil(again.statusLine, "nothing left to drop, so nothing to say")
        }
    }

    func testAFailedSaveThrowsAndKeepsTheLoadedPolicy() async throws {
        try await withPolicyWorkspacesRoot {
            let store = policyTestStore(demo: false, profile: "escape\n")

            XCTAssertThrowsError(try store.saveSecurityLevel(.warning, for: .sip))
            XCTAssertThrowsError(try store.saveHardwareLevel(.warning))
            XCTAssertThrowsError(try store.saveScoreFactors(SecurityScoreFactor.nativeDefaults))

            XCTAssertEqual(store.securityPolicy, .default)
        }
    }

    func testALoadWithNoConfigGivesTheDefaultPolicy() async throws {
        try await withPolicyWorkspacesRoot {
            _ = try writePolicyConfig("security_policy:\n  controls:\n    sip: warning\n",
                            profile: "policy-store-a")
            let store = policyTestStore(demo: false, profile: "policy-store-a")
            try await store.loadConfig()
            XCTAssertEqual(store.securityPolicy.sip, .warning)

            store.profile = "policy-store-none"
            try await store.loadConfig()

            XCTAssertEqual(store.securityPolicy, .default)
            XCTAssertEqual(store.securityPolicyIssues, [])
        }
    }

    /// A policy loaded for a live profile must not survive into the demo, so the demo's
    /// screens never score against a real workspace's levels.
    func testEnteringDemoModeDropsALivePolicy() async throws {
        try await withPolicyWorkspacesRoot {
            _ = try writePolicyConfig(
                "security_policy:\n  mode: x\n  controls:\n    sip: ignore\n",
                profile: "policy-store-live")
            let store = policyTestStore(demo: false, profile: "policy-store-live")
            try await store.loadConfig()
            XCTAssertEqual(store.securityPolicy.sip, .ignore, "the precondition")
            XCTAssertEqual(store.securityPolicyIssues.count, 1)

            store.demoMode = true
            try await store.loadConfig()

            XCTAssertEqual(store.securityPolicy, .default)
            XCTAssertEqual(store.securityPolicyIssues, [])
        }
    }

    func testSettingDemoModeDropsALivePolicy() async throws {
        let key = WorkspaceStore.forceDemoModeKey
        let previous = UserDefaults.standard.object(forKey: key) as? Bool
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        try await withPolicyWorkspacesRoot {
            _ = try writePolicyConfig(
                "security_policy:\n  mode: x\n  controls:\n    sip: ignore\n",
                profile: "policy-store-live")
            let store = policyTestStore(demo: false, profile: "policy-store-live")
            try await store.loadConfig()
            XCTAssertEqual(store.securityPolicy.sip, .ignore, "the precondition")

            store.setDemoMode(true)

            XCTAssertEqual(store.securityPolicy, .default)
            XCTAssertEqual(store.securityPolicyIssues, [])
        }
    }

    func testDemoModeReadsNoWorkspace() async throws {
        try await withPolicyWorkspacesRoot {
            _ = try writePolicyConfig(
                "security_policy:\n  controls:\n    sip: ignore\n  mode: x\n",
                profile: DemoData.org.profile)
            let store = policyTestStore(demo: true)

            try await store.loadConfig()

            XCTAssertEqual(store.securityPolicy, .default)
            XCTAssertEqual(store.securityPolicyIssues, [])
        }
    }

    func testDemoModeSaveWritesNothing() async throws {
        try await withPolicyWorkspacesRoot {
            let store = policyTestStore(demo: true)
            let workspace = try XCTUnwrap(ProfileService.workspaceURL(for: store.profile))

            try store.saveSecurityLevel(.warning, for: .sip)
            try store.saveHardwareLevel(.warning)
            try store.saveScoreFactors(SecurityScoreFactor.nativeDefaults)
            XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.path),
                           "no workspace folder is created for the demo profile")

            let text = "security_policy:\n  controls:\n    sip: ignore\n"
            let url = try writePolicyConfig(text, profile: store.profile)
            try store.saveSecurityLevel(.warning, for: .sip)
            try store.saveHardwareLevel(.warning)
            try store.saveScoreFactors(SecurityScoreFactor.nativeDefaults)
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), text)
            XCTAssertEqual(store.securityPolicy, .default)
        }
    }

    /// The save is built from the file: here the policy loaded fell back to the default
    /// because something else in config.yaml did not decode.
    func testSavingALevelKeepsTheFilesOtherLevelsWhenTheLoadFellBack() async throws {
        try await withPolicyWorkspacesRoot {
            let url = try writePolicyConfig("""
            security_policy:
              controls:
                filevault: warning
            custom_eas: "not a list"
            """, profile: "policy-store-fb")
            let store = policyTestStore(demo: false, profile: "policy-store-fb")
            try await store.loadConfig()
            XCTAssertEqual(store.securityPolicy, .default, "the precondition")

            try store.saveSecurityLevel(.warning, for: .sip)

            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertTrue(text.contains("filevault: warning\n"))
            XCTAssertEqual(store.securityPolicy, SecurityControlPolicy(sip: .warning))
        }
    }

    func testTheHardwareLevelAndTheFactorsSaveAloneAndAreAdopted() async throws {
        try await withPolicyWorkspacesRoot {
            _ = try writePolicyConfig(
                "security_policy:\n  controls:\n    sip: warn\n", profile: "policy-store-h")
            let store = policyTestStore(demo: false, profile: "policy-store-h")
            try await store.loadConfig()

            try store.saveHardwareLevel(.warning)
            XCTAssertEqual(store.securityPolicy.fileVaultOffHardwareEncrypted, .warning)
            try store.saveScoreFactors(SecurityScoreFactor.nativeDefaults)
            XCTAssertEqual(store.securityPolicy.scoreFactors, SecurityScoreFactor.nativeDefaults)
            XCTAssertEqual(
                SecurityPolicyConfigLoader.load(profile: "policy-store-h"),
                SecurityControlPolicy(
                    sip: .warning, fileVaultOffHardwareEncrypted: .warning,
                    scoreFactors: SecurityScoreFactor.nativeDefaults))

            try store.saveHardwareLevel(nil)
            XCTAssertNil(store.securityPolicy.fileVaultOffHardwareEncrypted)
        }
    }

    /// The factors card saves the whole list with one weight changed; a hand-typed level
    /// synonym in another key of the block stays as typed, and the other entries keep their
    /// weights, a fractional one included.
    func testEditingOneWeightKeepsTheHandTypedLevelAndTheOtherWeights() async throws {
        try await withPolicyWorkspacesRoot {
            let url = try writePolicyConfig("""
            security_policy:
              controls:
                firewall: warn
              score_factors:
                - {factor: xprotect_current, weight: 12.5}
                - {factor: sip, weight: 10}
            """, profile: "policy-store-w1")
            let store = policyTestStore(demo: false, profile: "policy-store-w1")
            try await store.loadConfig()
            let factors = try XCTUnwrap(store.securityPolicy.scoreFactors)
            let sip = try XCTUnwrap(factors.first { $0.kind == .sip })
            try store.saveScoreFactors(ScoreFactorsCard.replacing(sip, weight: 25, in: factors))

            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertTrue(text.contains("firewall: warn\n"), text)
            XCTAssertEqual(
                SecurityPolicyConfigLoader.load(profile: "policy-store-w1").scoreFactors,
                [SecurityScoreFactor(.xprotectCurrent, weight: 12.5),
                 SecurityScoreFactor(.sip, weight: 25)])
        }
    }

    /// The Scoring tab sits on the Config screen: its writes are the screen's own, so the
    /// screen's Save that follows must not read them as config.yaml changing on disk.
    func testTheConfigSaveAfterAScoringTabWriteSucceedsAndKeepsIt() async throws {
        try await withPolicyWorkspacesRoot {
            _ = try writePolicyConfig(
                "columns:\n  serial_number: \"Serial Number\"\n", profile: "policy-store-cs")
            let store = policyTestStore(demo: false, profile: "policy-store-cs")
            try await store.loadConfig()

            try store.saveSecurityLevel(.warning, for: .sip)
            try store.saveScoreFactors(SecurityScoreFactor.nativeDefaults)
            store.configState.staleDeviceDays = "45"
            try await store.saveConfig()

            let saved = SecurityPolicyConfigLoader.load(profile: "policy-store-cs")
            XCTAssertEqual(saved.sip, .warning)
            XCTAssertEqual(saved.scoreFactors, SecurityScoreFactor.nativeDefaults)
            try await store.loadConfig()
            XCTAssertEqual(store.configState.staleDeviceDays, "45")
        }
    }

    /// A file that has no config.yaml yet: the Scoring tab's write creates it.
    func testTheConfigSaveAfterAScoringTabWriteThatCreatedTheFileSucceeds() async throws {
        try await withPolicyWorkspacesRoot {
            let store = policyTestStore(demo: false, profile: "policy-store-cn")
            try await store.loadConfig()

            try store.saveSecurityLevel(.ignore, for: .firewall)
            try await store.saveConfig()

            XCTAssertEqual(SecurityPolicyConfigLoader.load(profile: "policy-store-cn").firewall,
                           .ignore)
        }
    }

    /// A change made outside the app before the Scoring tab's write is still one the
    /// Config screen's Save must not write over.
    func testAnOutsideEditBeforeAScoringTabWriteStillStopsTheConfigSave() async throws {
        try await withPolicyWorkspacesRoot {
            let url = try writePolicyConfig(
                "columns:\n  serial_number: \"Serial Number\"\n", profile: "policy-store-oe")
            let store = policyTestStore(demo: false, profile: "policy-store-oe")
            try await store.loadConfig()
            try "columns:\n  serial_number: \"Serial\"\nthresholds:\n  stale_device_days: 9\n"
                .write(to: url, atomically: true, encoding: .utf8)

            try store.saveSecurityLevel(.warning, for: .sip)

            do {
                try await store.saveConfig()
                XCTFail("the outside edit must stop the save")
            } catch ConfigService.ConfigError.changedOnDisk {}
            XCTAssertTrue(try String(contentsOf: url, encoding: .utf8)
                .contains("stale_device_days: 9"))
        }
    }
}

/// The Security Policy card's wording and its mapping from the file's issues to rows.
@MainActor
final class SecurityPolicyCardTests: XCTestCase {

    private func issue(_ keyPath: String, _ value: String, _ used: String) -> SecurityPolicyIssue {
        SecurityPolicyIssue(keyPath: keyPath, value: value, used: used)
    }

    func testControlAndLevelNamesAreTheOnesTheCardShows() {
        XCTAssertEqual(SecurityControl.allCases.map(\.displayName),
                       ["FileVault", "System Integrity Protection", "Firewall", "Gatekeeper"])
        XCTAssertEqual(SecurityControlLevel.allCases.map(\.displayName),
                       ["Fail", "Warning", "Not counted"])
    }

    func testSettingALevelChangesOnlyThatControl() {
        let policy = SecurityControlPolicy(
            fileVault: .warning, fileVaultOffHardwareEncrypted: .fail)
        let changed = policy.setting(.ignore, for: .firewall)
        XCTAssertEqual(changed, SecurityControlPolicy(
            fileVault: .warning, firewall: .ignore, fileVaultOffHardwareEncrypted: .fail))
        for control in SecurityControl.allCases {
            XCTAssertEqual(policy.setting(.warning, for: control).level(for: control), .warning)
        }
    }

    func testALevelIssueSaysWhatTheFileSaysAndWhatTheAppUsed() {
        XCTAssertEqual(
            SecurityPolicyCard.levelCaption(
                issue("security_policy.controls.sip", "wrn", "fail")),
            "config.yaml says \"wrn\", which is not fail, warning or ignore — using fail.")
        XCTAssertEqual(
            SecurityPolicyCard.levelCaption(issue(
                "security_policy.filevault_off_hardware_encrypted", "", "the FileVault level")),
            "config.yaml says \"\", which is not fail, warning or ignore — "
                + "using the FileVault level.")
    }

    /// The loader already cleans what it reads; the card cleans again whatever it is handed.
    func testTextFromTheFileIsCleanedBeforeItIsShown() {
        let raw = "ev\u{1B}[31mil\u{202E}\n" + String(repeating: "x", count: 80)
        let caption = SecurityPolicyCard.levelCaption(
            issue("security_policy.controls.sip", raw, "fail"))
        XCTAssertFalse(caption.contains("\u{1B}"))
        XCTAssertFalse(caption.contains("\u{202E}"))
        XCTAssertFalse(caption.contains("\n"))
        XCTAssertLessThan(caption.count, 140)
        let unknown = SecurityPolicyCard.unknownKeysCaption(
            [issue("security_policy.a\u{1B}b", "", "")])
        XCTAssertEqual(unknown, SecurityPolicyCard.unknownKeysCaption(
            [issue("security_policy.ab", "", "")]))
    }

    func testUnknownKeysAreListedOnceAndCounted() {
        let mode = issue("security_policy.mode", "", "")
        let custom = issue("security_policy.controls.custom", "", "")
        let level = issue("security_policy.controls.sip", "wrn", "fail")
        XCTAssertEqual(
            SecurityPolicyCard.unknownKeysCaption([level, mode]),
            "config.yaml has 1 security_policy setting the app does not read: "
                + "security_policy.mode.")
        XCTAssertEqual(
            SecurityPolicyCard.unknownKeysCaption([mode, level, custom]),
            "config.yaml has 2 security_policy settings the app does not read: "
                + "security_policy.mode, security_policy.controls.custom.")
        XCTAssertNil(SecurityPolicyCard.unknownKeysCaption([level]))
        XCTAssertNil(SecurityPolicyCard.unknownKeysCaption([]))
    }

    /// The key path is shown in full: the loader capped the typed part of it already.
    func testAKeyPathLongerThanFortyCharactersIsShownInFull() {
        let long = "security_policy.controls.screen_saver_lock"
        XCTAssertGreaterThan(long.count, 40)
        XCTAssertEqual(
            SecurityPolicyCard.unknownKeysCaption([issue(long, "", "")]),
            "config.yaml has 1 security_policy setting the app does not read: \(long).")
        XCTAssertTrue(SecurityPolicyCard.shapeCaption(issue(long, "strict", "the default policy"))
            .contains(long))
    }

    func testEachRowFindsItsOwnLevelIssue() {
        let sip = issue("security_policy.controls.sip", "wrn", "fail")
        let hardware = issue(
            "security_policy.filevault_off_hardware_encrypted", "maybe", "the FileVault level")
        let shape = issue("security_policy.controls", "strict", "fail for every control")
        let unknown = issue("security_policy.mode", "", "")
        let all = [unknown, shape, sip, hardware]
        XCTAssertEqual(SecurityPolicyCard.levelIssue(for: .sip, in: all), sip)
        XCTAssertNil(SecurityPolicyCard.levelIssue(for: .fileVault, in: all))
        XCTAssertEqual(SecurityPolicyCard.hardwareLevelIssue(in: all), hardware)
        XCTAssertEqual(SecurityPolicyCard.shapeIssues(in: all), [shape])
    }

    func testABlockOfTheWrongShapeIsExplained() {
        XCTAssertEqual(
            SecurityPolicyCard.shapeCaption(
                issue("security_policy.controls", "strict", "fail for every control")),
            "config.yaml's security_policy.controls is \"strict\", which is not a set of "
                + "settings — using fail for every control.")
    }

    func testAFactorIssueNamesTheEntryWhatTheFileSaysAndWhatTheAppDid() {
        XCTAssertEqual(
            SecurityPolicyCard.factorCaption(issue(
                "security_policy.score_factors[2]", "150",
                "skipped: weight is a number from 0 to 100")),
            "config.yaml's score_factors[2] (\"150\"): skipped: weight is a number from 0 "
                + "to 100.")
        XCTAssertEqual(
            SecurityPolicyCard.factorCaption(issue(
                "security_policy.score_factors[1].grace_days", "400",
                "30 days, since grace_days is a whole number from 0 to 365")),
            "config.yaml's score_factors[1].grace_days (\"400\"): 30 days, since grace_days "
                + "is a whole number from 0 to 365.")
        XCTAssertEqual(
            SecurityPolicyCard.factorCaption(issue(
                "security_policy.score_factors", "5",
                "the default factors, since this is not a list")),
            "config.yaml's score_factors (\"5\"): the default factors, since this is not a list.")
        let shown = SecurityPolicyCard.factorCaption(
            issue("security_policy.score_factors[1]", "a\u{202E}b\n", "skipped"))
        XCTAssertEqual(shown, SecurityPolicyCard.factorCaption(
            issue("security_policy.score_factors[1]", "ab", "skipped")))
    }

    func testFactorIssuesAreFoundApartFromLevelsShapesAndUnknownKeys() {
        let entry = issue("security_policy.score_factors[2]", "150", "skipped: weight")
        let notAList = issue("security_policy.score_factors", "5", "the default factors")
        let unknown = issue("security_policy.score_factors[1].colour", "", "")
        let shape = issue("security_policy.controls", "strict", "fail for every control")
        let level = issue("security_policy.controls.sip", "wrn", "fail")
        XCTAssertEqual(
            SecurityPolicyCard.factorIssues(in: [level, shape, unknown, entry, notAList]),
            [entry, notAList])
        XCTAssertNil(SecurityPolicyCard.levelIssue(for: .sip, in: [entry]))
        XCTAssertEqual(SecurityPolicyCard.shapeIssues(in: [entry, notAList, unknown]), [])
        XCTAssertEqual(
            SecurityPolicyCard.unknownKeysCaption([entry, unknown]),
            "config.yaml has 1 security_policy setting the app does not read: "
                + "security_policy.score_factors[1].colour.")
    }

    func testTheCardInstantiatesInAndOutOfDemoMode() {
        for demo in [true, false] {
            let workspace = WorkspaceStore(
                demoMode: demo, jamfCLIProfileNames: { [] }, discoverProfiles: { [] },
                jamfCLIInstallation: { nil })
            _ = SecurityPolicyCard().environment(workspace)
        }
    }

    // MARK: - Writing the level the app applied

    func testTheNoteOffersToWriteTheAppliedLevelOrRemoveTheEntry() {
        XCTAssertEqual(SecurityPolicyCard.writeTitle(for: .fail), "Write fail")
        XCTAssertEqual(SecurityPolicyCard.writeTitle(for: .warning), "Write warning")
        XCTAssertEqual(SecurityPolicyCard.writeTitle(for: .ignore), "Write ignore")
        XCTAssertEqual(SecurityPolicyCard.writeTitle(for: nil), "Remove the entry")
    }

    /// A typo is applied as `fail` and the picker shows Fail, so choosing Fail again fires
    /// nothing; this is how the issue is cleared without changing the level.
    func testWritingTheAppliedLevelClearsThatIssue() async throws {
        try await withPolicyWorkspacesRoot {
            let url = try writePolicyConfig("""
            security_policy:
              controls:
                filevault: faill
                sip: wrn
              filevault_off_hardware_encrypted: maybe
            """, profile: "policy-card")
            let store = policyTestStore(demo: false, profile: "policy-card")
            try await store.loadConfig()
            XCTAssertEqual(store.securityPolicyIssues.count, 3)
            let failure = Failure()

            SecurityPolicyCard.writeAppliedLevel(.fileVault, in: store,
                failure: failure.binding, note: failure.noteBinding)
            XCTAssertEqual(store.securityPolicyIssues.map(\.keyPath), [
                "security_policy.controls.sip", "security_policy.filevault_off_hardware_encrypted",
            ])
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertTrue(text.contains("filevault: fail\n"))
            XCTAssertTrue(text.contains("sip: wrn"), "another key's typed value stays")
            XCTAssertEqual(store.securityPolicy, .default)

            SecurityPolicyCard.writeAppliedHardwareLevel(in: store,
                failure: failure.binding, note: failure.noteBinding)
            XCTAssertEqual(store.securityPolicyIssues.map(\.keyPath),
                           ["security_policy.controls.sip"])
            XCTAssertFalse(try String(contentsOf: url, encoding: .utf8)
                .contains("filevault_off_hardware_encrypted"))
            XCTAssertNil(failure.value)
        }
    }

    func testAFailedWriteOfTheAppliedLevelIsTheCardsMessage() async throws {
        try await withPolicyWorkspacesRoot {
            let store = policyTestStore(demo: false, profile: "escape\n")
            let failure = Failure()
            SecurityPolicyCard.writeAppliedLevel(.sip, in: store,
                failure: failure.binding, note: failure.noteBinding)
            XCTAssertEqual(
                failure.value?.message,
                "Couldn't save the security policy: Invalid profile name: escape\n")
        }
    }

    // MARK: - What the pickers do

    @MainActor private final class Failure {
        var value: SecurityPolicyCard.SaveFailure?
        var binding: Binding<SecurityPolicyCard.SaveFailure?> {
            Binding(get: { self.value }, set: { self.value = $0 })
        }
        var note: ProfileSaveNote?
        var noteBinding: Binding<ProfileSaveNote?> {
            Binding(get: { self.note }, set: { self.note = $0 })
        }
    }

    /// Drives the binding a control's picker uses, as the picker does: set it, then read it.
    func testAControlsPickerWritesThatOneKeyToTheFile() async throws {
        try await withPolicyWorkspacesRoot {
            let url = try writePolicyConfig("""
            security_policy:
              controls:
                filevault: warning
                firewall: ignore
            custom_eas: "not a list"
            """, profile: "policy-card")
            let store = policyTestStore(demo: false, profile: "policy-card")
            try await store.loadConfig()
            let failure = Failure()
            let picker = SecurityPolicyCard.levelBinding(
                .sip, in: store, failure: failure.binding, note: failure.noteBinding)
            XCTAssertEqual(picker.wrappedValue, .fail)

            picker.wrappedValue = .warning

            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertTrue(text.contains("sip: warning"), "the picker saved nothing")
            XCTAssertTrue(text.contains("filevault: warning\n"), "another key was rewritten")
            XCTAssertTrue(text.contains("firewall: ignore\n"), "another key was rewritten")
            XCTAssertEqual(picker.wrappedValue, .warning)
            XCTAssertEqual(store.securityPolicy.sip, .warning)
            XCTAssertNil(failure.value)
        }
    }

    /// The note a save returns is the card's until the card goes: a later save with nothing
    /// to say leaves it. It belongs to the profile it was saved under and reads as nothing on
    /// another.
    func testAPickerSaveThatBacksUpTheFileLeavesTheCardsNote() async throws {
        try await withPolicyWorkspacesRoot {
            _ = try writePolicyConfig("""
            security_policy:
              controls:
                sip: fail  # agreed 2026-09
            """, profile: "policy-card-note")
            let store = policyTestStore(demo: false, profile: "policy-card-note")
            try await store.loadConfig()
            let failure = Failure()
            let picker = SecurityPolicyCard.levelBinding(
                .sip, in: store, failure: failure.binding, note: failure.noteBinding)

            picker.wrappedValue = .warning
            let note = try XCTUnwrap(failure.note)
            XCTAssertEqual(note.profile, "policy-card-note")
            let line = try XCTUnwrap(note.line(for: "policy-card-note"))
            XCTAssertTrue(line.contains("config.yaml.bak-"), line)
            XCTAssertNil(note.line(for: "another-profile"))

            picker.wrappedValue = .ignore
            XCTAssertEqual(failure.note, note)
            XCTAssertNil(failure.value)
        }
    }

    func testTheHardwarePickerWritesAndRemovesItsKey() async throws {
        try await withPolicyWorkspacesRoot {
            let url = try writePolicyConfig(
                "security_policy:\n  controls:\n    sip: warn\n", profile: "policy-card")
            let store = policyTestStore(demo: false, profile: "policy-card")
            try await store.loadConfig()
            let failure = Failure()
            let picker = SecurityPolicyCard.hardwareBinding(in: store,
                failure: failure.binding, note: failure.noteBinding)
            XCTAssertNil(picker.wrappedValue)

            picker.wrappedValue = .ignore
            XCTAssertTrue(try String(contentsOf: url, encoding: .utf8)
                .contains("filevault_off_hardware_encrypted: ignore"))
            XCTAssertEqual(picker.wrappedValue, .ignore)
            XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("sip: warn\n"))

            picker.wrappedValue = nil
            XCTAssertFalse(try String(contentsOf: url, encoding: .utf8)
                .contains("filevault_off_hardware_encrypted"))
            XCTAssertNil(picker.wrappedValue)
            XCTAssertNil(failure.value)
        }
    }

    /// The message is the card's, and the picker reads the saved policy, not the choice.
    func testAFailedSaveBecomesTheMessageAndThePickerStaysOnTheSavedPolicy() async throws {
        try await withPolicyWorkspacesRoot {
            let store = policyTestStore(demo: false, profile: "escape\n")
            let failure = Failure()
            let picker = SecurityPolicyCard.levelBinding(.sip, in: store,
                failure: failure.binding, note: failure.noteBinding)

            picker.wrappedValue = .warning

            XCTAssertEqual(
                failure.value?.message,
                "Couldn't save the security policy: Invalid profile name: escape\n")
            XCTAssertEqual(picker.wrappedValue, .fail)
            let first = failure.value
            picker.wrappedValue = .warning
            XCTAssertNotEqual(failure.value, first, "a repeat failure is a new value")
        }
    }

    func testAPickerInDemoModeWritesNothing() async throws {
        try await withPolicyWorkspacesRoot {
            let store = policyTestStore(demo: true)
            let failure = Failure()
            let picker = SecurityPolicyCard.levelBinding(.sip, in: store,
                failure: failure.binding, note: failure.noteBinding)

            picker.wrappedValue = .warning

            let workspace = try XCTUnwrap(ProfileService.workspaceURL(for: store.profile))
            XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.path))
            XCTAssertEqual(picker.wrappedValue, .fail)
            XCTAssertNil(failure.value)
        }
    }
}
