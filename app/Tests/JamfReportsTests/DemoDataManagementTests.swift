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

    /// Both demo surfaces draw on `managementFacts(index:)` and the same `referenceDate`: the
    /// Computers records are the first eight Macs of the Audit card's 524.
    @MainActor
    func testComputersDemoFiguresMatchTheCardForTheSameMacs() {
        let now = DevicesView.evaluationDate(demoMode: true)
        XCTAssertEqual(now, DemoData.referenceDate)
        let computers = DevicesView.Figures(
            snapshot: DemoData.deviceSnapshot, rule: StaleRule(days: 30), warningDays: 90,
            now: now).management
        let serials = Set(DemoData.deviceSnapshot.devices.map(\.serial))
        XCTAssertEqual(serials.count, 8)
        func held(_ health: ManagementHealth) -> [ManagementHealth.Finding: Set<String>] {
            health.figures.mapValues { Set($0.records.map(\.serial)).intersection(serials) }
        }
        XCTAssertEqual(held(computers), held(health))
        for record in DemoData.deviceSnapshot.devices {
            let twin = DemoData.outreachRecords.first { $0.serial == record.serial }
            XCTAssertEqual(record.management, twin?.management)
            XCTAssertEqual(computers.needsAttention(record),
                           twin.map(health.needsAttention) ?? false)
        }
    }

    func testTheRealClockWouldJudgeTheDemoDifferently() {
        let real = ManagementHealth(
            records: DemoData.outreachRecords, rule: StaleRule(days: 30), now: Date())
        XCTAssertNotEqual(
            real.figures[.profileExpired]?.count, health.figures[.profileExpired]?.count)
    }
}
