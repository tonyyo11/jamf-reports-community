import Foundation
import XCTest
@testable import JamfReports

/// The saved `mobile-devices-list` snapshot drops lost-mode text (phone number, location,
/// message, footnote): nothing reads it and the snapshot can sync to a shared folder.
final class MobileLostModeTextTests: XCTestCase {

    private var dataDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dataDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("JRC-LostMode-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dataDir)
        try super.tearDownWithError()
    }

    func testCollectedMobileListIsSavedWithoutLostModeText() throws {
        let saved = try saveAndRead(kind: MobileFleetService.deviceKind, payload: Self.record)
        let record = try XCTUnwrap(saved.first)
        let security = try XCTUnwrap(record["security"] as? [String: Any])

        for key in ReportEngine.lostModeTextKeys {
            XCTAssertNil(security[key], key)
        }
        XCTAssertEqual(security["lostModeEnabled"] as? Bool, true)
        XCTAssertEqual(security["passcodeCompliant"] as? Bool, true)
        XCTAssertEqual((record["general"] as? [String: Any])?["udid"] as? String, "UDID-1")
    }

    /// Only the mobile list loses lost-mode text.
    func testOtherKindsKeepLostModeText() throws {
        let saved = try saveAndRead(kind: "computers", payload: Self.record)
        let security = try XCTUnwrap(saved.first?["security"] as? [String: Any])
        XCTAssertEqual(security["lostModeMessage"] as? String, "Call the help desk")
    }

    /// The computers snapshot keeps the PO date and no other purchasing detail.
    func testCollectedComputersKeepOnlyThePODate() throws {
        let saved = try saveAndRead(kind: "computers", payload: Self.purchasingRecord)
        let purchasing = try XCTUnwrap(saved.first?["purchasing"] as? [String: Any])
        XCTAssertEqual(purchasing as? [String: String], ["poDate": "2022-06-01"])
        XCTAssertEqual((saved.first?["general"] as? [String: Any])?["name"] as? String, "Mac-A")
    }

    func testPurchasingOnAnotherKindIsSavedAsPrinted() throws {
        let saved = try saveAndRead(kind: "policies", payload: Self.purchasingRecord)
        let purchasing = try XCTUnwrap(saved.first?["purchasing"] as? [String: Any])
        XCTAssertEqual(purchasing["purchasePrice"] as? String, "$500")
    }

