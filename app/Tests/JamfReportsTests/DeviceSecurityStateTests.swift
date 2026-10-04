import Foundation
import XCTest
@testable import JamfReports

/// Verifies the per-device security state surfacing added in v2.1.0 PR 2.
///
/// The Excel sheet, the DevicesView per-control glyph row, and the detail-panel
/// "Security State" section all read the five fields populated here. These tests
/// cover the model layer; the view layer wraps these values in icons whose
/// tone follows the same workspace policy verdicts as
/// `DeviceInventoryRecord.securityGapCount(policy:)`.
final class DeviceSecurityStateTests: XCTestCase {

    func testRecordFromComputerExtractsAllFiveSecurityControls() {
        let item: [String: Any] = [
            "general": ["id": 7, "name": "Lab-Mac-OK"],
            "hardware": ["serialNumber": "OK7"],
            "diskEncryption": [
                "fileVault2Enabled": true,
                "bootPartitionEncryptionDetails": ["partitionFileVault2State": "ENCRYPTED"],
            ],
            "security": [
                "sipStatus": "ENABLED",
                "firewallEnabled": true,
                "gatekeeperStatus": "APP_STORE_AND_IDENTIFIED_DEVELOPERS",
                "bootstrapTokenEscrowedStatus": "ESCROWED",
            ],
        ]

        let record = DeviceInventoryService.recordFromComputer(item, source: "computers-list.json")

        XCTAssertFalse(record.fileVault.isEmpty)
        XCTAssertEqual(record.sip, "ENABLED")
        XCTAssertEqual(record.firewall.lowercased(), "true")
        XCTAssertEqual(record.gatekeeper, "APP_STORE_AND_IDENTIFIED_DEVELOPERS")
        XCTAssertEqual(record.bootstrapToken, "ESCROWED")
        XCTAssertEqual(record.securityGapCount(policy: .default), 0)
    }

    func testRecordFromComputerFlagsAllDisabledControls() {
        let item: [String: Any] = [
            "general": ["id": 8, "name": "Lab-Mac-Bad"],
            "hardware": ["serialNumber": "BAD8"],
            "diskEncryption": [
                "fileVault2Enabled": false,
                "bootPartitionEncryptionDetails": ["partitionFileVault2State": "UNENCRYPTED"],
            ],
            "security": [
                "sipStatus": "DISABLED",
                "firewallEnabled": false,
                "gatekeeperStatus": "DISABLED",
                "bootstrapTokenEscrowedStatus": "NOT_ESCROWED",
            ],
        ]

        let record = DeviceInventoryService.recordFromComputer(item, source: "computers-list.json")

        XCTAssertEqual(record.fileVault, "UNENCRYPTED")
        XCTAssertEqual(record.sip, "DISABLED")
        XCTAssertEqual(record.firewall.lowercased(), "false")
        XCTAssertEqual(record.gatekeeper, "DISABLED")
        XCTAssertEqual(record.bootstrapToken, "NOT_ESCROWED")
        XCTAssertEqual(record.securityGapCount(policy: .default), 5)
    }

    func testRecordWithMissingSecuritySectionLeavesFieldsEmpty() {
        let item: [String: Any] = [
            "general": ["id": 9, "name": "Lab-Mac-NoSecurity"],
            "hardware": ["serialNumber": "NODATA9"],
        ]

        let record = DeviceInventoryService.recordFromComputer(item, source: "computers-list.json")

        XCTAssertTrue(record.fileVault.isEmpty)
        XCTAssertTrue(record.sip.isEmpty)
        XCTAssertTrue(record.firewall.isEmpty)
        XCTAssertTrue(record.gatekeeper.isEmpty)
        XCTAssertTrue(record.bootstrapToken.isEmpty)
        XCTAssertEqual(record.securityGapCount(policy: .default), 0,
                       "empty values are unknown, not failed")
    }

    // MARK: - Today's numbers

