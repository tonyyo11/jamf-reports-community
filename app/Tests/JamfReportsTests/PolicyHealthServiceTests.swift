import XCTest
import SwiftUI
@testable import JamfReports

/// Tests for the PolicyHealthService and PolicyProfileView. Confirms the service can
/// decode jamf-cli policy-status and profile-status JSON shapes and compute aggregate
/// metrics, and that the view instantiates without crashing in both demo and live modes.
@MainActor
final class PolicyHealthServiceTests: XCTestCase {

    func testPolicyProfileViewInstantiatesInDemoMode() throws {
        let workspace = WorkspaceStore()
        workspace.profile = "test"
        workspace.demoMode = true

        _ = PolicyProfileView().environment(workspace)
    }

    func testPolicyProfileViewInstantiatesOutsideDemoMode() throws {
        let workspace = WorkspaceStore()
        workspace.profile = "test"
        workspace.demoMode = false

        _ = PolicyProfileView().environment(workspace)
    }

    // MARK: - Service decode parity

    func testPolicyStatusServiceDecodeParity() throws {
        let policyJSON = """
        [
          {
            "summary": {
              "total_policies": 25,
              "enabled": 20,
              "disabled": 5,
              "config_findings": 8,
              "warnings": 6,
              "info": 2
            },
            "config_findings": [
              {
                "severity": "critical",
                "policy": "Software Update Policy",
                "policy_id": "123",
                "check": "Maintenance Window",
                "detail": "No maintenance window configured"
              },
              {
                "severity": "warning",
                "policy": "FileVault Policy",
                "policy_id": "124",
                "check": "Scope Check",
                "detail": "Policy scope excludes mobile devices"
              },
              {
                "severity": "info",
                "policy": "Chrome Config",
                "policy_id": "125",
                "check": "Optimization",
                "detail": "Redundant payload keys detected"
              }
            ]
          }
        ]
        """

        let tmp = FileManager.default.temporaryDirectory
        let policyURL = tmp.appendingPathComponent("policy-\(UUID().uuidString).json")

        try Data(policyJSON.utf8).write(to: policyURL)
        defer { try? FileManager.default.removeItem(at: policyURL) }

        let snapshot = try XCTUnwrap(PolicyHealthService.load(policyURL: policyURL, profileURL: nil))

        // Summary verification
        let summary = try XCTUnwrap(snapshot.summary)
        XCTAssertEqual(summary.totalPolicies, 25)
        XCTAssertEqual(summary.enabled, 20)
        XCTAssertEqual(summary.disabled, 5)
        XCTAssertEqual(summary.configFindings, 8)
        XCTAssertEqual(summary.warnings, 6)
        XCTAssertEqual(summary.info, 2)

        // Findings verification
        XCTAssertEqual(snapshot.findings.count, 3)
        let severityGrouping = snapshot.findingsBySeverity
        XCTAssertEqual(severityGrouping["critical"], 1)
        XCTAssertEqual(severityGrouping["warning"], 1)
        XCTAssertEqual(severityGrouping["info"], 1)

        // File metadata
        XCTAssertEqual(snapshot.sourceFile, policyURL)
        XCTAssertNotNil(snapshot.snapshotDate)
    }

    func testProfileStatusServiceDecodeParity() throws {
        let profileJSON = """
        [
          {
            "id": 101,
            "name": "Wi-Fi Corporate",
            "category": "Network",
            "site": "Default",
            "management_status": "Installed",
            "error_count": 0
          },
          {
            "id": 102,
            "name": "Email Configuration",
            "category": "Email",
            "site": "Default",
            "management_status": "Pending",
            "error_count": 3
          },
          {
            "id": 103,
            "name": "Security Baseline",
            "category": "Security",
            "site": "Default",
            "management_status": "Failed",
            "error_count": 12
          },
          {
            "id": 104,
            "name": "Dock Settings",
            "category": "Desktop",
            "site": "Remote",
            "management_status": "Removed",
            "error_count": 5
          }
        ]
        """

        let tmp = FileManager.default.temporaryDirectory
        let profileURL = tmp.appendingPathComponent("profile-\(UUID().uuidString).json")

        try Data(profileJSON.utf8).write(to: profileURL)
        defer { try? FileManager.default.removeItem(at: profileURL) }

        let snapshot = try XCTUnwrap(PolicyHealthService.load(policyURL: nil, profileURL: profileURL))

        // Profile counts
        XCTAssertEqual(snapshot.totalProfiles, 4)
        XCTAssertEqual(snapshot.installedProfiles, 1, "Only 'Installed' status")
        XCTAssertEqual(snapshot.pendingProfiles, 1, "Only 'Pending' status")
        XCTAssertEqual(snapshot.failedProfiles, 2, "'Failed' and 'Removed' statuses")

        // Individual profiles
        XCTAssertEqual(snapshot.profiles.count, 4)
        let firstProfile = snapshot.profiles[0]
        XCTAssertEqual(firstProfile.name, "Wi-Fi Corporate")
        XCTAssertEqual(firstProfile.category, "Network")
        XCTAssertEqual(firstProfile.managementStatus, "Installed")

        // File metadata
        XCTAssertEqual(snapshot.sourceFile, profileURL)
        XCTAssertNotNil(snapshot.snapshotDate)
    }