    func testComputersWithNothingToRemoveKeepTheirBytes() {
        let null = Data(#"[{"id":"1","purchasing":null}]"#.utf8)
        XCTAssertEqual(ReportEngine.reducingComputers(null), null)
        let dateOnly = Data(#"[{"id":"1","purchasing":{"poDate":"2022-06-01"}}]"#.utf8)
        XCTAssertEqual(ReportEngine.reducingComputers(dateOnly), dateOnly)
    }

    func testAPayloadThatDoesNotParseIsNotSavedWithPurchasingDetails() throws {
        XCTAssertNil(ReportEngine.reducingComputers(Data("{".utf8)))
    }

    func testPayloadWithoutTheKeysKeepsItsBytes() {
        let data = Data(#"[{"security":{"lostModeEnabled":false}}]"#.utf8)
        XCTAssertEqual(ReportEngine.droppingLostModeText(data), data)
    }

    /// A payload the strip cannot parse is not saved: the previous snapshot stays newest.
    func testUnparseablePayloadIsNotSavedAndWarns() throws {
        XCTAssertNil(ReportEngine.droppingLostModeText(Data("5".utf8)))

        let kind = MobileFleetService.deviceKind
        let lines = LineBox()
        let result = try ReportEngine.saveCollectedPayload(
            kind: kind, data: Data("5".utf8),
            outcome: ReportEngine.CollectOutcome(kind: kind, exitCode: 0),
            isPartialFailure: false, dataDir: dataDir, recordManifest: false,
            stateStore: nil, collectStart: Date(), onLine: lines.append)

        XCTAssertFalse(result.saved)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dataDir.appendingPathComponent(kind).path), "nothing may reach disk")
        XCTAssertEqual(lines.texts.filter { $0.hasPrefix("[warn] \(kind)") }.count, 1)
    }

    func testAListThatCouldNotBeStrippedNeedsAttentionAndASavedOneClearsIt() throws {
        let kind = MobileFleetService.deviceKind
        func changes(_ payload: String) throws -> [AttentionCode: AttentionChange] {
            let log = AttentionLog(profile: "p", usesAppRecord: false)
            _ = try AttentionLog.$current.withValue(log) {
                try ReportEngine.saveCollectedPayload(
                    kind: kind, data: Data(payload.utf8),
                    outcome: ReportEngine.CollectOutcome(kind: kind, exitCode: 0),
                    isPartialFailure: false, dataDir: dataDir, recordManifest: false,
                    stateStore: nil, collectStart: Date(), onLine: { _ in })
            }
            return log.changes
        }
        XCTAssertEqual(try changes("5"), [.lostModeStripFailed: .raised(
            "Mobile device list not saved: lost-mode text not removed")])
        XCTAssertEqual(try changes(Self.record), [.lostModeStripFailed: .cleared])
    }

    // MARK: - Account names

    func testComputersLoseExactlyTheAccountNameKeys() throws {
        let saved = try saveAndRead(kind: "computers", payload: Self.accountRecord)
        let row = try XCTUnwrap(saved.first)
        let general = try XCTUnwrap(row["general"] as? [String: Any])
        let mdm = try XCTUnwrap(general["mdmCapable"] as? [String: Any])
        XCTAssertEqual(Set(mdm.keys), ["capable"])
        XCTAssertEqual(Set(general.keys), [
            "name", "mdmCapable", "lastLoggedInUsernameBinaryTimestamp",
            "lastLoggedInUsernameMdmTimestamp", "lastLoggedInUsernameSelfServiceTimestamp",
        ])
        let disk = try XCTUnwrap(row["diskEncryption"] as? [String: Any])
        XCTAssertEqual(Set(disk.keys), ["fileVault2Enabled"])
        let user = try XCTUnwrap(row["userAndLocation"] as? [String: Any])
        XCTAssertEqual(Set(user.keys), ["username", "email"])
        XCTAssertEqual((row["purchasing"] as? [String: Any])?["poDate"] as? String, "2022-06-01")
    }

    func testKeepAccountNamesLeavesThemAndStillCutsPurchasing() throws {
        let saved = try saveAndRead(
            kind: "computers", payload: Self.accountRecord, keepAccountNames: true)
        let row = try XCTUnwrap(saved.first)
        let general = try XCTUnwrap(row["general"] as? [String: Any])
        XCTAssertEqual(general["lastLoggedInUsernameMdm"] as? String, "placeholder-user")
        XCTAssertNotNil((general["mdmCapable"] as? [String: Any])?["capableUsers"])
        XCTAssertNotNil((row["diskEncryption"] as? [String: Any])?["fileVault2EnabledUserNames"])
        XCTAssertEqual(
            (row["userAndLocation"] as? [String: Any])?["realname"] as? String, "Placeholder Name")
        XCTAssertEqual((row["purchasing"] as? [String: Any])?.keys.sorted(), ["poDate"])
    }

    /// Valid JSON the reducer rejects (an object, not a list of rows) takes the failure path.
    /// A computers payload cannot: whatever parses also serializes, and `{` never reaches it.
    func testAnEnrollmentPayloadThatCannotBeReducedIsNotSavedAndFails() throws {
        let kind = ReportEngine.enrollmentInstancesKind
        let lines = LineBox()
        let stateDir = dataDir.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let store = StateFileStore(directory: stateDir)
        let result = try ReportEngine.saveCollectedPayload(
            kind: kind, data: Data(#"{"id": "1"}"#.utf8),
            outcome: ReportEngine.CollectOutcome(kind: kind, exitCode: 0),
            isPartialFailure: false, dataDir: dataDir, recordManifest: false,
            stateStore: store, collectStart: Date(), onLine: lines.append)
        XCTAssertFalse(result.saved)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dataDir.appendingPathComponent(kind).path))
        XCTAssertEqual(store.lastFailureExitCode(for: kind), 0, "the failure is recorded")
        XCTAssertEqual(lines.texts.filter { $0.hasPrefix("[warn] \(kind)") }.count, 1)
        XCTAssertTrue(lines.texts.contains { $0.contains("contact details") })
    }