    private func fixtureComputers() throws -> [DeviceInventoryRecord] {
        let url = TestFixtures.dir("jamf-cli-data/computers-list/computers-list.json")
        let items = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        return items.map {
            DeviceInventoryService.recordFromComputer($0, source: "computers-list.json")
        }
    }

    /// Jamf Pro 11.28's built-in computer CSV: four Apple-silicon Macs. Row 2 has FileVault
    /// `0/1` and the firewall `Not Enabled`, row 3 SIP `Disabled`, row 4 Gatekeeper `Disabled`.
    private func builtinCSVRecords() throws -> [DeviceInventoryRecord] {
        let url = TestFixtures.dir("csv/jamf1128_computers_builtin.csv")
        let (_, rows) = try CSVParser.parse(Data(contentsOf: url))
        return rows.map {
            DeviceInventoryService.recordFromCSV($0, source: "jamf1128_computers_builtin.csv")
        }
    }

    private func snapshot(_ devices: [DeviceInventoryRecord]) -> DeviceInventorySnapshot {
        DeviceInventorySnapshot(devices: devices, patchTitles: [], sourceFiles: [], warnings: [],
                                generatedAt: "", generatedDate: nil, isDemo: false)
    }

    func testComputersListFixtureKeepsTodaysGapsAndRisk() throws {
        let records = try fixtureComputers()
        XCTAssertEqual(records.map(\.name), ["Lab-Mac-01", "Lab-Mac-02", "Lab-Mac-03"])
        XCTAssertEqual(records.map { $0.securityGapCount(policy: .default) }, [0, 5, 0])
        XCTAssertEqual(records.map { $0.risk(policy: .default) }, [.ok, .attention, .ok])
    }

    /// Rows 1, 3 and 4; row 2 and the FileVault share change on purpose (below).
    func testBuiltinCSVKeepsTodaysGapsForRowsWithoutPartitionCounts() throws {
        let records = try builtinCSVRecords()
        XCTAssertEqual(records.map(\.name),
                       ["Fixture-Mac-01", "Fixture-Mac-02", "Fixture-Mac-03", "Fixture-Mac-04"])
        XCTAssertEqual([0, 2, 3].map { records[$0].securityGapCount(policy: .default) }, [0, 1, 1])
    }

    // MARK: - Intended changes at the default policy

    private func record(allControls value: String) -> DeviceInventoryRecord {
        var record = DeviceInventoryRecord.empty(id: "serial:x", source: "computers.json")
        record.fileVault = value
        record.sip = value
        record.firewall = value
        record.gatekeeper = value
        record.bootstrapToken = value
        return record
    }

    /// The records here carry no disk, check-in or rule facts, so every factor is a security one.
    private func riskFactors(
        _ record: DeviceInventoryRecord, _ policy: SecurityControlPolicy = .default
    ) -> Set<DeviceRisk.Factor> {
        Set(RiskScoringService.score(input: .from(record: record, policy: policy))
            .triggered.map(\.factor))
    }

    private let everySecurityFactor: Set<DeviceRisk.Factor> = [
        .noFileVault, .sipDisabled, .firewallDisabled, .gatekeeperDisabled, .bootstrapMissing,
    ]

    func testUnmeasuredValuesAreNoLongerGapsOrRiskPoints() {
        for value in ["Not collected", "Not supported", "Not available",
                      "NOT_COLLECTED", "NOT_SUPPORTED", "NOT_AVAILABLE"] {
            let record = record(allControls: value)
            XCTAssertEqual(record.securityGapCount(policy: .default), 0, value)
            XCTAssertEqual(riskFactors(record), [], value)
        }
    }

