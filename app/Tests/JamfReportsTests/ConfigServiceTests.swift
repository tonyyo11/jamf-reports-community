import Foundation
import XCTest
@testable import JamfReports

final class ConfigServiceTests: XCTestCase {
    func testNewConfigFieldsPersistOnSaveReload() throws {
        let root = try temporaryWorkspaceRoot()
        let profile = "config-test-\(UUID().uuidString.lowercased())"
        try writeConfig(
            """
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
              data_dir: existing-data
              profile: tenant-a
              use_cached_data: true
              max_cache_age_hours: 24
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
        XCTAssertTrue(savedText.contains("max_cache_age_hours: 24"))
    }

    /// Earlier builds wrote these keys and nothing reads them now. A save that rewrites the block
    /// holding one removes it, says so, and copies the file as it was first; every other key and
    /// the comments outside the rewritten blocks stay.
    func testASaveRemovesTheRetiredKeysTheAppWroteAndSaysSo() throws {
        let root = try temporaryWorkspaceRoot()
        let profile = "retired-keys-\(UUID().uuidString.lowercased())"
        try writeConfig(
            """
            # kept: a comment outside the blocks a save rewrites
            html:
              track_history: false
            thresholds:
              stale_device_days: 45
              profile_error_critical: 80
              team_note: keep me
            platform:
              enabled: true
              compliance_benchmarks:
                - CIS
            branding:
              org_name: Example Org
              accent_color: "#112233"
              accent_dark: "#445566"
            jamf_cli:
              data_dir: existing-data
              enabled: true
              allow_live_overview: false
              max_cache_age_hours: 24
            """,
            profile: profile, root: root)

        let loaded = try ConfigService.load(profile: profile, workspaceRoot: root)
        var state = loaded.state
        state.staleDeviceDays = "61"
        let saved = try ConfigService.save(
            profile: profile, state: state, existingDocument: loaded.document, workspaceRoot: root)

        XCTAssertEqual(saved.report.removedRetiredKeys, [
            "branding.accent_dark", "jamf_cli.allow_live_overview", "jamf_cli.enabled",
            "platform.enabled", "thresholds.profile_error_critical",
        ])
        let text = try savedText(profile: profile, root: root)
        for gone in ["accent_dark", "allow_live_overview", "profile_error_critical"] {
            XCTAssertFalse(text.contains(gone), gone)
        }
        let blocks = try XCTUnwrap(YAMLCodec.decode(text).root.mapping)
        XCTAssertNil(blocks.value(for: "jamf_cli")?.mapping?.value(for: "enabled"))
        XCTAssertNil(blocks.value(for: "platform")?.mapping?.value(for: "enabled"))
        for kept in ["# kept: a comment outside", "track_history: false", "team_note: keep me",
                     "max_cache_age_hours: 24", "data_dir: existing-data", "- CIS",
                     "org_name: Example Org", "accent_color", "stale_device_days: 61"] {
            XCTAssertTrue(text.contains(kept), kept)
        }

        let copy = try XCTUnwrap(saved.report.backupName, "a removed line is backed up first")
        let backup = try String(
            contentsOf: ConfigService.configURL(for: profile, workspaceRoot: root)
                .deletingLastPathComponent().appendingPathComponent(copy),
            encoding: .utf8)
        XCTAssertTrue(backup.contains("accent_dark: \"#445566\""), "the copy is the file as it was")
        XCTAssertEqual(saved.report.notes, [
            "Settings the app no longer reads were removed from config.yaml: "
                + "branding.accent_dark (since 2.9), jamf_cli.allow_live_overview (since 2.9), "
                + "jamf_cli.enabled (since 2.9), platform.enabled (since 2.9), "
                + "thresholds.profile_error_critical (since 2.9). "
                + "A copy of the file as it was is at \(copy).",
        ])

        // Nothing is left to remove, so the next save says nothing about it.
        let again = try ConfigService.save(
            profile: profile, state: saved.state, existingDocument: saved.document,
            workspaceRoot: root)
        XCTAssertEqual(again.report.removedRetiredKeys, [])
        XCTAssertEqual(again.report.notes, [])
        XCTAssertNil(again.report.backupName)
    }

    /// Only the blocks a writer rewrites lose a retired key, and every copy of a repeated key goes.
    func testRetiredKeysOutsideTheRewrittenBlocksStay() throws {
        var mapping = try XCTUnwrap(YAMLCodec.decode("""
            branding:
              accent_dark: "#445566"
            thresholds:
              profile_error_critical: 80
              profile_error_critical: 90
              stale_device_days: 45
            """).root.mapping)
        let removed = ConfigService.dropRetiredKeys(from: &mapping, inBlocks: ["thresholds"])

        XCTAssertEqual(removed, ["thresholds.profile_error_critical"])
        let thresholds = try XCTUnwrap(mapping.value(for: "thresholds")?.mapping)
        XCTAssertEqual(thresholds.entries.map(\.key), ["stale_device_days"])
        XCTAssertNotNil(mapping.value(for: "branding")?.mapping?.value(for: "accent_dark"))
        XCTAssertEqual(ConfigService.dropRetiredKeys(from: &mapping, inBlocks: []), [])
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

    /// `columns` and `mobile_columns` are retired blocks (2.11): a save removes both whole,
    /// copies the file as it was first, says so, and keeps every other top-level key and
    /// comment. The second save has nothing left to remove.
    func testASaveRemovesTheRetiredColumnBlocksAndKeepsEverythingElse() throws {
        let root = try temporaryWorkspaceRoot()
        let profile = "retired-columns-\(UUID().uuidString.lowercased())"
        try writeConfig(
            """
            # kept: a comment above the blocks
            columns:
              computer_name: Computer Name # dropped with its block
              serial_number: Serial Number
            custom_label: keep me
            mobile_columns:
              device_name: Display Name
            thresholds:
              stale_device_days: 45
            """,
            profile: profile,
            root: root
        )

        let loaded = try ConfigService.load(profile: profile, workspaceRoot: root)
        var state = loaded.state
        state.staleDeviceDays = "61"
        let saved = try ConfigService.save(
            profile: profile, state: state, existingDocument: loaded.document,
            workspaceRoot: root)

        XCTAssertEqual(saved.report.removedRetiredKeys, ["columns", "mobile_columns"])
        let text = try savedText(profile: profile, root: root)
        for gone in ["columns", "computer_name", "device_name", "dropped with its block"] {
            XCTAssertFalse(text.contains(gone), gone)
        }
        for kept in ["# kept: a comment above the blocks", "custom_label: keep me",
                     "stale_device_days: 61"] {
            XCTAssertTrue(text.contains(kept), kept)
        }

        let copy = try XCTUnwrap(saved.report.backupName, "the blocks are backed up first")
        let backup = try String(
            contentsOf: ConfigService.configURL(for: profile, workspaceRoot: root)
                .deletingLastPathComponent().appendingPathComponent(copy),
            encoding: .utf8)
        XCTAssertTrue(backup.contains("computer_name: Computer Name"))
        XCTAssertTrue(backup.contains("device_name: Display Name"))
        XCTAssertEqual(saved.report.notes, [
            "Settings the app no longer reads were removed from config.yaml: "
                + "columns (since 2.11), mobile_columns (since 2.11). "
                + "A copy of the file as it was is at \(copy).",
        ])

        let again = try ConfigService.save(
            profile: profile, state: saved.state, existingDocument: saved.document,
            workspaceRoot: root)
        XCTAssertEqual(again.report.removedRetiredKeys, [])
        XCTAssertNil(again.report.backupName)
        XCTAssertEqual(ConfigService.retiredKeyRemover(inBlock: "columns"), "Config save",
                       "Config Doctor names the save that removes it")
    }

    /// A one-segment retired path is the whole top-level block; it used to be read as a key
    /// named `columns` inside `columns`.
    func testDropRetiredKeysRemovesAWholeTopLevelBlockOnlyWhenListed() throws {
        var mapping = try XCTUnwrap(YAMLCodec.decode("""
            columns:
              columns: nested
              serial_number: Serial Number
            thresholds:
              stale_device_days: 45
            """).root.mapping)
        XCTAssertEqual(ConfigService.dropRetiredKeys(from: &mapping, inBlocks: ["thresholds"]), [])
        XCTAssertNotNil(mapping.value(for: "columns"), "a block not passed in stays")

        let removed = ConfigService.dropRetiredKeys(from: &mapping, inBlocks: ["columns"])
        XCTAssertEqual(removed, ["columns"])
        XCTAssertNil(mapping.value(for: "columns"))
        XCTAssertNotNil(mapping.value(for: "thresholds"))
    }

    private func savedText(profile: String, root: URL) throws -> String {
        try String(
            contentsOf: ConfigService.configURL(for: profile, workspaceRoot: root),
            encoding: .utf8
        )
    }

    func testNewConfigFieldsUseDefaultsWhenMissing() throws {
        let root = try temporaryWorkspaceRoot()
        let profile = "config-test-\(UUID().uuidString.lowercased())"
        try writeConfig(
            """
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
        return ConfigState(
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

    // MARK: - Baseline label

    /// Visual review 2026-10-04: the Overview's compliance card read "mSCP Compliance" until
    /// config.yaml loaded and the configured baseline name after, because the default state
    /// carried a benchmark name the workspace never chose.
    func testDefaultStateNamesNoBenchmark() {
        XCTAssertEqual(ConfigState.defaultState.baselineLabel, "")
    }

    func testSavingAWorkspaceWithoutABaselineLabelWritesNoBaselineLabelKey() throws {
        let root = try temporaryWorkspaceRoot()
        let profile = "no-label-\(UUID().uuidString.lowercased())"
        try writeConfig("columns:\n  computer_name: Computer Name", profile: profile, root: root)

        let loaded = try ConfigService.load(profile: profile, workspaceRoot: root)
        XCTAssertEqual(loaded.state.baselineLabel, "", "the file names none, so none is invented")
        _ = try ConfigService.save(
            profile: profile, state: loaded.state, existingDocument: loaded.document,
            workspaceRoot: root)

        XCTAssertFalse(try savedText(profile: profile, root: root).contains("baseline_label"))
    }

    func testClearingTheBaselineLabelRemovesItsKeyAndSettingOneWritesIt() throws {
        let root = try temporaryWorkspaceRoot()
        let profile = "label-\(UUID().uuidString.lowercased())"
        try writeConfig(
            "compliance:\n  enabled: true\n  baseline_label: Old Name\n",
            profile: profile, root: root)
        var loaded = try ConfigService.load(profile: profile, workspaceRoot: root)
        XCTAssertEqual(loaded.state.baselineLabel, "Old Name")

        var state = loaded.state
        state.baselineLabel = "  "
        _ = try ConfigService.save(
            profile: profile, state: state, existingDocument: loaded.document,
            workspaceRoot: root)
        XCTAssertFalse(try savedText(profile: profile, root: root).contains("baseline_label"))

        loaded = try ConfigService.load(profile: profile, workspaceRoot: root)
        state = loaded.state
        state.baselineLabel = "CIS Level 1"
        _ = try ConfigService.save(
            profile: profile, state: state, existingDocument: loaded.document,
            workspaceRoot: root)
        XCTAssertTrue(
            try savedText(profile: profile, root: root).contains("baseline_label: CIS Level 1"))
    }

    func testDeploymentFailureLevelsLoadAndSave() throws {
        let root = try temporaryWorkspaceRoot()
        let profile = "config-test-\(UUID().uuidString.lowercased())"
        try writeConfig(
            "thresholds:\n  deployment_failure_warning_percent: 5\n",
            profile: profile, root: root)
        let loaded = try ConfigService.load(profile: profile, workspaceRoot: root)
        XCTAssertEqual(loaded.state.deploymentFailureWarningPercent, "5")
        XCTAssertEqual(loaded.state.deploymentFailureCriticalPercent, "25", "the default")
        var state = loaded.state
        state.deploymentFailureCriticalPercent = "40"
        _ = try ConfigService.save(
            profile: profile, state: state, existingDocument: loaded.document,
            workspaceRoot: root)
        let text = try String(
            contentsOf: ConfigService.configURL(for: profile, workspaceRoot: root),
            encoding: .utf8)
        XCTAssertTrue(text.contains("deployment_failure_warning_percent: 5"))
        XCTAssertTrue(text.contains("deployment_failure_critical_percent: 40"))
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
