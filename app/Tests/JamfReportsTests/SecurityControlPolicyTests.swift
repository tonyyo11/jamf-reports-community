import XCTest
@testable import JamfReports

/// The workspace's `security_policy:` block: one reading of a security value, the
/// verdict each level gives it, and the per-device gap count built from those verdicts.
final class SecurityControlPolicyTests: XCTestCase {

    // MARK: - reading

    /// The three lists the Devices table's own classifier was pinned to before it read this.
    func testReadingKeepsTheDevicesTableAnswers() {
        let off = [
            "UNENCRYPTED", "NOT_ENCRYPTED", "Not Enabled", "NOT_ESCROWED", "Not Installed",
            "inactive", "DECRYPTING", "DISABLED", "false", "Off", "NONE",
        ]
        let on = [
            "ENCRYPTED", "ALL_ENCRYPTED", "Encrypted", "ENABLED", "true", "On", "ESCROWED",
            "APP_STORE_AND_IDENTIFIED_DEVELOPERS", "APP_STORE",
        ]
        let unknown = [
            "", "  ", "NOT_COLLECTED", "NOT_AVAILABLE", "NOT_SUPPORTED", "UNKNOWN", "ENCRYPTING",
        ]
        for value in off { XCTAssertEqual(SecurityControlPolicy.reading(value), false, value) }
        for value in on { XCTAssertEqual(SecurityControlPolicy.reading(value), true, value) }
        for value in unknown { XCTAssertNil(SecurityControlPolicy.reading(value), value) }
        XCTAssertNil(SecurityControlPolicy.reading(nil))
    }

    /// Jamf's CSV FileVault column ("encrypted/total partitions") and its phrases.
    func testReadingPartitionCountsAndPhrases() {
        XCTAssertEqual(SecurityControlPolicy.reading("1/1"), true)
        XCTAssertEqual(SecurityControlPolicy.reading("2/2"), true)
        XCTAssertEqual(SecurityControlPolicy.reading("0/1"), false)
        XCTAssertEqual(SecurityControlPolicy.reading("1/2"), false)
        XCTAssertEqual(SecurityControlPolicy.reading("0/0"), false)
        XCTAssertEqual(SecurityControlPolicy.reading("All Partitions Encrypted"), true)
        XCTAssertEqual(SecurityControlPolicy.reading("No Partitions Encrypted"), false)
        XCTAssertNil(SecurityControlPolicy.reading("Not collected"))
        XCTAssertNil(SecurityControlPolicy.reading("Some Partitions Encrypted"),
                     "does not say whether the boot volume is encrypted")
    }

    /// Commit 088ccd25: a Mac mid-encryption or unable to report FileVault is unmeasured.
    func testFileVaultTransitionStatesReadUnknown() {
        for value in ["ENCRYPTING", "INELIGIBLE", "RESTART_NEEDED"] {
            XCTAssertNil(SecurityControlPolicy.reading(value), value)
        }
    }

    /// Every state Jamf reports for FileVault, SIP and Gatekeeper. A paused encryption
    /// stays paused until someone resumes it, so unlike ENCRYPTING it reads off.
    func testJamfStates() {
        let states: [(String, Bool?)] = [
            ("UNKNOWN", nil), ("UNENCRYPTED", false), ("INELIGIBLE", nil), ("DECRYPTED", false),
            ("DECRYPTING", false), ("ENCRYPTED", true), ("ENCRYPTING", nil),
            ("RESTART_NEEDED", nil), ("OPTIMIZING", nil), ("DECRYPTING_PAUSED", false),
            ("ENCRYPTING_PAUSED", false),
            ("NOT_COLLECTED", nil), ("NOT_AVAILABLE", nil), ("ENABLED", true), ("DISABLED", false),
            ("APP_STORE", true), ("APP_STORE_AND_IDENTIFIED_DEVELOPERS", true),
        ]
        for (value, expected) in states {
            XCTAssertEqual(SecurityControlPolicy.reading(value), expected, value)
        }
    }

