import XCTest
@testable import JamfReports

/// The HTML report's management sentences and intervention rows. Every Mac is invented.
final class ManagementHealthHtmlTests: XCTestCase {

    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
        super.tearDown()
    }

    private func iso(days: Double) -> String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(days * 86_400 + 3_600))
    }

    private func day(_ offset: Int) -> String {
        CoreDashboard.dayText(Calendar.current.date(byAdding: .day, value: offset, to: Date()))
    }

    private func mac(
        _ id: Int, name: String? = nil, profile: Int? = nil, approved: Bool? = nil,
        checkIn: Double = -1
    ) -> [String: Any] {
        var general: [String: Any] = [
            "name": name ?? "Mac-\(id)", "managed": true, "lastCheckIn": iso(days: checkIn),
            "reportDate": iso(days: checkIn), "remoteManagement": ["managed": true],
        ]
        if let profile { general["mdmProfileExpiration"] = iso(days: Double(profile)) }
        if let approved { general["userApprovedMdm"] = approved }
        return ["id": String(id), "general": general, "hardware": ["serialNumber": "SER\(id)"],
                "operatingSystem": ["version": "26.0"], "security": ["x": 1]]
    }

    private func report(
        _ computers: [[String: Any]], instances: [[String: Any]]? = nil
    ) throws -> (HtmlReport, HtmlReport.Inputs) {
        let root = GoldenFleetWorkspace.freshRoot()
        roots.append(root)
        let dataDir = root.appendingPathComponent("jamf-cli-data", isDirectory: true)
        let anchor = GoldenFleetClock.anchorNoon()
        try GoldenFleetWorkspace.writeSnapshot(
            kind: "computers", dataDir: dataDir, at: anchor, rows: computers)
        if let instances {
            try GoldenFleetWorkspace.writeSnapshot(
                kind: "device-enrollment-instances", dataDir: dataDir, at: anchor,
                rows: instances)
        }
        let report = HtmlReport(config: try ConfigLoader.loadFromString(""), dataDir: dataDir)
        return (report, report.loadInputs(for: Set(SectionID.allCases)))
    }

    private func lines(_ pair: (HtmlReport, HtmlReport.Inputs)) -> [String] {
        pair.0.attentionItems(pair.1, shown: []).map(\.text)
    }

    // MARK: - Needs attention

    func testSentencesAppearOnlyWhileTheirCountIsAboveZero() throws {
        let quiet = try report([mac(1), mac(2, profile: 400), mac(3, approved: true)])
        XCTAssertFalse(lines(quiet).contains { $0.contains("MDM profile") })
        XCTAssertFalse(lines(quiet).contains { $0.contains("Enrollment") })

        let busy = try report([mac(1, profile: -5), mac(2, profile: -9), mac(3, profile: 10)])
        let text = lines(busy)
        XCTAssertTrue(text.contains(
            "2 Macs have expired MDM profiles and are leaving management."), "\(text)")
        XCTAssertTrue(text.contains(
            "1 Mac still checks in, but its MDM profile expires soon."), "\(text)")
    }

    func testAStaleMacWithAnExpiringProfileIsNotCountedAsStillCheckingIn() throws {
        let pair = try report([mac(1, profile: 10, checkIn: -80)])
        XCTAssertFalse(lines(pair).contains { $0.contains("still check") })
    }

    func testTheTokenSentenceCarriesCountsAndDaysNeverTheInstanceName() throws {
        let pair = try report(
            [mac(1)],
            instances: [["name": "Placeholder Instance", "tokenExpirationDate": day(12)],
                        ["name": "Other Instance", "tokenExpirationDate": day(-2)],
                        ["name": "Far Instance", "tokenExpirationDate": day(500)]])
        let sentence = try XCTUnwrap(lines(pair).first { $0.contains("Enrollment") })
        XCTAssertEqual(sentence, "1 Automated Device Enrollment token has expired; "
                       + "1 more expires, the soonest in 12 days.")
        XCTAssertFalse(lines(pair).joined().contains("Instance"))
    }

    func testNoTokenSentenceWithoutASnapshotOrWithTokensInDate() throws {
        XCTAssertFalse(lines(try report([mac(1)])).contains { $0.contains("Enrollment") })
        let fine = try report([mac(1)], instances: [
            ["name": "A", "tokenExpirationDate": day(300)]])
        XCTAssertFalse(lines(fine).contains { $0.contains("Enrollment") })
    }

    // MARK: - Intervention list

    func testTheInterventionListCarriesTheFindingTitleAsTheReason() throws {
        let pair = try report([
            mac(1, profile: -5), mac(2, profile: 10), mac(3, approved: false), mac(4),
            mac(5, profile: -2, approved: false),
        ])
        let macs = pair.0.interventionMacs(
            pair.1.computers,
            management: ManagementReport.interventionFindings(pair.1.management))
        let byName = Dictionary(uniqueKeysWithValues: macs.map {
            (pair.0.inventoryName($0.item), $0.reason)
        })
        XCTAssertEqual(byName["Mac-1"], "MDM profile expired")
        XCTAssertEqual(byName["Mac-2"], "MDM profile expiring, still checking in")
        XCTAssertEqual(byName["Mac-3"], "MDM not user-approved")
        XCTAssertEqual(byName["Mac-5"], "MDM profile expired; MDM not user-approved")
        XCTAssertNil(byName["Mac-4"])
        XCTAssertEqual(macs.count, 4, "each Mac once")
    }

    func testTheListHasItsTitleNoteAndEscapesText() throws {
        let pair = try report([mac(1, name: "<b>Mac</b> & co", profile: -5)])
        let html = pair.0.buildInterventionList(
            computersInventory: pair.1.computers, management: pair.1.management).html
        XCTAssertTrue(html.contains("Macs to follow up (1)"), html)
        XCTAssertTrue(html.contains("1 with a management finding"), html)
        XCTAssertTrue(html.contains("MDM profile expired"), html)
        XCTAssertTrue(html.contains("&lt;b&gt;Mac&lt;/b&gt; &amp; co"), html)
        XCTAssertFalse(html.contains("&amp;lt;"), "escaped once")
        XCTAssertFalse(html.contains("<b>Mac</b>"))
    }

    func testWithoutManagementTheListIsUnchanged() throws {
        let pair = try report([mac(1, profile: -5)])
        XCTAssertEqual(
            pair.0.buildInterventionList(computersInventory: pair.1.computers).omission,
            "no Mac has gone more than 30 days without a check-in")
    }

    func testNoComputersSnapshotLeavesTheManagementInputNil() {
        let report = HtmlReport(
            config: ReportConfig(), dataDir: FileManager.default.temporaryDirectory
                .appendingPathComponent("none-\(UUID().uuidString)"))
        let inputs = report.loadInputs(for: Set(SectionID.allCases))
        XCTAssertNil(inputs.management)
        XCTAssertEqual(report.buildInterventionList(computersInventory: []).omission,
                       "no computers snapshot")
    }
}
