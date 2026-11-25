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
}
