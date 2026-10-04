import Foundation
import XCTest
@testable import JamfReports

/// 2.9 visual pass: Jamf reports one release as both `26.7` and `26.7.0`, so every tally by
/// raw string listed it twice (prod: the macOS Distribution card, Devices legend, Security
/// Posture donut, and the workbook and HTML OS tables).
final class OSVersionNameTests: XCTestCase {

    func testAZeroPatchIsDropped() {
        XCTAssertEqual(OSVersionName.normalized("26.7.0"), "26.7")
        XCTAssertEqual(OSVersionName.normalized("27.0.0"), "27.0")
        XCTAssertEqual(OSVersionName.normalized(" 26.7.0\n"), "26.7")
    }

    func testEverythingElseIsLeftAsWritten() {
        for version in ["26.7", "26.7.1", "15.7.10", "15.0.10", "27", "", "26.7.00",
                        "macOS 26.7.0", "26.7.0.0", "26..0", "x.y.0"] {
            XCTAssertEqual(OSVersionName.normalized(version), version, version)
        }
    }

    func testMergedCombinesOneReleaseInOrderOfFirstAppearance() {
        let rows = OSVersionName.merged([
            .init(version: "26.7.0", count: 274, pct: 41.2),
            .init(version: "26.6.2", count: 76, pct: 11.4),
            .init(version: "26.7", count: 67, pct: 10.1),
        ])
        XCTAssertEqual(rows.map(\.version), ["26.7", "26.6.2"])
        XCTAssertEqual(rows.map(\.count), [341, 76])
        XCTAssertEqual(rows[0].pct, 51.3, accuracy: 0.001)
    }

    func testPercentReadsJamfCLIText() {
        XCTAssertEqual(OSVersionName.percent("41.2%"), 41.2, accuracy: 0.001)
        XCTAssertEqual(OSVersionName.percent("n/a"), 0)
    }

    // MARK: - Overview

    func testOverviewListsOneReleaseOnce() {
        let built = OverviewLiveDataLoader.osDistribution(
            counts: ["26.7.0": 274, "26.7": 67, "26.6.2": 76],
            latestByMajor: [26: "26.7"], limit: 6)

        XCTAssertEqual(built.rows.map(\.version), ["macOS 26.7", "macOS 26.6.2"])
        XCTAssertEqual(built.rows.map(\.count), [341, 76])
        XCTAssertEqual(built.versions, 2)
        XCTAssertEqual(built.rows.map(\.current), [true, false])
    }

    // MARK: - Devices

    func testDevicesLegendListsOneReleaseOnce() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jrc-osname-\(UUID().uuidString)", isDirectory: true)
        let kindDir = root.appendingPathComponent("osname/jamf-cli-data/computers")
        try FileManager.default.createDirectory(at: kindDir, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        addTeardownBlock {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: root)
        }
        try """
        [{"general": {"name": "Mac-A", "id": "1"}, "hardware": {"serialNumber": "AAA1"},
          "operatingSystem": {"version": "26.7.0"}},
         {"general": {"name": "Mac-B", "id": "2"}, "hardware": {"serialNumber": "BBB2"},
          "operatingSystem": {"version": "26.7"}}]
        """.write(to: kindDir.appendingPathComponent("computers_20261004T120000.json"),
                  atomically: true, encoding: .utf8)

        let snapshot = DeviceInventoryService.load(profile: "osname", demoMode: false)

        XCTAssertEqual(snapshot.devices.count, 2)
        XCTAssertEqual(snapshot.osDistribution.map(\.version), ["26.7"])
        XCTAssertEqual(snapshot.osDistribution.map(\.count), [2])
        XCTAssertEqual(Set(snapshot.devices.map(\.osVersion)), ["26.7"],
                       "the table and the legend filter agree on one spelling")
    }

    // MARK: - Security Posture, workbook and HTML

    private let securityJSON = """
    [{"section":"summary","data":{"total_devices":100,"filevault_encrypted":95,
      "gatekeeper_enabled":100,"sip_enabled":100,"firewall_enabled":80}},
     {"section":"os_version","os_version":"26.7.0","count":60,"pct":"60.0%"},
     {"section":"os_version","os_version":"26.7","count":10,"pct":"10.0%"},
     {"section":"os_version","os_version":"15.7.3","count":30,"pct":"30.0%"}]
    """

    func testSecurityPostureListsOneReleaseOnce() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("security-osname-\(UUID().uuidString).json")
        try Data(securityJSON.utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        let snapshot = try SecurityPostureService.load(from: url, policy: .default, hardware: [:])

        XCTAssertEqual(snapshot.osVersions.map(\.osVersion), ["26.7", "15.7.3"])
        XCTAssertEqual(snapshot.osVersions.map(\.count), [70, 30])
        XCTAssertEqual(snapshot.osVersions.map(\.pct), [70.0, 30.0])
    }

    func testWorkbookSecuritySheetListsOneReleaseOnce() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osname-wb-\(UUID().uuidString)", isDirectory: true)
        let kindDir = dir.appendingPathComponent("security", isDirectory: true)
        try FileManager.default.createDirectory(at: kindDir, withIntermediateDirectories: true)
        try securityJSON.write(to: kindDir.appendingPathComponent("security.json"),
                               atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let dash = CoreDashboard(config: ReportConfig(), dataDir: dir, workbook: Workbook())
        try dash.writeSecurity()

        let cells = try XCTUnwrap(dash.workbook.sheet(named: "Security Posture")).dedupedCells
        let labels = cells.compactMap { cell -> String? in
            if cell.col == 0, case .string(let s) = cell.value { return s }
            return nil
        }
        XCTAssertTrue(labels.contains("26.7"))
        XCTAssertFalse(labels.contains("26.7.0"))
        XCTAssertEqual(labels.filter { $0 == "26.7" }.count, 1)
    }

    func testHtmlOSChartListsOneReleaseOnce() {
        let report = HtmlReport(
            config: ReportConfig().withDefaults(),
            dataDir: URL(fileURLWithPath: "/tmp/nonexistent"))
        let html = report.buildOSChart(osVersions: [
            ["os_version": "26.7.0", "count": 60],
            ["os_version": "26.7", "count": 10],
            ["os_version": "15.7.3", "count": 30],
        ]).html

        XCTAssertTrue(html.contains("[\"26.7\",\"15.7.3\"]"), "one label per release")
        XCTAssertTrue(html.contains("[70,30]"))
        XCTAssertFalse(html.contains("26.7.0"))
    }
}
