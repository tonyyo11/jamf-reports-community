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