    func testOffNoneInactiveMissingAndDecryptingAreGapsAndRiskPoints() {
        for value in ["Off", "none", "inactive", "missing"] {
            let record = record(allControls: value)
            XCTAssertEqual(record.securityGapCount(policy: .default), 5, value)
            XCTAssertEqual(riskFactors(record), everySecurityFactor, value)
        }
        var decrypting = record(allControls: "Enabled")
        decrypting.fileVault = "DECRYPTING"
        XCTAssertEqual(decrypting.securityGapCount(policy: .default), 1)
        XCTAssertEqual(riskFactors(decrypting), [.noFileVault])
    }

    /// A hyphen reads as a space, and a true word with `not` or `un` joined on is off: each of
    /// these contains a word that reads as on.
    func testHyphenatedAndJoinedNegativesReadAsOff() {
        for value in ["Not-Connected", "NotConnected", "Not-Enabled", "notencrypted",
                      "Uninstalled", "Unescrowed"] {
            XCTAssertEqual(SecurityControlPolicy.reading(value), false, value)
        }
        for value in ["Connected", "Installed", "Escrowed", "Running", "Block-all-incoming"] {
            XCTAssertEqual(SecurityControlPolicy.reading(value), true, value)
        }
        XCTAssertNil(SecurityControlPolicy.reading("Not-Collected"))
    }

    /// Jamf's CSV FileVault column counts encrypted partitions over all partitions.
    func testCSVPartitionCountsReadAsFileVaultOnOrOff() throws {
        let records = try builtinCSVRecords()
        XCTAssertEqual(records.map(\.fileVault), ["1/1", "0/1", "1/1", "1/1"])
        XCTAssertEqual(records[1].securityGapCount(policy: .default), 2,
                       "FileVault 0/1 and the firewall off")
        XCTAssertTrue(riskFactors(records[1]).contains(.noFileVault))
        XCTAssertEqual(records[0].fileVaultEnabled(policy: .default), true)
        XCTAssertEqual(snapshot(records).fileVaultPercent, 75)
    }

    /// The share is over Macs whose FileVault value reads as on or off: a value that says
    /// neither is left out, not counted as not encrypted, and with no reading at all the
    /// share is unknown rather than 0%.
    func testTheFileVaultShareCountsOnlyMacsWithAReading() {
        var on = record(allControls: "Enabled")
        on.fileVault = "ENCRYPTED"
        var off = record(allControls: "Enabled")
        off.fileVault = "UNENCRYPTED"
        var encrypting = record(allControls: "Enabled")
        encrypting.fileVault = "ENCRYPTING"
        var unknown = record(allControls: "Enabled")
        unknown.fileVault = "Not Collected"
        XCTAssertEqual(snapshot([on, off, encrypting, unknown]).fileVaultPercent, 50)
        XCTAssertNil(snapshot([encrypting, unknown]).fileVaultPercent)
        XCTAssertNil(snapshot([]).fileVaultPercent)
        XCTAssertEqual(DevicesView.fileVaultTileValue(nil), "—")
        XCTAssertEqual(DevicesView.fileVaultTileValue(66.6), "67%")
    }

    /// An organization's FileVault words reach the share, the hardware-rule count and the
    /// record's own reading; without them the same Macs read as unmeasured.
    func testTheFileVaultShareAndCountsFollowTheWorkspaceVocabulary() {
        var wrapped = record(allControls: "Enabled")
        wrapped.fileVault = "Wrapped"
        var bare = record(allControls: "Enabled")
        bare.fileVault = "Bare"
        bare.hardwareEncrypted = true
        let words = SecurityControlPolicy(
            fileVaultOffHardwareEncrypted: .warning,
            onValues: [.fileVault: ["Wrapped"]], offValues: [.fileVault: ["Bare"]])
        func inventory(_ policy: SecurityControlPolicy) -> DeviceInventorySnapshot {
            DeviceInventorySnapshot(
                devices: [wrapped, bare], patchTitles: [], sourceFiles: [], warnings: [],
                generatedAt: "", generatedDate: nil, isDemo: false, securityPolicy: policy)
        }

        XCTAssertEqual(wrapped.fileVaultEnabled(policy: words), true)
        XCTAssertEqual(bare.fileVaultEnabled(policy: words), false)
        XCTAssertEqual(inventory(words).fileVaultPercent, 50)
        XCTAssertEqual(inventory(words).fileVaultOffHardwareEncryptedCount, 1)
        XCTAssertEqual(inventory(words).securityGapCount, 0, "the hardware rule is a warning")

        XCTAssertNil(bare.fileVaultEnabled(policy: .default))
        XCTAssertNil(inventory(.default).fileVaultPercent)
        XCTAssertEqual(inventory(.default).fileVaultOffHardwareEncryptedCount, 0)
    }

