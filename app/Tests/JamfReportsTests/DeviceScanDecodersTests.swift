import XCTest
@testable import JamfReports

final class DeviceScanDecodersTests: XCTestCase {

    private func fixture(_ rel: String) throws -> Data {
        try Data(contentsOf: TestFixtures.dir("jamf-cli-data/\(rel)"))
    }

    func testStatusItemsDecodeWithNullValues() throws {
        let payload = try JSONDecoder().decode(
            DDMStatusItemsPayload.self,
            from: fixture("ddm-status-items-raw/ddm-status-items-prod-macos27.json"))
        XCTAssertGreaterThan(payload.statusItems.count, 10)
        let failure = payload.statusItems.first { $0.key == "softwareupdate.failure-reason" }
        XCTAssertNotNil(failure, "fixture carries the key")
        XCTAssertNil(failure?.value, "JSON null decodes to nil, not to a crash or an empty string")
        let os = payload.statusItems.first { $0.key == "device.operating-system.version" }
        XCTAssertEqual(os?.value?.isEmpty, false)
    }

    func testHistoryCleanDeviceHasStringBucketsAndPendingArray() throws {
        let h = try JSONDecoder().decode(
            ComputerHistoryCommands.self,
            from: fixture("classic-computer-history-raw/nofailures.json"))
        XCTAssertEqual(h.commands.failed.command.count, 0, "failed: \"\" decodes as no commands")
        XCTAssertEqual(h.commands.pending.command.count, 3)
        XCTAssertEqual(h.commands.completed.command.count, 9)
        let pending = try XCTUnwrap(h.commands.pending.command.first)
        XCTAssertEqual(pending.name, "ProfileList")
        XCTAssertNotNil(pending.issuedEpoch)
        XCTAssertNotNil(pending.lastPushEpoch)
    }

    func testHistorySingleFailedCommandIsABareObject() throws {
        let h = try JSONDecoder().decode(
            ComputerHistoryCommands.self,
            from: fixture("classic-computer-history-raw/onefailed.json"))
        XCTAssertEqual(h.commands.failed.command.count, 1,
                       "one failure arrives as `command: {…}`, not `command: [{…}]`")
        XCTAssertEqual(h.commands.failed.command.first?.name, "Install App - Fixture App")
        XCTAssertEqual(h.commands.failed.command.first?.status,
                       "AppStore request (submitVPPRequest) timed out")
        XCTAssertEqual(h.commands.pending.command.count, 0, "pending: \"\" on this device")
    }

    func testHistoryBucketToleratesArrayAndMissingCommandKey() throws {
        let json = """
        {"commands": {"completed": {"command": [{"name": "A"}, {"name": "B"}]},
                      "failed": {},
                      "pending": {"command": []}}}
        """
        let h = try JSONDecoder().decode(ComputerHistoryCommands.self, from: Data(json.utf8))
        XCTAssertEqual(h.commands.completed.command.map(\.name), ["A", "B"])
        XCTAssertEqual(h.commands.failed.command.count, 0, "an object with no `command` key is empty")
        XCTAssertEqual(h.commands.pending.command.count, 0)
    }

    func testPersistedRowsRoundTrip() throws {
        let ddm = DDMDeviceStatusRecord(
            deviceId: "1", name: "Mac", managementId: "m-1", osVersion: "27.0", osBuild: "27A1",
            reportDate: "2026-09-04T07:25:58.000", ddmReported: true,
            declarations: [.init(identifier: "d-1", active: true, valid: true,
                                 reasonCode: nil, reasonText: nil)],
            softwareUpdate: .init(pendingOSVersion: "27.1", pendingBuild: nil, installState: "pending",
                                  installReason: nil, failureReason: nil, failureAt: nil,
                                  betaEnrollment: nil))
        let data = try JSONEncoder().encode([ddm])
        XCTAssertEqual(try JSONDecoder().decode([DDMDeviceStatusRecord].self, from: data), [ddm])

        let mdm = MDMCommandHealthRecord(deviceId: "1", name: "Mac", failedCount: 1, pendingCount: 0,
                                         failedCommands: ["Install App"], oldestPendingDays: nil)
        let data2 = try JSONEncoder().encode([mdm])
        XCTAssertEqual(try JSONDecoder().decode([MDMCommandHealthRecord].self, from: data2), [mdm])
    }
}
