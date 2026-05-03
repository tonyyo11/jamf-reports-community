import Foundation
import XCTest
@testable import JamfReports

final class TrendStoreTests: XCTestCase {
    func testOptionalMetricPointsKeepDatesAlignedWhenValuesAreMissing() {
        let store = TrendStore(
            summaries: [
                summary(date: "2026-04-01", compliancePct: 91),
                summary(date: "2026-04-08", compliancePct: nil),
                summary(date: "2026-04-15", compliancePct: 84),
            ],
            range: .all
        )

        let points = store.points(metric: .compliance)

        XCTAssertEqual(points.map { dateString($0.date) }, ["2026-04-01", "2026-04-15"])
        XCTAssertEqual(points.map(\.value), [91, 84])
        XCTAssertEqual(store.dates().map(dateString), ["2026-04-01", "2026-04-08", "2026-04-15"])
    }

    func testActiveDevicePointsIncludeEverySummary() {
        let store = TrendStore(
            summaries: [
                summary(date: "2026-04-01", totalDevices: 100),
                summary(date: "2026-04-08", totalDevices: 125),
            ],
            range: .all
        )

        let points = store.points(metric: .activeDevices)

        XCTAssertEqual(points.map { dateString($0.date) }, ["2026-04-01", "2026-04-08"])
        XCTAssertEqual(points.map(\.value), [100, 125])
    }

    func testActiveDevicesDemoSeriesUsesTotalDevicesTrend() {
        let points = TrendDemoSeries.points(for: .activeDevices, range: .all)

        XCTAssertEqual(points.count, min(TrendDemoSeries.dates.count, DemoData.totalDevicesTrend.count))
        XCTAssertEqual(points.map(\.value), DemoData.totalDevicesTrend)
    }

    func testDemoPointsClampMismatchedDateAndValueArrays() {
        let dates = ["2026-04-01", "2026-04-08", "2026-04-15"]
            .compactMap(SummaryJSONParser.dateFormatter.date)
        let values = [10.0, 20.0]

        let points = TrendDemoSeries.points(dates: dates, values: values, range: .all)

        XCTAssertEqual(points.map { dateString($0.date) }, ["2026-04-01", "2026-04-08"])
        XCTAssertEqual(points.map(\.value), values)
    }

    private func summary(
        date: String,
        totalDevices: Int = 500,
        compliancePct: Double? = 90,
        crowdstrikePct: Double? = 95
    ) -> DailySummary {
        DailySummary(
            date: date,
            totalDevices: totalDevices,
            fileVaultPct: 98,
            compliancePct: compliancePct,
            staleCount: 12,
            osCurrentPct: 80,
            crowdstrikePct: crowdstrikePct,
            patchPct: 88
        )
    }

    private func dateString(_ date: Date) -> String {
        SummaryJSONParser.dateFormatter.string(from: date)
    }

    // MARK: - stabilityIndex tests

    func testStabilityIndexCalculation() throws {
        // Normal case: compliance=90, patch=80, stale=10/100
        let idx1 = TrendSeries.stabilityIndex(compliancePct: 90, patchPct: 80, staleCount: 10, totalDevices: 100)
        XCTAssertEqual(try XCTUnwrap(idx1), 86.0, accuracy: 0.1)

        // compliancePct is nil -> returns nil
        let idx2 = TrendSeries.stabilityIndex(compliancePct: nil, patchPct: 80, staleCount: 10, totalDevices: 100)
        XCTAssertNil(idx2)

        // staleCount = 0, staleInverse = 100
        let idx3 = TrendSeries.stabilityIndex(compliancePct: 90, patchPct: 80, staleCount: 0, totalDevices: 100)
        XCTAssertEqual(try XCTUnwrap(idx3), 88.0, accuracy: 0.1)

        // All stale, staleInverse = 0
        let idx4 = TrendSeries.stabilityIndex(compliancePct: 90, patchPct: 80, staleCount: 100, totalDevices: 100)
        XCTAssertEqual(try XCTUnwrap(idx4), 68.0, accuracy: 0.1)

        // All perfect -> 100
        let idx5 = TrendSeries.stabilityIndex(compliancePct: 100, patchPct: 100, staleCount: 0, totalDevices: 100)
        XCTAssertEqual(try XCTUnwrap(idx5), 100.0, accuracy: 0.1)

        // All terrible -> 0
        let idx6 = TrendSeries.stabilityIndex(compliancePct: 0, patchPct: 0, staleCount: 100, totalDevices: 100)
        XCTAssertEqual(try XCTUnwrap(idx6), 0.0, accuracy: 0.1)
    }

    // MARK: - chartDomain tests

    func testChartDomainReturnsNilWhenEmpty() {
        let store = TrendStore(summaries: [], range: .w26)
        XCTAssertNil(store.chartDomain)
    }

    func testChartDomainForFourWeekRange() {
        let store = TrendStore(
            summaries: [
                summary(date: "2026-04-01"),
                summary(date: "2026-04-15"),
                summary(date: "2026-05-01"),
            ],
            range: .w4
        )
        guard let domain = store.chartDomain else {
            XCTFail("chartDomain should not be nil")
            return
        }
        let endDateStr = dateString(domain.upperBound)
        XCTAssertEqual(endDateStr, "2026-05-01")
        // startDate should be ~4 weeks before 2026-05-01
        let startDateStr = dateString(domain.lowerBound)
        XCTAssertTrue(startDateStr <= "2026-04-03" && startDateStr >= "2026-03-31",
                    "startDate \(startDateStr) not in expected range")
    }

    func testChartDomainForAllRange() {
        let store = TrendStore(
            summaries: [
                summary(date: "2026-01-01"),
                summary(date: "2026-05-01"),
            ],
            range: .all
        )
        guard let domain = store.chartDomain else {
            XCTFail("chartDomain should not be nil")
            return
        }
        let startDateStr = dateString(domain.lowerBound)
        let endDateStr = dateString(domain.upperBound)
        XCTAssertEqual(startDateStr, "2026-01-01")
        XCTAssertEqual(endDateStr, "2026-05-01")
    }

    func testChartDomainSingleSummary() {
        let store = TrendStore(
            summaries: [summary(date: "2026-05-01")],
            range: .w4
        )
        guard let domain = store.chartDomain else {
            XCTFail("chartDomain should not be nil")
            return
        }
        let startDateStr = dateString(domain.lowerBound)
        let endDateStr = dateString(domain.upperBound)
        XCTAssertEqual(startDateStr, "2026-04-03")
        XCTAssertEqual(endDateStr, "2026-05-01")
    }
}