    /// The phrase contains "Encrypted", which used to count it as encrypted.
    func testNoPartitionsEncryptedIsNotEncrypted() {
        var record = record(allControls: "Enabled")
        record.fileVault = "No Partitions Encrypted"
        XCTAssertEqual(record.fileVaultEnabled(policy: .default), false)
        XCTAssertEqual(snapshot([record]).fileVaultPercent, 0)
        XCTAssertEqual(record.securityGapCount(policy: .default), 1)
        XCTAssertEqual(riskFactors(record), [.noFileVault])
    }

    /// Jamf FileVault states that are off and stay off until someone acts. The Devices table
    /// already showed DECRYPTED and DECRYPTING_PAUSED red, but neither counted as a gap.
    func testDecryptedAndPausedFileVaultAreGapsAndRiskPoints() {
        for value in ["DECRYPTED", "DECRYPTING_PAUSED", "ENCRYPTING_PAUSED"] {
            var record = record(allControls: "Enabled")
            record.fileVault = value
            XCTAssertEqual(record.fileVaultEnabled(policy: .default), false, value)
            XCTAssertEqual(record.securityGapCount(policy: .default), 1, value)
            XCTAssertEqual(riskFactors(record), [.noFileVault], value)
        }
    }

    // MARK: - Bootstrap token escrow

    /// Jamf Pro reports escrow as `security.bootstrapTokenEscrowedStatus`; every other
    /// control here is on.
    private func computer(bootstrap: [String: Any]) -> DeviceInventoryRecord {
        let security: [String: Any] = [
            "sipStatus": "ENABLED", "firewallEnabled": true,
            "gatekeeperStatus": "APP_STORE_AND_IDENTIFIED_DEVELOPERS",
        ].merging(bootstrap) { _, new in new }
        return DeviceInventoryService.recordFromComputer([
            "general": ["id": 21, "name": "Lab-Mac-BT"],
            "hardware": ["serialNumber": "BT21"],
            "diskEncryption": [
                "bootPartitionEncryptionDetails": ["partitionFileVault2State": "ENCRYPTED"],
            ],
            "security": security,
        ], source: "computers.json")
    }

    func testNotEscrowedBootstrapTokenIsAGapAndARiskPoint() {
        let mac = computer(bootstrap: ["bootstrapTokenEscrowedStatus": "NOT_ESCROWED"])
        XCTAssertEqual(mac.bootstrapToken, "NOT_ESCROWED")
        XCTAssertEqual(mac.securityGapCount(policy: .default), 1)
        XCTAssertEqual(riskFactors(mac), [.bootstrapMissing])
    }

    func testEscrowedBootstrapTokenIsNoGapAndNoRiskPoint() {
        let mac = computer(bootstrap: ["bootstrapTokenEscrowedStatus": "ESCROWED"])
        XCTAssertEqual(SecurityControlPolicy.reading(mac.bootstrapToken), true)
        XCTAssertEqual(mac.securityGapCount(policy: .default), 0)
        XCTAssertEqual(riskFactors(mac), [])
    }

