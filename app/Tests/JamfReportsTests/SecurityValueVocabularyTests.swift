import XCTest
@testable import JamfReports

/// `security_policy.on_values` / `off_values`: the words an organization's own export uses
/// for on and off, per control. They are read before the built-in vocabulary, match the whole
/// value, and change nothing when absent.
final class SecurityValueVocabularyTests: XCTestCase {

    private func policy(_ yaml: String) throws -> SecurityControlPolicy {
        try ConfigLoader.loadFromString(yaml).resolvedSecurityPolicy
    }

    /// The org-export vocabulary most of these tests read through.
    private let passFail = SecurityControlPolicy(
        onValues: [.firewall: ["Pass", "Compliant"]],
        offValues: [.firewall: ["Fail", "Non-Compliant"]])

    // MARK: - Decoding

    func testAbsentKeysAreTheDefaultPolicy() throws {
        XCTAssertEqual(try policy("security_policy:\n  controls:\n    sip: warning\n"),
                       SecurityControlPolicy(sip: .warning))
        XCTAssertEqual(try policy("thresholds:\n  stale_device_days: 45\n"), .default)
        let plain = try policy("security_policy:\n  controls:\n    sip: warning\n")
        XCTAssertTrue(plain.onValues.isEmpty)
        XCTAssertTrue(plain.offValues.isEmpty)
    }

    func testAListAndASingleStringDecode() throws {
        let decoded = try policy("""
        security_policy:
          on_values:
            firewall: ["Pass", "Compliant"]
            sip: Protected
          off_values:
            firewall:
              - Fail
              - Non-Compliant
            gatekeeper: Open
        """)
        XCTAssertEqual(decoded.onValues, [.firewall: ["pass", "compliant"], .sip: ["protected"]])
        XCTAssertEqual(decoded.offValues,
                       [.firewall: ["fail", "non compliant"], .gatekeeper: ["open"]])
        XCTAssertEqual(decoded, SecurityControlPolicy(
            onValues: [.firewall: ["Pass", "Compliant"], .sip: ["Protected"]],
            offValues: [.firewall: ["Fail", "Non-Compliant"], .gatekeeper: ["Open"]]))
    }

    func testValuesAreStoredNormalisedAndWithoutDuplicates() throws {
        let decoded = try policy("""
        security_policy:
          off_values:
            firewall: ["  Non_Compliant ", "NON-COMPLIANT", "non compliant"]
        """)
        XCTAssertEqual(decoded.offValues, [.firewall: ["non compliant"]])
    }

    func testEmptyValuesAreNotStored() throws {
        let decoded = try policy("""
        security_policy:
          on_values:
            firewall: ["", "   ", "Pass"]
            sip: ""
          off_values:
            firewall: [""]
        """)
        XCTAssertEqual(decoded.onValues, [.firewall: ["pass"]])
        XCTAssertTrue(decoded.offValues.isEmpty)
        XCTAssertNil(decoded.reading("", for: .firewall))
    }

    func testWrongShapesAreNotUsed() throws {
        let decoded = try policy("""
        security_policy:
          on_values:
            firewall: 5
            sip:
              inner: Pass
            gatekeeper:
              - Pass
              - 7
              - null
          off_values: not a mapping
        """)
        XCTAssertEqual(decoded.onValues, [.gatekeeper: ["pass"]])
        XCTAssertTrue(decoded.offValues.isEmpty)
    }

    func testAnUnknownControlKeyIsIgnored() throws {
        let decoded = try policy("""
        security_policy:
          on_values:
            bootstrap_token: ["Escrowed"]
            firewall: Pass
        """)
        XCTAssertEqual(decoded.onValues, [.firewall: ["pass"]])
    }

    /// A quoted `"True"` or `"False"` reaches the decoder as a boolean; it is still the word
    /// the operator typed, and matching ignores case.
    func testAQuotedBooleanWordIsKept() throws {
        let decoded = try policy("""
        security_policy:
          on_values:
            firewall: ["True"]
          off_values:
            firewall: ["False", "Bad"]
        """)
        XCTAssertEqual(decoded.onValues, [.firewall: ["true"]])
        XCTAssertEqual(decoded.offValues, [.firewall: ["false", "bad"]])
    }

