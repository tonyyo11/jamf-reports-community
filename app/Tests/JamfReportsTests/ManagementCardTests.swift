import Foundation
import XCTest
@testable import JamfReports

final class ManagementCardTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_794_000_000)
    private let rule = StaleRule(days: 30)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }

    private func mac(
        _ id: String, managed: String = "Managed", _ configure: (inout ManagementFacts) -> Void
    ) -> DeviceInventoryRecord {
        var record = DeviceInventoryRecord.empty(id: id, source: "test")
        record.name = "mac-\(id)"
        record.managedState = managed
        record.daysSinceContact = 1
        var facts = ManagementFacts(item: [:])
        configure(&facts)
        record.management = facts
        return record
    }

    private func health(_ records: [DeviceInventoryRecord]) -> ManagementHealth {
        ManagementHealth(records: records, rule: rule, now: now)
    }

    private func row(_ card: ManagementCard?, _ id: String) -> ManagementCard.Row? {
        guard let card else { return nil }
        return (card.gaps + card.warnings + card.counts + card.settings).first { $0.id == id }
    }

    // MARK: - Counts and denominators

    func testManagedCountExcludesUnmanagedMacs() {
        let list = [mac("a") { $0.supervised = true }, mac("b", managed: "Unmanaged") { _ in }]
        XCTAssertEqual(health(list).managedCount, 1)
    }

    func testRowNamesCountAndDenominator() {
        let list = [
            mac("a") { $0.userApprovedMDM = false }, mac("b") { $0.userApprovedMDM = true },
            mac("c") { $0.supervised = true },
        ]
        let card = ManagementCard.build(health: health(list), tokens: .empty)
        let approved = row(card, "finding.notUserApproved")
        XCTAssertEqual(approved?.value, "1 of 2 Macs")
        XCTAssertEqual(approved?.tone, .gap)
        XCTAssertTrue(approved?.opensComputers ?? false)
        XCTAssertEqual(card?.gaps.map(\.id), ["finding.notUserApproved"])
    }

    func testGapWithNoMacsIsNeutralAndNotAButton() {
        let list = [mac("a") { $0.userApprovedMDM = true }]
        let approved = row(ManagementCard.build(health: health(list), tokens: .empty),
                           "finding.notUserApproved")
        XCTAssertEqual(approved?.value, "0 of 1 Macs")
        XCTAssertEqual(approved?.tone, .neutral)
        XCTAssertFalse(approved?.opensComputers ?? true)
    }

    func testToggleReportsNotReportedAsManagedLessEvaluated() {
        let list = [
            mac("a") { $0.recoveryLockEnabled = true }, mac("b") { $0.recoveryLockEnabled = false },
            mac("c") { $0.supervised = true }, mac("d") { $0.supervised = true },
        ]
        let card = ManagementCard.build(health: health(list), tokens: .empty)
        XCTAssertEqual(row(card, "toggle.recoveryLock")?.value, "Macs: on 1 · off 1 · not reported 2")
        XCTAssertEqual(row(card, "toggle.recoveryLock")?.tone, .neutral)
    }

    func testBinaryRowNamesTheNewestVersionAndBreakdownsKeepJamfsValues() {
        let list = [
            mac("a") { $0.binaryVersion = BinaryVersion("11.33.1") },
            mac("b") { $0.binaryVersion = BinaryVersion("11.32.0") },
            mac("c") { $0.attestationStatus = "DEVICE_PROPERTIES_MISMATCH" },
            mac("d") { $0.attestationStatus = "SUCCESS" },
        ]
        let card = ManagementCard.build(health: health(list), tokens: .empty)
        XCTAssertEqual(row(card, "finding.binaryBehind")?.title,
                       "Jamf binary behind the newest binary in this fleet (11.33)")
        XCTAssertEqual(row(card, "finding.binaryBehind")?.tone, .neutral)
        XCTAssertEqual(row(card, "finding.attestationProblem")?.breakdown,
                       "DEVICE_PROPERTIES_MISMATCH 1")
    }

    func testBreakdownLineShowsAtMostFiveValuesAndSaysHowManyThereAre() {
        let list = (1...8).map { index in
            mac("m\(index)") { $0.attestationStatus = "FAIL_\(index)" }
        }
        let card = ManagementCard.build(health: health(list), tokens: .empty)
        let line = row(card, "finding.attestationProblem")?.breakdown ?? ""
        XCTAssertEqual(line.components(separatedBy: " · ").count, 6, line)
        XCTAssertTrue(line.hasSuffix("5 of 8 values"), line)
    }

    // MARK: - Hidden when empty

    func testNoFactsAndNoTokenSnapshotIsNoCard() {
        XCTAssertNil(ManagementCard.build(health: nil, tokens: .empty))
        XCTAssertNil(ManagementCard.build(health: health([mac("a") { _ in }]), tokens: .empty))
    }

    // MARK: - Token wording

    private func token(_ date: String?) -> EnrollmentToken {
        var row: [String: Any] = ["name": "Macs"]
        if let date { row["tokenExpirationDate"] = date }
        return EnrollmentToken(row: row, warningDays: 90, now: now, calendar: calendar)
    }

    private var today: String {
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private func day(_ offset: Int) -> String {
        let date = calendar.date(byAdding: .day, value: offset, to: now) ?? now
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    func testTokenRowsWordExpiredExpiringAndNotReportedApart() {
        let expired = ManagementCard.tokenRow(token(day(-3)), position: 0)
        XCTAssertEqual(expired.value, "expired 3 days ago")
        XCTAssertEqual(expired.tone, .gap)
        let expiring = ManagementCard.tokenRow(token(day(12)), position: 1)
        XCTAssertEqual(expiring.value, "expires in 12 days")
        XCTAssertEqual(expiring.tone, .warning)
        let fine = ManagementCard.tokenRow(token(day(200)), position: 2)
        XCTAssertEqual(fine.tone, .neutral)
        let none = ManagementCard.tokenRow(token(nil), position: 3)
        XCTAssertEqual(none.value, "not reported")
        XCTAssertEqual(none.tone, .neutral)
        XCTAssertEqual(ManagementCard.tokenWording(days: 0), "expires today")
        XCTAssertEqual(ManagementCard.tokenWording(days: 1), "expires in 1 day")
        XCTAssertEqual(ManagementCard.tokenWording(days: -1), "expired 1 day ago")
    }

    func testTokenNotesNotCollectedAndCouldNotBeReadAreDifferentWords() {
        let withFacts = health([mac("a") { $0.supervised = true }])
        let notCollected = ManagementCard.build(health: withFacts, tokens: .empty)
        let unreadable = ManagementCard.build(health: withFacts, tokens: .unreadable)
        XCTAssertEqual(notCollected?.tokenNote,
                       "Automated Device Enrollment token: not collected")
        XCTAssertEqual(unreadable?.tokenNote,
                       "Automated Device Enrollment token: could not be read")
        // Unreadable is worth a card on its own; "not collected" alone is not.
        XCTAssertNotNil(ManagementCard.build(health: nil, tokens: .unreadable))
    }

    func testTokenRowsShowWithoutAComputersSnapshot() {
        let snapshot = EnrollmentTokenSnapshot(
            tokens: [token(day(5))], isDetected: true, readFailed: false)
        let card = ManagementCard.build(health: nil, tokens: snapshot)
        XCTAssertEqual(card?.tokens.count, 1)
        XCTAssertNil(card?.tokenNote)
    }

    // MARK: - Computers filter and detail

    func testManagementFilterHoldsGapsAndWarningsNotNeutralFindings() {
        let list = [
            mac("gap") { $0.userApprovedMDM = false },
            mac("neutral") { $0.supervised = false },
            mac("clean") { $0.userApprovedMDM = true },
        ]
        let result = health(list)
        let rows = DevicesView.buildRows(
            devices: list, query: "", osFilter: nil, filter: .management,
            sortOrder: [], policy: .default, staleRule: rule, contactGapDays: 14,
            needsManagementAttention: { result.needsAttention($0) },
            searchableText: { $0.searchableText },
            risk: { device in
                RiskScoringService.risk(
                    for: device, agentCheck: nil, policy: .default, staleRule: self.rule)
            })
        XCTAssertEqual(rows.map(\.device.name), ["mac-gap"])
    }

    func testDetailRowsOmitUnreportedFieldsAndKeepJamfValues() {
        var facts = ManagementFacts(item: [:])
        XCTAssertTrue(ManagementDetail.rows(facts, now: now, calendar: calendar).isEmpty)
        facts.supervised = false
        facts.attestationStatus = "DEVICE_PROPERTIES_MISMATCH"
        facts.mdmProfileExpiration = now.addingTimeInterval(10 * 86_400)
        let rows = Dictionary(
            uniqueKeysWithValues: ManagementDetail.rows(facts, now: now, calendar: calendar))
        XCTAssertEqual(rows["Supervised"], "No")
        XCTAssertEqual(rows["Attestation"], "DEVICE_PROPERTIES_MISMATCH")
        XCTAssertTrue(rows["MDM profile"]?.hasSuffix("expires in 10 days") ?? false)
        XCTAssertNil(rows["MDM capable"])
        XCTAssertEqual(rows.count, 3)
    }

    func testRemediationFollowsTheGaps() {
        var facts = ManagementFacts(item: [:])
        XCTAssertTrue(ManagementDetail.remediation(facts, warningDays: 90, now: now).isEmpty)
        facts.mdmProfileExpiration = now.addingTimeInterval(-86_400)
        facts.userApprovedMDM = false
        facts.mdmCapable = false
        let lines = ManagementDetail.remediation(facts, warningDays: 90, now: now)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].contains("Re-enroll"))
        XCTAssertTrue(lines[1].contains("System Settings"))
        facts.mdmProfileExpiration = now.addingTimeInterval(86_400)
        XCTAssertTrue(ManagementDetail.remediation(facts, warningDays: 90, now: now)[0]
            .contains("renews"))
    }

    // MARK: - Unreadable inventory

    func testAnUnreadableComputersSnapshotShowsANoteNeverNothing() {
        var snapshot = DeviceInventorySnapshot.empty
        XCTAssertFalse(ManagementCard.unreadableInventory(snapshot))
        snapshot.warnings = ["Could not parse computers_2026.json"]
        XCTAssertTrue(ManagementCard.unreadableInventory(snapshot))
        let card = ManagementCard.build(
            health: nil, tokens: .empty, inventoryUnreadable: true)
        XCTAssertEqual(card?.inventoryNote, "Computers snapshot: could not be read")
        XCTAssertTrue(card?.gaps.isEmpty ?? false)
        XCTAssertNil(ManagementCard.build(health: nil, tokens: .empty))
    }

    func testLoadSaysCouldNotBeReadForUnreadableInventoryAndAnUnresolvableDataFolder() {
        var snapshot = DeviceInventorySnapshot.empty
        snapshot.warnings = ["Could not read computers.json"]
        let card = ManagementCard.load(
            profile: "", inventory: snapshot, warningDays: 90)
        XCTAssertEqual(card?.inventoryNote, "Computers snapshot: could not be read")
        XCTAssertEqual(card?.tokenNote,
                       "Automated Device Enrollment token: could not be read")
    }

    func testBatteryCapacityThatCannotBeANumberIsNotReported() {
        for bad in [1e30, -1e30, Double.infinity, Double.nan] {
            var facts = ManagementFacts(item: [:])
            facts.batteryCapacityPercent = bad
            XCTAssertTrue(ManagementDetail.rows(facts, now: now).isEmpty, "\(bad)")
        }
        var facts = ManagementFacts(item: [:])
        facts.batteryCapacityPercent = 87.4
        XCTAssertEqual(ManagementDetail.rows(facts, now: now).first?.1, "87%")
    }
}