    func testUnsupportedBootstrapTokenIsUnknown() {
        let mac = computer(bootstrap: ["bootstrapTokenEscrowedStatus": "NOT_SUPPORTED"])
        XCTAssertEqual(mac.bootstrapToken, "NOT_SUPPORTED")
        XCTAssertNil(SecurityControlPolicy.reading(mac.bootstrapToken))
        XCTAssertEqual(mac.securityGapCount(policy: .default), 0)
        XCTAssertEqual(riskFactors(mac), [])
    }

    /// A snapshot that still carries the older Bool key, with no status key, is read from it.
    func testOlderEscrowedKeyIsReadWhenTheStatusKeyIsAbsent() {
        let mac = computer(bootstrap: ["bootstrapTokenEscrowed": false])
        XCTAssertEqual(SecurityControlPolicy.reading(mac.bootstrapToken), false)
        XCTAssertEqual(mac.securityGapCount(policy: .default), 1)
        XCTAssertEqual(riskFactors(mac), [.bootstrapMissing])
    }

    /// Allowed says the server accepts escrow, not that this Mac's token was escrowed.
    func testBootstrapTokenAllowedAloneIsUnknown() {
        for allowed in [true, false] {
            let mac = computer(bootstrap: ["bootstrapTokenAllowed": allowed])
            XCTAssertEqual(mac.bootstrapToken, "", "\(allowed)")
            XCTAssertNil(SecurityControlPolicy.reading(mac.bootstrapToken), "\(allowed)")
            XCTAssertEqual(mac.securityGapCount(policy: .default), 0, "\(allowed)")
            XCTAssertEqual(riskFactors(mac), [], "\(allowed)")
        }
    }

    /// The CSV export's Allowed column is the same server setting, so an empty Escrowed
    /// cell stays unknown rather than borrowing it.
    func testCSVBootstrapTokenAllowedAloneIsUnknown() {
        let base = ["Computer Name": "Lab-Mac-BT", "Serial Number": "BT22"]
        for allowed in ["Yes", "No"] {
            let onlyAllowed = ["Bootstrap Token Allowed": allowed]
            var emptyEscrowed = onlyAllowed
            emptyEscrowed["Bootstrap Token Escrowed"] = ""
            for bootstrap in [onlyAllowed, emptyEscrowed] {
                let mac = DeviceInventoryService.recordFromCSV(
                    base.merging(bootstrap) { _, new in new }, source: "computers.csv")
                XCTAssertEqual(mac.bootstrapToken, "", allowed)
                XCTAssertNil(SecurityControlPolicy.reading(mac.bootstrapToken), allowed)
                XCTAssertEqual(mac.securityGapCount(policy: .default), 0, allowed)
                XCTAssertEqual(riskFactors(mac), [], allowed)
            }
        }
    }

    // MARK: - security_policy

    private let hardwareWarning = SecurityControlPolicy(fileVaultOffHardwareEncrypted: .warning)

    /// FileVault off and every other control on, in the `computers` snapshot shape.
    private func fileVaultOffComputer(
        id: Int, serial: String, appleSilicon: Bool, model: String
    ) -> [String: Any] {
        [
            "general": ["id": id, "name": "Lab-Mac-\(serial)"],
            "hardware": [
                "serialNumber": serial, "appleSilicon": appleSilicon, "modelIdentifier": model,
            ],
            "diskEncryption": [
                "bootPartitionEncryptionDetails": ["partitionFileVault2State": "UNENCRYPTED"],
            ],
            "security": [
                "sipStatus": "ENABLED", "firewallEnabled": true,
                "gatekeeperStatus": "APP_STORE_AND_IDENTIFIED_DEVELOPERS",
                "bootstrapTokenEscrowedStatus": "ESCROWED",
            ],
        ]
    }

