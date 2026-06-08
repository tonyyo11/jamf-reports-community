import XCTest
@testable import JamfReports

/// Regression: a real-world config.yaml written by `workspace-init` and edited
/// in the GUI uses YAML's compact block-sequence syntax where list items share
/// the parent key's indent. PyYAML / ruamel accept this, and so should we —
/// the prior parser silently produced an empty mapping for `security_agents:`,
/// which surfaced as "Config decode failed" + a fallback to default config.
final class YAMLCompactSequenceTests: XCTestCase {
    func testCompactBlockSequenceUnderMappingKey() throws {
        let yaml = """
        security_agents:
        - name: CrowdStrike Falcon
          column: CrowdStrike Falcon - Status
          connected_value: Installed
        - name: SentinelOne
          column: SentinelOne - Agent Status
          connected_value: running
        """
        let cfg = try ConfigLoader.loadFromString(yaml)
        XCTAssertEqual(cfg.securityAgents?.count, 2)
        XCTAssertEqual(cfg.securityAgents?.first?.name, "CrowdStrike Falcon")
        XCTAssertEqual(cfg.securityAgents?.last?.connectedValue, "running")
    }

    func testIndentedBlockSequenceStillWorks() throws {
        let yaml = """
        security_agents:
          - name: CrowdStrike Falcon
            column: CrowdStrike Falcon - Status
            connected_value: Installed
        """
        let cfg = try ConfigLoader.loadFromString(yaml)
        XCTAssertEqual(cfg.securityAgents?.count, 1)
        XCTAssertEqual(cfg.securityAgents?.first?.name, "CrowdStrike Falcon")
    }

    /// An empty `key:\n` with no following list items should not throw or
    /// turn into a malformed mapping that breaks downstream keys.
    func testEmptyCompactList() throws {
        let yaml = """
        security_agents:
        custom_eas:
        - name: FileVault Status
          column: FileVault 2 - Status
          type: boolean
          true_value: Encrypted
        """
        let cfg = try ConfigLoader.loadFromString(yaml)
        XCTAssertTrue(cfg.securityAgents == nil || cfg.securityAgents?.isEmpty == true)
        XCTAssertEqual(cfg.customEas?.count, 1)
    }

    /// Comments interleaved between compact list items must not break parsing.
    func testCompactListWithComments() throws {
        let yaml = """
        security_agents:
        # primary EDR
        - name: CrowdStrike Falcon
          column: CrowdStrike Falcon - Status
          connected_value: Installed
        # secondary EDR
        - name: SentinelOne
          column: SentinelOne - Agent Status
          connected_value: running
        """
        let cfg = try ConfigLoader.loadFromString(yaml)
        XCTAssertEqual(cfg.securityAgents?.count, 2)
    }

    /// A compact list followed by another mapping key at the parent indent
    /// must terminate the list at the right place.
    func testCompactListThenSiblingKey() throws {
        let yaml = """
        security_agents:
        - name: CrowdStrike Falcon
          column: CrowdStrike Falcon - Status
          connected_value: Installed
        custom_eas:
        - name: FileVault Status
          column: FileVault 2 - Status
          type: boolean
          true_value: Encrypted
        """
        let cfg = try ConfigLoader.loadFromString(yaml)
        XCTAssertEqual(cfg.securityAgents?.count, 1)
        XCTAssertEqual(cfg.customEas?.count, 1)
        XCTAssertEqual(cfg.customEas?.first?.name, "FileVault Status")
    }
}

// MARK: - Corrupt-config recovery (key: [] + orphaned items)

/// Regression: GUI builds prior to the compact-sequence fix (5d69c28) parsed
/// zero-indent sequences as empty, then ConfigService.save rewrote the key
/// line as `key: []` while preserving the now-orphaned `- name:` lines below
/// it. The result is invalid YAML that strict parsers reject. The codec must
/// (a) repair the pattern on parse instead of silently discarding everything
/// after it, and (b) heal the file on the next save.
final class YAMLCorruptConfigRecoveryTests: XCTestCase {

