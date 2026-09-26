import XCTest
@testable import JamfReports

/// The demo macOS Distribution legend must read as the live one does, so a demo
/// label never shows a form the live Overview cannot produce.
@MainActor
final class DemoDataOSDistributionTests: XCTestCase {

    func testDemoLabelsMatchTheLiveLabelForTheSameVersions() {
        let demo = DemoData.osDistribution
        let counts = Dictionary(uniqueKeysWithValues: demo.map {
            (DemoData.osVersionNumber($0.version), $0.count)
        })
        let live = OverviewLiveDataLoader.osDistribution(
            counts: counts, latestByMajor: [:], limit: OverviewLiveDataLoader.osRowLimit)

        XCTAssertEqual(demo.map(\.version), live.rows.map(\.version))
    }

    func testDemoLabelsAreOneForm() {
        for entry in DemoData.osDistribution {
            XCTAssertEqual(entry.version, "macOS " + DemoData.osVersionNumber(entry.version))
        }
    }
}