    /// `security.bootstrapTokenEscrowedStatus`: a Mac that cannot escrow is unmeasured.
    func testBootstrapEscrowStates() {
        XCTAssertEqual(SecurityControlPolicy.reading("ESCROWED"), true)
        XCTAssertEqual(SecurityControlPolicy.reading("NOT_ESCROWED"), false)
        XCTAssertNil(SecurityControlPolicy.reading("NOT_SUPPORTED"))
    }

    // MARK: - Decoding

    func testAbsentBlockIsNilAndResolvesToTheDefault() throws {
        let config = try ConfigLoader.loadFromString("thresholds:\n  stale_device_days: 45\n")
        XCTAssertNil(config.securityPolicy)
        XCTAssertEqual(config.resolvedSecurityPolicy, .default)
        XCTAssertEqual(SecurityControlPolicy.default, SecurityControlPolicy(
            fileVault: .fail, sip: .fail, firewall: .fail, gatekeeper: .fail,
            fileVaultOffHardwareEncrypted: nil))
    }

    func testFullBlockDecodes() throws {
        let config = try ConfigLoader.loadFromString("""
        security_policy:
          controls:
            filevault: warning
            sip: ignore
            firewall: fail
            gatekeeper: warning
          filevault_off_hardware_encrypted: ignore
        """)
        XCTAssertEqual(config.securityPolicy, SecurityControlPolicy(
            fileVault: .warning, sip: .ignore, firewall: .fail, gatekeeper: .warning,
            fileVaultOffHardwareEncrypted: .ignore))
    }

    func testLevelsAreTrimmedAndCaseInsensitive() throws {
        let config = try ConfigLoader.loadFromString("""
        security_policy:
          controls:
            filevault: Warning
            sip: "  IGNORE  "
          filevault_off_hardware_encrypted: WARNING
        """)
        XCTAssertEqual(config.securityPolicy, SecurityControlPolicy(
            fileVault: .warning, sip: .ignore, fileVaultOffHardwareEncrypted: .warning))
    }

    /// A level the app does not know keeps the control's strict default, and an unknown
    /// hardware level leaves the hardware rule off. `warn` used to be in this list and
    /// read as `fail` with no message; it is now an accepted spelling of `warning`
    /// (`testSynonymsDecode`), so the unrecognised examples are `wrn` and a typed `true`.
    func testUnrecognisedLevelsFallBack() throws {
        let config = try ConfigLoader.loadFromString("""
        security_policy:
          controls:
            filevault: wrn
            firewall: true
          filevault_off_hardware_encrypted: wrn
        """)
        XCTAssertEqual(config.securityPolicy, .default)
    }

    func testSynonymsDecode() throws {
        let config = try ConfigLoader.loadFromString("""
        security_policy:
          controls:
            filevault: warn
            sip: Not_Counted
            firewall: GAP
            gatekeeper: skip
          filevault_off_hardware_encrypted: warn
        """)
        XCTAssertEqual(config.securityPolicy, SecurityControlPolicy(
            fileVault: .warning, sip: .ignore, firewall: .fail, gatekeeper: .ignore,
            fileVaultOffHardwareEncrypted: .warning))
    }

    // MARK: - Hand-typed levels

    func testParseAcceptsEverySpellingInAnyCase() {
        let spellings: [SecurityControlLevel: [String]] = [
            .fail: ["fail", "FAIL", "Failure", "gap", "Gap", " fail "],
            .warning: ["warning", "Warning", "WARN", "warn", "wArN"],
            .ignore: ["ignore", "Ignored", "IGNORED", "skip", "not counted", "Not Counted",
                      "not_counted", "NOT-COUNTED", "  not counted  "],
        ]
        for (level, texts) in spellings {
            for text in texts {
                XCTAssertEqual(SecurityControlLevel.parse(text), level, text)
            }
        }
        for level in SecurityControlLevel.allCases {
            XCTAssertEqual(SecurityControlLevel.parse(level.rawValue), level)
        }
    }

    func testParseRejectsWhatIsNotALevel() {
        for text in ["on", "off", "true", "yes", "no", "", "  ", "wrn", "1", "notcounted",
                     "not counted!", "failed"] {
            XCTAssertNil(SecurityControlLevel.parse(text), "\"\(text)\"")
        }
    }

