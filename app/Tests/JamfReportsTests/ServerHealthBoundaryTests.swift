import XCTest
@testable import JamfReports

/// Parsing edges of `CredentialExpiry` the 2.13 mutation sweep left unpinned.
final class CredentialExpiryBoundaryTests: XCTestCase {

    func testAnInstantExactlyNowIsExpired() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let credential = CredentialExpiry(
            key: "ca", label: "CA", raw: Int(now.timeIntervalSince1970), warningDays: 90,
            now: now)
        XCTAssertEqual(credential.state, .expired)
    }

    func testTheSecondsAndMillisecondsCutoff() {
        XCTAssertEqual(CredentialExpiry.parse(50_000_000_000),
                       .instant(Date(timeIntervalSince1970: 50_000_000_000)),
                       "5e10 is under 1e11, so seconds")
        XCTAssertEqual(CredentialExpiry.parse(500_000_000_000),
                       .instant(Date(timeIntervalSince1970: 500_000_000)),
                       "5e11 is over 1e11, so milliseconds")
        XCTAssertNil(CredentialExpiry.parse(NSNumber(value: 1e16)), "past 1e15 is no time")
    }

    func testADayIsReadTrimmed() {
        XCTAssertEqual(CredentialExpiry.parse(" 2026-12-01\n"), .day("2026-12-01"))
    }

    func testADayNeedsFourTwoAndTwoASCIIDigits() {
        for text in ["26-12-01", "2026-1-01", "2026-01-1", "2026-01-+1", "2026--01-01"] {
            XCTAssertNil(CredentialExpiry.parse(text), text)
        }
    }
}

/// `ServerHealth`'s words, lists and opt-in counts, and the reduction's allow-list edges.
final class ServerHealthBoundaryTests: XCTestCase {

    private let calendar = Calendar.current
    private var noon: Date {
        calendar.date(byAdding: .hour, value: 12,
                      to: calendar.startOfDay(for: Date(timeIntervalSince1970: 1_790_000_000)))!
    }

    private func credential(_ raw: Any?, now: Date? = nil, key: String = "ca") -> CredentialExpiry {
        CredentialExpiry(key: key, label: "CA", raw: raw, warningDays: 90, now: now ?? noon)
    }

    private func at(days: Int, minutes: Int = 0) -> Int {
        Int(noon.timeIntervalSince1970) + days * 86_400 + minutes * 60
    }

    // MARK: - Words

    func testExpiredWordsCountTheDays() throws {
        let today = credential(at(days: 0, minutes: -60))
        let day = try XCTUnwrap(ServerHealth.expiryDay(today))
        XCTAssertEqual(ServerHealth.credentialText(today), "Expired (\(day))")
        let yesterday = credential(at(days: -1))
        XCTAssertTrue(ServerHealth.credentialText(yesterday).hasPrefix("Expired 1 day ago ("),
                      ServerHealth.credentialText(yesterday))
        let tomorrow = credential(at(days: 1))
        XCTAssertTrue(ServerHealth.credentialText(tomorrow).hasPrefix("Expires in 1 day ("),
                      ServerHealth.credentialText(tomorrow))
    }

    /// The expiry is the Mac's own calendar day, to match `daysLeft`; an instant late in the
    /// local day (west of UTC) or early in it (east) falls on another UTC day.
    func testTheExpiryDayIsTheLocalDay() throws {
        let offset = TimeZone.current.secondsFromGMT()
        let start = calendar.startOfDay(for: noon)
        let instant = offset < 0 ? start.addingTimeInterval(23.5 * 3_600)
            : start.addingTimeInterval(0.5 * 3_600)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        XCTAssertEqual(ServerHealth.expiryDay(credential(instant.timeIntervalSince1970)),
                       formatter.string(from: instant))
    }

    func testFewTypesSayNoNOfM() {
        XCTAssertEqual(ServerHealth.notificationsText(.init(types: ["A", "B", "A"])),
                       "3 (A: 2, B: 1)")
    }

    // MARK: - Lists

    private func row(
        _ credential: CredentialExpiry, stale: Date? = nil
    ) -> ServerHealth.CredentialRow {
        .init(key: credential.key, label: credential.label,
              fact: .value(.credential(credential), stale: stale))
    }

