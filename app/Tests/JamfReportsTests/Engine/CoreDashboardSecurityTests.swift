import Foundation
import XCTest
@testable import JamfReports

// MARK: - CoreDashboardSecurityTests
//
// Validates the three sheet writers migrated from [String: Any] to typed decoders
// in the typed-decoder collapse (W24 / Task 1).
//
// Pattern for future migrations:
//   1. Write a "happy path" test seeding a valid fixture into a temp dir.
//   2. Write a "malformed JSON" test verifying no crash and a logged warning.
//   3. Write a "missing data" test verifying the function throws noCachedData.

final class CoreDashboardSecurityTests: XCTestCase {

    // MARK: - Helpers

    private func makeDashboard(dataDir: URL) -> CoreDashboard {
        CoreDashboard(config: ReportConfig(), dataDir: dataDir, workbook: Workbook())
    }

    /// Write `json` into `<dataDir>/<kind>/<kind>.json` and return `dataDir`.
    private func seedJSON(_ json: String, kind: String, in dir: URL) throws {
        let kindDir = dir.appendingPathComponent(kind, isDirectory: true)
        try FileManager.default.createDirectory(at: kindDir, withIntermediateDirectories: true)
        let fileURL = kindDir.appendingPathComponent("\(kind).json")
        try json.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private func makeTempDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoreDashboardSecurityTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private func fixtureData(kind: String) -> String? {
        let fixtureDir = TestFixtures.dir("jamf-cli-data")
            .appendingPathComponent(kind)
        let files = TestFixtures.listDir(fixtureDir).filter { $0.pathExtension == "json" }
        // `listDir` order is undefined. Sort by filename so the test
        // deterministically pins to the same fixture every run — for
        // `security` the corpus holds three files (Epic #102).
        guard let first = files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first,
              let content = try? String(contentsOf: first, encoding: .utf8)
        else { return nil }
        return content
    }

    // MARK: - writeSecurity: happy path

    func testWriteSecurityHappyPath() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let json = """
        [{"section":"summary","data":{"total_devices":100,"filevault_encrypted":95,
          "gatekeeper_enabled":100,"sip_enabled":100,"firewall_enabled":80}},
         {"section":"os_version","os_version":"15.4.1","count":60,"pct":"60%"},
         {"section":"os_version","os_version":"14.7.2","count":40,"pct":"40%"}]
        """
        try seedJSON(json, kind: "security", in: dir)

        let dash = makeDashboard(dataDir: dir)
        XCTAssertNoThrow(try dash.writeSecurity(), "writeSecurity must not throw on valid data")

        let ws = dash.workbook.sheet(named: "Security Posture")
        XCTAssertNotNil(ws, "Security Posture sheet must be created")
    }

    // MARK: - writeSecurity: malformed JSON does not crash

    func testWriteSecurityMalformedJSONSkipsSheet() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Valid JSON syntax but wrong shape — not an array of SecurityReportItem
        try seedJSON("{\"not\":\"an array\"}", kind: "security", in: dir)