    func testWrongShapesKeepTheRestOfTheConfig() throws {
        let scalarControls = try ConfigLoader.loadFromString("""
        security_policy:
          controls: "x"
          filevault_off_hardware_encrypted: warning
        thresholds:
          stale_device_days: 45
        """)
        XCTAssertEqual(scalarControls.securityPolicy,
                       SecurityControlPolicy(fileVaultOffHardwareEncrypted: .warning))
        XCTAssertEqual(scalarControls.thresholds?.staleDeviceDays, 45)

        let sequenceBlock = try ConfigLoader.loadFromString("""
        security_policy: [1]
        thresholds:
          stale_device_days: 45
        """)
        XCTAssertEqual(sequenceBlock.resolvedSecurityPolicy, .default)
        XCTAssertEqual(sequenceBlock.thresholds?.staleDeviceDays, 45)

        let scalarBlock = try ConfigLoader.loadFromString("""
        security_policy: "x"
        thresholds:
          stale_device_days: 45
        """)
        XCTAssertEqual(scalarBlock.resolvedSecurityPolicy, .default)
        XCTAssertEqual(scalarBlock.thresholds?.staleDeviceDays, 45)

        for hardwareShape in ["{level: warning}", "[warning]"] {
            let config = try ConfigLoader.loadFromString("""
            security_policy:
              controls:
                sip: warning
              filevault_off_hardware_encrypted: \(hardwareShape)
            """)
            XCTAssertEqual(config.securityPolicy, SecurityControlPolicy(sip: .warning),
                           "hardware level \(hardwareShape) is nil; the controls still decode")
        }
    }