    func testOnlyCurrentExpiredOrExpiringCredentialsAreListedSoonestFirst() {
        let health = ServerHealth(credentials: [
            row(credential(at(days: 10), key: "ten")),
            row(credential(at(days: 200), key: "ok")),
            row(credential(at(days: -3), key: "expired")),
            row(credential(at(days: 5), key: "five")),
            row(credential(at(days: -9), key: "stale"), stale: noon),
        ])
        XCTAssertEqual(health.expiringCredentials.map(\.key), ["expired", "five", "ten"])
    }

    func testAnAttemptedCredentialAloneIsAnAttempt() {
        let health = ServerHealth(credentials: [.init(key: "ca", label: "CA", fact: .unreadable)])
        XCTAssertTrue(health.hasAttempt)
    }

    // MARK: - Opt-in counts on disk

    private func dataDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func hygiene(_ kind: String, _ json: String, in dir: URL) throws {
        let folder = dir.appendingPathComponent(kind, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try json.write(to: folder.appendingPathComponent("\(kind)_20260921T120000.json"),
                       atomically: true, encoding: .utf8)
    }

    func testTheUnknownTalliesAreReadFromTheSnapshot() throws {
        let dir = try dataDir()
        try hygiene("admin-accounts", #"{"total":4,"fullAccessLocal":1,"fullAccessFederated":0,"#
            + #""withFailedLogins":2,"passwordOlderThanYear":1,"passwordAgeUnknown":0,"#
            + #""failedLoginsUnknown":3}"#, in: dir)
        try hygiene("api-integrations", #"{"total":6,"disabled":1,"enabledWithTokenOverOneDay":0,"#
            + #""tokenLifetimeUnknown":2,"enabledUnknown":4}"#, in: dir)
        let health = ServerHealth.load(dataDir: dir, warningDays: 90, now: noon,
                                       optIn: ["admin-accounts", "api-integrations"])
        guard case .value(.accounts(let accounts), _) = health.adminHygiene[0].fact,
              case .value(.apiClients(let clients), _) = health.adminHygiene[1].fact else {
            return XCTFail("expected both counts")
        }
        XCTAssertEqual(accounts.failedLoginsUnknown, 3)
        XCTAssertEqual(clients.tokenLifetimeUnknown, 2)
        XCTAssertEqual(clients.enabledUnknown, 4)
    }

    // MARK: - Reduction

    private func reduced(_ kind: String, _ json: String) throws -> [String: Any] {
        let out = try XCTUnwrap(ServerHealthReduction.reduce(kind: kind, payload: Data(json.utf8)))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: out) as? [String: Any])
    }

    func testLAPSUsesTheEnvelopesOwnCount() throws {
        let laps = try reduced("laps-pending-rotations", #"{"totalCount":7,"results":[]}"#)
        XCTAssertEqual(laps["totalCount"] as? Int, 7)
    }

    func testOnlyAnEnabledAccountIsAFullAccessAdmin() throws {
        let counts = try reduced("admin-accounts", #"[{"accountStatus":"Locked","#
            + #""accessLevel":"FullAccess","privilegeLevel":"ADMINISTRATOR","#
            + #""accountType":"DEFAULT","failedLoginAttempts":0}]"#)
        XCTAssertEqual(counts["fullAccessLocal"] as? Int, 0)
        XCTAssertEqual(counts["passwordAgeUnknown"] as? Int, 0, "a locked account is not judged")
    }

    func testOnlyABooleanIsAnEnabledFlag() throws {
        let counts = try reduced("api-integrations",
                                 #"[{"enabled":1,"accessTokenLifetimeSeconds":100000}]"#)
        XCTAssertEqual(counts["enabledUnknown"] as? Int, 1)
        XCTAssertEqual(counts["enabledWithTokenOverOneDay"] as? Int, 0)
    }

    func testABooleanIsNoWholeCount() {
        XCTAssertNil(wholeCount(true))
        XCTAssertNil(wholeCount(NSNumber(value: false)))
        XCTAssertEqual(wholeCount(NSNumber(value: 3)), 3)
    }
}