        let dash = makeDashboard(dataDir: dir)
        // Must throw noCachedData (typed decode returns nil → guard fails → throw)
        // OR throw a decode error — either way, must not crash or produce garbage output.
        XCTAssertThrowsError(try dash.writeSecurity())
    }

    // MARK: - writeSecurity: missing data throws noCachedData

    func testWriteSecurityMissingDataThrows() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let dash = makeDashboard(dataDir: dir)
        XCTAssertThrowsError(try dash.writeSecurity()) { error in
            if let err = error as? CoreDashboardError,
               case .noCachedData(let names) = err {
                XCTAssertTrue(names.contains("security"))
            }
            // Other error types are also acceptable (e.g. decode failure on bad shape)
        }
    }

    // MARK: - writeSecurity: fixture round-trip (skipped when fixture absent)

    func testWriteSecurityFromFixture() throws {
        guard let json = fixtureData(kind: "security") else {
            throw XCTSkip("security fixture not available")
        }
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try seedJSON(json, kind: "security", in: dir)

        let dash = makeDashboard(dataDir: dir)
        XCTAssertNoThrow(try dash.writeSecurity())
    }

    // MARK: - writePatch: happy path

    func testWritePatchHappyPath() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let json = """
        [{"title":"Firefox","id":"1","on_latest":80,"on_other":20,
          "total":100,"latest":"130.0","compliance_pct":"80%"},
         {"title":"Chrome","id":"2","on_latest":95,"on_other":5,
          "total":100,"latest":"123.0","compliance_pct":"95%"}]
        """
        try seedJSON(json, kind: "patch-status", in: dir)

        let dash = makeDashboard(dataDir: dir)
        XCTAssertNoThrow(try dash.writePatch(), "writePatch must not throw on valid data")

        let ws = dash.workbook.sheet(named: "Patch Compliance")
        XCTAssertNotNil(ws, "Patch Compliance sheet must be created")
    }

    // MARK: - writePatch: missing data throws

    func testWritePatchMissingDataThrows() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let dash = makeDashboard(dataDir: dir)
        XCTAssertThrowsError(try dash.writePatch())
    }

    // MARK: - writePatch: fixture (skipped when fixture absent)

    func testWritePatchFromFixture() throws {
        guard let json = fixtureData(kind: "patch-status") else {
            throw XCTSkip("patch-status fixture not available")
        }
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try seedJSON(json, kind: "patch-status", in: dir)

        let dash = makeDashboard(dataDir: dir)
        XCTAssertNoThrow(try dash.writePatch())
    }

    // MARK: - writeUpdateStatus: happy path

    func testWriteUpdateStatusHappyPath() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let json = """
        [{"total":200,
          "status_summary":[{"status":"UP_TO_DATE","count":180},{"status":"PENDING","count":20}],
          "plan_total":5,
          "plan_state_summary":[{"state":"Activated","count":3},{"state":"Pending","count":2}]}]
        """
        try seedJSON(json, kind: "update-status", in: dir)

        let dash = makeDashboard(dataDir: dir)
        XCTAssertNoThrow(try dash.writeUpdateStatus(), "writeUpdateStatus must not throw on valid data")

        let ws = dash.workbook.sheet(named: "Update Status")
        XCTAssertNotNil(ws, "Update Status sheet must be created")
    }

    // MARK: - writeUpdateStatus: missing data throws

    func testWriteUpdateStatusMissingDataThrows() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let dash = makeDashboard(dataDir: dir)
        XCTAssertThrowsError(try dash.writeUpdateStatus())
    }

    // MARK: - writeUpdateStatus: fixture (skipped when fixture absent or not a valid shape)

    func testWriteUpdateStatusFromFixture() throws {
        guard let json = fixtureData(kind: "update-status") else {
            throw XCTSkip("update-status fixture not available")
        }
        // S-07 (PR-5): the committed fixture is the happy-path shape;
        // the prior conditional skip ("not a valid UpdateStatusReport
        // shape") was masking an out-of-spec fixture and is no longer
        // needed. The 503-error response shape is preserved in
        // tests/fixtures/jamf-cli-data-variants/update-status/update-status-error-503.json
        // for any future test that wants to exercise the error path.
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try seedJSON(json, kind: "update-status", in: dir)

        let dash = makeDashboard(dataDir: dir)
        XCTAssertNoThrow(try dash.writeUpdateStatus())
    }

    // MARK: - loadLatestTyped returns nil on type mismatch (logged, not thrown)

    func testLoadLatestTypedReturnsMalformedAsNilForPatch() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Write a JSON array of objects that won't decode as PatchStatusRow
        // (missing required fields like "title", "on_latest", etc.)
        try seedJSON("[{\"wrong_field\":true}]", kind: "patch-status", in: dir)

        let dash = makeDashboard(dataDir: dir)
        // writePatch decodes via loadLatestTyped: if every item fails,
        // the array decodes successfully but fields default; "title" will be empty string
        // (since PatchStatusRow fields are non-optional). Actually PatchStatusRow has
        // non-optional String fields, so this will throw a decode error — guard fails.
        XCTAssertThrowsError(try dash.writePatch())
    }

    // MARK: - Reading a written sheet

    private static func text(_ value: CellValue) -> String {
        switch value {
        case .string(let s): s
        case .int(let i): "\(i)"
        case .double(let d): "\(d)"
        case .bool(let b): "\(b)"
        case .blank: ""
        }
    }

    /// The cells of the row whose first cell reads `label`, by column.
    private func row(
        _ dash: CoreDashboard, _ sheet: String, _ label: String
    ) throws -> [Int: (text: String, format: CellFormat?)] {
        let ws = try XCTUnwrap(dash.workbook.sheet(named: sheet), "no \(sheet) sheet")
        let cells = ws.dedupedCells
        let first = try XCTUnwrap(
            cells.first { $0.col == 0 && Self.text($0.value) == label },
            "\(sheet) has no row \(label)")
        var result: [Int: (text: String, format: CellFormat?)] = [:]
        for cell in cells where cell.row == first.row {
            result[cell.col] = (Self.text(cell.value), cell.format)
        }
        return result
    }

    private func hasRow(_ dash: CoreDashboard, _ sheet: String, _ label: String) -> Bool {
        dash.workbook.sheet(named: sheet)?.dedupedCells.contains {
            $0.col == 0 && Self.text($0.value) == label
        } ?? false
    }

    private func dashboard(_ yaml: String, dataDir: URL) throws -> CoreDashboard {
        CoreDashboard(
            config: try ConfigLoader.loadFromString(yaml), dataDir: dataDir, workbook: Workbook())
    }

    // MARK: - Characterization: the sheets at the default policy

    /// Fixture `security.json` (a real `pro report security` shape): 101 Macs, FileVault 100,
    /// SIP 1, Firewall 0, Gatekeeper 100.
    func testCompliancePostureStatusesOnTheSecurityFixture() throws {
        let json = try XCTUnwrap(fixtureData(kind: "security"))
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try seedJSON(json, kind: "security", in: dir)
        let dash = makeDashboard(dataDir: dir)
        try dash.writeCompliancePosture()

        let expected: [(String, String, String, CellFormat)] = [
            ("FileVault Encrypted", "100 (99.0%)", "GREEN", .green),
            ("SIP Enabled", "1 (1.0%)", "RED", .red),
            ("Firewall Enabled", "0 (0.0%)", "RED", .red),
            ("Gatekeeper Enabled", "100 (99.0%)", "GREEN", .green),
        ]
        for (label, value, status, format) in expected {
            let cells = try row(dash, "Compliance Posture", label)
            XCTAssertEqual(cells[1]?.text, value, label)
            XCTAssertEqual(cells[2]?.text, status, label)
            XCTAssertEqual(cells[2]?.format, format, label)
        }
    }

    /// Fixture `computers-list.json`: Lab-Mac-01 has every control on, Lab-Mac-02 has them off,
    /// Lab-Mac-03 has no security section and gets no row. FileVault's text and format for
    /// Lab-Mac-02 and the bootstrap column move with the named tests below.
    func testDeviceSecurityStateFormatsOnTheComputersListFixture() throws {
        let json = try XCTUnwrap(fixtureData(kind: "computers-list"))
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try seedJSON(json, kind: "computers", in: dir)
        let dash = makeDashboard(dataDir: dir)
        try dash.writeDeviceSecurityState()

        let on = try row(dash, "Device Security State", "Lab-Mac-01")
        XCTAssertEqual(on[2]?.text, "ENCRYPTED")
        XCTAssertEqual(on[3]?.text, "ENABLED")
        XCTAssertEqual(on[4]?.text, "ENABLED")
        XCTAssertEqual(on[5]?.text, "APP_STORE_AND_IDENTIFIED_DEVELOPERS")
        for col in 2...5 { XCTAssertEqual(on[col]?.format, .green, "Lab-Mac-01 col \(col)") }

        let off = try row(dash, "Device Security State", "Lab-Mac-02")
        XCTAssertEqual(off[2]?.text, "UNENCRYPTED")
        XCTAssertEqual(off[3]?.text, "DISABLED")
        XCTAssertEqual(off[4]?.text, "DISABLED")
        XCTAssertEqual(off[5]?.text, "DISABLED")
        for col in 3...5 { XCTAssertEqual(off[col]?.format, .red, "Lab-Mac-02 col \(col)") }

        XCTAssertFalse(hasRow(dash, "Device Security State", "Lab-Mac-03"))
    }

    // MARK: - Device Security State: intended changes at the default policy

    /// A real v4 `computers` record. `bootstrap` and `hardware` add or replace keys.
    private func computer(
        _ name: String, fileVault: String = "ENCRYPTED", sip: String = "ENABLED",
        firewall: Bool = true, gatekeeper: String = "APP_STORE",
        bootstrap: [String: Any] = ["bootstrapTokenEscrowedStatus": "ESCROWED"],
        hardware: [String: Any] = [:]
    ) -> [String: Any] {
        var hardwareFacts: [String: Any] = ["serialNumber": name.uppercased()]
        hardwareFacts.merge(hardware) { _, new in new }
        var security: [String: Any] = [
            "sipStatus": sip, "firewallEnabled": firewall, "gatekeeperStatus": gatekeeper,
        ]
        security.merge(bootstrap) { _, new in new }
        return [
            "general": ["id": name, "name": name], "hardware": hardwareFacts,
            "diskEncryption": ["bootPartitionEncryptionDetails": [
                "partitionFileVault2State": fileVault]],
            "security": security,
        ]
    }

    private func seedComputers(_ items: [[String: Any]], in dir: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: items)
        try seedJSON(String(decoding: data, as: UTF8.self), kind: "computers", in: dir)
    }

    /// Writes Device Security State for `items` and returns the row of each computer by name.
    private func securityState(
        _ items: [[String: Any]], yaml: String = ""
    ) throws -> [String: [Int: (text: String, format: CellFormat?)]] {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try seedComputers(items, in: dir)
        let dash = try dashboard(yaml, dataDir: dir)
        try dash.writeDeviceSecurityState()
        var rows: [String: [Int: (text: String, format: CellFormat?)]] = [:]
        for item in items {
            let name = ((item["general"] as? [String: Any])?["name"] as? String) ?? ""
            rows[name] = try row(dash, "Device Security State", name)
        }
        return rows
    }

    /// Intended change: UNENCRYPTED was green, because the old rule took any value
    /// containing "ENCRYPT" as encrypted.
    func testUnencryptedFileVaultIsRed() throws {
        let rows = try securityState([computer("off", fileVault: "UNENCRYPTED")])
        XCTAssertEqual(rows["off"]?[2]?.text, "UNENCRYPTED")
        XCTAssertEqual(rows["off"]?[2]?.format, .red)
    }

    /// Intended change: ENCRYPTING_PAUSED was green for the same reason. A paused encryption
    /// stays paused until someone resumes it, so it reads as off.
    func testPausedEncryptionIsRed() throws {
        let rows = try securityState([computer("paused", fileVault: "ENCRYPTING_PAUSED")])
        XCTAssertEqual(rows["paused"]?[2]?.format, .red)
    }

    /// Intended change: a value Jamf did not collect, or the Mac cannot report, was red. It
    /// says nothing about the control, so it is neutral and keeps its text.
    func testUnreadableValuesAreNeutral() throws {
        let rows = try securityState([
            computer("a", fileVault: "NOT_COLLECTED", sip: "NOT_COLLECTED",
                     gatekeeper: "NOT_COLLECTED"),
            computer("b", fileVault: "INELIGIBLE", sip: "NOT_AVAILABLE"),
            computer("c", fileVault: "RESTART_NEEDED"),
            computer("d", fileVault: "OPTIMIZING"),
        ])
        for (name, columns) in [("a", [2, 3, 5]), ("b", [2, 3]), ("c", [2]), ("d", [2])] {
            for col in columns {
                XCTAssertEqual(rows[name]?[col]?.format, .cell, "\(name) col \(col)")
            }
        }
        XCTAssertEqual(rows["a"]?[3]?.text, "NOT_COLLECTED")
        XCTAssertEqual(rows["b"]?[2]?.text, "INELIGIBLE")
    }

    /// Intended change: ENCRYPTING was green. It does not say yet whether the volume is
    /// encrypted, so it is neutral.
    func testEncryptingFileVaultIsNeutral() throws {
        let rows = try securityState([computer("busy", fileVault: "ENCRYPTING")])
        XCTAssertEqual(rows["busy"]?[2]?.format, .cell)
    }

    /// Intended change: the bootstrap cell follows `security.bootstrapTokenEscrowedStatus`,
    /// the key every live record carries. The sheet read `bootstrapTokenEscrowed`, which none
    /// does, so the column was empty on live data. The older key stays a fallback, and
    /// `bootstrapTokenAllowed` (whether escrow is permitted) never stands in.
    func testBootstrapCellFollowsTheStatusKey() throws {
        let rows = try securityState([
            computer("escrowed", bootstrap: ["bootstrapTokenEscrowedStatus": "ESCROWED"]),
            computer("missing", bootstrap: ["bootstrapTokenEscrowedStatus": "NOT_ESCROWED"]),
            computer("unsupported", bootstrap: ["bootstrapTokenEscrowedStatus": "NOT_SUPPORTED"]),
            computer("older-yes", bootstrap: ["bootstrapTokenEscrowedStatus": "",
                                              "bootstrapTokenEscrowed": true]),
            computer("older-no", bootstrap: ["bootstrapTokenEscrowedStatus": "",
                                             "bootstrapTokenEscrowed": false]),
            computer("both", bootstrap: ["bootstrapTokenEscrowedStatus": "NOT_ESCROWED",
                                         "bootstrapTokenEscrowed": true]),
            computer("allowed", bootstrap: ["bootstrapTokenEscrowedStatus": "",
                                            "bootstrapTokenAllowed": true]),
        ])
        let expected: [(String, String, CellFormat)] = [
            ("escrowed", "ESCROWED", .green), ("missing", "NOT_ESCROWED", .red),
            ("unsupported", "NOT_SUPPORTED", .cell), ("older-yes", "ESCROWED", .green),
            ("older-no", "NOT ESCROWED", .red), ("both", "NOT_ESCROWED", .red),
            ("allowed", "", .cell),
        ]
        for (name, text, format) in expected {
            XCTAssertEqual(rows[name]?[6]?.text, text, name)
            XCTAssertEqual(rows[name]?[6]?.format, format, name)
        }
    }

    // MARK: - Device Security State: the policy

    private let siliconFacts: [String: Any] = ["appleSilicon": true]
    private let intelFacts: [String: Any] = [
        "appleSilicon": false, "modelIdentifier": "MacBookPro14,1",
    ]

    private var policyFleet: [[String: Any]] {
        [
            computer("silicon", fileVault: "UNENCRYPTED", sip: "DISABLED", firewall: false,
                     hardware: siliconFacts),
            computer("intel", fileVault: "UNENCRYPTED", hardware: intelFacts),
            computer("unknown-hardware", fileVault: "UNENCRYPTED"),
        ]
    }

    func testWithoutAPolicyNothingIsLabelledAndFailingControlsAreRed() throws {
        let rows = try securityState(policyFleet)
        for name in ["silicon", "intel", "unknown-hardware"] {
            XCTAssertEqual(rows[name]?[2]?.text, "UNENCRYPTED", name)
        }
        XCTAssertEqual(rows["silicon"]?[3]?.format, .red)
        XCTAssertEqual(rows["silicon"]?[4]?.format, .red)
    }

    /// A warning is amber, an ignored control is neutral, and the hardware rule needs the
    /// Mac's own hardware facts: Intel and unknown hardware keep FileVault's level.
    func testDeviceSecurityStateFollowsThePolicy() throws {
        let rows = try securityState(policyFleet, yaml: """
        security_policy:
          controls:
            sip: warning
            firewall: ignore
          filevault_off_hardware_encrypted: warning
        """)
        XCTAssertEqual(rows["silicon"]?[2]?.text, "FileVault off (hardware-encrypted)")
        XCTAssertEqual(rows["silicon"]?[2]?.format, .yellow)
        XCTAssertEqual(rows["silicon"]?[3]?.text, "DISABLED")
        XCTAssertEqual(rows["silicon"]?[3]?.format, .yellow, "SIP is a warning")
        XCTAssertEqual(rows["silicon"]?[4]?.text, "DISABLED")
        XCTAssertEqual(rows["silicon"]?[4]?.format, .cell, "Firewall is not counted")
        XCTAssertEqual(rows["silicon"]?[5]?.format, .green)
        for name in ["intel", "unknown-hardware"] {
            XCTAssertEqual(rows[name]?[2]?.text, "UNENCRYPTED", name)
            XCTAssertEqual(rows[name]?[2]?.format, .red, name)
        }
    }

    func testHardwareRuleAtIgnoreLeavesAHardwareEncryptedMacNeutral() throws {
        let rows = try securityState(policyFleet, yaml: """
        security_policy:
          filevault_off_hardware_encrypted: ignore
        """)
        XCTAssertEqual(rows["silicon"]?[2]?.text, "FileVault off (hardware-encrypted)")
        XCTAssertEqual(rows["silicon"]?[2]?.format, .cell)
        XCTAssertEqual(rows["intel"]?[2]?.format, .red)
    }

    /// A hardware level stricter than FileVault's makes the hardware-encrypted Mac a failure
    /// (no "hardware-encrypted" label, since it is a plain failure), while the others warn.
    func testHardwareRuleStricterThanFileVaultMakesThoseMacsRed() throws {
        let rows = try securityState(policyFleet, yaml: """
        security_policy:
          controls:
            filevault: warning
          filevault_off_hardware_encrypted: fail
        """)
        XCTAssertEqual(rows["silicon"]?[2]?.text, "UNENCRYPTED")
        XCTAssertEqual(rows["silicon"]?[2]?.format, .red)
        XCTAssertEqual(rows["intel"]?[2]?.format, .yellow)
        XCTAssertEqual(rows["unknown-hardware"]?[2]?.format, .yellow)
    }

    // MARK: - Security Posture and Compliance Posture: the hardware rule

    /// `pro report security` shape: `encrypted` Macs with FileVault on, then `silicon` Apple
    /// silicon and `intel` Intel Macs with it off (the `computers` snapshot says which); every
    /// other control is on everywhere. By default ten Macs: seven on, three Apple silicon off.
    private func hardwareDataDir(
        encrypted: Int = 7, silicon: Int = 3, intel: Int = 0
    ) throws -> URL {
        func device(_ name: String, _ serial: String, _ fileVault: String) -> [String: Any] {
            ["section": "device", "name": name, "serial": serial, "os_version": "15.4.1",
             "filevault": fileVault, "sip": "ENABLED", "firewall": true,
             "gatekeeper": "APP_STORE"]
        }
        let total = encrypted + silicon + intel
        var items: [[String: Any]] = [["section": "summary", "data": [
            "total_devices": total, "filevault_encrypted": encrypted, "sip_enabled": total,
            "firewall_enabled": total, "gatekeeper_enabled": total,
        ]]]
        var computers: [[String: Any]] = []
        for n in 0..<encrypted { items.append(device("on\(n)", "ON\(n)", "ENCRYPTED")) }
        for n in 0..<silicon {
            items.append(device("as\(n)", "AS\(n)", "UNENCRYPTED"))
            computers.append(["general": ["name": "as\(n)"],
                              "hardware": ["serialNumber": "AS\(n)", "appleSilicon": true]])
        }
        for n in 0..<intel {
            items.append(device("in\(n)", "IN\(n)", "UNENCRYPTED"))
            computers.append(["general": ["name": "in\(n)"],
                              "hardware": ["serialNumber": "IN\(n)", "appleSilicon": false,
                                           "modelIdentifier": "MacBookPro14,1"]])
        }
        let dir = try makeTempDir()
        try seedJSON(String(decoding: JSONSerialization.data(withJSONObject: items), as: UTF8.self),
                     kind: "security", in: dir)
        try seedComputers(computers, in: dir)
        return dir
    }

    func testSecurityPostureNamesHardwareEncryptedMacsWithFileVaultOff() throws {
        let dir = try hardwareDataDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for level in ["warning", "ignore"] {
            let dash = try dashboard(
                "security_policy:\n  filevault_off_hardware_encrypted: \(level)\n", dataDir: dir)
            try dash.writeSecurity()
            let ws = try XCTUnwrap(dash.workbook.sheet(named: "Security Posture"))
            let cells = ws.dedupedCells
            let fileVault = try row(dash, "Security Posture", "FileVault Encrypted")
            XCTAssertEqual(fileVault[1]?.text, "7 (70.0%)", "the fact stays")
            let extra = try row(dash, "Security Posture", "FileVault off, hardware-encrypted")
            XCTAssertEqual(extra[1]?.text, "3", level)
            let labelRows = cells.filter {
                $0.col == 0 && Self.text($0.value) == "FileVault off, hardware-encrypted"
            }.map(\.row)
            let fileVaultRow = try XCTUnwrap(cells.first {
                $0.col == 0 && Self.text($0.value) == "FileVault Encrypted"
            }?.row)
            XCTAssertEqual(labelRows, [fileVaultRow + 1], "directly after FileVault Encrypted")
        }
    }

    /// Without the rule, at a hardware level equal to FileVault's, or stricter (those Macs are
    /// plain failures), no Mac is named apart.
    func testSecurityPostureHasNoHardwareRowWhenNoMacIsLowered() throws {
        let dir = try hardwareDataDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for yaml in [
            "", "security_policy:\n  filevault_off_hardware_encrypted: fail\n",
            "security_policy:\n  controls:\n    filevault: warning\n" +
                "  filevault_off_hardware_encrypted: fail\n",
        ] {
            let dash = try dashboard(yaml, dataDir: dir)
            try dash.writeSecurity()
            XCTAssertFalse(hasRow(dash, "Security Posture", "FileVault off, hardware-encrypted"),
                           yaml)
        }
    }

    func testCompliancePostureGradesTheControlsUnderThePolicy() throws {
        let dir = try hardwareDataDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let expected: [(yaml: String, status: String, format: CellFormat)] = [
            ("", "RED", .red),
            ("security_policy:\n  filevault_off_hardware_encrypted: warning\n", "AMBER", .yellow),
            ("security_policy:\n  filevault_off_hardware_encrypted: ignore\n", "GREEN", .green),
        ]
        for (yaml, status, format) in expected {
            let dash = try dashboard(yaml, dataDir: dir)
            try dash.writeCompliancePosture()
            let cells = try row(dash, "Compliance Posture", "FileVault Encrypted")
            XCTAssertEqual(cells[1]?.text, "7 (70.0%)", "the value column is the fact")
            XCTAssertEqual(cells[2]?.text, status, yaml)
            XCTAssertEqual(cells[2]?.format, format, yaml)
        }
    }

    /// On the real-shape fixture: SIP at warning turns its red into amber (no Mac fails it),
    /// Firewall at ignore is "Not counted", and the rows that fail nothing stay green.
    func testCompliancePostureShowsWarningsAndNotCountedControls() throws {
        let json = try XCTUnwrap(fixtureData(kind: "security"))
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try seedJSON(json, kind: "security", in: dir)
        let dash = try dashboard("""
        security_policy:
          controls:
            sip: warning
            firewall: ignore
        """, dataDir: dir)
        try dash.writeCompliancePosture()

        let sip = try row(dash, "Compliance Posture", "SIP Enabled")
        XCTAssertEqual(sip[1]?.text, "1 (1.0%)")
        XCTAssertEqual(sip[2]?.text, "AMBER")
        XCTAssertEqual(sip[2]?.format, .yellow)
        let firewall = try row(dash, "Compliance Posture", "Firewall Enabled")
        XCTAssertEqual(firewall[1]?.text, "0 (0.0%)", "the value column is the fact")
        XCTAssertEqual(firewall[2]?.text, "Not counted")
        XCTAssertEqual(firewall[2]?.format, .cell)
        for label in ["FileVault Encrypted", "Gatekeeper Enabled"] {
            let cells = try row(dash, "Compliance Posture", label)
            XCTAssertEqual(cells[2]?.text, "GREEN", label)
            XCTAssertEqual(cells[2]?.format, .green, label)
        }
    }

    /// Ten Macs: five encrypted, three Apple silicon and two Intel with FileVault off, the
    /// hardware level at `ignore`. The three are not counted, so FileVault is graded on 5 of
    /// the 7 Macs left (71.4%, RED), the share the score and the CSV sheet use; with them in
    /// the share it read 8 of 10 (AMBER).
    func testCompliancePostureGradesFileVaultOverTheMacsThatAreCounted() throws {
        let dir = try hardwareDataDir(encrypted: 5, silicon: 3, intel: 2)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dash = try dashboard(
            "security_policy:\n  filevault_off_hardware_encrypted: ignore\n", dataDir: dir)
        try dash.writeCompliancePosture()
        let cells = try row(dash, "Compliance Posture", "FileVault Encrypted")
        XCTAssertEqual(cells[1]?.text, "5 (50.0%)", "the value column is the fact")
        XCTAssertEqual(cells[2]?.text, "RED")
        XCTAssertEqual(cells[2]?.format, .red)

        // At warning the three stay in the share as not failing: 8 of 10.
        let warning = try dashboard(
            "security_policy:\n  filevault_off_hardware_encrypted: warning\n", dataDir: dir)
        try warning.writeCompliancePosture()
        XCTAssertEqual(try row(warning, "Compliance Posture", "FileVault Encrypted")[2]?.text,
                       "AMBER")
    }

    /// Every Mac with FileVault off is hardware-encrypted and not counted, and none is on:
    /// nothing is left to grade, so the row has no status rather than a red one.
    func testCompliancePostureHasNoFileVaultStatusWhenNoMacIsCounted() throws {
        let dir = try hardwareDataDir(encrypted: 0, silicon: 2, intel: 0)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dash = try dashboard(
            "security_policy:\n  filevault_off_hardware_encrypted: ignore\n", dataDir: dir)
        try dash.writeCompliancePosture()
        let cells = try row(dash, "Compliance Posture", "FileVault Encrypted")
        XCTAssertEqual(cells[2]?.text, "\u{2014}")
        XCTAssertEqual(cells[2]?.format, .cell)
    }
}