    /// The shipped example spells out the defaults, so a fresh workspace behaves as today.
    func testShippedExampleIsTheDefaultPolicy() throws {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var example: URL?
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("config.example.yaml")
            if FileManager.default.fileExists(atPath: candidate.path) {
                example = candidate
                break
            }
            dir = dir.deletingLastPathComponent()
        }
        guard let example else {
            throw XCTSkip("config.example.yaml not found above \(#filePath)")
        }
        let config = try ConfigLoader.load(from: example)
        XCTAssertNotNil(config.securityPolicy, "the example carries the block")
        XCTAssertEqual(config.resolvedSecurityPolicy, .default)
    }

    // MARK: - Verdicts

    private func makePolicy(
        _ control: SecurityControl, _ level: SecurityControlLevel,
        hardware: SecurityControlLevel? = nil
    ) -> SecurityControlPolicy {
        var policy = SecurityControlPolicy(fileVaultOffHardwareEncrypted: hardware)
        switch control {
        case .fileVault: policy.fileVault = level
        case .sip: policy.sip = level
        case .firewall: policy.firewall = level
        case .gatekeeper: policy.gatekeeper = level
        }
        return policy
    }

    private let hardwareFacts: [Bool?] = [true, false, nil]

    /// Without the hardware rule the hardware fact never matters.
    func testVerdictForEachLevelAndReading() {
        let expected: [SecurityControlLevel: [Bool?: SecurityVerdict]] = [
            .fail: [true: .pass, false: .fail, nil: .unknown],
            .warning: [true: .pass, false: .warning, nil: .unknown],
            .ignore: [true: .ignored, false: .ignored, nil: .ignored],
        ]
        for control in SecurityControl.allCases {
            for (level, byReading) in expected {
                let policy = makePolicy(control, level)
                XCTAssertEqual(policy.level(for: control), level)
                for (reading, verdict) in byReading {
                    for hardware in hardwareFacts {
                        XCTAssertEqual(
                            policy.verdict(for: control, reading: reading,
                                           hardwareEncrypted: hardware),
                            verdict, "\(control) \(level) \(String(describing: reading)) "
                                + "hw \(String(describing: hardware))")
                    }
                }
            }
        }
    }

    /// FileVault off: (filevault level, hardware rule level, verdict by hardware fact).
    func testHardwareRuleOnlyMovesFileVaultOffOnHardwareEncryptedMacs() {
        let cases: [(SecurityControlLevel, SecurityControlLevel?, [Bool?: SecurityVerdict])] = [
            (.fail, .warning, [true: .warning, false: .fail, nil: .fail]),
            (.fail, .ignore, [true: .ignored, false: .fail, nil: .fail]),
            (.warning, .warning, [true: .warning, false: .warning, nil: .warning]),
            (.warning, .ignore, [true: .ignored, false: .warning, nil: .warning]),
            (.ignore, .warning, [true: .ignored, false: .ignored, nil: .ignored]),
            (.ignore, .ignore, [true: .ignored, false: .ignored, nil: .ignored]),
            (.warning, .fail, [true: .warning, false: .warning, nil: .warning]),
            (.fail, nil, [true: .fail, false: .fail, nil: .fail]),
        ]
        for (fileVault, rule, byHardware) in cases {
            let policy = makePolicy(.fileVault, fileVault, hardware: rule)
            let onVerdict: SecurityVerdict = fileVault == .ignore ? .ignored : .pass
            let unmeasured: SecurityVerdict = fileVault == .ignore ? .ignored : .unknown
            for hardware in hardwareFacts {
                let label = "\(fileVault) rule \(String(describing: rule)) "
                    + "hw \(String(describing: hardware))"
                XCTAssertEqual(policy.verdict(for: .fileVault, reading: false,
                                              hardwareEncrypted: hardware),
                               byHardware[hardware], label)
                XCTAssertEqual(policy.verdict(for: .fileVault, reading: true,
                                              hardwareEncrypted: hardware), onVerdict, label)
                XCTAssertEqual(policy.verdict(for: .fileVault, reading: nil,
                                              hardwareEncrypted: hardware), unmeasured, label)
            }
        }
    }

    func testHardwareRuleLeavesOtherControlsAlone() {
        let policy = SecurityControlPolicy(fileVaultOffHardwareEncrypted: .ignore)
        for control in [SecurityControl.sip, .firewall, .gatekeeper] {
            XCTAssertEqual(policy.verdict(for: control, reading: false, hardwareEncrypted: true),
                           .fail, "\(control)")
        }
    }

    func testUsesHardwareRule() {
        XCTAssertFalse(SecurityControlPolicy.default.usesHardwareRule)
        XCTAssertTrue(SecurityControlPolicy(fileVaultOffHardwareEncrypted: .warning)
            .usesHardwareRule)
        XCTAssertTrue(SecurityControlPolicy(fileVaultOffHardwareEncrypted: .ignore)
            .usesHardwareRule)
        XCTAssertFalse(SecurityControlPolicy(fileVaultOffHardwareEncrypted: .fail)
            .usesHardwareRule)
        XCTAssertFalse(SecurityControlPolicy(fileVault: .ignore,
                                             fileVaultOffHardwareEncrypted: .warning)
            .usesHardwareRule, "filevault: ignore disables the rule")
    }

    func testHardwareRuleAppliesOnlyToFileVaultOffOnAHardwareEncryptedMac() {
        let policy = SecurityControlPolicy(fileVaultOffHardwareEncrypted: .warning)
        XCTAssertTrue(policy.hardwareRuleApplies(fileVaultReading: false, hardwareEncrypted: true))
        XCTAssertFalse(policy.hardwareRuleApplies(fileVaultReading: true, hardwareEncrypted: true))
        XCTAssertFalse(policy.hardwareRuleApplies(fileVaultReading: nil, hardwareEncrypted: true))
        XCTAssertFalse(policy.hardwareRuleApplies(fileVaultReading: false,
                                                  hardwareEncrypted: false))
        XCTAssertFalse(policy.hardwareRuleApplies(fileVaultReading: false, hardwareEncrypted: nil))
        XCTAssertFalse(SecurityControlPolicy.default.hardwareRuleApplies(
            fileVaultReading: false, hardwareEncrypted: true))
    }

    func testVerdictForAValueReadsItFirst() {
        let policy = SecurityControlPolicy(fileVaultOffHardwareEncrypted: .warning)
        XCTAssertEqual(policy.verdict(for: .fileVault, value: "UNENCRYPTED",
                                      hardwareEncrypted: true), .warning)
        XCTAssertEqual(policy.verdict(for: .fileVault, value: "UNENCRYPTED",
                                      hardwareEncrypted: nil), .fail)
        XCTAssertEqual(policy.verdict(for: .fileVault, value: "ENCRYPTING",
                                      hardwareEncrypted: true), .unknown)
        XCTAssertEqual(policy.verdict(for: .gatekeeper, value: "APP_STORE",
                                      hardwareEncrypted: nil), .pass)
        XCTAssertEqual(policy.verdict(for: .sip, value: nil, hardwareEncrypted: nil), .unknown)
    }

    // MARK: - gapCount

    func testGapCountIsNilWhenNoEvaluatedControlWasMeasured() {
        let strict = SecurityControlPolicy.default
        XCTAssertNil(strict.gapCount(fileVault: nil, sip: nil, firewall: nil, gatekeeper: nil,
                                     hardwareEncrypted: nil))
        XCTAssertEqual(strict.gapCount(fileVault: nil, sip: nil, firewall: false, gatekeeper: nil,
                                       hardwareEncrypted: nil), 1)

        let noFirewall = SecurityControlPolicy(firewall: .ignore)
        XCTAssertNil(noFirewall.gapCount(fileVault: nil, sip: nil, firewall: false,
                                         gatekeeper: nil, hardwareEncrypted: nil),
                     "an ignored control's reading does not make a device measured")

        let nothing = SecurityControlPolicy(
            fileVault: .ignore, sip: .ignore, firewall: .ignore, gatekeeper: .ignore)
        XCTAssertNil(nothing.gapCount(fileVault: false, sip: false, firewall: false,
                                      gatekeeper: false, hardwareEncrypted: nil))
    }

    func testGapCountCountsOnlyFailVerdicts() {
        let strict = SecurityControlPolicy.default
        XCTAssertEqual(strict.gapCount(fileVault: false, sip: false, firewall: false,
                                       gatekeeper: false, hardwareEncrypted: nil), 4)
        XCTAssertEqual(strict.gapCount(fileVault: true, sip: nil, firewall: false,
                                       gatekeeper: true, hardwareEncrypted: nil), 1)

        let lenient = SecurityControlPolicy(fileVault: .warning, sip: .ignore)
        XCTAssertEqual(lenient.gapCount(fileVault: false, sip: false, firewall: true,
                                        gatekeeper: true, hardwareEncrypted: nil), 0)

        let rule = SecurityControlPolicy(fileVaultOffHardwareEncrypted: .warning)
        XCTAssertEqual(rule.gapCount(fileVault: false, sip: true, firewall: true,
                                     gatekeeper: true, hardwareEncrypted: true), 0)
        XCTAssertEqual(rule.gapCount(fileVault: false, sip: true, firewall: true,
                                     gatekeeper: true, hardwareEncrypted: nil), 1)
    }

    // MARK: - Loader

    private func withWorkspacesRoot(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-policy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let saved = ProcessInfo.processInfo.environment["JRC_TEST_WORKSPACES_ROOT"]
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        defer {
            if let saved { setenv("JRC_TEST_WORKSPACES_ROOT", saved, 1) }
            else { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
            try? FileManager.default.removeItem(at: root)
        }
        try body(root)
    }

    private func writeConfig(_ yaml: String, profile: String) throws {
        let workspace = try XCTUnwrap(ProfileService.workspaceURL(for: profile))
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try yaml.write(to: workspace.appendingPathComponent("config.yaml"),
                       atomically: true, encoding: .utf8)
    }

    func testLoaderReadsTheWorkspaceBlock() throws {
        try withWorkspacesRoot { _ in
            XCTAssertEqual(SecurityPolicyConfigLoader.load(profile: "policy-none"), .default,
                           "no workspace or no config.yaml")
            try writeConfig("security_policy:\n  controls:\n    sip: warning\n",
                            profile: "policy-set")
            XCTAssertEqual(SecurityPolicyConfigLoader.load(profile: "policy-set"),
                           SecurityControlPolicy(sip: .warning))
        }
    }

    func testLoaderFallsBackToTheDefaultWhenConfigDoesNotDecode() throws {
        try withWorkspacesRoot { _ in
            try writeConfig("""
            security_policy:
              controls:
                sip: warning
            custom_eas: "not a list"
            """, profile: "policy-broken")
            XCTAssertEqual(SecurityPolicyConfigLoader.load(profile: "policy-broken"), .default)
        }
    }

    // MARK: - Issues in a hand-typed block

    private func issues(_ yaml: String?) throws -> [SecurityPolicyIssue] {
        var found: [SecurityPolicyIssue] = []
        try withWorkspacesRoot { _ in
            if let yaml { try writeConfig(yaml, profile: "policy-issues") }
            found = SecurityPolicyConfigLoader.issues(profile: "policy-issues")
        }
        return found
    }

    private func issue(_ keyPath: String, _ value: String, _ used: String) -> SecurityPolicyIssue {
        SecurityPolicyIssue(keyPath: keyPath, value: value, used: used)
    }

    func testIssuesNameAnUnrecognisedLevel() throws {
        let found = try issues("""
        security_policy:
          controls:
            filevault: warning
            sip: wrn
          filevault_off_hardware_encrypted: maybe
        """)
        XCTAssertEqual(found, [
            issue("security_policy.controls.sip", "wrn", "fail"),
            issue("security_policy.filevault_off_hardware_encrypted", "maybe",
                  "the FileVault level"),
        ])
    }

    /// `true` arrives as a Bool, `1` as a number and an empty value as null. Each is shown
    /// the way it was typed: the null as an empty string, never as "null" or a type name.
    func testIssuesShowTypedBoolNumberNullAndStringValuesAsWritten() throws {
        let found = try issues("""
        security_policy:
          controls:
            filevault: no
            sip: true
            firewall: 1
            gatekeeper:
          filevault_off_hardware_encrypted: false
        """)
        XCTAssertEqual(found, [
            issue("security_policy.controls.filevault", "no", "fail"),
            issue("security_policy.controls.sip", "true", "fail"),
            issue("security_policy.controls.firewall", "1", "fail"),
            issue("security_policy.controls.gatekeeper", "", "fail"),
            issue("security_policy.filevault_off_hardware_encrypted", "false",
                  "the FileVault level"),
        ])
    }

    func testIssuesNameAnUnknownControlWithoutItsValue() throws {
        let found = try issues("""
        security_policy:
          controls:
            antivirus: warning
            sip: warning
        """)
        XCTAssertEqual(found, [issue("security_policy.controls.antivirus", "", "")])
    }

    func testIssuesNameAnUnknownKeyInTheBlock() throws {
        let found = try issues("""
        security_policy:
          mode: strict
          Controls:
            sip: warning
          score_weights:
            sip: 5
          filevault_off_hardware_encrypted: warning
        """)
        XCTAssertEqual(found, [
            issue("security_policy.mode", "", ""),
            issue("security_policy.Controls", "", ""),
        ], "keys are case-sensitive, as the decoder reads them")
    }

    func testIssuesNameABlockOfTheWrongShape() throws {
        XCTAssertEqual(try issues("security_policy: strict\n"),
                       [issue("security_policy", "strict", "the default policy")])
        XCTAssertEqual(try issues("security_policy: [a, b]\n"),
                       [issue("security_policy", "[a, b]", "the default policy")])
        XCTAssertEqual(try issues("""
            security_policy:
              controls: strict
              score_weights: [5]
              filevault_off_hardware_encrypted: {level: warning}
            """), [
            issue("security_policy.controls", "strict", "fail for every control"),
            issue("security_policy.score_weights", "[5]", "the default weights"),
            issue("security_policy.filevault_off_hardware_encrypted", "{…}",
                  "the FileVault level"),
        ])
    }

    func testCleanAbsentAndEmptyBlocksHaveNoIssues() throws {
        XCTAssertEqual(try issues(nil), [], "no config.yaml")
        XCTAssertEqual(try issues("thresholds:\n  stale_device_days: 45\n"), [], "no block")
        XCTAssertEqual(try issues("security_policy:\n"), [], "an empty block")
        XCTAssertEqual(try issues("security_policy: {}\n"), [])
        XCTAssertEqual(try issues("security_policy:\n  controls:\n"), [], "an empty controls")
        XCTAssertEqual(try issues("""
            security_policy:
              controls:
                filevault: Warn
                sip: not_counted
                firewall: GAP
                gatekeeper: ignore
              filevault_off_hardware_encrypted: skip
              score_weights:
                sip: 5
            """), [], "accepted synonyms are not issues")
    }

    /// The decoder keeps the last of a repeated key, so the issue follows the last one.
    func testIssuesFollowTheLastOfARepeatedKey() throws {
        XCTAssertEqual(try issues("""
            security_policy:
              controls:
                sip: wrn
                sip: warning
            """), [])
        XCTAssertEqual(try issues("""
            security_policy:
              controls:
                sip: warning
                sip: wrn
                sip: wrn
            """), [issue("security_policy.controls.sip", "wrn", "fail")],
                       "one issue for a key, not one per line")
    }

    func testDisplayTextStripsControlCharactersAndCapsAtFortyCharacters() {
        XCTAssertEqual(SecurityPolicyConfigLoader.displayText("a\u{7}b\nc\t\u{202E}d\u{2028}e"),
                       "abcde")
        let forty = String(repeating: "x", count: 40)
        XCTAssertEqual(SecurityPolicyConfigLoader.displayText(forty), forty)
        XCTAssertEqual(SecurityPolicyConfigLoader.displayText(forty + "y"),
                       String(repeating: "x", count: 39) + "…")
        XCTAssertEqual(SecurityPolicyConfigLoader.displayText(""), "")
    }

    /// Text from the file reaches the Doctor and the card through the issue, so the issue
    /// is where it is cleaned: a typed value and a key name alike.
    func testIssuesCleanTheTextTheyTakeFromTheFile() throws {
        let long = String(repeating: "z", count: 60)
        let found = try issues("""
        security_policy:
          controls:
            sip: w\u{7}r\u{202E}n\u{1B}[31m
            firewall: \(long)
            \(long): warning
        """)
        let capped = String(repeating: "z", count: 39) + "…"
        XCTAssertEqual(found.map(\.value), ["wrn[31m", capped, ""])
        XCTAssertEqual(found.last?.keyPath, "security_policy.controls." + capped)
        XCTAssertTrue(found.allSatisfy { $0.keyPath.count <= 80 && $0.value.count <= 40 })
    }

    /// Three bad values: for each, `used` is what `load(profile:)` really applied, and the
    /// synonyms in the same file are understood by the loader and absent from the issues.
    func testIssuesAndTheLoadedPolicyAgree() throws {
        try withWorkspacesRoot { _ in
            try writeConfig("""
            security_policy:
              controls:
                filevault: warn
                sip: wrn
                firewall: true
                gatekeeper: skip
              filevault_off_hardware_encrypted: maybe
            """, profile: "policy-agree")
            let policy = SecurityPolicyConfigLoader.load(profile: "policy-agree")
            let found = SecurityPolicyConfigLoader.issues(profile: "policy-agree")

            XCTAssertEqual(policy.fileVault, .warning)
            XCTAssertEqual(policy.gatekeeper, .ignore)
            XCTAssertEqual(found.map(\.keyPath), [
                "security_policy.controls.sip", "security_policy.controls.firewall",
                "security_policy.filevault_off_hardware_encrypted",
            ])
            XCTAssertEqual(found[0].used, policy.level(for: .sip).rawValue)
            XCTAssertEqual(found[1].used, policy.level(for: .firewall).rawValue)
            XCTAssertNil(policy.fileVaultOffHardwareEncrypted)
            XCTAssertEqual(found[2].used, "the FileVault level")
        }
    }
}