    func testHardwareRuleAtWarningKeepsAppleSiliconFileVaultOffOutOfTheGaps() {
        let mac = DeviceInventoryService.recordFromComputer(
            fileVaultOffComputer(id: 11, serial: "AS1", appleSilicon: true, model: "Mac14,2"),
            source: "computers.json")
        XCTAssertEqual(mac.hardwareEncrypted, true)

        XCTAssertEqual(mac.securityGapCount(policy: .default), 1)
        XCTAssertEqual(mac.risk(policy: .default), .attention)
        XCTAssertEqual(riskFactors(mac, .default), [.noFileVault])
        XCTAssertEqual(SecurityControlPolicy.default.fileVaultLabel(
            mac.fileVault, hardwareEncrypted: mac.hardwareEncrypted), "UNENCRYPTED")

        XCTAssertEqual(mac.securityGapCount(policy: hardwareWarning), 0)
        XCTAssertEqual(mac.risk(policy: hardwareWarning), .ok)
        XCTAssertEqual(riskFactors(mac, hardwareWarning), [])
        XCTAssertEqual(hardwareWarning.fileVaultLabel(
            mac.fileVault, hardwareEncrypted: mac.hardwareEncrypted),
                       "FileVault off (hardware-encrypted)")
    }

    /// A typed hardware level stricter than FileVault's: FileVault off on an Apple-silicon Mac
    /// is a plain failure, so neither its label nor the tile's count calls it hardware-encrypted.
    func testAStricterHardwareLevelMakesAppleSiliconFileVaultOffAPlainFailure() {
        let stricter = SecurityControlPolicy(
            fileVault: .warning, fileVaultOffHardwareEncrypted: .fail)
        let appleSilicon = DeviceInventoryService.recordFromComputer(
            fileVaultOffComputer(id: 11, serial: "AS1", appleSilicon: true, model: "Mac14,2"),
            source: "computers.json")
        let intel = DeviceInventoryService.recordFromComputer(
            fileVaultOffComputer(
                id: 12, serial: "IN1", appleSilicon: false, model: "MacBookPro14,1"),
            source: "computers.json")

        XCTAssertEqual(appleSilicon.securityGapCount(policy: stricter), 1)
        XCTAssertEqual(riskFactors(appleSilicon, stricter), [.noFileVault])
        XCTAssertEqual(stricter.fileVaultLabel(appleSilicon.fileVault, hardwareEncrypted: true),
                       "UNENCRYPTED")
        XCTAssertEqual(stricter.fileVaultLabel(
            appleSilicon.fileVault, hardwareEncrypted: true, short: true), "UNENCRYPTED")
        XCTAssertEqual(intel.securityGapCount(policy: stricter), 0, "FileVault off is a warning")
        XCTAssertEqual(riskFactors(intel, stricter), [])

        var fleet = snapshot([appleSilicon, intel])
        fleet.securityPolicy = stricter
        XCTAssertEqual(fleet.securityGapCount, 1)
        XCTAssertEqual(fleet.fileVaultOffHardwareEncryptedCount, 0)
    }

    func testHardwareRuleLeavesAnIntelMacWithoutT2AsAGap() {
        let mac = DeviceInventoryService.recordFromComputer(
            fileVaultOffComputer(
                id: 12, serial: "IN1", appleSilicon: false, model: "MacBookPro14,1"),
            source: "computers.json")
        XCTAssertEqual(mac.hardwareEncrypted, false)
        XCTAssertEqual(mac.securityGapCount(policy: hardwareWarning), 1)
        XCTAssertEqual(riskFactors(mac, hardwareWarning), [.noFileVault])
        XCTAssertEqual(hardwareWarning.fileVaultLabel(mac.fileVault, hardwareEncrypted: false),
                       "UNENCRYPTED")
    }