    func testABadVocabularyKeepsTheRestOfThePolicy() throws {
        let decoded = try policy("""
        security_policy:
          controls:
            firewall: warning
          filevault_off_hardware_encrypted: ignore
          on_values: [1, 2]
          off_values:
            firewall:
              inner: b
        """)
        XCTAssertEqual(decoded, SecurityControlPolicy(
            firewall: .warning, fileVaultOffHardwareEncrypted: .ignore))
    }

    func testTheVocabularyDecodesBesideEveryOtherKey() throws {
        let decoded = try policy("""
        security_policy:
          controls:
            firewall: ignore
          score_weights:
            filevault: 20
          on_values:
            sip: Protected
        """)
        XCTAssertEqual(decoded.firewall, .ignore)
        XCTAssertEqual(decoded.scoreWeights?.fileVault, 20)
        XCTAssertEqual(decoded.onValues, [.sip: ["protected"]])
    }

    func testTheVocabularyIsPartOfPolicyEquality() {
        XCTAssertNotEqual(passFail, SecurityControlPolicy())
        XCTAssertNotEqual(
            SecurityControlPolicy(onValues: [.firewall: ["Pass"]]),
            SecurityControlPolicy(onValues: [.sip: ["Pass"]]))
        XCTAssertEqual(
            SecurityControlPolicy(onValues: [.firewall: ["PASS"]]),
            SecurityControlPolicy(onValues: [.firewall: [" pass"]]))
    }

    func testSettingALevelKeepsTheVocabulary() {
        XCTAssertEqual(passFail.setting(.warning, for: .firewall).onValues, passFail.onValues)
        XCTAssertEqual(passFail.setting(.warning, for: .firewall).offValues, passFail.offValues)
    }

    // MARK: - Reading

    func testConfiguredValuesReadAsTheirList() {
        XCTAssertEqual(passFail.reading("Pass", for: .firewall), true)
        XCTAssertEqual(passFail.reading("Compliant", for: .firewall), true)
        XCTAssertEqual(passFail.reading("Fail", for: .firewall), false)
        XCTAssertEqual(passFail.reading("Non-Compliant", for: .firewall), false)
    }

    /// The same normalisation as the built-in reading: trimmed, any case, `_` and `-` as spaces.
    func testMatchingNormalisesBothSides() {
        XCTAssertEqual(passFail.reading("  PASS\n", for: .firewall), true)
        XCTAssertEqual(passFail.reading("non_compliant", for: .firewall), false)
        XCTAssertEqual(passFail.reading("NON COMPLIANT", for: .firewall), false)
        XCTAssertEqual(passFail.reading("Non-Compliant ", for: .firewall), false)
    }

    /// "Non-Compliant" holds the word "Compliant", and neither reads as the other.
    func testAConfiguredValueMatchesTheWholeValueOnly() {
        let onOnly = SecurityControlPolicy(onValues: [.firewall: ["Compliant"]])
        XCTAssertEqual(onOnly.reading("Compliant", for: .firewall), true)
        XCTAssertNil(onOnly.reading("Non-Compliant", for: .firewall))
        XCTAssertNil(onOnly.reading("Compliant (pending review)", for: .firewall))
        let offOnly = SecurityControlPolicy(offValues: [.firewall: ["Fail"]])
        XCTAssertEqual(offOnly.reading("Fail", for: .firewall), false)
        XCTAssertNil(offOnly.reading("Failover ready", for: .firewall))
    }

    func testAValueInBothListsReadsOff() {
        let both = SecurityControlPolicy(
            onValues: [.firewall: ["Pass"]], offValues: [.firewall: ["pass"]])
        XCTAssertEqual(both.reading("Pass", for: .firewall), false)
    }