    func testEnrollmentInstancesKeepFourKeys() throws {
        let kind = ReportEngine.enrollmentInstancesKind
        let payload = #"""
            [{"id": "1", "name": "Placeholder ADE", "serverName": "Placeholder Server",
              "tokenExpirationDate": "2027-01-01", "adminId": "admin-x",
              "orgEmail": "org@example.com", "orgPhone": "555-0100", "orgAddress": "1 Example St",
              "serverUuid": "uuid-x", "orgName": "Example Org"}]
            """#
        let saved = try saveAndRead(kind: kind, payload: payload)
        XCTAssertEqual(
            Set(try XCTUnwrap(saved.first).keys),
            ["id", "name", "serverName", "tokenExpirationDate"])
        let kept = try saveAndRead(kind: kind, payload: payload, keepAccountNames: true)
        XCTAssertEqual(try XCTUnwrap(kept.first).keys.count, 10)
        XCTAssertNil(ReportEngine.keepingEnrollmentIdentity(Data(#"{"id":"1"}"#.utf8)))
        XCTAssertNil(ReportEngine.reducingComputers(Data("{".utf8)))
    }

    func testMobileListLosesTheSelfServiceUsernameAndContactKeys() throws {
        let kind = MobileFleetService.deviceKind
        let payload = #"""
            [{"id": "7",
              "general": {"udid": "U-1", "lastLoggedInUsernameSelfService": "placeholder"},
              "userAndLocation": {"username": "placeholder", "emailAddress": "a@example.com",
                                  "realName": "Placeholder Name", "phoneNumber": "555-0100",
                                  "position": "Role", "room": "1"},
              "security": {"lostModeEnabled": false}}]
            """#
        let saved = try XCTUnwrap(saveAndRead(kind: kind, payload: payload).first)
        XCTAssertEqual(Set((saved["general"] as? [String: Any] ?? [:]).keys), ["udid"])
        XCTAssertEqual(
            Set((saved["userAndLocation"] as? [String: Any] ?? [:]).keys),
            ["username", "emailAddress"])
        let kept = try XCTUnwrap(
            saveAndRead(kind: kind, payload: payload, keepAccountNames: true).first)
        XCTAssertNotNil((kept["general"] as? [String: Any])?["lastLoggedInUsernameSelfService"])
    }

    /// jamf-cli prints an empty Go slice as `null`: a valid empty answer for every reducer.
    func testEmptyListsAreSavedAsTheyAreForAllThreeReducers() throws {
        let kinds = [
            "computers", MobileFleetService.deviceKind, ReportEngine.enrollmentInstancesKind,
        ]
        for kind in kinds {
            for payload in ["null", "[]"] {
                let stateDir = dataDir.appendingPathComponent("state-\(kind)-\(payload.count)")
                try FileManager.default.createDirectory(
                    at: stateDir, withIntermediateDirectories: true)
                let store = StateFileStore(directory: stateDir)
                let result = try ReportEngine.saveCollectedPayload(
                    kind: kind, data: Data(payload.utf8),
                    outcome: ReportEngine.CollectOutcome(kind: kind, exitCode: 0),
                    isPartialFailure: false, dataDir: dataDir, recordManifest: false,
                    stateStore: store, collectStart: Date(), onLine: { _ in })
                XCTAssertTrue(result.saved, "\(kind) \(payload)")
                XCTAssertNil(store.lastFailureExitCode(for: kind), "\(kind) \(payload)")
            }
        }
    }

    func testAnEnvelopeOfEnrollmentRowsIsReducedInsideResults() throws {
        let data = Data(
            #"{"totalCount":1,"results":[{"id":"1","orgEmail":"o@example.com"}]}"#.utf8)
        let reduced = try XCTUnwrap(ReportEngine.keepingEnrollmentIdentity(data))
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: reduced) as? [String: Any])
        XCTAssertEqual(object["totalCount"] as? Int, 1)
        let rows = try XCTUnwrap(object["results"] as? [[String: Any]])
        XCTAssertEqual(Set(try XCTUnwrap(rows.first).keys), ["id"])
    }

    func testComputersEnvelopeIsReducedLikeABareList() throws {
        let data = Data(
            #"{"totalCount":1,"results":[{"general":{"lastLoggedInUsernameMdm":"x"}}]}"#.utf8)
        let reduced = try XCTUnwrap(ReportEngine.reducingComputers(data))
        XCTAssertFalse(String(decoding: reduced, as: UTF8.self).contains("lastLoggedIn"))
    }

    func testSharedIPadUserListsAreRemovedWhateverTheirValue() throws {
        for value in ["null", #"[{"username":"placeholder"}]"#] {
            let payload = """
                [{"id":"7","sharedUsers":\(value),"userProfiles":\(value),
                  "general":{"udid":"U-1","residentUsers":\(value)}}]
                """
            let row = try XCTUnwrap(
                saveAndRead(kind: MobileFleetService.deviceKind, payload: payload).first)
            XCTAssertEqual(Set(row.keys), ["id", "general"], value)
            XCTAssertEqual(Set((row["general"] as? [String: Any] ?? [:]).keys), ["udid"], value)
            let kept = try XCTUnwrap(saveAndRead(
                kind: MobileFleetService.deviceKind, payload: payload,
                keepAccountNames: true).first)
            XCTAssertNotNil(kept["sharedUsers"], value)
        }
    }

    func testRemoteManagementUsernameGoesButTheManagedFlagStays() throws {
        let payload = #"[{"id":"1","general":{"remoteManagement":"#
            + #"{"managed":true,"managementUsername":"placeholder"}}}]"#
        let row = try XCTUnwrap(saveAndRead(kind: "computers", payload: payload).first)
        let remote = try XCTUnwrap(
            (row["general"] as? [String: Any])?["remoteManagement"] as? [String: Any])
        XCTAssertEqual(Set(remote.keys), ["managed"])
    }

    func testStatusReportsLoseDeviceUsernamesAndKeepWhatTheReadersDecode() throws {
        for kind in ["app-status", "profile-status"] {
            let payload = #"[{"summary":{"days":7},"failures":[{"name":"P","errors":1}],"#
                + #""device_failures":[{"device":"Mac-A","username":"placeholder"}],"#
                + #""device_pending":[{"device":"Mac-B","username":"placeholder"}]}]"#
            let row = try XCTUnwrap(saveAndRead(kind: kind, payload: payload).first)
            XCTAssertNotNil(row["summary"], kind)
            XCTAssertNotNil(row["failures"], kind)
            for key in ["device_failures", "device_pending"] {
                let devices = try XCTUnwrap(row[key] as? [[String: Any]])
                XCTAssertEqual(Set(try XCTUnwrap(devices.first).keys), ["device"], kind)
            }
            let kept = try XCTUnwrap(
                saveAndRead(kind: kind, payload: payload, keepAccountNames: true).first)
            XCTAssertNotNil((kept["device_failures"] as? [[String: Any]])?.first?["username"])
        }
        XCTAssertNotNil(ReportEngine.droppingAccountNames(
            Data("null".utf8), table: ReportEngine.statusReportAccountNameKeys))
    }

    func testMobileDetailDropsPurchasingNetworkPhoneAndUserListsInEitherShape() throws {
        let payload = #"{"location":{"username":"u","realName":"R","phoneNumber":"1"},"#
            + #""ios":{"mdmCapableUsers":["x"],"purchasing":{"vendor":"V","poNumber":"1"}},"#
            + #""network":{"phoneNumber":"1","wifiMacAddress":"m"},"purchasing":{"vendor":"V"}}"#
        let reduced = try XCTUnwrap(ReportEngine.reducingDeviceDetail(
            Data(payload.utf8), mobile: true, keepAccountNames: false))
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: reduced) as? [String: Any])
        XCTAssertEqual(Set((object["location"] as? [String: Any] ?? [:]).keys), ["username"])
        let ios = try XCTUnwrap(object["ios"] as? [String: Any])
        XCTAssertNil(ios["mdmCapableUsers"])
        XCTAssertEqual((ios["purchasing"] as? [String: Any])?.count, 0)
        XCTAssertEqual((object["purchasing"] as? [String: Any])?.count, 0)
        XCTAssertEqual(Set((object["network"] as? [String: Any] ?? [:]).keys), ["wifiMacAddress"])
    }

    // MARK: - Device detail flat rows

    private func flat(_ rows: String, keep: Bool = false) -> Data? {
        ReportEngine.reducingDeviceDetail(Data(rows.utf8), mobile: false, keepAccountNames: keep)
    }

    func testFlatRowsMatchContactLabelsInAnySectionCaseAndKeepHistoryRows() throws {
        let rows = #"""
            [{"section":"USER & location","resource":"  FULL NAME ","value":"x"},
             {"section":"Contact","resource":"Phone Number","value":"x"},
             {"section":"User & Location","resource":"Username","value":"x"},
             {"section":"Identity","resource":"Last Logged In User","value":"x"},
             {"section":"MDM Command History (Last 10)","resource":"Last Logged In User","value":"x"},
             {"section":"Policy History (Last 10)","resource":"Full Name","value":"x"}]
            """#
        let reduced = try XCTUnwrap(flat(rows))
        let kept = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: reduced) as? [[String: Any]])
        XCTAssertEqual(kept.map { $0["section"] as? String }, [
            "User & Location", "MDM Command History (Last 10)", "Policy History (Last 10)",
        ])
    }

    /// Fails closed: an array with a non-object element is not cached.
    func testAnArrayWithAnythingButObjectsIsNotCached() {
        XCTAssertNil(flat(#"[{"section":"Identity","resource":"Name"}, 5]"#))
        XCTAssertNil(flat(#"[{"section":"Identity","resource":"Name"}, null]"#))
        XCTAssertNotNil(flat("[]"))
        XCTAssertNotNil(flat("null"))
    }

    // MARK: - Fixtures

    private static let accountRecord = #"""
        [{"id": "1",
          "general": {"name": "Mac-A",
                      "mdmCapable": {"capable": true, "capableUsers": ["placeholder-user"],
                                     "userManagementInfo": [{"username": "placeholder-user"}]},
                      "lastLoggedInUsernameBinary": "placeholder-user",
                      "lastLoggedInUsernameBinaryTimestamp": "2026-01-01T00:00:00Z",
                      "lastLoggedInUsernameMdm": "placeholder-user",
                      "lastLoggedInUsernameMdmTimestamp": "2026-01-01T00:00:00Z",
                      "lastLoggedInUsernameSelfService": "placeholder-user",
                      "lastLoggedInUsernameSelfServiceTimestamp": "2026-01-01T00:00:00Z"},
          "diskEncryption": {"fileVault2Enabled": true,
                             "fileVault2EnabledUserNames": ["placeholder-user"]},
          "userAndLocation": {"username": "placeholder-user", "email": "a@example.com",
                              "realname": "Placeholder Name", "phone": "555-0100",
                              "position": "Role", "room": "1"},
          "purchasing": {"poDate": "2022-06-01", "vendor": "Example Vendor"}}]
        """#

    private static let record = #"""
        [{"id": "7",
          "general": {"udid": "UDID-1", "managed": true},
          "security": {"lostModeEnabled": true, "passcodeCompliant": true,
                       "lostModePhoneNumber": "555-0100", "lostModeLocation": "Building 4",
                       "lostModeMessage": "Call the help desk", "lostModeFootnote": "Reward"}}]
        """#

    private static let purchasingRecord = #"""
        [{"id": "1", "general": {"name": "Mac-A"},
          "purchasing": {"poDate": "2022-06-01", "poNumber": "53-1", "purchasePrice": "$500",
                         "vendor": "Example Vendor", "warrantyDate": "2025-06-01"}}]
        """#

    private func saveAndRead(
        kind: String, payload: String, keepAccountNames: Bool = false
    ) throws -> [[String: Any]] {
        let data = Data(payload.utf8)
        let folder = dataDir.appendingPathComponent(kind, isDirectory: true)
        // An earlier save's file would be read back instead, in whatever order the folder lists.
        try? FileManager.default.removeItem(at: folder)
        let result = try ReportEngine.saveCollectedPayload(
            kind: kind, data: data,
            outcome: ReportEngine.CollectOutcome(kind: kind, exitCode: 0),
            isPartialFailure: false, dataDir: dataDir, recordManifest: false,
            keepAccountNames: keepAccountNames, stateStore: nil, collectStart: Date(),
            onLine: { _ in }
        )
        XCTAssertTrue(result.saved)
        let file = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "json" })
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file))
        return try XCTUnwrap(object as? [[String: Any]])
    }
}

private final class LineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    var append: @Sendable (CLIBridge.LogLine) -> Void {
        { line in
            self.lock.lock(); defer { self.lock.unlock() }
            self.lines.append(line.text)
        }
    }

    var texts: [String] {
        lock.lock(); defer { lock.unlock() }
        return lines
    }
}
