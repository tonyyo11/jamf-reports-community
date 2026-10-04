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
        // Neither jamf_cli.enabled nor allow_live_overview is read any more; a save still
        // keeps what the file holds.
        XCTAssertTrue(savedText.contains("allow_live_overview: false"))
        let jamfCLI = try XCTUnwrap(
            YAMLCodec.decode(savedText).root.mapping?.value(for: "jamf_cli")?.mapping)
        XCTAssertEqual(jamfCLI.value(for: "enabled"), .scalar(.bool(true)))
    }

    /// The editor models a few keys per entry; any other key typed on an entry rides along with
    /// it. A deleted entry takes its keys with it, and a new one has none.
    func testEntryKeysTheEditorDoesNotModelSurviveASave() throws {
        let root = try temporaryWorkspaceRoot()
        let profile = "entry-extras-\(UUID().uuidString.lowercased())"
        try writeConfig(
            """
            security_agents:
              - name: Agent One
                column: Agent One - Status
                connected_value: Running
                owner_team: desk-one
              - name: Agent Two
                column: Agent Two - Status
                owner_team: desk-two
                connected_value: Running
            custom_eas:
              - name: Battery
                column: Battery Cycle Count
                type: text
                sheet_note: from the battery EA
                tags:
                  - power
            """,
            profile: profile, root: root)

        let loaded = try ConfigService.load(profile: profile, workspaceRoot: root)
        var state = loaded.state
        state.securityAgents.removeFirst()
        state.securityAgents[0].connectedValue = "Connected"
        state.securityAgents.append(
            ConfigSecurityAgent(name: "Agent Three", column: "Three", connectedValue: "Up"))
        state.customEAs[0].name = "Battery Cycles"
        _ = try ConfigService.save(
            profile: profile, state: state, existingDocument: loaded.document, workspaceRoot: root)

        let text = try savedText(profile: profile, root: root)
        XCTAssertFalse(text.contains("desk-one"), "a deleted entry's keys go with it")
        let agents = try XCTUnwrap(YAMLCodec.decode(text).root.mapping?
            .value(for: "security_agents")?.sequence?.compactMap(\.mapping))
        XCTAssertEqual(agents.map { $0.entries.map(\.key) }, [
            ["name", "column", "owner_team", "connected_value"],
            ["name", "column", "connected_value"],
        ])
        XCTAssertEqual(agents[0].value(for: "owner_team"), .scalar(.string("desk-two")))
        XCTAssertEqual(agents[0].value(for: "connected_value"), .scalar(.string("Connected")))
        let ea = try XCTUnwrap(YAMLCodec.decode(text).root.mapping?
            .value(for: "custom_eas")?.sequence?.first?.mapping)
        XCTAssertEqual(ea.value(for: "name"), .scalar(.string("Battery Cycles")))
        XCTAssertEqual(ea.value(for: "sheet_note"), .scalar(.string("from the battery EA")))
        XCTAssertEqual(ea.value(for: "tags"), .sequence([.scalar(.string("power"))]))
        XCTAssertEqual(try ConfigService.load(profile: profile, workspaceRoot: root).state,
                       state, "a reload reads back what was saved")
    }

    /// The editor's values are set on each entry's own keys, so an untouched entry comes back
    /// as typed: key order, and an earlier copy of a repeated key, included.
    func testAnUntouchedEntryIsWrittenBackAsTyped() throws {
        let root = try temporaryWorkspaceRoot()
        let profile = "entry-order-\(UUID().uuidString.lowercased())"
        let agents = """
            security_agents:
              - column: Agent One - Status
                owner_team: desk
                name: Agent One
                connected_value: Running
              - name: Agent Two
                column: Old Column
                column: Agent Two - Status
                connected_value: Running

            """
        let eas = """
            custom_eas:
              - type: percentage
                name: Disk Free
                note: typed
                critical_threshold: 90
                column: Disk Free Percent
                warning_threshold: 80

            """
        try writeConfig(agents + eas, profile: profile, root: root)

        let loaded = try ConfigService.load(profile: profile, workspaceRoot: root)
        XCTAssertEqual(loaded.state.securityAgents[1].column, "Agent Two - Status")
        _ = try ConfigService.save(
            profile: profile, state: loaded.state, existingDocument: loaded.document,
            workspaceRoot: root)

        let text = try savedText(profile: profile, root: root)
        XCTAssertTrue(text.contains(agents), text)
        XCTAssertTrue(text.contains(eas.dropLast()), text)
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

    // MARK: - Extra column keys (listed on the Config screen after the original 18)

    private static let extraColumnMappings: [(key: String, header: String)] = [
        ("full_name", "Full Name"), ("asset_tag", "Asset Tag"), ("building", "Building"),
        ("position", "Job Title"), ("last_logged_in_user", "Last Logged In"),
        ("recovery_lock", "Recovery Lock"), ("battery_health", "Battery Health"),
        ("entra_sso_status", "Entra SSO"), ("purchase_date", "Purchase Date"),
    ]

    private func extraColumnsConfig(only keys: Set<String>? = nil) -> String {
        let lines = Self.extraColumnMappings
            .filter { keys?.contains($0.key) ?? true }
            .map { "  \($0.key): \"\($0.header)\"" }
        return (["columns:", "  computer_name: Computer Name"] + lines).joined(separator: "\n")
    }

    private func savedText(profile: String, root: URL) throws -> String {
        try String(
            contentsOf: ConfigService.configURL(for: profile, workspaceRoot: root),
            encoding: .utf8
        )
    }

    func testExtraColumnKeysAreListedAfterTheOriginalEighteen() {
        let extras = Self.extraColumnMappings.map(\.key)
        XCTAssertEqual(ConfigState.columnKeys.count, 18 + extras.count)
        XCTAssertEqual(Array(ConfigState.columnKeys.suffix(extras.count)), extras)
        // Every column the engine decodes has a row: writing each listed key reaches every field.
        let keyLines = ConfigState.columnKeys.map { "  \($0): X" }
        let yaml = (["columns:"] + keyLines).joined(separator: "\n")
        let columns = try? XCTUnwrap(ConfigLoader.loadFromString(yaml).columns)
        XCTAssertEqual(ConfigState.columnKeys.count, ColumnField.allCases.count)
        for field in ColumnField.allCases {
            XCTAssertNotNil(columns?.columnName(for: field), "\(field) has no key in columnKeys")
        }
    }

    func testExtraColumnMappingsLoadAndSurviveSaveUnchanged() throws {
        let root = try temporaryWorkspaceRoot()
        let profile = "extra-cols-\(UUID().uuidString.lowercased())"
        try writeConfig(extraColumnsConfig(), profile: profile, root: root)

        let loaded = try ConfigService.load(profile: profile, workspaceRoot: root)
        for (key, header) in Self.extraColumnMappings {
            XCTAssertEqual(loaded.state.columns[key], header, "\(key) must load into the state")
        }

        var state = loaded.state
        state.columns["computer_name"] = "Device Name"
        _ = try ConfigService.save(
            profile: profile, state: state, existingDocument: loaded.document, workspaceRoot: root)

        let url = try ConfigService.configURL(for: profile, workspaceRoot: root)
        let columns = try XCTUnwrap(ConfigLoader.load(from: url).columns)
        XCTAssertEqual(columns.computerName, "Device Name")
        XCTAssertEqual(columns.fullName, "Full Name")
        XCTAssertEqual(columns.assetTag, "Asset Tag")
        XCTAssertEqual(columns.building, "Building")
        XCTAssertEqual(columns.position, "Job Title")
        XCTAssertEqual(columns.lastLoggedInUser, "Last Logged In")
        XCTAssertEqual(columns.recoveryLock, "Recovery Lock")
        XCTAssertEqual(columns.batteryHealth, "Battery Health")
        XCTAssertEqual(columns.entraSSOStatus, "Entra SSO")
        XCTAssertEqual(columns.purchaseDate, "Purchase Date")
    }

    func testClearingAnExtraColumnRemovesItsKeyFromTheFile() throws {
        let root = try temporaryWorkspaceRoot()
        let profile = "clear-extra-\(UUID().uuidString.lowercased())"
        try writeConfig(
            extraColumnsConfig(only: ["building", "position", "asset_tag"]),
            profile: profile, root: root)

        let loaded = try ConfigService.load(profile: profile, workspaceRoot: root)
        var state = loaded.state
        state.columns["building"] = ""
        state.columns["asset_tag"] = "   "
        _ = try ConfigService.save(
            profile: profile, state: state, existingDocument: loaded.document, workspaceRoot: root)

        let text = try savedText(profile: profile, root: root)
        XCTAssertFalse(text.contains("building:"), "a cleared mapping leaves the file")
        XCTAssertFalse(text.contains("asset_tag:"), "a blank mapping leaves the file")
        XCTAssertTrue(text.contains("position: Job Title"))
    }

    func testExtraColumnsNeverTypedStayOutOfTheFile() throws {
        let root = try temporaryWorkspaceRoot()
        let profile = "untyped-extra-\(UUID().uuidString.lowercased())"
        // full_name is a `key: ""` placeholder, as an older scaffold or the example wrote it.
        try writeConfig(
            "columns:\n  computer_name: Computer Name\n  full_name: \"\"\n",
            profile: profile, root: root)

        let loaded = try ConfigService.load(profile: profile, workspaceRoot: root)
        var state = loaded.state
        state.columns["manager"] = ""
        _ = try ConfigService.save(
            profile: profile, state: state, existingDocument: loaded.document, workspaceRoot: root)

        let text = try savedText(profile: profile, root: root)
        for (key, _) in Self.extraColumnMappings {
            XCTAssertFalse(text.contains("\(key):"), "\(key) was never typed and must stay absent")
        }
        // The original 18 keep their `key: ""` form.
        XCTAssertTrue(text.contains("manager: \"\""))
        XCTAssertTrue(text.contains("department: \"\""))
    }

    func testTypingAnExtraColumnWritesIt() throws {
        let root = try temporaryWorkspaceRoot()
        let profile = "type-extra-\(UUID().uuidString.lowercased())"
        try writeConfig("columns:\n  computer_name: Computer Name\n", profile: profile, root: root)

        let loaded = try ConfigService.load(profile: profile, workspaceRoot: root)
        var state = loaded.state
        state.columns["purchase_date"] = "Purchase Date"
        _ = try ConfigService.save(
            profile: profile, state: state, existingDocument: loaded.document, workspaceRoot: root)

        let url = try ConfigService.configURL(for: profile, workspaceRoot: root)
        XCTAssertEqual(try ConfigLoader.load(from: url).columns?.purchaseDate, "Purchase Date")
        XCTAssertFalse(try savedText(profile: profile, root: root).contains("building:"))
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
        ).document
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
            profileErrorWarning: "5",
            complianceEnabled: true,
            baselineLabel: "CIS Level 1",
            failuresCountColumn: "Compliance Failures",
            failuresListColumn: "Compliance Failure List",
            complianceBenchmarks: ["CIS", "NIST"],
            outputDir: "Executive Reports",
            archiveDir: "Report Archive",
            timestampOutputs: false,
            archiveEnabled: false,
            keepLatestRuns: "42",
            jamfCLIUseCachedData: false,
            jamfCLIRequireManifest: true,
            orgName: "Example Org",
            logoPath: "/tmp/example-logo.png",
            accentColor: "#112233"
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
