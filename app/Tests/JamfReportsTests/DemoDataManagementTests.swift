import Foundation
import XCTest
@testable import JamfReports

final class DemoDataManagementTests: XCTestCase {
    private let health = ManagementHealth(
        records: DemoData.outreachRecords, rule: StaleRule(days: 30),
        now: DemoData.referenceDate)

    func testTheCardIsJudgedOverTheWholeDemoFleet() {
        XCTAssertEqual(DemoData.outreachRecords.count, 524)
        XCTAssertEqual(health.managedCount, DemoData.fleetMacs.count)
        XCTAssertEqual(health.figures[.profileExpired]?.evaluated, 524)
        XCTAssertEqual(health.figures[.notUserApproved]?.evaluated, 524)
    }

    func testEveryGapAndWarningHasMacsAndTheFilterIsTheirUnion() {
        for finding in [ManagementHealth.Finding.profileExpired, .notUserApproved, .notMDMCapable,
                        .attestationProblem] {
            XCTAssertGreaterThan(health.figures[finding]?.count ?? 0, 0, "\(finding)")
        }
        let attention = DemoData.outreachRecords.filter(health.needsAttention)
        let union = Set(health.figures.filter { $0.key.kind != .neutral }
            .flatMap { $0.value.records.map(\.id) })
        XCTAssertEqual(Set(attention.map(\.id)), union)
        XCTAssertLessThan(attention.count, 524)
    }

    func testCardAndDetailReadOnlyDemoDates() {
        let card = DemoData.managementCard
        XCTAssertNotNil(card)
        XCTAssertEqual(card?.tokens.count, 2)
        XCTAssertEqual(card?.tokens.first?.value, "expires in 38 days")
        XCTAssertEqual(card?.tokens.first?.tone, .warning)
        XCTAssertNil(card?.tokenNote)
        let expiry = DemoData.managementFacts(index: 5).mdmProfileExpiration
        XCTAssertLessThan(expiry ?? .distantFuture, DemoData.referenceDate)
    }

    func testComputersDemoRecordsCarryFacts() {
        XCTAssertTrue(DemoData.deviceSnapshot.devices.allSatisfy { $0.management != nil })
    }
}
