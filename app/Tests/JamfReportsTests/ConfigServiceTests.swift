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

    func testMobileColumnsPersistAndPreserveSiblings() throws {
        let root = try temporaryWorkspaceRoot()
        let profile = "mobile-cols-\(UUID().uuidString.lowercased())"
        try writeConfig(
            """
            columns:
              computer_name: Computer Name
              serial_number: Serial Number
            mobile_columns:
              device_name: Display Name
            custom_label: keep me
            """,
            profile: profile,
            root: root
        )

        let loaded = try ConfigService.load(profile: profile, workspaceRoot: root)
        XCTAssertEqual(loaded.state.mobileColumns["device_name"], "Display Name")

        var state = loaded.state
        state.mobileColumns["device_name"] = "Mobile Display Name"
        state.mobileColumns["operating_system"] = "OS Version"
        state.columns["computer_name"] = "Updated Computer Name"

        _ = try ConfigService.save(
            profile: profile,
            state: state,
            existingDocument: loaded.document,
            workspaceRoot: root
        )

        let reloaded = try ConfigService.load(profile: profile, workspaceRoot: root)
        XCTAssertEqual(reloaded.state.mobileColumns["device_name"], "Mobile Display Name")
        XCTAssertEqual(reloaded.state.mobileColumns["operating_system"], "OS Version")
        XCTAssertEqual(reloaded.state.columns["computer_name"], "Updated Computer Name")

        // The unmanaged top-level key must survive the round-trip.
        let savedText = try String(
            contentsOf: ConfigService.configURL(for: profile, workspaceRoot: root),
            encoding: .utf8
        )
        XCTAssertTrue(savedText.contains("custom_label: keep me"))
        XCTAssertTrue(savedText.contains("mobile_columns:"))
        XCTAssertTrue(savedText.contains("device_name: Mobile Display Name"))
    }

    func testDefaultStateFileVaultColumnAndEmptyMobileColumns() {
        XCTAssertEqual(ConfigState.defaultState.columns["filevault"], "FileVault 2 Status")
        for key in ConfigState.mobileColumnKeys {
            XCTAssertEqual(
                ConfigState.defaultState.mobileColumns[key], "",
                "mobile column \(key) should default empty (opt-in)"
            )
        }
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

    func testEmptyPercentageThresholdIsOmittedNotEmptyString() throws {
        let root = try temporaryWorkspaceRoot()
        let profile = "empty-threshold-test"
        var state = fullState()
        // The EA-walkthrough adoption case: a percentage EA with no thresholds
        // set. Previously this wrote `warning_threshold: ""`, which the engine
        // decoder (Int?) rejected as "value has the wrong type".
        state.customEAs = [
            ConfigCustomEA(
                name: "Disk Usage", column: "Disk Usage Percent", type: "percentage",
                trueValue: "", warningThreshold: "", criticalThreshold: "",
                currentVersions: [], warningDays: "")
        ]
        _ = try ConfigService.save(
            profile: profile, state: state, existingDocument: nil, workspaceRoot: root)
        let yaml = try String(
            contentsOf: ConfigService.configURL(for: profile, workspaceRoot: root),
            encoding: .utf8)
        XCTAssertFalse(yaml.contains("warning_threshold"),
            "empty threshold must be omitted entirely, not written as an empty string")
        XCTAssertFalse(yaml.contains("critical_threshold"))

        // A populated threshold still serializes as a bare int.
        state.customEAs[0].warningThreshold = "80"
        _ = try ConfigService.save(
            profile: profile, state: state, existingDocument: nil, workspaceRoot: root)
        let yaml2 = try String(
            contentsOf: ConfigService.configURL(for: profile, workspaceRoot: root),
            encoding: .utf8)
        XCTAssertTrue(yaml2.contains("warning_threshold: 80"))
    }

    private func fullState() -> ConfigState {
        var columns: [String: String] = [:]
        for key in ConfigState.columnKeys {
            columns[key] = "Mapped \(key)"
        }
        var mobileColumns: [String: String] = [:]
        for key in ConfigState.mobileColumnKeys {
            mobileColumns[key] = "Mobile \(key)"
        }

        return ConfigState(
            columns: columns,
            mobileColumns: mobileColumns,
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
            jamfCLIRequireManifest: true,
            orgName: "Example Org",
            logoPath: "/tmp/example-logo.png",
            accentColor: "#112233",
            accentDark: "#445566"
        )
    }

    func testSaveRejectsSymlinkedConfigYAML() throws {
        // Verify rejectSymlinkDestination uses lstat (never follows links) by
        // replacing config.yaml with a symlink and asserting save throws.
        let root = try temporaryWorkspaceRoot()
        let profile = "symlink-test-\(UUID().uuidString.lowercased())"
        // Write a real config first so the workspace directory exists.
        try writeConfig("columns: {}\nthresholds: {}\noutput:\n  output_dir: Reports\njamf_cli:\n  data_dir: jamf-cli-data\n",
                        profile: profile, root: root)
        let configURL = try ConfigService.configURL(for: profile, workspaceRoot: root)
        // Replace the real file with a symlink pointing elsewhere.
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("symlink-target-\(UUID().uuidString).yaml")
        try "columns: {}".write(to: target, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: target) }
        try FileManager.default.removeItem(at: configURL)
        try FileManager.default.createSymbolicLink(at: configURL, withDestinationURL: target)

        let loaded = try ConfigService.load(profile: profile, workspaceRoot: root)
        XCTAssertThrowsError(
            try ConfigService.save(
                profile: profile,
                state: loaded.state,
                existingDocument: loaded.document,
                workspaceRoot: root)
        ) { error in
            guard case ConfigService.ConfigError.symlinkDestination = error else {
                XCTFail("expected symlinkDestination, got \(error)")
                return
            }
        }
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
