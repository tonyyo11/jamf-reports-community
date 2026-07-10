import XCTest
@testable import JamfReports

/// Pins `TrendsView.relativeChangePercent` — the hero-chart "(N%)" relative
/// change parenthetical must omit itself when the comparison baseline is
/// near zero, since a tiny absolute move off a near-zero baseline produces
/// an arithmetically-correct but meaningless swing (e.g. 0.2% -> 16.2%
/// reads as "+8200%").
final class TrendsViewRelativeChangeTests: XCTestCase {

    func testNearZeroBaselineOmitsRelativeChange() {
        // The real prod case: "On Current macOS" 0.2% -> 16.2%.
        XCTAssertNil(TrendsView.relativeChangePercent(delta: 16.0, baseline: 0.2))
    }

    func testExactZeroBaselineOmitsRelativeChange() {
        XCTAssertNil(TrendsView.relativeChangePercent(delta: 16.0, baseline: 0))
    }

    func testBaselineAtFloorIsIncluded() {
        // Floor is inclusive: baseline == floor still computes.
        let result = TrendsView.relativeChangePercent(
            delta: 1.0,
            baseline: TrendsView.relativeChangeBaselineFloor
        )
        XCTAssertEqual(result, 100.0)
    }

    func testJustBelowFloorOmitsRelativeChange() {
        let justBelow = TrendsView.relativeChangeBaselineFloor - 0.01
        XCTAssertNil(TrendsView.relativeChangePercent(delta: 5.0, baseline: justBelow))
    }

    func testNormalBaselineComputesRelativeChange() {
        // 66.3% -> 68.3% is a +2.0 absolute change, +3.02% relative.
        let result = TrendsView.relativeChangePercent(delta: 2.0, baseline: 66.3)
        XCTAssertNotNil(result)
        XCTAssertEqual(result!, (2.0 / 66.3) * 100, accuracy: 0.0001)
    }

    func testNegativeBaselineMagnitudeRespectsFloor() {
        // Baseline sign shouldn't matter — only its magnitude vs. the floor.
        XCTAssertNil(TrendsView.relativeChangePercent(delta: 1.0, baseline: -0.5))
    }

    func testNegativeDeltaWithNormalBaselineComputes() throws {
        let result = try XCTUnwrap(TrendsView.relativeChangePercent(delta: -10.0, baseline: 50.0))
        XCTAssertEqual(result, -20.0, accuracy: 0.0001)
    }
}
