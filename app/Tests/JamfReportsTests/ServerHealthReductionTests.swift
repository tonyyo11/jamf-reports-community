import XCTest
@testable import JamfReports

final class ServerHealthReductionTests: XCTestCase {

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: TestFixtures.dir("server-health/\(name)"))
    }

    private func reduced(_ kind: String, _ data: Data) throws -> [String: Any]? {
        guard let out = ServerHealthReduction.reduce(kind: kind, payload: data) else { return nil }
        return try JSONSerialization.jsonObject(with: out) as? [String: Any]
    }

    func testTheCAKeepsOnlyNotAfter() throws {
        let kept = try XCTUnwrap(
            try reduced("certificate-authority", fixture("certificate-authority-active.json")))
        XCTAssertEqual(Array(kept.keys), ["notAfter"])
        XCTAssertEqual(kept["notAfter"] as? Int, 1_893_456_000)
    }

    func testAnExtraKeyAndAPersonKeyAreDropped() throws {
        let payload = Data(#"{"notAfter":1893456000,"owner":"Jane Doe","email":"a@b.c"}"#.utf8)
        let kept = try XCTUnwrap(try reduced("certificate-authority", payload))
        XCTAssertEqual(Array(kept.keys), ["notAfter"])
    }

    func testAListOfOneIsReadAndAnythingElseIsNotSaved() throws {
        let list = Data(#"[{"notAfter":1893456000}]"#.utf8)
        XCTAssertEqual(try reduced("certificate-authority", list)?["notAfter"] as? Int,
                       1_893_456_000)
        for bad in ["\"text\"", "3", "null", "[]"] {
            XCTAssertNil(ServerHealthReduction.reduce(
                kind: "certificate-authority", payload: Data(bad.utf8)), bad)
        }
        XCTAssertNil(ServerHealthReduction.reduce(kind: "computers", payload: list))
    }

    func testAMissingOrNonNumericExpirySavesAnEmptyObject() throws {
        for payload in [#"{"serialNumber":"1"}"#, #"{"notAfter":"soon"}"#, #"{"notAfter":true}"#] {
            let kept = try XCTUnwrap(try reduced("certificate-authority", Data(payload.utf8)))
            XCTAssertTrue(kept.isEmpty, payload)
        }
    }

    func testTheCAReadsAnEnvelopeRowAndKeepsATextExpiry() throws {
        let envelope = Data(#"{"results":[{"notAfter":1893456000}]}"#.utf8)
        XCTAssertEqual(try reduced("certificate-authority", envelope)?["notAfter"] as? Int,
                       1_893_456_000)
        let text = Data(#"{"notAfter":"2030-01-01T00:00:00Z"}"#.utf8)
        XCTAssertEqual(try reduced("certificate-authority", text)?["notAfter"] as? String,
                       "2030-01-01T00:00:00Z")
    }

    func testLAPSFallsBackToTheRowsOfABareListOrNull() throws {
        XCTAssertEqual(try reduced("laps-pending-rotations", Data("[{},{}]".utf8))?["totalCount"]
            as? Int, 2)
        XCTAssertEqual(try reduced("laps-pending-rotations", Data("null".utf8))?["totalCount"]
            as? Int, 0)
        XCTAssertEqual(try reduced("laps-pending-rotations", Data("[]".utf8))?["totalCount"]
            as? Int, 0)
        XCTAssertNil(ServerHealthReduction.reduce(
            kind: "laps-pending-rotations", payload: Data("-3".utf8)))
        XCTAssertNil(ServerHealthReduction.reduce(
            kind: "laps-pending-rotations", payload: Data(#"{"totalCount":-3}"#.utf8)))
        XCTAssertNil(ServerHealthReduction.reduce(
            kind: "laps-pending-rotations", payload: Data(#"{"totalCount":2.7}"#.utf8)))
    }

    func testNotificationsKeepOnlyTheTypeOfEachRow() throws {
        let out = try XCTUnwrap(ServerHealthReduction.reduce(
            kind: "jamf-pro-notifications",
            payload: fixture("jamf-pro-notifications-list.json")))
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: out) as? [[String: Any]])
        XCTAssertEqual(rows.count, 7)
        XCTAssertTrue(rows.allSatisfy { $0.count == 1 }, "only the type is kept")
        XCTAssertEqual(rows.compactMap { $0["type"] as? String }, [
            "BUILT_IN_CA_EXPIRING", "CAN_ENABLE_PASSWORD_RESET_CLOUD_ENVIRONMENT",
            "DEP_INSTANCE_EXPIRED", "EXCEEDED_LICENSE_COUNT", "PATCH_EXTENTION_ATTRIBUTE",
            "PUSH_CERT_EXPIRED", "VPP_ACCOUNT_EXPIRED",
        ])
        let text = String(decoding: out, as: UTF8.self)
        XCTAssertFalse(text.contains("Example"), "params and id are not saved")
    }

    func testNotificationsSaveAnEmptyListAndRefuseAnyOtherShape() throws {
        for empty in ["[]", "null", #"{"results":[]}"#] {
            let out = try XCTUnwrap(ServerHealthReduction.reduce(
                kind: "jamf-pro-notifications", payload: Data(empty.utf8)), empty)
            XCTAssertEqual(String(decoding: out, as: UTF8.self), "[]", empty)
        }
        let odd = try XCTUnwrap(ServerHealthReduction.reduce(
            kind: "jamf-pro-notifications", payload: Data(#"[{"type":5},"x"]"#.utf8)))
        XCTAssertEqual(String(decoding: odd, as: UTF8.self), "[{},{}]")
        for bad in ["\"text\"", "3", #"{"other":1}"#] {
            XCTAssertNil(ServerHealthReduction.reduce(
                kind: "jamf-pro-notifications", payload: Data(bad.utf8)), bad)
        }
    }

    func testTheNotificationsFixtureKeepsTheCapturedShape() throws {
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(
            with: fixture("jamf-pro-notifications-list.json")) as? [[String: Any]])
        XCTAssertTrue(rows.allSatisfy { Set($0.keys) == ["id", "type", "params"] })
        // As captured: `params` is `{}`, `{id, name}` or the patch EA trio, and an `id` in it
        // can be a number.
        let params = rows.compactMap { $0["params"] as? [String: Any] }
        XCTAssertEqual(params.count, rows.count)
        XCTAssertEqual(Set(params.map { $0.keys.sorted() }), [
            [], ["id", "name"], ["extensionAttributeName", "id", "softwareTitleName"],
        ])
        XCTAssertTrue(params.contains { $0["id"] is Int })
    }

    func testListRowsReadsEveryShapeTheEnrollmentReductionDoes() {
        XCTAssertEqual(ReportEngine.listRows(of: NSNull())?.count, 0)
        XCTAssertEqual(ReportEngine.listRows(of: [1, 2] as [Any])?.count, 2)
        XCTAssertEqual(ReportEngine.listRows(of: ["results": [1]] as [String: Any])?.count, 1)
        XCTAssertNil(ReportEngine.listRows(of: ["other": 1] as [String: Any]))
    }

    func testEveryServerHealthKindInTheMatrixHasAFixture() throws {
        let matrixKinds = Set(ReportEngine.collectCommandMatrix(profile: "p", staleDays: 30)
            .map(\.kind)).intersection(ReportEngine.serverHealthKinds)
        XCTAssertEqual(matrixKinds, ReportEngine.serverHealthKinds, "a kind has no matrix row")
        let names = try FileManager.default.contentsOfDirectory(
            atPath: TestFixtures.dir("server-health").path)
        for kind in matrixKinds {
            XCTAssertTrue(names.contains { $0.hasPrefix(kind + "-") && $0.hasSuffix(".json") },
                          "\(kind) has no fixture under Fixtures/server-health")
        }
    }

    func testTheCAFixtureKeepsTheCapturedShape() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: fixture("certificate-authority-active.json")) as? [String: Any])
        XCTAssertEqual(Set(object.keys), [
            "subjectX500Principal", "issuerX500Principal", "serialNumber", "version", "notAfter",
            "notBefore", "signature", "keyUsage", "keyUsageExtended", "sha1Fingerprint",
            "sha256Fingerprint",
        ])
        XCTAssertEqual(String(describing: object["notAfter"] ?? "").count, 10, "epoch seconds")
        XCTAssertEqual((object["keyUsage"] as? [String])?.count, 4)
        XCTAssertEqual((object["keyUsageExtended"] as? [String])?.count, 1)
        let signature = try XCTUnwrap(object["signature"] as? [String: Any])
        XCTAssertEqual(Set(signature.keys), ["algorithm", "algorithmOid", "value"])
    }

    // MARK: - Admin hygiene (opt-in): counts only

    private let now = ISO8601DateFormatter().date(from: "2026-11-25T12:00:00Z")!

    private func counts(_ kind: String, _ payload: Data) throws -> [String: Int] {
        let out = try XCTUnwrap(ServerHealthReduction.reduce(kind: kind, payload: payload, now: now))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: out) as? [String: Int])
    }

    func testAccountCountsFollowTheFixture() throws {
        XCTAssertEqual(try counts("admin-accounts", fixture("admin-accounts-list.json")), [
            "total": 3, "fullAccessLocal": 1, "fullAccessFederated": 1, "withFailedLogins": 1,
            "passwordOlderThanYear": 1, "passwordAgeUnknown": 0, "failedLoginsUnknown": 0,
        ])
    }

    func testAMissingFailedLoginCountIsUnknownNotZero() throws {
        let rows = try counts("admin-accounts", Data("""
            [{"accountType":"FEDERATED","accountStatus":"Enabled"},
             {"failedLoginAttempts":"3"}, {"failedLoginAttempts":2}, {"failedLoginAttempts":0}]
            """.utf8))
        XCTAssertEqual(rows["failedLoginsUnknown"], 2)
        XCTAssertEqual(rows["withFailedLogins"], 1)
    }

    private func account(
        access: String = "FullAccess", privilege: String = "ADMINISTRATOR",
        type: String = "DEFAULT", status: String = "Enabled", failed: Int = 0,
        changed: String? = "2026-11-01T00:00:00"
    ) -> String {
        let date = changed.map { #","lastPasswordChange":"\#($0)""# } ?? ""
        return #"{"accessLevel":"\#(access)","privilegeLevel":"\#(privilege)","accountType":"\#(type)","#
            + #""accountStatus":"\#(status)","failedLoginAttempts":\#(failed)\#(date)}"#
    }

    private func accountCounts(_ rows: String...) throws -> [String: Int] {
        try counts("admin-accounts", Data("[\(rows.joined(separator: ","))]".utf8))
    }

    func testFullAccessNeedsEveryPartAndAnEnabledAccount() throws {
        let rows = try accountCounts(
            account(), account(access: "SiteAccess"), account(privilege: "AUDITOR"),
            account(status: "Disabled"), account(type: "FEDERATED"),
            account(type: "FEDERATED", status: "Disabled"), account(type: "LDAP"))
        XCTAssertEqual(rows["fullAccessLocal"], 1)
        XCTAssertEqual(rows["fullAccessFederated"], 1)
        XCTAssertEqual(rows["total"], 7)
    }

    func testFailedLoginsCountAnyAccountWithAPositiveNumber() throws {
        let rows = try accountCounts(
            account(failed: 1), account(failed: 0), account(status: "Disabled", failed: 9),
            account(type: "FEDERATED", failed: 2))
        XCTAssertEqual(rows["withFailedLogins"], 3)
    }

    /// The date has no zone and is read as UTC, so every Mac counts the same accounts.
    func testPasswordAgeIsMeasuredInUTCAtTheYearBoundary() throws {
        let justInside = try accountCounts(account(changed: "2025-11-25T12:00:01"))
        XCTAssertEqual(justInside["passwordOlderThanYear"], 0)
        let justOutside = try accountCounts(account(changed: "2025-11-25T11:59:59"))
        XCTAssertEqual(justOutside["passwordOlderThanYear"], 1)
        let exactly = try accountCounts(account(changed: "2025-11-25T12:00:00"))
        XCTAssertEqual(exactly["passwordOlderThanYear"], 0, "over a year means more than 365 days")
    }

    func testAMissingOrUnparsablePasswordDateIsUnknownNotOld() throws {
        let rows = try accountCounts(
            account(changed: nil), account(changed: "last week"),
            account(changed: "2025-01-01T00:00:00Z"), account(changed: "2026-11-01T00:00:00"))
        XCTAssertEqual(rows["passwordAgeUnknown"], 3)
        XCTAssertEqual(rows["passwordOlderThanYear"], 0)
    }

    func testOnlyEnabledLocalAccountsAreJudgedForPasswordAge() throws {
        let rows = try accountCounts(
            account(type: "FEDERATED", changed: "2020-01-01T00:00:00"),
            account(status: "Disabled", changed: nil),
            account(type: "DEFAULT", status: "Disabled", changed: "2020-01-01T00:00:00"))
        XCTAssertEqual(rows["passwordOlderThanYear"], 0)
        XCTAssertEqual(rows["passwordAgeUnknown"], 0)
    }

    func testAnEmptyAccountListIsARealZeroAndAnotherShapeIsNotSaved() throws {
        XCTAssertEqual(try counts("admin-accounts", Data("[]".utf8))["total"], 0)
        XCTAssertEqual(try counts("admin-accounts", Data("null".utf8))["total"], 0)
        XCTAssertNil(ServerHealthReduction.reduce(
            kind: "admin-accounts", payload: Data(#""text""#.utf8), now: now))
    }

    func testAPIClientCounts() throws {
        XCTAssertEqual(try counts("api-integrations", fixture("api-integrations-list.json")), [
            "total": 3, "disabled": 1, "enabledWithTokenOverOneDay": 1,
            "tokenLifetimeUnknown": 0, "enabledUnknown": 0,
        ])
        func client(enabled: String, seconds: Int) -> String {
            #"{"enabled":\#(enabled),"accessTokenLifetimeSeconds":\#(seconds)}"#
        }
        let rows = try counts("api-integrations", Data("""
            [\(client(enabled: "true", seconds: 86_400)), \(client(enabled: "true", seconds: 86_401)),
             \(client(enabled: "false", seconds: 999_999)), {"enabled":"yes","accessTokenLifetimeSeconds":9}]
            """.utf8))
        XCTAssertEqual(rows, ["total": 4, "disabled": 1, "enabledWithTokenOverOneDay": 1,
                              "tokenLifetimeUnknown": 0, "enabledUnknown": 1],
                       "a day exactly is not over a day; a non-boolean flag is counted unknown")
        let unknown = try counts("api-integrations", Data("""
            [{"enabled":true}, {"enabled":true,"accessTokenLifetimeSeconds":"x"},
             {"enabled":true,"accessTokenLifetimeSeconds":60}, {"accessTokenLifetimeSeconds":9}]
            """.utf8))
        XCTAssertEqual(unknown["tokenLifetimeUnknown"], 2)
        XCTAssertEqual(unknown["enabledUnknown"], 1)
        XCTAssertEqual(unknown["enabledWithTokenOverOneDay"], 0)
    }

    func testLAPSKeepsOnlyTheCount() throws {
        XCTAssertEqual(
            try counts("laps-pending-rotations",
                       fixture("laps-pending-rotations-list.json")), ["totalCount": 0])
        XCTAssertEqual(try counts("laps-pending-rotations",
                                  Data(#"{"totalCount":2,"results":[{},{}]}"#.utf8)),
                       ["totalCount": 2])
        XCTAssertEqual(try counts("laps-pending-rotations", Data(#"{"results":[1,2,3]}"#.utf8)),
                       ["totalCount": 3])
        // A bare list or null counts its rows, so `[]` is a measured zero (see the fallback test).
        for bad in ["\"x\"", #"{"totalCount":"2"}"#, #"{"totalCount":-1}"#, "{}"] {
            XCTAssertNil(ServerHealthReduction.reduce(
                kind: "laps-pending-rotations", payload: Data(bad.utf8), now: now), bad)
        }
    }

    /// Whatever `keep_account_names` says, no person or credential reaches the saved document.
    func testNoNameEmailClientIDOrDisplayNameIsSaved() throws {
        let saved = try ["admin-accounts-list.json", "api-integrations-list.json",
                         "laps-pending-rotations-list.json"].map { name -> String in
            let kind = name.replacingOccurrences(of: "-list.json", with: "")
            let out = try XCTUnwrap(ServerHealthReduction.reduce(
                kind: kind, payload: fixture(name), now: now))
            return String(decoding: out, as: UTF8.self)
        }.joined()
        for leaked in ["example.admin", "Example", "example.com", "555-0100", "00000000-0000",
                       "CN=", "username", "realname", "email", "clientId", "displayName"] {
            XCTAssertFalse(saved.contains(leaked), leaked)
        }
    }

    func testTheOptInFixturesKeepTheCapturedShape() throws {
        let account = try XCTUnwrap(JSONSerialization.jsonObject(
            with: fixture("admin-accounts-list.json")) as? [[String: Any]])
        XCTAssertEqual(Set(account[0].keys), [
            "id", "username", "realname", "email", "phone", "distinguishedName", "siteId",
            "accessLevel", "privilegeLevel", "failedLoginAttempts", "accountStatus",
            "accountType", "ropfMigrationScope", "ldapServerId", "lastPasswordChange",
            "changePasswordOnNextLogin",
        ])
        let client = try XCTUnwrap(JSONSerialization.jsonObject(
            with: fixture("api-integrations-list.json")) as? [[String: Any]])
        XCTAssertEqual(Set(client[0].keys), [
            "authorizationScopes", "displayName", "enabled", "accessTokenLifetimeSeconds", "id",
            "appType", "clientId",
        ])
        let laps = try XCTUnwrap(JSONSerialization.jsonObject(
            with: fixture("laps-pending-rotations-list.json")) as? [String: Any])
        XCTAssertEqual(Set(laps.keys), ["totalCount", "results"])
        XCTAssertEqual((laps["results"] as? [Any])?.isEmpty, true, "no captured row shape yet")
    }

    func testAMalformedAccountsPayloadIsNotSavedAndRecordsAFailure() throws {
        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shr-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dataDir) }
        let store = StateFileStore(directory: dataDir.appendingPathComponent("state"))
        final class Lines: @unchecked Sendable {
            let lock = NSLock()
            var texts: [String] = []
            func add(_ line: CLIBridge.LogLine) { lock.lock(); texts.append(line.text); lock.unlock() }
        }
        let lines = Lines()
        let kind = ServerHealth.accountsKind
        let result = try ReportEngine.saveCollectedPayload(
            kind: kind, data: Data(#"{"oops":true}"#.utf8),
            outcome: ReportEngine.CollectOutcome(kind: kind, exitCode: 0),
            isPartialFailure: false, dataDir: dataDir, recordManifest: false,
            stateStore: store, collectStart: Date(), onLine: lines.add)
        XCTAssertFalse(result.saved)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dataDir.appendingPathComponent(kind).path))
        XCTAssertNotNil(store.failures(report: kind), "a failure is recorded")
        XCTAssertTrue(lines.texts.contains { $0.contains("unexpected payload shape") })
    }
}
