import Foundation
import XCTest
@testable import JamfReports

final class ComplianceBandingServiceTests: XCTestCase {

    // MARK: - v3.5 parity anchor
    //
    // Mirrors `_category_counts()` in jamf_reports_cli_v3.5.py against a
    // synthetic mix that exercises every band. If we ever change the
    // thresholds this test will fail loud, which is the goal.
    func testCategoryCountsMatchLegacyThresholds() {
        let failures: [Int?] = [
            // Pass (0)
            0, 0, 0, 0, 0,
            // Low (1–10): 6 devices
            1, 2, 5, 7, 9, 10,
            // Med-Low (11–30): 3 devices
            11, 20, 30,
            // Medium (31–50): 2 devices
            31, 50,
            // High (>50): 4 devices
            51, 100, 200, 500,
            // No data: 2 devices
            nil, nil
        ]
        let bands = ComplianceBandingService.bands(failures: failures)
        let byLabel = Dictionary(uniqueKeysWithValues: bands.map { ($0.label, $0.count) })

        XCTAssertEqual(byLabel["Pass"], 5)
        XCTAssertEqual(byLabel["Low"], 6)
        XCTAssertEqual(byLabel["Med-Low"], 3)
        XCTAssertEqual(byLabel["Medium"], 2)
        XCTAssertEqual(byLabel["High"], 4)
        XCTAssertEqual(byLabel["No Data"], 2)
    }

    func testBoundaryValuesGoIntoCorrectBucket() {
        XCTAssertEqual(ComplianceBandingService.Band.from(failures: 0), .pass)
        XCTAssertEqual(ComplianceBandingService.Band.from(failures: 1), .low)
        XCTAssertEqual(ComplianceBandingService.Band.from(failures: 10), .low)
        XCTAssertEqual(ComplianceBandingService.Band.from(failures: 11), .medLow)
        XCTAssertEqual(ComplianceBandingService.Band.from(failures: 30), .medLow)
        XCTAssertEqual(ComplianceBandingService.Band.from(failures: 31), .medium)
        XCTAssertEqual(ComplianceBandingService.Band.from(failures: 50), .medium)
        XCTAssertEqual(ComplianceBandingService.Band.from(failures: 51), .high)
        XCTAssertEqual(ComplianceBandingService.Band.from(failures: nil), .noData)
        XCTAssertEqual(ComplianceBandingService.Band.from(failures: -1), .noData,
                       "Negative failure counts must not be treated as Pass")
    }

    func testPercentagesSumToOneHundredWithoutNoData() {
        // 100 devices: 70 Pass, 20 Low, 10 High. NoData is empty.
        let failures: [Int?] =
            Array(repeating: 0, count: 70) +
            Array(repeating: 5, count: 20) +
            Array(repeating: 100, count: 10)

        let bands = ComplianceBandingService.bands(failures: failures)
        let sum = bands.reduce(0.0) { $0 + $1.pct }

        XCTAssertEqual(sum, 100.0, accuracy: 0.01)
    }

    func testEmptyInputReturnsZeroedBandsNotEmptyArray() {
        // Donut needs a renderable empty state; an empty array would
        // break SectorMark.
        let bands = ComplianceBandingService.bands(failures: [])
        XCTAssertEqual(bands.count, 6)
        XCTAssertTrue(bands.allSatisfy { $0.count == 0 })
        XCTAssertTrue(bands.allSatisfy { $0.pct == 0 })
    }

    func testBandOrderIsBestToWorstThenNoData() {
        let bands = ComplianceBandingService.bands(
            failures: Array(repeating: 0, count: 5)
        )
        XCTAssertEqual(bands.map(\.label),
                       ["Pass", "Low", "Med-Low", "Medium", "High", "No Data"])
    }

    func testParseOSMajorAcceptsMultipleFormats() {
        XCTAssertEqual(ComplianceBandingService.parseOSMajor("15.4.1"), 15)
        XCTAssertEqual(ComplianceBandingService.parseOSMajor("14"), 14)
        XCTAssertEqual(ComplianceBandingService.parseOSMajor("macOS 13.6.5"), 13)
        XCTAssertEqual(ComplianceBandingService.parseOSMajor("macOS Sonoma 14.7.5"), 14)
        XCTAssertNil(ComplianceBandingService.parseOSMajor(""))
        XCTAssertNil(ComplianceBandingService.parseOSMajor("Unknown"))
    }

    func testBandsByOSMajorGroupsAndSortsNewestFirst() {
        let pairs: [(osMajor: Int, failures: Int?)] = [
            (15, 0), (15, 0), (15, 25),
            (14, 60), (14, 5),
            (26, 0),
        ]
        let groups = ComplianceBandingService.bandsByOSMajor(pairs)

        XCTAssertEqual(groups.map(\.osMajor), [26, 15, 14],
                       "Groups must sort newest macOS major first")

        let fifteen = groups.first { $0.osMajor == 15 }!.bands
        let fifteenByLabel = Dictionary(uniqueKeysWithValues:
            fifteen.map { ($0.label, $0.count) })
        XCTAssertEqual(fifteenByLabel["Pass"], 2)
        XCTAssertEqual(fifteenByLabel["Med-Low"], 1)

        let fourteen = groups.first { $0.osMajor == 14 }!.bands
        let fourteenByLabel = Dictionary(uniqueKeysWithValues:
            fourteen.map { ($0.label, $0.count) })
        XCTAssertEqual(fourteenByLabel["Low"], 1)
        XCTAssertEqual(fourteenByLabel["High"], 1)
    }
}