    /// The exact corruption pattern observed in a production config.
    /// Values here are synthetic — never copy real tenant data into fixtures.
    private let corruptYAML = """
    columns:
      computer_name: Computer Name
    security_agents: []
    - name: Example EDR
      column: Example EDR - Status
      connected_value: Installed
    - name: Example AV
      column: Example AV - Agent Status
      connected_value: running
    compliance:
      enabled: false
      baseline_label: Example Compliance
    custom_eas: []
    - name: Example Boolean EA
      column: Example EA - Status
      type: boolean
      true_value: Encrypted
    thresholds:
      stale_device_days: 45
    """

    func testCorruptEmptyListWithOrphansRepairsToSequence() throws {
        let cfg = try ConfigLoader.loadFromString(corruptYAML)
        XCTAssertEqual(cfg.securityAgents?.count, 2)
        XCTAssertEqual(cfg.securityAgents?.first?.name, "Example EDR")
        XCTAssertEqual(cfg.securityAgents?.last?.connectedValue, "running")
        XCTAssertEqual(cfg.customEas?.count, 1)
        XCTAssertEqual(cfg.customEas?.first?.name, "Example Boolean EA")
    }

    /// The data-loss half of the bug: keys after the orphaned items must
    /// still parse. Before the fix, parseMapping broke at the first orphan
    /// and every subsequent top-level key vanished from the document.
    func testCorruptPatternDoesNotLoseSubsequentKeys() throws {
        let cfg = try ConfigLoader.loadFromString(corruptYAML)
        XCTAssertEqual(cfg.compliance?.baselineLabel, "Example Compliance")
        XCTAssertEqual(cfg.thresholds?.staleDeviceDays, 45)
    }

    func testRepairedKeysSurfacedOnDocument() throws {
        let document = try YAMLCodec.decode(corruptYAML)
        XCTAssertEqual(document.repairedKeys, ["security_agents", "custom_eas"])
    }

    func testValidDocumentHasNoRepairedKeys() throws {
        let valid = """
        security_agents:
        - name: Example EDR
          column: Example EDR - Status
          connected_value: Installed
        """
        let document = try YAMLCodec.decode(valid)
        XCTAssertTrue(document.repairedKeys.isEmpty)
    }

    /// Re-encoding a repaired document must heal the file: the orphaned items
    /// become a properly indented sequence under their key, appear exactly
    /// once, and the result re-parses cleanly with no repairs needed.
    func testEncodeAfterRepairHealsFile() throws {
        let document = try YAMLCodec.decode(corruptYAML)
        let healed = try YAMLCodec.encode(
            document,
            replacingTopLevelKeys: ["security_agents", "custom_eas"]
        )

        XCTAssertFalse(healed.contains("security_agents: []"),
                       "healed file must not retain the empty-list scalar")
        XCTAssertFalse(healed.contains("custom_eas: []"))
        XCTAssertEqual(
            healed.components(separatedBy: "name: Example EDR").count - 1, 1,
            "orphaned items must not be duplicated by encode"
        )

        let reparsed = try YAMLCodec.decode(healed)
        XCTAssertTrue(reparsed.repairedKeys.isEmpty, "healed file must parse without repairs")
        let cfg = try ConfigLoader.loadFromString(healed)
        XCTAssertEqual(cfg.securityAgents?.count, 2)
        XCTAssertEqual(cfg.customEas?.count, 1)
        XCTAssertEqual(cfg.thresholds?.staleDeviceDays, 45)
    }

    /// Orphaned items after a key holding a real scalar value cannot be
    /// attached anywhere — they are dropped, but parsing must continue so
    /// later keys survive.
    func testOrphansAfterScalarValueAreDroppedNotFatal() throws {
        let yaml = """
        some_key: real value
        - name: orphan
          column: Orphan - Status
        thresholds:
          stale_device_days: 60
        """
        let document = try YAMLCodec.decode(yaml)
        XCTAssertTrue(document.repairedKeys.isEmpty)
        let cfg = try ConfigLoader.loadFromString(yaml)
        XCTAssertEqual(cfg.thresholds?.staleDeviceDays, 60)
    }
}
