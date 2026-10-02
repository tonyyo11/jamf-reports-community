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

            // The card saves the loaded policy with one control changed, so its weights ride
            // along; a policy built without them is the Reset button's (see the weights tests).
            let loaded = SecurityPolicyConfigLoader.load(profile: profile)
            try SecurityPolicyConfigWriter.save(
                loaded.setting(.warning, for: .sip), profile: profile)

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

    // MARK: - Score weights

    private let custom = SecurityScoreWeights(
        fileVault: 30, sip: 12, firewall: 15, edrAgent: 0, mscp: 20, xprotect: 5, cve: 100,
        secureBoot: 5)

    func testSaveThenLoadReturnsTheWeights() throws {
        try withWorkspacesRoot {
            try write("columns:\n  serial_number: \"Serial Number\"\n")
            let policy = SecurityControlPolicy(sip: .warning, scoreWeights: custom)

            try SecurityPolicyConfigWriter.save(policy, profile: profile)

            XCTAssertEqual(SecurityPolicyConfigLoader.load(profile: profile), policy)
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
            let policy = SecurityControlPolicy(scoreWeights: .defaultWeights)
            try SecurityPolicyConfigWriter.save(policy, profile: profile)
            XCTAssertEqual(SecurityPolicyConfigLoader.load(profile: profile), policy)
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
            let loaded = SecurityPolicyConfigLoader.load(profile: profile)
            XCTAssertNotNil(loaded.scoreWeights)

            var reset = loaded
            reset.scoreWeights = nil
            try SecurityPolicyConfigWriter.save(reset, profile: profile)

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

            try SecurityPolicyConfigWriter.save(loaded, profile: profile)

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
            var policy = SecurityPolicyConfigLoader.load(profile: profile)
            var weights = try XCTUnwrap(policy.scoreWeights)
            weights.sip = 8
            policy.scoreWeights = weights

            try SecurityPolicyConfigWriter.save(policy, profile: profile)

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
            var policy = SecurityPolicyConfigLoader.load(profile: profile)
            XCTAssertEqual(policy.scoreWeights?.sip, 15)

            try SecurityPolicyConfigWriter.save(policy, profile: profile)
            XCTAssertTrue(try readBack().contains("sip: abc"))
            XCTAssertEqual(SecurityPolicyConfigLoader.issues(profile: profile).count, 1)

            policy.scoreWeights?.sip = 16
            try SecurityPolicyConfigWriter.save(policy, profile: profile)
            XCTAssertEqual(SecurityPolicyConfigLoader.issues(profile: profile), [])
            XCTAssertEqual(SecurityPolicyConfigLoader.load(profile: profile), policy)
        }
    }

    /// A fractional weight typed by hand is what the score uses, so a save of another control
    /// must not round it.
    func testASaveOfAnotherControlLeavesAFractionalWeightAsTyped() throws {
        try withWorkspacesRoot {
            try write("security_policy:\n  score_weights:\n    xprotect: 12.5\n")
            let loaded = SecurityPolicyConfigLoader.load(profile: profile)
            XCTAssertEqual(loaded.scoreWeights?.xprotect, 12.5)

            try SecurityPolicyConfigWriter.save(
                loaded.setting(.warning, for: .sip), profile: profile)

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
            try SecurityPolicyConfigWriter.save(
                SecurityControlPolicy(scoreWeights: weights), profile: profile)

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
            try SecurityPolicyConfigWriter.save(.default, profile: profile)
            XCTAssertNil(SecurityPolicyConfigLoader.load(profile: profile).scoreWeights)
            XCTAssertFalse(try readBack().contains("score_weights"), "nil removes the key")

            try write("security_policy:\n  score_weights: 5\n")
            try SecurityPolicyConfigWriter.save(
                SecurityControlPolicy(scoreWeights: custom), profile: profile)
            XCTAssertEqual(SecurityPolicyConfigLoader.load(profile: profile).scoreWeights, custom)
            XCTAssertEqual(SecurityPolicyConfigLoader.issues(profile: profile), [])
        }
    }

    func testARepeatedWeightKeyIsWrittenOnce() throws {
        try withWorkspacesRoot {
            try write("security_policy:\n  score_weights:\n    sip: 9\n    sip: 5\n")
            var policy = SecurityPolicyConfigLoader.load(profile: profile)
            XCTAssertEqual(policy.scoreWeights?.sip, 5)
            policy.scoreWeights?.sip = 7

            try SecurityPolicyConfigWriter.save(policy, profile: profile)

            XCTAssertEqual(SecurityPolicyConfigLoader.load(profile: profile).scoreWeights?.sip, 7)
            XCTAssertEqual(try readBack().components(separatedBy: "sip:").count, 2)
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

    func testTheStoreLoadsSavesAndResetsTheWeights() async throws {
        try await withWorkspacesRoot {
            try writeConfig("""
            security_policy:
              score_weights:
                filevault: 30
                sip: 150
            """, profile: "policy-store-w")
            let store = store(demo: false, profile: "policy-store-w")

            try await store.loadConfig()

            XCTAssertEqual(store.securityPolicy.scoreWeights?.fileVault, 30)
            XCTAssertEqual(store.securityPolicy.scoreWeights?.sip, 15)
            XCTAssertEqual(store.securityPolicyIssues.map(\.keyPath),
                           ["security_policy.score_weights.sip"])

            var policy = store.securityPolicy
            policy.scoreWeights?.sip = 25
            try store.saveSecurityPolicy(policy)
            XCTAssertEqual(store.securityPolicy.scoreWeights?.sip, 25)
            XCTAssertEqual(store.securityPolicyIssues, [], "the saved weight clears its issue")
            XCTAssertEqual(
                SecurityPolicyConfigLoader.load(profile: "policy-store-w").scoreWeights?.sip, 25)

            policy.scoreWeights = nil
            try store.saveSecurityPolicy(policy)
            XCTAssertNil(store.securityPolicy.scoreWeights)
            XCTAssertNil(SecurityPolicyConfigLoader.load(profile: "policy-store-w").scoreWeights)
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
}