    func testFileVaultLabelIsTheValueUnlessTheRuleApplies() {
        XCTAssertEqual(hardwareWarning.fileVaultLabel("ENCRYPTED", hardwareEncrypted: true),
                       "ENCRYPTED")
        XCTAssertEqual(hardwareWarning.fileVaultLabel("ENCRYPTING", hardwareEncrypted: true),
                       "ENCRYPTING")
        XCTAssertEqual(hardwareWarning.fileVaultLabel("UNENCRYPTED", hardwareEncrypted: nil),
                       "UNENCRYPTED")
        XCTAssertEqual(hardwareWarning.fileVaultLabel("", hardwareEncrypted: true), "")
        let ignored = SecurityControlPolicy(fileVaultOffHardwareEncrypted: .ignore)
        XCTAssertEqual(ignored.fileVaultLabel("0/1", hardwareEncrypted: true),
                       SecurityControlPolicy.hardwareEncryptedFileVaultOffLabel)
    }

    /// A pill already under a "FileVault" label takes the short form; everywhere else the long.
    func testFileVaultShortLabelForAPillUnderAFileVaultLabel() {
        XCTAssertEqual(SecurityControlPolicy.hardwareEncryptedFileVaultOffShortLabel,
                       "Off (hardware-encrypted)")
        XCTAssertEqual(
            hardwareWarning.fileVaultLabel("UNENCRYPTED", hardwareEncrypted: true, short: true),
            "Off (hardware-encrypted)")
        XCTAssertEqual(hardwareWarning.fileVaultLabel("UNENCRYPTED", hardwareEncrypted: true),
                       "FileVault off (hardware-encrypted)", "the long form is the default")
        XCTAssertEqual(
            hardwareWarning.fileVaultLabel("ENCRYPTED", hardwareEncrypted: true, short: true),
            "ENCRYPTED")
        XCTAssertEqual(SecurityControlPolicy.default.fileVaultLabel(
            "UNENCRYPTED", hardwareEncrypted: true, short: true), "UNENCRYPTED")
    }

    /// The CSV export names FileVault as the screen does, so a Mac the rule lowered does not
    /// export UNENCRYPTED beside a risk of OK.
    func testDevicesCSVExportLabelsHardwareEncryptedFileVaultOff() {
        let macs = [
            DeviceInventoryService.recordFromComputer(
                fileVaultOffComputer(id: 11, serial: "AS1", appleSilicon: true, model: "Mac14,2"),
                source: "computers.json"),
            DeviceInventoryService.recordFromComputer(
                fileVaultOffComputer(
                    id: 12, serial: "IN1", appleSilicon: false, model: "MacBookPro14,1"),
                source: "computers.json"),
        ]
        let header = "Name,Serial,OS Version,User,Email,Department,FileVault,Last Check-in,Risk"
        XCTAssertEqual(DevicesView.exportCSV(devices: macs, policy: hardwareWarning), [
            header,
            "Lab-Mac-AS1,AS1,,,,,FileVault off (hardware-encrypted),,ok",
            "Lab-Mac-IN1,IN1,,,,,UNENCRYPTED,,attention",
        ].joined(separator: "\n"))
        XCTAssertEqual(DevicesView.exportCSV(devices: macs, policy: .default), [
            header,
            "Lab-Mac-AS1,AS1,,,,,UNENCRYPTED,,attention",
            "Lab-Mac-IN1,IN1,,,,,UNENCRYPTED,,attention",
        ].joined(separator: "\n"))
    }

    /// Device names, users and departments come from Jamf, where anyone who can name a Mac
    /// can type a formula; a spreadsheet must open them as text.
    func testTheDevicesCSVExportNeutralisesFormulaPrefixes() throws {
        var mac = DeviceInventoryService.recordFromComputer(
            fileVaultOffComputer(id: 11, serial: "AS1", appleSilicon: true, model: "Mac14,2"),
            source: "computers.json")
        mac.name = "=HYPERLINK(\"https://x\",\"y\")"
        mac.serial = "-3"
        mac.osVersion = "\r=2"
        mac.user = "+1"
        mac.email = "@sum"
        mac.department = "\t=1"
        let row = try XCTUnwrap(
            DevicesView.exportCSV(devices: [mac], policy: .default)
                .components(separatedBy: "\n").dropFirst().first)
        XCTAssertEqual(
            row,
            "\"\t=HYPERLINK(\"\"https://x\"\",\"\"y\"\")\",\t-3,\"\t\r=2\",\t+1,\t@sum,"
                + "\t\t=1,UNENCRYPTED,,attention")
    }

