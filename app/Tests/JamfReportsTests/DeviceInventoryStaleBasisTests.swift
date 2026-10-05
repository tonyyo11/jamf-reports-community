import XCTest
@testable import JamfReports

/// `DeviceInventoryService.load` reads `thresholds.stale_basis` and `contact_gap_days` from the
/// workspace's config.yaml and hands the Devices, Outreach and Audit screens one stale rule.
final class DeviceInventoryStaleBasisTests: XCTestCase {

    private var root: URL!
    private let profile = "stalebasis"

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jrc-stale-basis-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(profile, isDirectory: true),
            withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        try? FileManager.default.removeItem(at: root)
    }

    private func iso(_ days: Double) -> String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(-days * 86_400 - 3_600))
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// A: healthy. B: inventory 50 days old. C: the Jamf binary is silent (check-in 40 days
    /// old, contact yesterday, so also stale by check-in).
    private func workspace(config: String) throws {
        let base = root.appendingPathComponent(profile, isDirectory: true)
        try write(config, to: base.appendingPathComponent("config.yaml"))
        let macs: [[String: Any]] = [
            ["id": "1", "general": ["name": "A", "lastCheckIn": iso(1), "reportDate": iso(1),
                                    "lastContact": iso(0)], "hardware": ["serialNumber": "SA"]],
            ["id": "2", "general": ["name": "B", "lastCheckIn": iso(1), "reportDate": iso(50),
                                    "lastContact": iso(0)], "hardware": ["serialNumber": "SB"]],
            ["id": "3", "general": ["name": "C", "lastCheckIn": iso(40), "reportDate": iso(40),
                                    "lastContact": iso(0)], "hardware": ["serialNumber": "SC"]],
        ]
        let compliance: [[String: Any]] = [
            ["name": "A", "serial": "SA", "days_since_contact": "1", "stale": false],
            ["name": "B", "serial": "SB", "days_since_contact": "1", "stale": false],
            ["name": "C", "serial": "SC", "days_since_contact": "40", "stale": true],
        ]
        let data = base.appendingPathComponent("jamf-cli-data", isDirectory: true)
        try JSONSerialization.data(withJSONObject: macs).write(
            to: try prepare(data.appendingPathComponent("computers/computers_20260901T090000.json")))
        try JSONSerialization.data(withJSONObject: compliance).write(
            to: try prepare(data.appendingPathComponent(
                "device-compliance/device-compliance_20260901T090000.json")))
    }

    private func prepare(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url
    }

    private func stale(_ snapshot: DeviceInventorySnapshot) -> [String] {
        snapshot.devices.filter(\.stale).map(\.name).sorted()
    }

    func testTheDefaultBasisCountsTheCheckInAlone() throws {
        try workspace(config: "thresholds:\n  stale_device_days: 30\n")
        let snapshot = DeviceInventoryService.load(profile: profile, demoMode: false)
        XCTAssertEqual(snapshot.staleBasis, [.checkIn])
        XCTAssertEqual(snapshot.staleDays, 30)
        XCTAssertEqual(snapshot.contactGapDays, 14)
        XCTAssertEqual(stale(snapshot), ["C"])
        XCTAssertEqual(snapshot.staleCount(thresholdDays: 30), 1)
    }

    func testTheConfiguredBasisMakesTheInventoryDateCount() throws {
        try workspace(config: """
        thresholds:
          stale_device_days: 30
          stale_basis: [check_in, inventory]
          contact_gap_days: 10
        """)
        let snapshot = DeviceInventoryService.load(profile: profile, demoMode: false)
        XCTAssertEqual(snapshot.staleBasis, [.checkIn, .inventory])
        XCTAssertEqual(snapshot.contactGapDays, 10)
        XCTAssertEqual(stale(snapshot), ["B", "C"], "B by inventory, C by check-in")
        XCTAssertEqual(snapshot.staleCount(thresholdDays: 30), 2)
        let tiers = StaleDeviceService.snapshot(
            from: snapshot.devices, staleDays: 30, staleBasis: snapshot.staleBasis)
        XCTAssertEqual(Set(tiers.devicesByTier[.offline]?.map(\.name) ?? []), ["B", "C"])
    }

    func testTheContactGapListsComeFromTheSameLoad() throws {
        try workspace(config: "thresholds:\n  stale_basis: [check_in]\n")
        let snapshot = DeviceInventoryService.load(profile: profile, demoMode: false)
        let gaps = snapshot.contactGaps(staleDays: snapshot.staleDays)
        XCTAssertEqual(gaps[.binarySilent]?.map(\.name), ["C"])
        XCTAssertEqual(gaps[.inventoryStale]?.map(\.name), ["B"])
        let findings = contactGapFindings(snapshot)
        XCTAssertEqual(findings.map(\.affected), [1, 1])
        XCTAssertEqual(findings[0].devices, ["C (SC)"])
    }

    func testAWrongValueFallsBackToTheDefaultsWithoutLosingTheScreen() throws {
        try workspace(config: """
        thresholds:
          stale_device_days: 30
          stale_basis: 7
          contact_gap_days: abc
        """)
        let snapshot = DeviceInventoryService.load(profile: profile, demoMode: false)
        XCTAssertEqual(snapshot.devices.count, 3)
        XCTAssertEqual(snapshot.staleBasis, [.checkIn])
        XCTAssertEqual(snapshot.contactGapDays, 14)
    }

    func testASingleWordAndAnOutOfRangeGapRead() throws {
        try workspace(config: "thresholds:\n  stale_basis: inventory\n  contact_gap_days: 400\n")
        let snapshot = DeviceInventoryService.load(profile: profile, demoMode: false)
        XCTAssertEqual(snapshot.staleBasis, [.inventory])
        XCTAssertEqual(snapshot.contactGapDays, 14)
        XCTAssertEqual(stale(snapshot), ["B", "C"], "C's inventory is 40 days old too")
    }
}