    func testCombinedPolicyAndProfileData() throws {
        let policyJSON = """
        [
          {
            "summary": {
              "total_policies": 10,
              "enabled": 8,
              "disabled": 2,
              "config_findings": 3,
              "warnings": 2,
              "info": 1
            },
            "config_findings": [
              {
                "severity": "Warning",
                "policy": "Test Policy",
                "policy_id": "999",
                "check": "Test Check",
                "detail": "Test detail"
              }
            ]
          }
        ]
        """

        let profileJSON = """
        [
          {
            "id": 201,
            "name": "Test Profile",
            "category": "Test",
            "site": "Default",
            "management_status": "Success",
            "error_count": 0
          }
        ]
        """

        let tmp = FileManager.default.temporaryDirectory
        let policyURL = tmp.appendingPathComponent("combined-policy-\(UUID().uuidString).json")
        let profileURL = tmp.appendingPathComponent("combined-profile-\(UUID().uuidString).json")

        try Data(policyJSON.utf8).write(to: policyURL)
        try Data(profileJSON.utf8).write(to: profileURL)
        defer {
            try? FileManager.default.removeItem(at: policyURL)
            try? FileManager.default.removeItem(at: profileURL)
        }

        let snapshot = try XCTUnwrap(PolicyHealthService.load(policyURL: policyURL, profileURL: profileURL))

        // Both data sources present
        XCTAssertNotNil(snapshot.summary)
        XCTAssertEqual(snapshot.findings.count, 1)
        XCTAssertEqual(snapshot.profiles.count, 1)
        XCTAssertEqual(snapshot.installedProfiles, 1, "'Success' counts as installed")

        // Uses policy file as primary source for timestamp
        XCTAssertEqual(snapshot.sourceFile, policyURL)
    }

    func testEmptyInputHandling() throws {
        // Test that nil URLs return nil snapshot
        let nilSnapshot = PolicyHealthService.load(policyURL: nil, profileURL: nil)
        XCTAssertNil(nilSnapshot, "Should return nil when both URLs are nil")

        // Test that empty arrays produce a valid snapshot
        let emptyPolicyJSON = "[{\"summary\":{\"total_policies\":0,\"enabled\":0,\"disabled\":0,\"config_findings\":0,\"warnings\":0,\"info\":0},\"config_findings\":[]}]"
        let emptyProfileJSON = "[]"

        let tmp = FileManager.default.temporaryDirectory
        let policyURL = tmp.appendingPathComponent("empty-policy-\(UUID().uuidString).json")
        let profileURL = tmp.appendingPathComponent("empty-profile-\(UUID().uuidString).json")

        try Data(emptyPolicyJSON.utf8).write(to: policyURL)
        try Data(emptyProfileJSON.utf8).write(to: profileURL)
        defer {
            try? FileManager.default.removeItem(at: policyURL)
            try? FileManager.default.removeItem(at: profileURL)
        }

        let snapshot = try XCTUnwrap(PolicyHealthService.load(policyURL: policyURL, profileURL: profileURL))

        XCTAssertEqual(snapshot.summary?.totalPolicies, 0)
        XCTAssertEqual(snapshot.findings.count, 0)
        XCTAssertEqual(snapshot.profiles.count, 0)
        XCTAssertEqual(snapshot.totalProfiles, 0)
        XCTAssertEqual(snapshot.installedProfiles, 0)
        XCTAssertEqual(snapshot.pendingProfiles, 0)
        XCTAssertEqual(snapshot.failedProfiles, 0)
    }

    func testSeverityGroupingCaseInsensitive() throws {
        let policyJSON = """
        [
          {
            "summary": {
              "total_policies": 5,
              "enabled": 5,
              "disabled": 0,
              "config_findings": 4,
              "warnings": 2,
              "info": 2
            },
            "config_findings": [
              {"severity": "Critical", "policy": "P1", "policy_id": "1", "check": "C1", "detail": "D1"},
              {"severity": "CRITICAL", "policy": "P2", "policy_id": "2", "check": "C2", "detail": "D2"},
              {"severity": "Warning", "policy": "P3", "policy_id": "3", "check": "C3", "detail": "D3"},
              {"severity": "warning", "policy": "P4", "policy_id": "4", "check": "C4", "detail": "D4"}
            ]
          }
        ]
        """

        let tmp = FileManager.default.temporaryDirectory
        let policyURL = tmp.appendingPathComponent("severity-\(UUID().uuidString).json")

        try Data(policyJSON.utf8).write(to: policyURL)
        defer { try? FileManager.default.removeItem(at: policyURL) }

        let snapshot = try XCTUnwrap(PolicyHealthService.load(policyURL: policyURL, profileURL: nil))

        let severityGrouping = snapshot.findingsBySeverity
        XCTAssertEqual(severityGrouping["critical"], 2, "Both 'Critical' and 'CRITICAL' should group together")
        XCTAssertEqual(severityGrouping["warning"], 2, "Both 'Warning' and 'warning' should group together")
    }
}