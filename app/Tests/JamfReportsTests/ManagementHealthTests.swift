import Foundation
import XCTest
@testable import JamfReports

final class ManagementHealthTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_794_000_000)
    private let rule = StaleRule(days: 30)

    private func iso(daysAgo: Int) -> String {
        ISO8601DateFormatter().string(from: now.addingTimeInterval(-Double(daysAgo) * 86_400))
    }

    private func iso(daysAhead: Int) -> String { iso(daysAgo: -daysAhead) }

    /// A `computers` row; `checkInDaysAgo` nil leaves out both Jamf dates.
    private func record(
        _ id: String, managed: Bool = true, checkInDaysAgo: Int? = 1,
        inventoried: Bool = true, general: String = "", security: String = "", hardware: String = ""
    ) -> DeviceInventoryRecord {
        var dates = ""
        if !inventoried { dates = #""reportDate": null,"# }
        if let days = checkInDaysAgo {
            dates = #""lastCheckIn": "\#(iso(daysAgo: days))", "reportDate": "\#(iso(daysAgo: days))","#
        }
        let row = ManagementFixture.row("""
        {"id": "\(id)", "general": {"name": "mac-\(id)", "managed": \(managed), \(dates)
          "remoteManagement": {"managed": \(managed)}\(general)},
         "operatingSystem": {"version": \(inventoried ? "\"26.0\"" : "null")}, "security": {"x": 1\(security)},
         "hardware": {"x": 1\(hardware)}}
        """)
        return DeviceInventoryService.recordFromComputer(row, source: "test")
    }

    private func health(_ records: [DeviceInventoryRecord], window: Int = 90) -> ManagementHealth {
        ManagementHealth(records: records, rule: rule, warningDays: window, now: now)
    }

    private func expiring(_ id: String, days: Int, checkIn: Int?) -> DeviceInventoryRecord {
        record(id, checkInDaysAgo: checkIn,
               general: #", "mdmProfileExpiration": "\#(iso(daysAhead: days))""#)
    }

    func testExpiringProfileLandsInExactlyOneBucket() {
        let list = [
            expiring("a", days: 10, checkIn: 1), expiring("b", days: 10, checkIn: 60),
            expiring("c", days: 10, checkIn: nil),
            record("d", general: #", "mdmProfileExpiration": "\#(iso(daysAgo: 3))""#),
            expiring("e", days: 400, checkIn: 1),
        ]
        let result = health(list)
        func ids(_ finding: ManagementHealth.Finding) -> [String] {
            result.figures[finding]?.records.map(\.name) ?? []
        }
        XCTAssertEqual(ids(.profileExpiringCheckingIn), ["mac-a"])
        // The computers source dates every Mac, so no check-in at all reads as never: stale.
        XCTAssertEqual(ids(.profileExpiringStale), ["mac-b", "mac-c"])
        XCTAssertEqual(ids(.profileExpiringCheckInUnknown), [])
        XCTAssertEqual(ids(.profileExpired), ["mac-d"])
        XCTAssertEqual(result.figures[.profileExpired]?.evaluated, 5)
        XCTAssertTrue(result.needsAttention(list[0]))
        // Expiring on a stale Mac is a count: the stale list already holds it.
        XCTAssertFalse(result.needsAttention(list[1]))
        XCTAssertTrue(result.needsAttention(list[3]))
        XCTAssertFalse(result.needsAttention(list[4]))
    }

    func testMacWithNoKnownDateIsInTheUnknownBucket() {
        // Contact-only basis: a Mac with no Last Contact has an unknown age, not an old one.
        let list = [expiring("a", days: 10, checkIn: nil)]
        let result = ManagementHealth(
            records: list, rule: StaleRule(days: 30, basis: [.contact]), warningDays: 90, now: now)
        XCTAssertEqual(result.figures[.profileExpiringCheckInUnknown]?.count, 1)
        XCTAssertEqual(result.figures[.profileExpiringStale]?.count, 0)
        XCTAssertEqual(result.figures[.profileExpiringCheckingIn]?.count, 0)
    }

    func testUnmanagedAndBinaryMissingAreInNoFinding() {
        let bad = #", "userApprovedMdm": false, "supervised": false"#
        let unmanaged = record("u", managed: false, general: bad)
        let missing = record("m", checkInDaysAgo: nil, inventoried: false, general: bad)
        XCTAssertTrue(missing.isBinaryMissing)
        XCTAssertTrue(BinaryMissing.isUnmanaged(unmanaged.managedState))
        let result = health([unmanaged, missing])
        XCTAssertTrue(result.figures.isEmpty)
        XCTAssertFalse(result.needsAttention(unmanaged))
        let kept = record("k", general: bad)
        XCTAssertEqual(health([unmanaged, kept]).figures[.notUserApproved]?.evaluated, 1)
    }

    func testFieldNoMacReportsHasNoFigureAndNullLeavesTheDenominator() {
        let list = [
            record("a", general: #", "userApprovedMdm": false"#),
            record("b", general: #", "userApprovedMdm": null"#),
            record("c", general: #", "userApprovedMdm": true"#),
        ]
        let figure = health(list).figures[.notUserApproved]
        XCTAssertEqual(figure?.count, 1)
        XCTAssertEqual(figure?.evaluated, 2)
        XCTAssertNil(health(list).figures[.notSupervised])
        XCTAssertNil(health(list).figures[.profileExpired])
    }

    func testBinaryVersionNeedsTwoDistinctAndStaysNeutral() {
        func binary(_ id: String, _ version: String) -> DeviceInventoryRecord {
            record(id, general: #", "jamfBinaryVersion": "\#(version)""#)
        }
        XCTAssertNil(health([binary("a", "11.33.3-t1"), binary("b", "11.33.0-t2")])
            .figures[.binaryBehind])
        XCTAssertNil(health([binary("a", "11.33.3-t1"), binary("b", "garbage")])
            .figures[.binaryBehind])
        let list = [binary("a", "11.33.3-t1"), binary("b", "11.32.9"), binary("c", "11.33.0")]
        let result = health(list)
        XCTAssertEqual(result.figures[.binaryBehind]?.count, 1)
        XCTAssertEqual(result.figures[.binaryBehind]?.evaluated, 3)
        XCTAssertEqual(result.newestBinary?.label, "11.33")
        XCTAssertEqual(ManagementHealth.Finding.binaryBehind.kind, .neutral)
        XCTAssertFalse(list.contains(where: result.needsAttention))
    }

    func testAttestationAndBattery() {
        func mac(_ id: String, _ status: String, _ health: String, _ capacity: Int) -> DeviceInventoryRecord {
            record(id, security: #", "attestationStatus": "\#(status)""#,
                   hardware: #", "batteryHealth": "\#(health)", "batteryCapacityPercent": \#(capacity)"#)
        }
        let result = health([
            mac("a", "SUCCESS", "NORMAL", 95), mac("b", "MDA_UNSUPPORTED_DUE_TO_HARDWARE", "UNKNOWN", -1),
            mac("c", "PENDING", "Service Recommended", 70), mac("d", "FAILED_X", "NORMAL", 79),
        ])
        XCTAssertEqual(result.figures[.attested]?.count, 1)
        XCTAssertEqual(result.figures[.attested]?.evaluated, 3)
        XCTAssertEqual(result.figures[.attestationPending]?.count, 1)
        XCTAssertEqual(result.values(.attestationProblem).map(\.value), ["FAILED_X"])
        XCTAssertEqual(result.values(.batteryHealth).map(\.value), ["Service Recommended"])
        XCTAssertEqual(result.figures[.batteryNeedsService]?.evaluated, 4)
        XCTAssertEqual(result.figures[.batteryLowCapacity]?.count, 2)
        XCTAssertEqual(result.figures[.batteryLowCapacity]?.evaluated, 3)
    }

    func testValuesAreCappedMostMacsFirstAndShownAsDisplayText() {
        var list: [DeviceInventoryRecord] = []
        for index in 0..<8 {
            let status = index == 0 ? "FAIL\u{202E}_0" : "FAIL_\(index)"
            // FAIL_0 on three Macs, the others on one.
            let repeats = index == 0 ? 3 : 1
            for copy in 0..<repeats {
                list.append(record("m\(index)-\(copy)",
                                   security: #", "attestationStatus": "\#(status)""#))
            }
        }
        let capped = health(list).cappedValues(.attestationProblem)
        XCTAssertEqual(capped.distinct, 8)
        XCTAssertEqual(capped.shown.count, ManagementHealth.maxShownValues)
        XCTAssertEqual(capped.shown.first?.count, 3)
        XCTAssertEqual(capped.shown.first?.value, ConfigSchema.displayText("FAIL\u{202E}_0"))
        XCTAssertEqual(capped.shown.dropFirst().map(\.value), ["FAIL_1", "FAIL_2", "FAIL_3", "FAIL_4"])
    }

    func testTogglesAppearOnlyWhenReported() {
        let result = health([
            record("a", security: #", "recoveryLockEnabled": true"#),
            record("b", security: #", "recoveryLockEnabled": false, "lockdownModeEnabled": null"#),
        ])
        XCTAssertEqual(result.toggles[.recoveryLock]?.on.count, 1)
        XCTAssertEqual(result.toggles[.recoveryLock]?.evaluated, 2)
        XCTAssertNil(result.toggles[.lockdownMode])
        XCTAssertNil(result.toggles[.awaitingConfiguration])
    }
}