    func testCSVFieldNeutralisesALeadingTabOrCarriageReturn() {
        XCTAssertEqual(StaleDeviceService.csvField("\t=1"), "\t\t=1")
        XCTAssertEqual(StaleDeviceService.csvField("\r=1"), "\"\t\r=1\"")
        XCTAssertEqual(StaleDeviceService.csvField("a\t=1"), "a\t=1")
    }

    /// The tile counts the Macs the rule took out of the gaps; FileVault stays off for the share.
    func testSnapshotCountsHardwareEncryptedFileVaultOffApart() {
        let macs = [
            DeviceInventoryService.recordFromComputer(
                fileVaultOffComputer(id: 11, serial: "AS1", appleSilicon: true, model: "Mac14,2"),
                source: "computers.json"),
            DeviceInventoryService.recordFromComputer(
                fileVaultOffComputer(
                    id: 12, serial: "IN1", appleSilicon: false, model: "MacBookPro14,1"),
                source: "computers.json"),
        ]
        var fleet = snapshot(macs)
        XCTAssertEqual(fleet.securityPolicy, .default)
        XCTAssertEqual(fleet.securityGapCount, 2)
        XCTAssertEqual(fleet.fileVaultOffHardwareEncryptedCount, 0)

        fleet.securityPolicy = hardwareWarning
        XCTAssertEqual(fleet.securityGapCount, 1)
        XCTAssertEqual(fleet.fileVaultOffHardwareEncryptedCount, 1)
        XCTAssertEqual(fleet.fileVaultPercent, 0)
    }

    /// The workspace's policy reaches the snapshot and the risk order: with the rule the
    /// Apple-silicon Mac is OK and sorts after the Intel Mac; without it both need attention
    /// and sort by name.
    func testLoadUsesTheWorkspacePolicy() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-devices-policy-\(UUID().uuidString)", isDirectory: true)
        let saved = ProcessInfo.processInfo.environment["JRC_TEST_WORKSPACES_ROOT"]
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        defer {
            if let saved { setenv("JRC_TEST_WORKSPACES_ROOT", saved, 1) }
            else { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
            try? FileManager.default.removeItem(at: root)
        }
        let profile = "devices-policy"
        let workspace = try XCTUnwrap(ProfileService.workspaceURL(for: profile))
        let computersDir = workspace.appendingPathComponent("jamf-cli-data/computers")
        try FileManager.default.createDirectory(at: computersDir, withIntermediateDirectories: true)
        let computers = [
            fileVaultOffComputer(id: 11, serial: "AS1", appleSilicon: true, model: "Mac14,2"),
            fileVaultOffComputer(
                id: 12, serial: "IN1", appleSilicon: false, model: "MacBookPro14,1"),
        ]
        try JSONSerialization.data(withJSONObject: computers)
            .write(to: computersDir.appendingPathComponent("computers_20261001T090000.json"))

        let before = DeviceInventoryService.load(profile: profile, demoMode: false)
        XCTAssertEqual(before.securityPolicy, .default)
        XCTAssertEqual(before.devices.map(\.serial), ["AS1", "IN1"])

        try "security_policy:\n  filevault_off_hardware_encrypted: warning\n".write(
            to: workspace.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
        let after = DeviceInventoryService.load(profile: profile, demoMode: false)
        XCTAssertEqual(after.securityPolicy, hardwareWarning)
        XCTAssertEqual(after.devices.map(\.serial), ["IN1", "AS1"])
        XCTAssertEqual(after.securityGapCount, 1)
        XCTAssertEqual(after.fileVaultOffHardwareEncryptedCount, 1)
    }
}
