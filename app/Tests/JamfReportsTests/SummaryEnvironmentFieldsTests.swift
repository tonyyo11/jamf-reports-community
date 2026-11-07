import XCTest
@testable import JamfReports

/// The P9 optional fields on `DailySummary`: absent reads as nil, round trips, merges, ranges.
final class SummaryEnvironmentFieldsTests: XCTestCase {

    private func base(
        products: [String]? = nil, matched: Double? = nil, open: Int? = nil,
        alerts: [String: Int]? = nil, os: [String: Int]? = nil, count: Int? = nil,
        buckets: LastSeenBuckets? = nil
    ) -> DailySummary {
        DailySummary(
            date: "2026-11-07", totalDevices: 10, fileVaultPct: 90, compliancePct: nil,
            staleCount: 1, osCurrentPct: 80, crowdstrikePct: nil, patchPct: nil,
            source: "jamf-cli", products: products, protectComputerCount: count,
            protectMatchedPct: matched, protectOpenAlerts: open, protectAlertCounts: alerts,
            osMajorCounts: os, lastSeenBuckets: buckets)
    }

    private func encode(_ summary: DailySummary) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(summary)
    }

    func testOldSummaryDecodesWithNilFieldsAndReencodesIdentically() throws {
        let old = try encode(base())
        let text = String(decoding: old, as: UTF8.self)
        for key in ["products", "protect", "osMajorCounts", "lastSeenBuckets"] {
            XCTAssertFalse(text.contains(key), key)
        }
        let decoded = try SummaryJSONParser.decode(old)
        XCTAssertNil(decoded.products)
        XCTAssertNil(decoded.protectComputerCount)
        XCTAssertNil(decoded.lastSeenBuckets)
        XCTAssertEqual(try encode(decoded), old)
    }

    func testFullRoundTrip() throws {
        let buckets = LastSeenBuckets(
            computers: .init(underOneDay: 4, underSevenDays: 3, sevenDaysOrMore: 2, never: 1),
            mobile: .init(underOneDay: 2))
        let summary = base(
            products: ["jamf_pro", "protect"], matched: 87.5, open: 3,
            alerts: ["high": 1, "low": 2], os: ["macOS 26": 9], count: 8, buckets: buckets)
        let decoded = try SummaryJSONParser.decode(try encode(summary))
        XCTAssertEqual(decoded.products, ["jamf_pro", "protect"])
        XCTAssertEqual(decoded.protectMatchedPct, 87.5)
        XCTAssertEqual(decoded.protectAlertCounts, ["high": 1, "low": 2])
        XCTAssertEqual(decoded.osMajorCounts, ["macOS 26": 9])
        XCTAssertEqual(decoded.lastSeenBuckets, buckets)
        XCTAssertEqual(buckets.computers?.total, 10)
    }

    func testFillingCarriesOlderValuesAndUnionsProducts() {
        let older = base(products: ["jamf_pro"], matched: 70, open: 2, os: ["macOS 26": 5])
        let fresh = base(products: ["protect", "jamf_pro"], open: 4)
        let merged = fresh.filling(from: older)
        XCTAssertEqual(merged.products, ["jamf_pro", "protect"])
        XCTAssertEqual(merged.protectMatchedPct, 70)
        XCTAssertEqual(merged.protectOpenAlerts, 4)
        XCTAssertEqual(merged.osMajorCounts, ["macOS 26": 5])
    }

    func testRangeCheckRejectsBadValues() {
        XCTAssertTrue(base(matched: 100, open: 2, alerts: ["high": 2]).numbersAreInRange)
        XCTAssertFalse(base(count: -1).numbersAreInRange)
        XCTAssertFalse(base(matched: 100.5).numbersAreInRange)
        XCTAssertFalse(base(os: ["macOS 26": -3]).numbersAreInRange)
        XCTAssertFalse(base(open: 1, alerts: ["high": 2]).numbersAreInRange)
        XCTAssertFalse(base(count: SummaryJSONParser.maxSummaryNumber + 1).numbersAreInRange)
    }

    func testWithEnvironmentSetsOnlyWhatItIsGiven() {
        let start = base(products: ["jamf_pro"], matched: 70, open: 2, count: 5)
        let untouched = start.withEnvironment(products: nil, protect: nil)
        XCTAssertEqual(untouched.products, ["jamf_pro"])
        XCTAssertEqual(untouched.protectMatchedPct, 70)
        let changed = start.withEnvironment(
            products: ["protect"],
            protect: ProtectSummaryFigures(computerCount: 9, openAlerts: 0))
        XCTAssertEqual(changed.products, ["jamf_pro", "protect"])
        XCTAssertEqual(changed.protectComputerCount, 9)
        XCTAssertNil(changed.protectMatchedPct)
        XCTAssertEqual(changed.protectOpenAlerts, 0)
    }

    func testNewlyMeasuredFieldIsAnUpgrade() {
        let existing = base()
        XCTAssertTrue(ReportEngine.freshSummaryIsBetter(
            existing: existing, fresh: base(open: 1)))
        XCTAssertFalse(ReportEngine.freshSummaryIsBetter(
            existing: base(open: 1), fresh: base()))
    }
}
