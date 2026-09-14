import XCTest
@testable import JamfReports

final class DDMDeviceStatusServiceTests: XCTestCase {

    private func write(_ records: [DDMDeviceStatusRecord]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ddm-dev-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("ddm-device-status_20260904T120000.json")
        try JSONEncoder().encode(records).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return url
    }

    private func rec(_ id: String, reported: Bool = true,
                     decl: [(String, Bool?, Bool?)] = [],
                     pending: String? = nil, failure: String? = nil) -> DDMDeviceStatusRecord {
        .init(deviceId: id, name: "Mac-\(id)", managementId: "m-\(id)",
              osVersion: "27.0",
              reportDate: "2026-09-04T07:00:00.000", ddmReported: reported,
              declarations: decl.map { .init(identifier: $0.0, active: $0.1, valid: $0.2) },
              softwareUpdate: .init(pendingOSVersion: pending, installState: nil,
                                    failureReason: failure))
    }

    func testNilURLIsNotDetected() {
        let s = DDMDeviceStatusService.load(url: nil)
        XCTAssertFalse(s.isDetected); XCTAssertFalse(s.readFailed); XCTAssertTrue(s.records.isEmpty)
    }

    func testGarbageFileIsUnreadable() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ddm-bad-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("ddm-device-status_20260904T120000.json")
        try Data("nope".utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let s = DDMDeviceStatusService.load(url: url)
        XCTAssertTrue(s.readFailed); XCTAssertFalse(s.isDetected)
    }

    func testIdentifierCountsIncludingMixedRule() throws {
        // A: active on 1, inactive on 2 → mixed? No: mixed is SAME device both states.
        // B: on device 3 twice — once active, once inactive → mixed 1.
        // C: invalid on 1.
        let url = try write([
            rec("1", decl: [("A", true, true), ("C", true, false)]),
            rec("2", decl: [("A", false, true)]),
            rec("3", decl: [("B", true, true), ("B", false, true)]),
            rec("4", reported: false),
        ])
        let s = DDMDeviceStatusService.load(url: url)
        XCTAssertTrue(s.isDetected)
        XCTAssertEqual(s.ddmReportedCount, 3)
        let a = try XCTUnwrap(s.byIdentifier.first { $0.identifier == "A" })
        XCTAssertEqual(a.active, 1); XCTAssertEqual(a.inactive, 1); XCTAssertEqual(a.mixed, 0)
        let b = try XCTUnwrap(s.byIdentifier.first { $0.identifier == "B" })
        XCTAssertEqual(b.mixed, 1); XCTAssertEqual(b.active, 0); XCTAssertEqual(b.inactive, 0)
        let c = try XCTUnwrap(s.byIdentifier.first { $0.identifier == "C" })
        XCTAssertEqual(c.invalid, 1)
        // failing = invalid + inactive + mixed device-declarations
        XCTAssertEqual(s.failingDeclarationCount, 3)
        XCTAssertEqual(s.byIdentifier.map(\.identifier), ["B", "C", "A"],
                       "worst first: mixed, then invalid, then inactive, then name")
    }

    func testSoftwareUpdateAggregation() throws {
        let url = try write([
            rec("1", pending: "27.1"), rec("2", pending: "27.1"), rec("3", pending: "27.0.1"),
            rec("4", failure: "Insufficient space"), rec("5", failure: "Insufficient space"),
        ])
        let s = DDMDeviceStatusService.load(url: url)
        XCTAssertEqual(s.pendingVersions.map(\.version), ["27.1", "27.0.1"])
        XCTAssertEqual(s.pendingVersions.first?.devices.map(\.id), ["1", "2"])
        XCTAssertEqual(s.failureReasons.first?.reason, "Insufficient space")
        XCTAssertEqual(s.failureReasons.first?.devices.count, 2)
        XCTAssertEqual(s.record(forDeviceId: "3")?.softwareUpdate.pendingOSVersion, "27.0.1")
        XCTAssertNil(s.record(forDeviceId: "99"))
    }

    func testSourceDatesComeFromTheFilenameStamp() throws {
        let url = try write([rec("1")])
        let s = DDMDeviceStatusService.load(url: url)
        XCTAssertNotNil(s.snapshotDate)
        XCTAssertEqual(s.sourceDates.keys.sorted(), ["ddm-device-status"])
    }

    func testFleetDDMCountsReadsComputers() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ddm-computers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("computers_20260904T120000.json")
        let json = """
        [{"id":"1","general":{
             "name":"A","managementId":"m1","declarativeDeviceManagementEnabled":true}},
         {"id":"2","general":{
             "name":"B","managementId":"m2","declarativeDeviceManagementEnabled":false}},
         {"id":"3","general":{"name":"C","managementId":"m3"}}]
        """
        try Data(json.utf8).write(to: url)
        let counts = DDMDeviceStatusService.fleetDDMCounts(computersURL: url)
        XCTAssertEqual(counts.enabled, 1)
        XCTAssertEqual(counts.total, 3)
        XCTAssertEqual(DDMDeviceStatusService.fleetDDMCounts(computersURL: nil).total, 0)
    }
}
