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
        // Real `pro report profile-status` envelope (same shape the Python
        // engine's _write_profile_status parses).
        let profileJSON = """
        [
          {
            "summary": {
              "total_errors": 20,
              "unique_profiles": 3,
              "unique_devices": 14,
              "days": 30,
              "devices_high_failure": 1,
              "devices_high_pending": 0
            },
            "failures": [
              {"device_type": "Computer", "name": "Security Baseline", "id": "103",
               "errors": 12, "devices": 9, "last_error": "2026-06-10",
               "top_error": "Payload rejected"},
              {"device_type": "Computer", "name": "Dock Settings", "id": 104,
               "errors": 5, "devices": 4, "last_error": "2026-06-09",
               "top_error": "Install timeout"},
              {"device_type": "Mobile Device", "name": "Email Configuration", "id": null,
               "errors": 3, "devices": 3, "last_error": "2026-06-08",
               "top_error": "Account exists"}
            ],
            "device_failures": [],
            "device_pending": []
          }
        ]
        """

        let tmp = FileManager.default.temporaryDirectory
        let profileURL = tmp.appendingPathComponent("profile-\(UUID().uuidString).json")

        try Data(profileJSON.utf8).write(to: profileURL)
        defer { try? FileManager.default.removeItem(at: profileURL) }

        let snapshot = try XCTUnwrap(PolicyHealthService.load(policyURL: nil, profileURL: profileURL))

        // Summary-driven KPIs
        XCTAssertTrue(snapshot.hasProfileData)
        XCTAssertEqual(snapshot.profileTotalErrors, 20)
        XCTAssertEqual(snapshot.profilesWithFailures, 3)
        XCTAssertEqual(snapshot.profileDevicesAffected, 14)
        XCTAssertEqual(snapshot.profileLookbackDays, 30)

        // Failure rows — typed and ordered
        XCTAssertEqual(snapshot.profiles.count, 3)
        let first = snapshot.profiles[0]
        XCTAssertEqual(first.name, "Security Baseline")
        XCTAssertEqual(first.deviceType, "Computer")
        XCTAssertEqual(first.errors, 12)
        XCTAssertEqual(first.devices, 9)
        XCTAssertEqual(first.topError, "Payload rejected")
        XCTAssertEqual(snapshot.profiles[2].name, "Email Configuration",
                       "null id keeps the row — name is identity enough")

        // File metadata
        XCTAssertEqual(snapshot.sourceFile, profileURL)
        XCTAssertNotNil(snapshot.snapshotDate)
    }

    // MARK: - #185 crash regression

    /// The 2.2.1 decoder turned the real envelope into one all-nil row whose
    /// computed id changed on every access — an AttributeGraph abort in
    /// SwiftUI Table. The envelope (even a zero-failure one) must decode to
    /// zero phantom rows, and every produced id must be stable and unique.
    func testRealEnvelopeProducesNoPhantomRows() throws {
        let emptyEnvelope = """
        [{"device_failures": [], "device_pending": [], "failures": [],
          "summary": {"days": 30, "total_errors": 0, "unique_devices": 0,
                      "unique_profiles": 0}}]
        """
        let tmp = FileManager.default.temporaryDirectory
        let url = tmp.appendingPathComponent("profile-empty-\(UUID().uuidString).json")
        try Data(emptyEnvelope.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let snapshot = try XCTUnwrap(PolicyHealthService.load(policyURL: nil, profileURL: url))
        XCTAssertTrue(snapshot.profiles.isEmpty,
                      "an empty envelope must not decode into phantom all-nil rows")
        XCTAssertTrue(snapshot.hasProfileData, "summary present → healthy state, not empty state")
        XCTAssertEqual(snapshot.profileTotalErrors, 0)
    }

    func testFailureRowIDsAreStableAndUnique() {
        func row(name: String?, id: AnyCodable?) -> ProfileFailureRow {
            ProfileFailureRow(deviceType: nil, name: name, profileId: id,
                              errors: nil, devices: nil, lastError: nil, topError: nil)
        }
        let rows = [
            row(name: "WiFi", id: nil),
            row(name: "WiFi", id: nil),          // duplicate name, no id
            row(name: nil, id: AnyCodable(7)),
            row(name: nil, id: nil)              // all-nil — must be dropped
        ]
        let mapped = PolicyHealthService.failureRows(from: rows)
        XCTAssertEqual(mapped.count, 3, "all-nil row dropped")
        XCTAssertEqual(Set(mapped.map(\.id)).count, 3, "ids unique despite duplicate names")
        XCTAssertEqual(mapped[0].id, mapped[0].id, "id is stored, not recomputed")
        XCTAssertEqual(mapped[2].name, "Profile 7", "id-only rows get a synthesized name")
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
            "summary": {"total_errors": 2, "unique_profiles": 1,
                        "unique_devices": 2, "days": 30},
            "failures": [
              {"device_type": "Computer", "name": "Test Profile", "id": "201",
               "errors": 2, "devices": 2, "last_error": "2026-06-10",
               "top_error": "Install failed"}
            ],
            "device_failures": [],
            "device_pending": []
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
        XCTAssertEqual(snapshot.profileTotalErrors, 2)

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
        XCTAssertFalse(snapshot.hasProfileData,
                       "a bare [] profile file is no data, not zero failures")
        XCTAssertEqual(snapshot.profileTotalErrors, 0)
        XCTAssertEqual(snapshot.profileDevicesAffected, 0)
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

    // MARK: - CacheSource derivation

    func testCacheSourceWithNilSnapshotDate() {
        let snapshot = PolicyHealthService.Snapshot(
            summary: nil,
            findings: [],
            profiles: [],
            profileSummary: nil,
            sourceFile: nil,
            snapshotDate: nil
        )
        XCTAssertEqual(snapshot.cacheSource, .neverFetchedLive)
    }

    func testCacheSourceWithFreshSnapshotDate() {
        let recent = Date(timeIntervalSinceNow: -1800) // 30 minutes ago
        let snapshot = PolicyHealthService.Snapshot(
            summary: nil,
            findings: [],
            profiles: [],
            profileSummary: nil,
            sourceFile: nil,
            snapshotDate: recent
        )
        XCTAssertEqual(snapshot.cacheSource, .fresh)
    }

    func testCacheSourceWithStaleSnapshotDate() {
        let stale = Date(timeIntervalSinceNow: -48 * 3600) // 48 hours ago
        let snapshot = PolicyHealthService.Snapshot(
            summary: nil,
            findings: [],
            profiles: [],
            profileSummary: nil,
            sourceFile: nil,
            snapshotDate: stale
        )
        XCTAssertEqual(snapshot.cacheSource, .stale(at: stale))
    }
}