    func testAnUnlistedValueFallsThroughToTheBuiltInVocabulary() {
        XCTAssertEqual(passFail.reading("Enabled", for: .firewall), true)
        XCTAssertEqual(passFail.reading("DISABLED", for: .firewall), false)
        XCTAssertEqual(passFail.reading("Block all incoming connections", for: .firewall), true)
        XCTAssertNil(passFail.reading("NOT_COLLECTED", for: .firewall))
        XCTAssertNil(passFail.reading("Maybe", for: .firewall))
        XCTAssertNil(passFail.reading("", for: .firewall))
        XCTAssertNil(passFail.reading(nil, for: .firewall))
    }

    /// Configured values come before the built-in ones, so an organization can say what its
    /// own word means even when the built-in vocabulary reads it another way.
    func testConfiguredValuesWinOverTheBuiltInVocabulary() {
        let inverted = SecurityControlPolicy(
            onValues: [.sip: ["Pending"]], offValues: [.sip: ["Enabled"]])
        XCTAssertEqual(inverted.reading("Pending", for: .sip), true)
        XCTAssertEqual(inverted.reading("enabled", for: .sip), false)
        XCTAssertNil(SecurityControlPolicy.reading("Pending"))
    }

    func testTheVocabularyBelongsToItsControl() {
        XCTAssertNil(passFail.reading("Pass", for: .sip))
        XCTAssertNil(passFail.reading("Fail", for: .fileVault))
        XCTAssertNil(passFail.reading("Pass", for: .gatekeeper))
    }

    func testTheStaticReadingKnowsNoVocabulary() {
        XCTAssertNil(SecurityControlPolicy.reading("Pass"))
        XCTAssertNil(SecurityControlPolicy.reading("Fail"))
        XCTAssertEqual(SecurityControlPolicy.reading("Escrowed"), true)
    }

    func testNoVocabularyReadsLikeTheBuiltInVocabulary() {
        let samples = [
            "ENCRYPTED", "UNENCRYPTED", "Not Enabled", "On", "off", "3/3", "2/3", "ENCRYPTING",
            "NOT_COLLECTED", "", "Pass", "Running", "Disconnected",
        ]
        for control in SecurityControl.allCases {
            for sample in samples {
                XCTAssertEqual(
                    SecurityControlPolicy.default.reading(sample, for: control),
                    SecurityControlPolicy.reading(sample), "\(control) \(sample)")
            }
        }
    }

    // MARK: - Verdicts

    func testVerdictForAValueUsesTheVocabulary() {
        XCTAssertEqual(
            passFail.verdict(for: .firewall, value: "Pass", hardwareEncrypted: nil), .pass)
        XCTAssertEqual(
            passFail.verdict(for: .firewall, value: "Non-Compliant", hardwareEncrypted: nil),
            .fail)
        XCTAssertEqual(
            passFail.setting(.warning, for: .firewall)
                .verdict(for: .firewall, value: "Fail", hardwareEncrypted: nil), .warning)
        XCTAssertEqual(
            passFail.verdict(for: .sip, value: "Pass", hardwareEncrypted: nil), .unknown)
        XCTAssertEqual(
            SecurityControlPolicy().verdict(for: .firewall, value: "Pass", hardwareEncrypted: nil),
            .unknown)
    }

    func testTheHardwareRuleFollowsAConfiguredFileVaultValue() {
        let rule = SecurityControlPolicy(
            fileVaultOffHardwareEncrypted: .warning, offValues: [.fileVault: ["Bare"]])
        XCTAssertEqual(
            rule.verdict(for: .fileVault, value: "Bare", hardwareEncrypted: true), .warning)
        XCTAssertEqual(
            rule.verdict(for: .fileVault, value: "Bare", hardwareEncrypted: false), .fail)
        XCTAssertEqual(
            rule.fileVaultLabel("Bare", hardwareEncrypted: true),
            SecurityControlPolicy.hardwareEncryptedFileVaultOffLabel)
        XCTAssertEqual(rule.fileVaultLabel("Bare", hardwareEncrypted: false), "Bare")
        let none = SecurityControlPolicy(fileVaultOffHardwareEncrypted: .warning)
        XCTAssertEqual(none.fileVaultLabel("Bare", hardwareEncrypted: true), "Bare")
    }
}
