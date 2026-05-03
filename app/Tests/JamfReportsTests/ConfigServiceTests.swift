import Foundation
import XCTest
@testable import JamfReports

final class ConfigServiceTests: XCTestCase {
    func testNewConfigFieldsPersistOnSaveReload() throws {
        let root = try temporaryWorkspaceRoot()
        let profile = "config-test-\(UUID().uuidString.lowercased())"
        try writeConfig(
            """
            columns:
              computer_name: Computer Name
              serial_number: Serial Number
            security_agents:
              - name: Falcon
                column: Falcon Status
                connected_value: Installed
            custom_eas:
              - name: FileVault
                column: FileVault 2 - Status
                type: boolean
                true_value: Encrypted
            thresholds:
              stale_device_days: 45
              checkin_overdue_days: 8
            output:
              output_dir: Generated Reports
              timestamp_outputs: false
              keep_latest_runs: 7
            jamf_cli:
              enabled: true
              data_dir: existing-data
              profile: tenant-a
              use_cached_data: true
              allow_live_overview: false
            """,
            profile: profile,
            root: root
        )

        let loaded = try ConfigService.load(profile: profile, workspaceRoot: root)
        XCTAssertEqual(loaded.state.staleDeviceDays, "45")
        XCTAssertEqual(loaded.state.keepLatestRuns, "7")
        XCTAssertTrue(loaded.state.jamfCLIUseCachedData)

        var state = loaded.state
        state.staleDeviceDays = "61"
        state.keepLatestRuns = "3"
        state.jamfCLIUseCachedData = false
        state.outputDir = "Updated Reports"
        state.columns["computer_name"] = "Updated Computer Name"

        _ = try ConfigService.save(
            profile: profile,
            state: state,
            existingDocument: loaded.document,
            workspaceRoot: root
        )

        let reloaded = try ConfigService.load(profile: profile, workspaceRoot: root)
        XCTAssertEqual(reloaded.state.staleDeviceDays, "61")
        XCTAssertEqual(reloaded.state.keepLatestRuns, "3")
        XCTAssertFalse(reloaded.state.jamfCLIUseCachedData)
        XCTAssertEqual(reloaded.state.outputDir, "Updated Reports")
        XCTAssertEqual(reloaded.state.columns["computer_name"], "Updated Computer Name")
        XCTAssertFalse(reloaded.state.timestampOutputs)
        XCTAssertEqual(reloaded.state.securityAgents.first?.name, "Falcon")
        XCTAssertEqual(reloaded.state.customEAs.first?.trueValue, "Encrypted")

        let savedText = try String(
            contentsOf: ConfigService.configURL(for: profile, workspaceRoot: root),
            encoding: .utf8
        )
        XCTAssertTrue(savedText.contains("stale_device_days: 61"))
        XCTAssertTrue(savedText.contains("keep_latest_runs: 3"))
        XCTAssertTrue(savedText.contains("use_cached_data: false"))
        XCTAssertTrue(savedText.contains("data_dir: existing-data"))
        XCTAssertTrue(savedText.contains("profile: tenant-a"))
        XCTAssertTrue(savedText.contains("allow_live_overview: false"))
    }

    func testNewConfigFieldsUseDefaultsWhenMissing() throws {
        let root = try temporaryWorkspaceRoot()
        let profile = "config-test-\(UUID().uuidString.lowercased())"
        try writeConfig(
            """
            columns: {}
            thresholds: {}
            output:
              output_dir: Generated Reports
            jamf_cli:
              data_dir: jamf-cli-data
            """,
            profile: profile,
            root: root
        )

        let loaded = try ConfigService.load(profile: profile, workspaceRoot: root)
        XCTAssertEqual(loaded.state.staleDeviceDays, ConfigState.defaultState.staleDeviceDays)
        XCTAssertEqual(loaded.state.keepLatestRuns, ConfigState.defaultState.keepLatestRuns)
        XCTAssertEqual(
            loaded.state.jamfCLIUseCachedData,
            ConfigState.defaultState.jamfCLIUseCachedData
        )
    }

    func testSaveRoundTripPreservesAllExposedConfigKeys() throws {
        let root = try temporaryWorkspaceRoot()
        let profile = "roundtrip-test"
        let state = fullState()

        let savedDocument = try ConfigService.save(
            profile: profile,
            state: state,
            existingDocument: nil,
            workspaceRoot: root
        )
        let loaded = try ConfigService.load(profile: profile, workspaceRoot: root)

        XCTAssertEqual(savedDocument, loaded.document)
        XCTAssertEqual(loaded.state, state)
    }

    private func fullState() -> ConfigState {
        var columns: [String: String] = [:]
        for key in ConfigState.columnKeys {
            columns[key] = "Mapped \(key)"
        }

        return ConfigState(
            columns: columns,
            securityAgents: [
                ConfigSecurityAgent(
                    name: "Endpoint Agent",
                    column: "Endpoint Agent Status",
                    connectedValue: "Connected"
                ),
            ],
            customEAs: [
                ConfigCustomEA(
                    name: "Encryption",
                    column: "Encryption Status",
                    type: "boolean",
                    trueValue: "Encrypted",
                    warningThreshold: "",
                    criticalThreshold: "",
                    currentVersions: [],
                    warningDays: ""
                ),
                ConfigCustomEA(
                    name: "Disk Free",
                    column: "Disk Free Percent",
                    type: "percentage",
                    trueValue: "",
                    warningThreshold: "80",
                    criticalThreshold: "90",
                    currentVersions: [],
                    warningDays: ""
                ),
                ConfigCustomEA(
                    name: "Agent Version",
                    column: "Agent Version",
                    type: "version",
                    trueValue: "",
                    warningThreshold: "",
                    criticalThreshold: "",
                    currentVersions: ["5.0", "5.1"],
                    warningDays: ""
                ),
                ConfigCustomEA(
                    name: "Owner",
                    column: "Owner",
                    type: "text",
                    trueValue: "",
                    warningThreshold: "",
                    criticalThreshold: "",
                    currentVersions: [],
                    warningDays: ""
                ),
                ConfigCustomEA(
                    name: "Certificate Expiry",
                    column: "Certificate Expiry",
                    type: "date",
                    trueValue: "",
                    warningThreshold: "",
                    criticalThreshold: "",
                    currentVersions: [],
                    warningDays: "30"
                ),
            ],
            staleDeviceDays: "60",
            checkinOverdueDays: "14",
            warningDiskPercent: "75",
            criticalDiskPercent: "92",
            certWarningDays: "120",
            profileErrorCritical: "25",
            profileErrorWarning: "5",
            complianceEnabled: true,
            baselineLabel: "CIS Level 1",
            failuresCountColumn: "Compliance Failures",
            failuresListColumn: "Compliance Failure List",
            platformEnabled: true,
            complianceBenchmarks: ["CIS", "NIST"],
            outputDir: "Executive Reports",
            archiveDir: "Report Archive",
            timestampOutputs: false,
            archiveEnabled: false,
            keepLatestRuns: "42",
            exportPptx: true,
            jamfCLIUseCachedData: false,
            orgName: "Example Org",
            logoPath: "/tmp/example-logo.png",
            accentColor: "#112233",
            accentDark: "#445566"
        )
    }

    private func temporaryWorkspaceRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("JamfReportsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }

    private func writeConfig(_ text: String, profile: String, root: URL) throws {
        let url = try ConfigService.configURL(for: profile, workspaceRoot: root)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
