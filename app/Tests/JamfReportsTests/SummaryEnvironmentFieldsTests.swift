import XCTest
@testable import JamfReports

/// The P9 optional fields on `DailySummary`: absent reads as nil, round trips, merges, ranges.
final class SummaryEnvironmentFieldsTests: XCTestCase {

    private func base(
        products: [String]? = nil, matched: MobileSummary.Share? = nil, open: Int? = nil,
        alerts: [String: Int]? = nil, os: [String: Int]? = nil, count: Int? = nil,
        buckets: LastSeenBuckets? = nil
    ) -> DailySummary {
        DailySummary(
            date: "2026-11-07", totalDevices: 10, fileVaultPct: 90, compliancePct: nil,
            staleCount: 1, osCurrentPct: 80, crowdstrikePct: nil, patchPct: nil,
            source: "jamf-cli", products: products, protectComputerCount: count,
            protectMatched: matched, protectOpenAlerts: open, protectAlertCounts: alerts,
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
            products: ["jamf_pro", "protect"], matched: .init(met: 7, of: 8), open: 3,
            alerts: ["high": 1, "low": 2], os: ["macOS 26": 9], count: 8, buckets: buckets)
        let decoded = try SummaryJSONParser.decode(try encode(summary))
        XCTAssertEqual(decoded.products, ["jamf_pro", "protect"])
        XCTAssertEqual(decoded.protectMatched, .init(met: 7, of: 8))
        XCTAssertEqual(decoded.protectAlertCounts, ["high": 1, "low": 2])
        XCTAssertEqual(decoded.osMajorCounts, ["macOS 26": 9])
        XCTAssertEqual(decoded.lastSeenBuckets, buckets)
        XCTAssertEqual(buckets.computers?.total, 10)
    }

    func testFillingCarriesOlderValuesAndUnionsProducts() {
        let older = base(products: ["jamf_pro"], matched: .init(met: 7, of: 10), open: 2, os: ["macOS 26": 5])
        let fresh = base(products: ["protect", "jamf_pro"], open: 4)
        let merged = fresh.filling(from: older)
        XCTAssertEqual(merged.products, ["jamf_pro", "protect"])
        XCTAssertEqual(merged.protectMatched, .init(met: 7, of: 10))
        XCTAssertEqual(merged.protectOpenAlerts, 4)
        XCTAssertEqual(merged.osMajorCounts, ["macOS 26": 5])
    }

    /// A merge must not pair the target's open total with the source's severity counts.
    func testFillingTakesPairedFiguresAsOneGroup() {
        let target = base(open: 0)
        let source = base(matched: .init(met: 3, of: 4), open: 3, alerts: ["high": 3], count: 4)
        let merged = target.filling(from: source)
        XCTAssertEqual(merged.protectOpenAlerts, 0)
        XCTAssertNil(merged.protectAlertCounts)
        XCTAssertTrue(merged.numbersAreInRange)
        let countOnly = base(count: 9).filling(from: source)
        XCTAssertEqual(countOnly.protectComputerCount, 9)
        XCTAssertEqual(countOnly.protectMatched, .init(met: 3, of: 4), "a share stands alone")
    }

    func testRangeCheckRejectsBadValues() {
        XCTAssertTrue(base(matched: .init(met: 5, of: 5), open: 2, alerts: ["high": 2]).numbersAreInRange)
        XCTAssertFalse(base(count: -1).numbersAreInRange)
        XCTAssertFalse(base(matched: .init(met: 6, of: 5)).numbersAreInRange)
        XCTAssertFalse(base(matched: .init(met: -1, of: 5)).numbersAreInRange)
        XCTAssertFalse(base(os: ["macOS 26": -3]).numbersAreInRange)
        XCTAssertFalse(base(open: 1, alerts: ["high": 2]).numbersAreInRange)
        XCTAssertFalse(base(count: SummaryJSONParser.maxSummaryNumber + 1).numbersAreInRange)
        // A peer-written pair past the bound is refused, so no reader does arithmetic on it.
        XCTAssertFalse(base(matched: .init(met: Int.max, of: Int.max)).numbersAreInRange)
        let limit = SummaryJSONParser.maxSummaryNumber
        XCTAssertTrue(base(matched: .init(met: limit, of: limit)).numbersAreInRange)
    }

    func testWithEnvironmentSetsOnlyTheGroupsThisRunMeasured() {
        let start = base(
            products: ["jamf_pro"], matched: .init(met: 7, of: 10), open: 2,
            alerts: ["high": 2], count: 5)
        let untouched = start.withEnvironment(products: nil, protect: nil)
        XCTAssertEqual(untouched.products, ["jamf_pro"])
        XCTAssertEqual(untouched.protectMatched, .init(met: 7, of: 10))
        let computersOnly = start.withEnvironment(
            products: ["protect"],
            protect: .init(computers: .init(count: 9, matched: nil)))
        XCTAssertEqual(computersOnly.products, ["jamf_pro", "protect"])
        XCTAssertEqual(computersOnly.protectComputerCount, 9)
        XCTAssertNil(computersOnly.protectMatched)
        XCTAssertEqual(computersOnly.protectOpenAlerts, 2)
        XCTAssertEqual(computersOnly.protectAlertCounts, ["high": 2])
        let alertsOnly = start.withEnvironment(
            products: nil, protect: .init(alerts: .init(open: 0, counts: nil)))
        XCTAssertEqual(alertsOnly.protectOpenAlerts, 0)
        XCTAssertNil(alertsOnly.protectAlertCounts)
        XCTAssertEqual(alertsOnly.protectComputerCount, 5)
        XCTAssertEqual(alertsOnly.protectMatched, .init(met: 7, of: 10))
    }

    func testNewlyMeasuredFieldIsAnUpgrade() {
        let existing = base()
        XCTAssertTrue(ReportEngine.freshSummaryIsBetter(
            existing: existing, fresh: base(open: 1)))
        XCTAssertFalse(ReportEngine.freshSummaryIsBetter(
            existing: base(open: 1), fresh: base()))
    }

    func testComputersOnlyRunKeepsMobileHalvesAndMobileOnlyRunKeepsMacKeys() {
        let counts = { (n: Int) in LastSeenBuckets.Counts(underOneDay: n) }
        let older = base(
            os: ["macOS 26": 4, "iOS 18": 3],
            buckets: LastSeenBuckets(computers: counts(4), mobile: counts(3)))
        let macsOnly = base(
            os: ["macOS 26": 5], buckets: LastSeenBuckets(computers: counts(5), mobile: nil))
            .filling(from: older)
        XCTAssertEqual(macsOnly.osMajorCounts, ["macOS 26": 5, "iOS 18": 3])
        XCTAssertEqual(macsOnly.lastSeenBuckets?.mobile, counts(3))
        XCTAssertEqual(macsOnly.lastSeenBuckets?.computers, counts(5))
        let mobileOnly = base(
            os: ["iPadOS 18": 2], buckets: LastSeenBuckets(computers: nil, mobile: counts(2)))
            .filling(from: older)
        XCTAssertEqual(mobileOnly.osMajorCounts, ["macOS 26": 4, "iPadOS 18": 2])
        XCTAssertEqual(mobileOnly.lastSeenBuckets?.computers, counts(4))
    }
}
