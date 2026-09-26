import XCTest
@testable import JamfReports

/// Pins `TrendsView.chartYDomain`: device counts get a top derived from the data, so a small
/// fleet fills the chart, while percentage metrics keep their preferred frame.
final class TrendsViewYDomainTests: XCTestCase {

    func testSmallFleetIsNotFlattenedUnderAThousand() {
        // The demo fleet: 524 Macs and 25 mobile devices.
        let domain = TrendsView.chartYDomain(metric: .managedDevices, values: [520, 524, 25, 23])
        XCTAssertEqual(domain.lowerBound, 0)
        XCTAssertEqual(domain.upperBound, 580, accuracy: 0.0001)
    }

    func testLargeFleetKeepsHeadroomAboveItsLargestCount() {
        let domain = TrendsView.chartYDomain(metric: .managedDevices, values: [1_050, 1_100])
        XCTAssertEqual(domain.upperBound, 1_400, accuracy: 0.0001)
        XCTAssertGreaterThan(domain.upperBound, 1_100)
    }

    func testActiveDevicesFollowTheDataToo() {
        let domain = TrendsView.chartYDomain(metric: .activeDevices, values: [40, 42])
        XCTAssertEqual(domain.lowerBound, 0)
        XCTAssertEqual(domain.upperBound, 48, accuracy: 0.0001)
    }

    func testDeviceCountAxisTopNeverDropsBelowTen() {
        XCTAssertEqual(TrendsView.deviceCountAxisTop(0), 10, accuracy: 0.0001)
        XCTAssertEqual(TrendsView.deviceCountAxisTop(3), 10, accuracy: 0.0001)
    }

    func testDeviceCountAxisTopRoundsUpToAFifthOfTheMagnitude() {
        XCTAssertEqual(TrendsView.deviceCountAxisTop(25), 28, accuracy: 0.0001)
        XCTAssertEqual(TrendsView.deviceCountAxisTop(1_000), 1_200, accuracy: 0.0001)
    }

    func testNoDataKeepsTheMetricFrame() {
        let metric = TrendSeries.Metric.managedDevices
        let domain = TrendsView.chartYDomain(metric: metric, values: [])
        XCTAssertEqual(domain, metric.minY...metric.maxY)
    }

    func testPercentMetricKeepsItsPreferredFrame() {
        let domain = TrendsView.chartYDomain(metric: .stability, values: [70, 72])
        XCTAssertEqual(domain, 40...100)
    }

    func testPercentMetricStillExpandsBelowItsFloor() {
        let domain = TrendsView.chartYDomain(metric: .stability, values: [0, 25])
        XCTAssertEqual(domain, 0...100)
    }
}
