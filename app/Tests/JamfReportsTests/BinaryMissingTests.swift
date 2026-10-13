import XCTest
@testable import JamfReports

/// A Mac enrolled through Automated Device Enrollment that never received the Jamf binary
/// (#274): unmanaged and never checked in. It is its own state, not stale and not a contact
/// gap. Every Mac is invented; ages keep an hour clear of a day boundary.
final class BinaryMissingTests: XCTestCase {

    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
        super.tearDown()
    }

    // MARK: - Fixtures

    private func iso(daysAgo days: Double) -> String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(-days * 86_400 - 3_600))
    }

    /// A `computers` element. `managed` nil leaves the field out; `checkIn` nil is JSON null.
    private func computer(
        _ name: String, managed: Bool?, checkIn: Double?, contact: Double? = nil
    ) -> [String: Any] {
        var general: [String: Any] = [
            "name": name,
            "lastCheckIn": checkIn.map { iso(daysAgo: $0) } ?? NSNull(),
            "reportDate": checkIn.map { iso(daysAgo: $0) } ?? NSNull(),
            "lastContact": contact.map { iso(daysAgo: $0) } ?? NSNull(),
        ]
        if let managed { general["remoteManagement"] = ["managed": managed] }
        return ["id": name, "general": general, "hardware": ["serialNumber": "SER-\(name)"]]
    }

    private func record(_ item: [String: Any]) -> DeviceInventoryRecord {
        DeviceInventoryService.recordFromComputer(item, source: "computers")
    }

    private let rule = StaleRule(days: 30)

    // MARK: - The rule

    func testTheRuleNeedsUnmanagedAndNeverCheckedIn() {
        XCTAssertTrue(BinaryMissing.isMissing(managedState: "Unmanaged", neverCheckedIn: true))
        XCTAssertTrue(BinaryMissing.isMissing(managedState: "false", neverCheckedIn: true))
        XCTAssertFalse(BinaryMissing.isMissing(managedState: "Managed", neverCheckedIn: true))
        XCTAssertFalse(BinaryMissing.isMissing(managedState: "Unmanaged", neverCheckedIn: false))
        XCTAssertFalse(BinaryMissing.isMissing(managedState: "", neverCheckedIn: true),
                       "an unknown managed state is not unmanaged")
        XCTAssertFalse(BinaryMissing.isMissing(managedState: "Pending", neverCheckedIn: true))
    }

    func testARecordFollowsTheRuleAndNeverTheName() {
        let missing = record(computer("DEP - C02ABC", managed: false, checkIn: nil))
        XCTAssertTrue(missing.isBinaryMissing)
        XCTAssertEqual(missing.managedState, "Unmanaged")

        let renamed = record(computer("Reception iMac", managed: false, checkIn: nil))
        XCTAssertTrue(renamed.isBinaryMissing, "a renamed record is found by its data")
        let namedLikeIt = record(computer("DEP - C02XYZ", managed: true, checkIn: 2))
        XCTAssertFalse(namedLikeIt.isBinaryMissing, "the name alone proves nothing")

        XCTAssertFalse(record(computer("A", managed: true, checkIn: nil)).isBinaryMissing)
        XCTAssertFalse(record(computer("B", managed: false, checkIn: 90)).isBinaryMissing)
        XCTAssertFalse(record(computer("C", managed: nil, checkIn: nil)).isBinaryMissing)
    }

    func testARecordFromASourceThatDoesNotDateEveryMacIsNeverFlagged() {
        var csvLike = DeviceInventoryRecord.empty(id: "x", source: "export.csv")
        csvLike.managedState = "Unmanaged"
        XCTAssertFalse(csvLike.carriesDates)
        XCTAssertFalse(csvLike.isBinaryMissing, "a blank check-in there proves nothing")
        csvLike.carriesDates = true
        XCTAssertTrue(csvLike.isBinaryMissing)
    }

    // MARK: - Stale and contact gap

    func testAMacWithoutTheBinaryIsNotStaleButAnUnmanagedMacThatCheckedInStillCan() {
        XCTAssertFalse(record(computer("A", managed: false, checkIn: nil)).isStale(rule))
        XCTAssertTrue(record(computer("B", managed: true, checkIn: nil)).isStale(rule),
                      "managed and never checked in: still stale as before")
        XCTAssertTrue(record(computer("C", managed: false, checkIn: 90)).isStale(rule))
        XCTAssertFalse(record(computer("D", managed: false, checkIn: 90)).isBinaryMissing)
    }

    func testAMacWithoutTheBinaryShowsNoContactGapEvenWhenMDMReachesIt() {
        let reached = record(computer("A", managed: false, checkIn: nil, contact: 1))
        XCTAssertTrue(reached.isBinaryMissing, "Last Contact does not make it checked in")
        XCTAssertNil(reached.contactGap(rule: rule, gapDays: 14))
        let silent = record(computer("B", managed: true, checkIn: nil, contact: 1))
        XCTAssertEqual(silent.contactGap(rule: rule, gapDays: 14), .binarySilent)
    }

    func testTheDevicesStaleCountAndTheBinaryMissingCountDoNotOverlap() {
        let devices = [
            record(computer("Missing1", managed: false, checkIn: nil)),
            record(computer("Missing2", managed: false, checkIn: nil, contact: 1)),
            record(computer("Stale", managed: true, checkIn: 60)),
            record(computer("Fine", managed: true, checkIn: 2)),
        ]
        var snapshot = DeviceInventorySnapshot.empty
        snapshot.devices = devices
        XCTAssertEqual(snapshot.staleCount(rule), 1)
        XCTAssertEqual(snapshot.binaryMissingCount, 2)
        XCTAssertTrue(snapshot.contactGaps(staleDays: 30).isEmpty)
        XCTAssertEqual(snapshot.totalDevices, 4, "the Mac is still in the inventory")
    }

    func testOutreachTiersLeaveTheMacOutAndCountItApart() {
        let devices = [
            record(computer("Missing", managed: false, checkIn: nil)),
            record(computer("Stale", managed: true, checkIn: 60)),
            record(computer("Fine", managed: true, checkIn: 2)),
        ]
        let snapshot = StaleDeviceService.snapshot(from: devices, staleDays: 30)
        XCTAssertEqual(snapshot.totalDevices, 2)
        XCTAssertEqual(snapshot.binaryMissingCount, 1)
        XCTAssertEqual(snapshot.tierCounts[.dormant], 0, "it was dormant (never) before #274")
        XCTAssertEqual(snapshot.tierCounts[.offline], 1)
        XCTAssertEqual(snapshot.tierCounts[.recent], 1)
        let all = snapshot.devicesByTier.values.flatMap { $0 }.map(\.name)
        XCTAssertFalse(all.contains("Missing"))
    }

    func testOnlyBinaryMissingMacsStillGiveAnOutreachSnapshotThatNamesThem() {
        let snapshot = StaleDeviceService.snapshot(
            from: [record(computer("Missing", managed: false, checkIn: nil))],
            staleDays: 30, dataCollectedDate: Date())
        XCTAssertEqual(snapshot.totalDevices, 0)
        XCTAssertEqual(snapshot.binaryMissingCount, 1)
    }

    // MARK: - HTML report

    private func report(computers: [[String: Any]]) throws -> HtmlReport {
        let root = GoldenFleetWorkspace.freshRoot()
        roots.append(root)
        let dataDir = root.appendingPathComponent("jamf-cli-data", isDirectory: true)
        try GoldenFleetWorkspace.writeSnapshot(
            kind: "computers", dataDir: dataDir, at: GoldenFleetClock.anchorNoon(),
            rows: computers)
        return HtmlReport(config: try ConfigLoader.loadFromString(""), dataDir: dataDir)
    }

    private func tableRows(_ html: String) throws -> [[String]] {
        let body = try XCTUnwrap(html.components(separatedBy: "<tbody>").dropFirst().first)
        return body.components(separatedBy: "</tr>").compactMap { row in
            let cells = row.components(separatedBy: "<td>").dropFirst()
                .map { $0.components(separatedBy: "</td>")[0] }
            return cells.isEmpty ? nil : cells
        }
    }

    private var fleet: [[String: Any]] {
        [computer("Healthy", managed: true, checkIn: 2, contact: 1),
         computer("StaleOnly", managed: true, checkIn: 60),
         computer("DEP - C02AAA", managed: false, checkIn: nil),
         computer("Renamed", managed: false, checkIn: nil, contact: 1)]
    }

    func testTheInterventionListGivesTheMacsItsOwnReasonAndKeepsThemOutOfStale() throws {
        let report = try report(computers: fleet)
        let html = report.buildInterventionList(computersInventory: fleet).html
        let rows = try tableRows(html)

        XCTAssertEqual(rows.map { $0[0] }, ["StaleOnly", "DEP - C02AAA", "Renamed"],
                       "stale first, the binary-missing Macs after")
        let byName = Dictionary(uniqueKeysWithValues: rows.map { ($0[0], $0) })
        XCTAssertEqual(byName["StaleOnly"]?[5], "—")
        XCTAssertEqual(byName["DEP - C02AAA"]?[5], "Jamf binary missing")
        XCTAssertEqual(byName["DEP - C02AAA"]?[3], "never")
        XCTAssertEqual(byName["Renamed"]?[5], "Jamf binary missing",
                       "Last Contact does not turn it into a contact gap")
        XCTAssertTrue(html.contains("Macs to follow up (3)"), html)
        XCTAssertTrue(
            html.contains("1 with no check-in for more than 30 days, "
                + "2 enrolled without the Jamf binary."), html)
        XCTAssertTrue(html.contains("own summaries and may still include them"), html)
        XCTAssertFalse(html.contains("A Mac that is both"), "no gap, no gap sentence")
    }

    func testTheSentenceTheHeadlineAndTheTableCountTheSameMacs() throws {
        let report = try report(computers: fleet)
        let inputs = report.loadInputs(for: Set(SectionID.allCases))

        XCTAssertEqual(inputs.staleMacCount, 1)
        XCTAssertEqual(inputs.binaryMissingCount, 2)
        XCTAssertTrue(inputs.contactGapCounts.isEmpty)
        XCTAssertEqual(
            report.groupSummary(.devices, shown: [], inputs: inputs),
            "1 Mac idle over 30 days · 2 without the Jamf binary")

        let items = report.attentionItems(inputs, shown: [.interventionList])
        let line = try XCTUnwrap(items.first { $0.text.contains("Jamf binary") })
        XCTAssertTrue(line.text.hasPrefix("2 Macs enrolled but never received the Jamf binary"),
                      line.text)
        XCTAssertTrue(line.text.contains("sudo profiles renew -type enrollment"), line.text)
        XCTAssertEqual(line.anchor, "intervention-list")
        let stale = try XCTUnwrap(items.first { $0.text.contains("not checked in") })
        XCTAssertTrue(stale.text.hasPrefix("1 Mac has"), stale.text)
    }

    func testNoSentenceWhenNoMacIsMissingTheBinary() throws {
        let healthy = [computer("Healthy", managed: true, checkIn: 2, contact: 1)]
        let report = try report(computers: healthy)
        let inputs = report.loadInputs(for: Set(SectionID.allCases))
        XCTAssertEqual(inputs.binaryMissingCount, 0)
        XCTAssertFalse(report.attentionItems(inputs, shown: []).contains {
            $0.text.contains("Jamf binary")
        })
    }

    func testTheSingularSentence() {
        XCTAssertTrue(BinaryMissing.attentionSentence(count: 1).hasPrefix(
            "1 Mac enrolled but never received the Jamf binary: Jamf Pro lists it as"))
    }
}
