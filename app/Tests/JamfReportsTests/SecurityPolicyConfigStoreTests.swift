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

    private func loadedWeights() -> SecurityScoreWeights? {
        SecurityPolicyConfigLoader.load(profile: profile).scoreWeights
    }

    // MARK: - Round trip

    func testEachSettingRoundTripsThroughTheLoader() throws {
        try withWorkspacesRoot {
            try write("columns:\n  serial_number: \"Serial Number\"\n")
            let policy = SecurityControlPolicy(
                fileVault: .warning, sip: .ignore, firewall: .fail, gatekeeper: .warning,
                fileVaultOffHardwareEncrypted: .fail, scoreWeights: custom)

            for control in SecurityControl.allCases {
                try save(.level(policy.level(for: control), for: control))
            }
            try save(.hardwareLevel(policy.fileVaultOffHardwareEncrypted))
            try save(.scoreWeights(policy.scoreWeights))

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

            try save(.level(.warning, for: .sip))

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
            try save(.scoreWeights(nil))
            XCTAssertTrue(try readBack().contains("controls: strict"), "nothing to write")

            try save(.level(.warning, for: .sip))
            XCTAssertEqual(SecurityPolicyConfigLoader.load(profile: profile).sip, .warning)
            XCTAssertEqual(SecurityPolicyConfigLoader.issues(profile: profile), [])
        }
    }

    // MARK: - Score weights

    private let custom = SecurityScoreWeights(
        fileVault: 30, sip: 12, firewall: 15, edrAgent: 0, mscp: 20, xprotect: 5, cve: 100,
        secureBoot: 5)

    func testSaveThenLoadReturnsTheWeights() throws {
        try withWorkspacesRoot {
            try write("columns:\n  serial_number: \"Serial Number\"\n")

            try save(.level(.warning, for: .sip))
            try save(.scoreWeights(custom))

            XCTAssertEqual(SecurityPolicyConfigLoader.load(profile: profile),
                           SecurityControlPolicy(sip: .warning, scoreWeights: custom))
            XCTAssertEqual(SecurityPolicyConfigLoader.issues(profile: profile), [])
            let text = try readBack()
            XCTAssertTrue(text.contains("score_weights:"))
            XCTAssertTrue(text.contains("Serial Number"))
            for key in ["filevault: 30", "sip: 12", "edr_agent: 0", "secure_boot: 5",
                        "cve: 100"] {
                XCTAssertTrue(text.contains(key), key)
            }
        }
    }

    /// Saved weights that equal the defaults are still a saved block: they load back as set.
    func testWeightsEqualToTheDefaultsAreWrittenAsABlock() throws {
        try withWorkspacesRoot {
            try save(.scoreWeights(.defaultWeights))
            XCTAssertEqual(SecurityPolicyConfigLoader.load(profile: profile),
                           SecurityControlPolicy(scoreWeights: .defaultWeights))
            XCTAssertFalse(try readBack().contains("controls:"), "no control level was written")
        }
    }

    func testNilWeightsRemoveTheBlockAndNothingElse() throws {
        try withWorkspacesRoot {
            try write("""
            security_policy:
              mode: strict
              controls:
                sip: warning
              score_weights:
                sip: 5
            notify:
              enabled: true
            """)
            XCTAssertNotNil(SecurityPolicyConfigLoader.load(profile: profile).scoreWeights)

            try save(.scoreWeights(nil))

            let text = try readBack()
            XCTAssertFalse(text.contains("score_weights"))
            for kept in ["mode: strict", "sip: warning", "notify:"] {
                XCTAssertTrue(text.contains(kept), kept)
            }
            XCTAssertNil(SecurityPolicyConfigLoader.load(profile: profile).scoreWeights)
        }
    }

    func testASaveOfTheWeightsTheFileAlreadyYieldsLeavesTheFileAlone() throws {
        try withWorkspacesRoot {
            let typed = """
            security_policy:
              score_weights:
                # a comment the writer would drop if it rewrote the block
                filevault: "30"
                sip: 5
            """
            try write(typed)
            let loaded = SecurityPolicyConfigLoader.load(profile: profile)

            try save(.scoreWeights(loaded.scoreWeights))

            XCTAssertEqual(try readBack(), typed)
        }
    }

    func testChangingOneWeightKeepsTheOthersAsTypedAndTheUnknownKeys() throws {
        try withWorkspacesRoot {
            try write("""
            security_policy:
              score_weights:
                filevault: "30"
                sip: 5
                crowdstrike: 9
            """)
            var weights = try XCTUnwrap(loadedWeights())
            weights.sip = 8

            try save(.scoreWeights(weights))

            let text = try readBack()
            XCTAssertTrue(text.contains("\"30\""), "a weight that reads as saved stays typed")
            XCTAssertTrue(text.contains("crowdstrike: 9"))
            XCTAssertFalse(text.contains("sip: 5"))
            XCTAssertEqual(SecurityPolicyConfigLoader.load(profile: profile).scoreWeights, weights)
        }
    }

    /// An unreadable weight reads as its default, so a save that leaves the default as it is
    /// leaves the typo and its issue; changing that weight writes a number over it.
    func testAnUnreadableWeightStaysUntilItsOwnWeightChanges() throws {
        try withWorkspacesRoot {
            try write("security_policy:\n  score_weights:\n    sip: abc\n    cve: 30\n")
            var weights = try XCTUnwrap(loadedWeights())
            XCTAssertEqual(weights.sip, 15)

            try save(.scoreWeights(weights))
            XCTAssertTrue(try readBack().contains("sip: abc"))
            XCTAssertEqual(SecurityPolicyConfigLoader.issues(profile: profile).count, 1)

            weights.sip = 16
            try save(.scoreWeights(weights))
            XCTAssertEqual(SecurityPolicyConfigLoader.issues(profile: profile), [])
            XCTAssertEqual(SecurityPolicyConfigLoader.load(profile: profile).scoreWeights, weights)
        }
    }

    /// A fractional weight typed by hand is what the score uses, so a save of a control
    /// level must not touch it.
    func testASaveOfAControlLeavesAFractionalWeightAsTyped() throws {
        try withWorkspacesRoot {
            try write("security_policy:\n  score_weights:\n    xprotect: 12.5\n")
            XCTAssertEqual(
                SecurityPolicyConfigLoader.load(profile: profile).scoreWeights?.xprotect, 12.5)

            try save(.level(.warning, for: .sip))

            XCTAssertTrue(try readBack().contains("xprotect: 12.5"))
            XCTAssertEqual(SecurityPolicyConfigLoader.load(profile: profile).scoreWeights?.xprotect,
                           12.5)
        }
    }

    func testWeightsAreWrittenAsWholeNumbersFromZeroToOneHundred() throws {
        try withWorkspacesRoot {
            var weights = SecurityScoreWeights.defaultWeights
            weights.fileVault = 12.6
            weights.sip = 150
            weights.firewall = -3
            weights.edrAgent = .nan
            try save(.scoreWeights(weights))

            let loaded = try XCTUnwrap(
                SecurityPolicyConfigLoader.load(profile: profile).scoreWeights)
            XCTAssertEqual(loaded.fileVault, 13)
            XCTAssertEqual(loaded.sip, 100)
            XCTAssertEqual(loaded.firewall, 0)
            XCTAssertEqual(loaded.edrAgent, 10, "a weight that is not a number is its default")
            XCTAssertEqual(SecurityPolicyConfigLoader.issues(profile: profile), [])
        }
    }

    func testAWeightsBlockOfTheWrongShapeIsReplacedWhenWeightsAreSaved() throws {
        try withWorkspacesRoot {
            try write("security_policy:\n  score_weights: 5\n")
            try save(.scoreWeights(nil))
            XCTAssertNil(SecurityPolicyConfigLoader.load(profile: profile).scoreWeights)
            XCTAssertFalse(try readBack().contains("score_weights"), "nil removes the key")

            try write("security_policy:\n  score_weights: 5\n")
            try save(.scoreWeights(custom))
            XCTAssertEqual(SecurityPolicyConfigLoader.load(profile: profile).scoreWeights, custom)
            XCTAssertEqual(SecurityPolicyConfigLoader.issues(profile: profile), [])
        }
    }

    func testARepeatedWeightKeyIsWrittenOnce() throws {
        try withWorkspacesRoot {
            try write("security_policy:\n  score_weights:\n    sip: 9\n    sip: 5\n")
            var weights = try XCTUnwrap(loadedWeights())
            XCTAssertEqual(weights.sip, 5)
            weights.sip = 7

            try save(.scoreWeights(weights))

            XCTAssertEqual(SecurityPolicyConfigLoader.load(profile: profile).scoreWeights?.sip, 7)
            XCTAssertEqual(try readBack().components(separatedBy: "sip:").count, 2)
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

    func testTheStoreLoadsSavesAndResetsTheWeights() async throws {
        try await withPolicyWorkspacesRoot {
            _ = try writePolicyConfig("""
            security_policy:
              score_weights:
                filevault: 30
                sip: 150
            """, profile: "policy-store-w")
            let store = policyTestStore(demo: false, profile: "policy-store-w")

            try await store.loadConfig()

            XCTAssertEqual(store.securityPolicy.scoreWeights?.fileVault, 30)
            XCTAssertEqual(store.securityPolicy.scoreWeights?.sip, 15)
            XCTAssertEqual(store.securityPolicyIssues.map(\.keyPath),
                           ["security_policy.score_weights.sip"])

            var weights = try XCTUnwrap(store.securityPolicy.scoreWeights)
            weights.sip = 25
            try store.saveScoreWeights(weights)
            XCTAssertEqual(store.securityPolicy.scoreWeights?.sip, 25)
            XCTAssertEqual(store.securityPolicyIssues, [], "the saved weight clears its issue")
            XCTAssertEqual(
                SecurityPolicyConfigLoader.load(profile: "policy-store-w").scoreWeights?.sip, 25)

            try store.saveScoreWeights(nil)
            XCTAssertNil(store.securityPolicy.scoreWeights)
            XCTAssertNil(SecurityPolicyConfigLoader.load(profile: "policy-store-w").scoreWeights)
        }
    }

    func testAFailedSaveThrowsAndKeepsTheLoadedPolicy() async throws {
        try await withPolicyWorkspacesRoot {
            let store = policyTestStore(demo: false, profile: "escape\n")

            XCTAssertThrowsError(try store.saveSecurityLevel(.warning, for: .sip))
            XCTAssertThrowsError(try store.saveHardwareLevel(.warning))
            XCTAssertThrowsError(try store.saveScoreWeights(.defaultWeights))

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
            try store.saveScoreWeights(.defaultWeights)
            XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.path),
                           "no workspace folder is created for the demo profile")

            let text = "security_policy:\n  controls:\n    sip: ignore\n"
            let url = try writePolicyConfig(text, profile: store.profile)
            try store.saveSecurityLevel(.warning, for: .sip)
            try store.saveHardwareLevel(.warning)
            try store.saveScoreWeights(.defaultWeights)
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

    func testTheHardwareLevelAndTheWeightsSaveAloneAndAreAdopted() async throws {
        try await withPolicyWorkspacesRoot {
            _ = try writePolicyConfig(
                "security_policy:\n  controls:\n    sip: warn\n", profile: "policy-store-h")
            let store = policyTestStore(demo: false, profile: "policy-store-h")
            try await store.loadConfig()

            try store.saveHardwareLevel(.warning)
            XCTAssertEqual(store.securityPolicy.fileVaultOffHardwareEncrypted, .warning)
            try store.saveScoreWeights(.defaultWeights)
            XCTAssertEqual(store.securityPolicy.scoreWeights, .defaultWeights)
            XCTAssertEqual(
                SecurityPolicyConfigLoader.load(profile: "policy-store-h"),
                SecurityControlPolicy(
                    sip: .warning, fileVaultOffHardwareEncrypted: .warning,
                    scoreWeights: .defaultWeights))

            try store.saveHardwareLevel(nil)
            XCTAssertNil(store.securityPolicy.fileVaultOffHardwareEncrypted)
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

    func testAWeightIssueNamesTheKeyWhatTheFileSaysAndWhatTheAppUsed() {
        XCTAssertEqual(
            SecurityPolicyCard.weightCaption(
                issue("security_policy.score_weights.sip", "150", "15")),
            "config.yaml's score_weights.sip is \"150\", which is not a number from 0 to 100 "
                + "— using 15.")
        XCTAssertEqual(
            SecurityPolicyCard.weightCaption(
                issue("security_policy.score_weights.secure_boot", "abc", "5")),
            "config.yaml's score_weights.secure_boot is \"abc\", which is not a number from 0 "
                + "to 100 — using 5.", "the longest key is not cut short")
        let shown = SecurityPolicyCard.weightCaption(
            issue("security_policy.score_weights.s\u{1B}ip", "a\u{202E}b\n", "15"))
        XCTAssertEqual(shown, SecurityPolicyCard.weightCaption(
            issue("security_policy.score_weights.sip", "ab", "15")))
    }

    func testWeightIssuesAreFoundApartFromLevelsShapesAndUnknownKeys() {
        let weight = issue("security_policy.score_weights.sip", "150", "15")
        let unknown = issue("security_policy.score_weights.extra", "", "")
        let shape = issue("security_policy.score_weights", "[5]", "the default weights")
        let level = issue("security_policy.controls.sip", "wrn", "fail")
        XCTAssertEqual(
            SecurityPolicyCard.weightIssues(in: [level, shape, unknown, weight]), [weight])
        XCTAssertNil(SecurityPolicyCard.levelIssue(for: .sip, in: [weight]))
        XCTAssertEqual(SecurityPolicyCard.shapeIssues(in: [weight, unknown]), [])
        XCTAssertEqual(
            SecurityPolicyCard.unknownKeysCaption([weight, unknown]),
            "config.yaml has 1 security_policy setting the app does not read: "
                + "security_policy.score_weights.extra.")
    }

    func testTheCardInstantiatesInAndOutOfDemoMode() {
        for demo in [true, false] {
            let workspace = WorkspaceStore(
                demoMode: demo, jamfCLIProfileNames: { [] }, discoverProfiles: { [] },
                jamfCLIInstallation: { nil })
            _ = SecurityPolicyCard().environment(workspace)
        }
    }

    // MARK: - What the pickers do

    @MainActor private final class Failure {
        var value: SecurityPolicyCard.SaveFailure?
        var binding: Binding<SecurityPolicyCard.SaveFailure?> {
            Binding(get: { self.value }, set: { self.value = $0 })
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
                .sip, in: store, failure: failure.binding)
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

    func testTheHardwarePickerWritesAndRemovesItsKey() async throws {
        try await withPolicyWorkspacesRoot {
            let url = try writePolicyConfig(
                "security_policy:\n  controls:\n    sip: warn\n", profile: "policy-card")
            let store = policyTestStore(demo: false, profile: "policy-card")
            try await store.loadConfig()
            let failure = Failure()
            let picker = SecurityPolicyCard.hardwareBinding(in: store, failure: failure.binding)
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
            let picker = SecurityPolicyCard.levelBinding(.sip, in: store, failure: failure.binding)

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
            let picker = SecurityPolicyCard.levelBinding(.sip, in: store, failure: failure.binding)

            picker.wrappedValue = .warning

            let workspace = try XCTUnwrap(ProfileService.workspaceURL(for: store.profile))
            XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.path))
            XCTAssertEqual(picker.wrappedValue, .fail)
            XCTAssertNil(failure.value)
        }
    }
}
