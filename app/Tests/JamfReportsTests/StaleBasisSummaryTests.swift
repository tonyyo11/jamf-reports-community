import XCTest
@testable import JamfReports

/// The stale rule where the daily summary, the score and Offline Outreach read it:
/// `thresholds.stale_basis` over device-compliance rows and the `computers` snapshot.
/// Fixtures are hand-built; every age keeps an hour clear of a day boundary.
final class StaleBasisSummaryTests: XCTestCase {

    // MARK: - Fixtures

    private func iso(daysAgo days: Double) -> String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(-days * 86_400 - 3_600))
    }

    private var recentStamp: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        return formatter.string(from: Date().addingTimeInterval(-3_600))
    }

    /// One `computers` element: Jamf Pro v4 inventory keys.
    private func computer(
        id: Int, serial: String, checkIn: Double?, inventory: Double?, contact: Double?
    ) -> [String: Any] {
        var general: [String: Any] = ["name": "Mac-\(id)"]
        if let checkIn { general["lastCheckIn"] = iso(daysAgo: checkIn) }
        if let inventory { general["reportDate"] = iso(daysAgo: inventory) }
        general["lastContact"] = contact.map { iso(daysAgo: $0) } ?? NSNull()
        return ["id": String(id), "general": general, "hardware": ["serialNumber": serial]]
    }

    private func complianceRow(
        serial: String, days: Int, id: Int? = nil, flag: Bool = false
    ) -> [String: Any] {
        var row: [String: Any] = [
            "name": "Mac-\(serial)", "serial": serial, "managed": true, "stale": flag,
            "days_since_contact": String(days),
        ]
        if let id { row["id"] = id }
        return row
    }

    private func config(_ yaml: String = "") throws -> ReportConfig {
        try ConfigLoader.loadFromString(yaml)
    }

    /// Writes the snapshots, builds the day's summary and returns its `staleCount`.
    private func summaryStaleCount(
        _ config: ReportConfig, compliance: [[String: Any]], computers: [[String: Any]]?
    ) throws -> Int? {
        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("stale-basis-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dataDir) }
        let total = compliance.count
        func put(_ kind: String, _ payload: Any) throws {
            let dir = dataDir.appendingPathComponent(kind, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: payload)
                .write(to: dir.appendingPathComponent("\(kind)_\(recentStamp).json"))
        }
        try put("security", [["section": "summary", "data": [
            "total_devices": total, "filevault_encrypted": total, "sip_enabled": total,
            "firewall_enabled": total, "gatekeeper_enabled": total,
        ]]])
        try put("device-compliance", compliance)
        if let computers { try put("computers", computers) }

        let summaries = dataDir.appendingPathComponent("summaries", isDirectory: true)
        try FileManager.default.createDirectory(at: summaries, withIntermediateDirectories: true)
        ReportEngine(config: config, dataDir: dataDir).emitSummaryJSON(summariesDir: summaries)
        let today = SummaryJSONParser.dateFormatter.string(from: Date())
        let file = summaries.appendingPathComponent("summary_\(today).json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file))
        return (object as? [String: Any])?["staleCount"] as? Int
    }

    /// Three Macs. Every one checked in recently; the inventory dates differ.
    ///   A: inventory 3 days old        B: inventory 50 days old
    ///   C: inventory 3 days old, Last Contact 45 days old
    private var computers: [[String: Any]] {
        [
            computer(id: 1, serial: "AAA", checkIn: 3, inventory: 3, contact: 1),
            computer(id: 2, serial: "BBB", checkIn: 3, inventory: 50, contact: 2),
            computer(id: 3, serial: "CCC", checkIn: 3, inventory: 3, contact: 45),
        ]
    }

    private var compliance: [[String: Any]] {
        [complianceRow(serial: "AAA", days: 3), complianceRow(serial: "BBB", days: 3),
         complianceRow(serial: "CCC", days: 3)]
    }

    // MARK: - The summary's count

    func testTheDefaultBasisCountsTheCheckInAloneWhateverComputersHolds() throws {
        XCTAssertEqual(try summaryStaleCount(
            config(), compliance: compliance, computers: computers), 0)
        XCTAssertEqual(try summaryStaleCount(
            config(), compliance: compliance, computers: nil), 0, "equal without the snapshot")
    }

    func testInventoryInTheBasisJoinsTheRowsToTheComputersSnapshotBySerial() throws {
        let rule = try config("thresholds:\n  stale_basis: [check_in, inventory]\n")
        XCTAssertEqual(try summaryStaleCount(rule, compliance: compliance, computers: computers),
                       1, "only B's inventory is more than 30 days old")
    }

    func testWithoutAComputersSnapshotTheBasisFallsBackToTheCheckIn() throws {
        let rule = try config("thresholds:\n  stale_basis: [check_in, inventory]\n")
        XCTAssertEqual(try summaryStaleCount(rule, compliance: compliance, computers: nil), 0)
        let aged = [complianceRow(serial: "AAA", days: 45)]
        XCTAssertEqual(try summaryStaleCount(rule, compliance: aged, computers: nil), 1,
                       "the check-in still counts without it")
    }

    func testARowTheSnapshotCannotPlaceCountsItsCheckInAlone() throws {
        let rule = try config("thresholds:\n  stale_basis: [check_in, inventory]\n")
        let rows = [complianceRow(serial: "NOPE", days: 3), complianceRow(serial: "BBB", days: 3)]
        XCTAssertEqual(try summaryStaleCount(rule, compliance: rows, computers: computers), 1)
    }

    func testARowWithAJamfIDJoinsByIDBeforeSerial() throws {
        let rule = try config("thresholds:\n  stale_basis: [check_in, inventory]\n")
        let rows = [complianceRow(serial: "WRONG-SERIAL", days: 3, id: 2)]
        XCTAssertEqual(try summaryStaleCount(rule, compliance: rows, computers: computers), 1,
                       "Jamf ID 2 is B, whose inventory is old, whatever the serial says")
    }

    func testContactInTheBasisCountsTheLastContactAndIgnoresAMissingOne() throws {
        let rule = try config("thresholds:\n  stale_basis: [check_in, contact]\n")
        XCTAssertEqual(try summaryStaleCount(rule, compliance: compliance, computers: computers),
                       1, "only C's Last Contact is more than 30 days old")
        var noContact = computers
        noContact[2] = computer(id: 3, serial: "CCC", checkIn: 3, inventory: 3, contact: nil)
        XCTAssertEqual(try summaryStaleCount(
            rule, compliance: compliance, computers: noContact), 0,
            "a Mac with no Last Contact is not judged by it")
    }

    func testTheMostStaleDateDecidesAndEachMacCountsOnce() throws {
        let rule = try config("thresholds:\n  stale_basis: [check_in, inventory, contact]\n")
        XCTAssertEqual(try summaryStaleCount(rule, compliance: compliance, computers: computers),
                       2, "B by inventory and C by contact, once each")
    }

    // MARK: - The score's checked-in factor

    private func rows(_ payload: [[String: Any]]) throws -> [DeviceComplianceRow] {
        try JSONDecoder().decode(
            [DeviceComplianceRow].self, from: JSONSerialization.data(withJSONObject: payload))
    }

    private func checkedIn(_ config: ReportConfig, index: ComputerDateIndex?) throws
        -> SecurityScoreMeasure? {
        var sources = SecurityScoreInputs.Sources()
        sources.complianceRows = try rows(compliance)
        sources.computerDates = index
        return SecurityScoreInputs.measures(
            for: [SecurityScoreFactor(.checkedIn, weight: 5)], fleet: nil, sources: sources,
            config: config)[SecurityScoreFactor(.checkedIn, weight: 5).key]
    }

    func testTheCheckedInFactorFollowsTheBasis() throws {
        let data = try JSONSerialization.data(withJSONObject: computers)
        let index = try XCTUnwrap(ComputerDateIndex(snapshot: data))
        let byDefault = try XCTUnwrap(checkedIn(config(), index: index))
        XCTAssertEqual(byDefault.passing, 3)
        XCTAssertEqual(byDefault.evaluated, 3)
        let both = try config("thresholds:\n  stale_basis: [check_in, inventory]\n")
        let widened = try XCTUnwrap(checkedIn(both, index: index))
        XCTAssertEqual(widened.passing, 2, "B no longer passes")
        XCTAssertEqual(widened.evaluated, 3)
        let withoutIndex = try XCTUnwrap(checkedIn(both, index: nil))
        XCTAssertEqual(withoutIndex.passing, 3, "no snapshot, the check-in alone")
    }

    func testTheScoresLabelNamesTheBasis() throws {
        let factor = SecurityScoreFactor(.checkedIn, weight: 5)
        let rule = try config("""
            thresholds:
              stale_basis: [check_in, inventory]
              stale_device_days: 21
            """).staleRule
        XCTAssertEqual(factor.label(staleDays: rule.days, staleBasis: rule.basis),
                       "Checked in and inventoried within 21 days")
        XCTAssertEqual(SecurityScoreFactor.labels(
            inBasis: "checked_in=5", staleDays: rule.days, staleBasis: rule.basis),
            ["Checked in and inventoried within 21 days"])
    }

    // MARK: - Offline Outreach tiers

    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func record(
        _ id: String, checkInDays: Int?, inventoryDays: Double?, carries: Bool = true
    ) -> DeviceInventoryRecord {
        var record = DeviceInventoryRecord.empty(id: id, source: "computers.json")
        record.name = id
        record.daysSinceContact = checkInDays
        record.checkInDate = checkInDays.map { now.addingTimeInterval(-Double($0) * 86_400) }
        record.inventoryDate = inventoryDays.map { now.addingTimeInterval(-$0 * 86_400) }
        record.carriesDates = carries
        return record
    }

    func testTiersBucketByTheStaleAgeNotTheCheckInAlone() {
        let records = [
            record("A", checkInDays: 5, inventoryDays: 100),    // stale age 100: inactive
            record("B", checkInDays: 5, inventoryDays: nil),    // never inventoried: dormant
            record("C", checkInDays: 40, inventoryDays: 40),    // 40: offline
            record("D", checkInDays: 3, inventoryDays: 3),      // recent
        ]
        let both = StaleDeviceService.snapshot(
            from: records, staleDays: 30, staleBasis: [.checkIn, .inventory], now: now)
        XCTAssertEqual(both.devicesByTier[.inactive]?.map(\.id), ["A"])
        XCTAssertEqual(both.devicesByTier[.dormant]?.map(\.id), ["B"])
        XCTAssertEqual(both.devicesByTier[.offline]?.map(\.id), ["C"])
        XCTAssertEqual(both.devicesByTier[.recent]?.map(\.id), ["D"])
        XCTAssertEqual(both.staleBasis, [.checkIn, .inventory])

        let checkInOnly = StaleDeviceService.snapshot(from: records, staleDays: 30, now: now)
        XCTAssertEqual(Set(checkInOnly.devicesByTier[.recent]?.map(\.id) ?? []), ["A", "B", "D"])
        XCTAssertEqual(checkInOnly.devicesByTier[.offline]?.map(\.id), ["C"])
    }

    func testAMacIsListedMostStaleFirstWithinItsTier() {
        let records = [
            record("old", checkInDays: 5, inventoryDays: 80),
            record("older", checkInDays: 5, inventoryDays: 85),
            record("checkin-only", checkInDays: 70, inventoryDays: 1),
        ]
        let snapshot = StaleDeviceService.snapshot(
            from: records, staleDays: 30, staleBasis: [.checkIn, .inventory], now: now)
        XCTAssertEqual(snapshot.devicesByTier[.offline]?.map(\.id),
                       ["older", "old", "checkin-only"], "ages 85, 80 and 70")
    }

    func testTierForAStaleAge() {
        typealias Tier = StaleDeviceService.Tier
        XCTAssertEqual(Tier.tier(forAge: nil), .recent)
        XCTAssertEqual(Tier.tier(forAge: .never), .dormant)
        XCTAssertEqual(Tier.tier(forAge: .days(30), staleDays: 30), .recent)
        XCTAssertEqual(Tier.tier(forAge: .days(31), staleDays: 30), .offline)
        XCTAssertEqual(Tier.tier(forAge: .days(91), staleDays: 30), .inactive)
        XCTAssertEqual(Tier.tier(forAge: .days(181), staleDays: 30), .dormant)
    }
}
