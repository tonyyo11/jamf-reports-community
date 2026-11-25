import XCTest
@testable import JamfReports

final class ServerHealthTests: XCTestCase {

    private var dir: URL!
    private let kind = "certificate-authority"
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent(kind), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        try super.tearDownWithError()
    }

    private var store: StateFileStore { StateFileStore(directory: dir.appendingPathComponent("state")) }

    private func snapshot(_ json: String) throws {
        try json.write(
            to: dir.appendingPathComponent("\(kind)/\(kind)_20260921T120000.json"),
            atomically: true, encoding: .utf8)
    }

    private func fact(warning: Int = 90) -> ServerHealth.FactState? {
        ServerHealth.load(dataDir: dir, warningDays: warning, now: now).credentials.first?.fact
    }

    private func fail(_ cause: FailureCause.Kind, names: [String] = [], exit: Int32) {
        store.record(.failed(exitCode: exit), report: kind, at: now,
                     cause: FailureCause(kind: cause, names: names, hint: nil, exitCode: exit))
    }

    func testNeverAttemptedIsNotCollectedAndTheCardHasNothingToSay() {
        let health = ServerHealth.load(dataDir: dir, warningDays: 90, now: now)
        XCTAssertEqual(fact(), .notCollected)
        XCTAssertFalse(health.hasAttempt)
    }

    func testALandedCredentialIsAValue() throws {
        try snapshot(#"{"notAfter":\#(Int(now.timeIntervalSince1970) + 40 * 86_400)}"#)
        guard case .value(.credential(let credential), let stale)? = fact() else {
            return XCTFail("expected a value")
        }
        XCTAssertEqual(credential.state, .expiring)
        XCTAssertEqual(credential.daysLeft, 40)
        XCTAssertNil(stale)
        let asOf = ServerHealth.load(dataDir: dir, warningDays: 90, now: now).credentials[0].asOf
        XCTAssertNotNil(asOf, "the snapshot's own stamp")
    }

    func testAnEmptyObjectIsExpiryNotReportedNotAnExpiringCredential() throws {
        try snapshot("{}")
        let health = ServerHealth.load(dataDir: dir, warningDays: 90, now: now)
        guard case .value(.credential(let credential), _)? = health.credentials.first?.fact else {
            return XCTFail("expected a value")
        }
        XCTAssertEqual(credential.state, .notReported)
        XCTAssertTrue(health.expiringCredentials.isEmpty)
        XCTAssertEqual(ServerHealth.text(for: health.credentials[0].fact), "Expiry not reported")
    }

    func testARefusalWithNoSnapshotIsNotPermittedWithJamfCLIsNames() {
        fail(.missingPermission, names: ["Read SSO Settings"], exit: 5)
        XCTAssertEqual(fact(), .notPermitted(["Read SSO Settings"]))
        XCTAssertEqual(ServerHealth.text(for: .notPermitted(["Read SSO Settings"])),
                       "Not permitted: Read SSO Settings")
    }

    func testARefusalNamingNothingSaysOnlyThat() {
        fail(.missingPermission, exit: 5)
        XCTAssertEqual(fact(), .notPermitted([]))
        XCTAssertEqual(ServerHealth.text(for: .notPermitted([])), "Not permitted for this login")
    }

    func testNotConfiguredWinsEvenOverAnOlderSnapshot() throws {
        try snapshot(#"{"notAfter":1893456000}"#)
        fail(.notConfiguredOnServer, exit: 4)
        XCTAssertEqual(fact(), .notConfigured)
    }

    func testAFailureWithNoSnapshotIsFailedWithItsCause() {
        fail(.other, exit: 1)
        XCTAssertEqual(fact(), .failed("exit 1"))
    }

    func testAFailureAfterALandingKeepsTheValueMarkedStale() throws {
        try snapshot(#"{"notAfter":1893456000}"#)
        store.record(.landed, report: kind, at: now.addingTimeInterval(-3_600))
        fail(.other, exit: 1)
        guard case .value(_, let stale)? = fact() else { return XCTFail("expected a value") }
        XCTAssertNotNil(stale)
    }

    func testAnUnreadableSnapshotIsUnreadable() throws {
        try snapshot("not json")
        XCTAssertEqual(fact(), .unreadable)
    }

    func testTheCredentialWordsNameDaysAndExpiry() {
        func credential(_ offsetDays: Int) -> CredentialExpiry {
            CredentialExpiry(
                key: "ca", label: "x", raw: Int(now.timeIntervalSince1970) + offsetDays * 86_400,
                warningDays: 90, now: now)
        }
        XCTAssertTrue(ServerHealth.credentialText(credential(40)).hasPrefix("Expires in 40 days ("))
        XCTAssertTrue(ServerHealth.credentialText(credential(-3)).hasPrefix("Expired 3 days ago ("))
    }

    func testTheDemoCredentialExpiresFortyDaysAfterTheReferenceDate() {
        guard case .value(.credential(let credential), _) = DemoData.serverHealth.credentials[0].fact
        else { return XCTFail("expected a value") }
        XCTAssertEqual(credential.daysLeft, 40)
        XCTAssertEqual(credential.state, .expiring)
    }

    func testTheHtmlSentenceNamesTheCredentialAndDays() {
        let soon = CredentialExpiry(
            key: "ca", label: "x", raw: Int(now.timeIntervalSince1970) + 40 * 86_400,
            warningDays: 90, now: now)
        XCTAssertEqual(HtmlReport.credentialSentence(soon),
                       "The Jamf Pro built-in CA expires in 40 days.")
        let past = CredentialExpiry(
            key: "ca", label: "x", raw: Int(now.timeIntervalSince1970) - 3 * 86_400,
            warningDays: 90, now: now)
        XCTAssertEqual(HtmlReport.credentialSentence(past),
                       "The Jamf Pro built-in CA expired 3 days ago.")
    }

    func testTheDoctorRowListsOnlyRefusalsAndNeverInventsAPrivilege() {
        let named = FailureCause(kind: .missingPermission, names: ["Read X"], hint: nil, exitCode: 5)
        let bare = FailureCause(kind: .missingPermission, names: [], hint: nil, exitCode: 5)
        let notSet = FailureCause(kind: .notConfiguredOnServer, names: [], hint: nil, exitCode: 4)
        XCTAssertTrue(ConfigDoctorService.serverHealthRows(refused: [kind: notSet]).isEmpty)
        let row = ConfigDoctorService.serverHealthRows(refused: [kind: named]).first
        XCTAssertEqual(row?.id, "server_health.not_permitted")
        XCTAssertTrue(row?.detail.contains("Read X") == true)
        let none = ConfigDoctorService.serverHealthRows(refused: [kind: bare]).first
        XCTAssertTrue(none?.detail.contains("cannot read") == true)
    }

    func testAJamfSchoolWorkspaceGetsNoDoctorRowAndNoTab() throws {
        let config = try ConfigLoader.loadFromString("school_cli:\n  enabled: true\n")
        XCTAssertEqual(ProfileProductType.detect(from: config, profile: "schoolws").type,
                       .jamfSchool)
        XCTAssertTrue(ConfigDoctorService.serverHealthRows(profile: "schoolws", config: config)
            .isEmpty)
        XCTAssertFalse(SchoolDashboard.sheetNames.contains(SheetID.serverAdminHealth.rawValue))
    }

    // MARK: - Notifications

    private func notifications(_ json: String) throws -> ServerHealth {
        let notices = dir.appendingPathComponent("jamf-pro-notifications", isDirectory: true)
        try FileManager.default.createDirectory(at: notices, withIntermediateDirectories: true)
        try json.write(
            to: notices.appendingPathComponent("jamf-pro-notifications_20260921T120000.json"),
            atomically: true, encoding: .utf8)
        return ServerHealth.load(dataDir: dir, warningDays: 90, now: now)
    }

    func testZeroNotificationsReadNoneVisibleToThisLogin() throws {
        let health = try notifications("[]")
        XCTAssertEqual(health.notificationFigure?.value.total, 0)
        XCTAssertEqual(ServerHealth.text(for: health.notifications), "None visible to this login")
        XCTAssertTrue(health.hasAttempt)
    }

    func testTypesAreCountedSortedAndCappedAtFiveWithNOfM() throws {
        let types = ["B", "B", "A", "C", "C", "C", "D", "E", "F", "G"]
            .map { #"{"type":"\#($0)"}"# }.joined(separator: ",")
        let health = try notifications("[\(types)]")
        let figure = try XCTUnwrap(health.notificationFigure?.value)
        XCTAssertEqual(figure.total, 10)
        XCTAssertEqual(figure.shown.map(\.name), ["C", "B", "A", "D", "E"])
        XCTAssertEqual(figure.types.count, 7)
        XCTAssertEqual(ServerHealth.text(for: health.notifications),
                       "10 (C: 3, B: 2, A: 1, D: 1, E: 1) · 5 of 7 types")
    }

    func testATypeIsShownAsJamfNamesItAndAMissingOneIsUnknown() throws {
        let health = try notifications(#"[{"type":"PATCH_EXTENTION_ATTRIBUTE"},{}]"#)
        XCTAssertEqual(health.notificationFigure?.value.types.map(\.name),
                       ["PATCH_EXTENTION_ATTRIBUTE", "Unknown type"])
        XCTAssertTrue(health.expiringCredentials.isEmpty, "never folded into the credentials")
    }

    func testANotificationsRefusalIsNotPermittedAndABadSnapshotIsUnreadable() throws {
        store.record(.failed(exitCode: 5), report: "jamf-pro-notifications", at: now,
                     cause: FailureCause(kind: .missingPermission, names: [], hint: nil,
                                         exitCode: 5))
        XCTAssertEqual(ServerHealth.load(dataDir: dir, warningDays: 90, now: now).notifications,
                       .notPermitted([]))
        XCTAssertEqual(try notifications(#"{"other":1}"#).notifications, .unreadable)
    }

    // MARK: - Admin hygiene (opt-in)

    private func hygiene(_ kind: String, _ json: String) throws {
        let folder = dir.appendingPathComponent(kind, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try json.write(to: folder.appendingPathComponent("\(kind)_20260921T120000.json"),
                       atomically: true, encoding: .utf8)
    }

    func testAnOptedInSourceReadsItsCountsAndAnotherIsHidden() throws {
        try hygiene("laps-pending-rotations", #"{"totalCount":3}"#)
        try hygiene("admin-accounts", #"{"total":4,"fullAccessLocal":1,"fullAccessFederated":0,"#
            + #""withFailedLogins":2,"passwordOlderThanYear":1,"passwordAgeUnknown":0}"#)
        let none = ServerHealth.load(dataDir: dir, warningDays: 90, now: now)
        XCTAssertTrue(none.adminHygiene.isEmpty, "opted out: the snapshot on disk is not shown")
        XCTAssertFalse(none.hasAttempt)
        let health = ServerHealth.load(
            dataDir: dir, warningDays: 90, now: now,
            optIn: ["laps-pending-rotations", "admin-accounts", "api-integrations"])
        XCTAssertEqual(health.adminHygiene.map(\.kind),
                       ["laps-pending-rotations", "admin-accounts", "api-integrations"])
        XCTAssertEqual(health.lapsPendingFigure, 3)
        XCTAssertTrue(health.hasAttempt)
        guard case .value(.accounts(let accounts), _) = health.adminHygiene[1].fact else {
            return XCTFail("expected accounts")
        }
        XCTAssertEqual(accounts.withFailedLogins, 2)
        XCTAssertEqual(health.adminHygiene[2].fact, .notCollected, "listed, never attempted")
        XCTAssertEqual(ServerHealth.text(for: health.adminHygiene[0].fact), "3")
        XCTAssertEqual(
            ServerHealth.text(for: health.adminHygiene[1].fact),
            "Total: 4 · Full access, local: 1 · Full access, federated: 0 · With failed logins: 2"
                + " · Password over a year old: 1 · Password age unknown: 0")
    }

    func testAHygieneCountThatIsNegativeFractionalOrHugeIsUnreadable() throws {
        for bad in ["-3", "2.7", "1e30"] {
            try hygiene("laps-pending-rotations", "{\"totalCount\":\(bad)}")
            let health = ServerHealth.load(
                dataDir: dir, warningDays: 90, now: now, optIn: ["laps-pending-rotations"])
            XCTAssertEqual(health.adminHygiene.first?.fact, .unreadable, bad)
            XCTAssertNil(health.lapsPendingFigure, bad)
        }
    }

    func testARefusalOfAnOptedOutKindRaisesNoDoctorRow() {
        let laps = ServerHealth.lapsKind
        let cause = FailureCause(kind: .missingPermission, names: ["X"], hint: nil, exitCode: 5)
        let refused = [laps: cause, kind: cause]
        let off = ConfigDoctorService.standingRefusals(refused, optedIn: [])
        XCTAssertEqual(Set(off.keys), [kind], "refused while on, then switched off")
        XCTAssertEqual(
            Set(ConfigDoctorService.standingRefusals(refused, optedIn: [laps]).keys), [laps, kind])
        XCTAssertTrue(ConfigDoctorService.serverHealthRows(refused: [:]).isEmpty)
    }

    func testAStaleNotificationFigureIsNotAnHtmlWarningAndTheTabSaysAsOf() throws {
        let stale = Date(timeIntervalSince1970: 1_780_000_000)
        func inputs(_ stale: Date?, _ report: HtmlReport) -> HtmlReport.Inputs {
            var inputs = report.loadInputs(for: [])
            inputs.serverHealth = ServerHealth(
                credentials: [],
                notifications: .value(.notifications(.init(types: ["A", "A"])), stale: stale))
            return inputs
        }
        let report = HtmlReport(config: ReportConfig(), dataDir: dir)
        XCTAssertFalse(report.attentionItems(inputs(stale, report), shown: [])
            .contains { $0.text.contains("notification") })
        XCTAssertTrue(report.attentionItems(inputs(nil, report), shown: [])
            .contains { $0.text.contains("notification") })

        let folder = dir.appendingPathComponent("jamf-pro-notifications", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try #"[{"type":"A"}]"#.write(
            to: folder.appendingPathComponent("jamf-pro-notifications_20260921T120000.json"),
            atomically: true, encoding: .utf8)
        store.record(.landed, report: "jamf-pro-notifications", at: now)
        store.record(.failed(exitCode: 1), report: "jamf-pro-notifications", at: now)
        let workbook = Workbook()
        try CoreDashboard(config: ReportConfig(), dataDir: dir, workbook: workbook)
            .writeServerAdminHealth()
        let csv = try XCTUnwrap(workbook.sheet(named: "Server and Admin Health")?
            .csvText(percentFormat: .standard))
        XCTAssertTrue(csv.contains("no longer measured"), csv)
    }

    func testAZeroLAPSCountSaysNonePendingAndAnUnreadableSnapshotSaysSo() throws {
        try hygiene("laps-pending-rotations", #"{"totalCount":0}"#)
        try hygiene("api-integrations", #"{"total":"many"}"#)
        let health = ServerHealth.load(
            dataDir: dir, warningDays: 90, now: now,
            optIn: ["laps-pending-rotations", "api-integrations"])
        XCTAssertEqual(ServerHealth.text(for: health.adminHygiene[0].fact), "None pending")
        XCTAssertEqual(health.adminHygiene[1].fact, .unreadable)
    }

    func testARefusedOptInSourceIsAdviceNotAFailure() throws {
        store.record(.failed(exitCode: 5), report: "laps-pending-rotations", at: now,
                     cause: FailureCause(kind: .missingPermission,
                                         names: ["View Local Admin Password"], hint: nil, exitCode: 5))
        let health = ServerHealth.load(
            dataDir: dir, warningDays: 90, now: now, optIn: ["laps-pending-rotations"])
        XCTAssertEqual(health.adminHygiene[0].fact, .notPermitted(["View Local Admin Password"]))
    }
}
