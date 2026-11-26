import XCTest
@testable import JamfReports

/// M6: the Fleet Overview's device tiles read the summary's four maps, and a map or bucket the
/// summary lacks draws nothing rather than a 0.
final class FleetDeviceMapTileTests: XCTestCase {
    private typealias Row = FleetDeviceMapTile.Row

    private func summary(
        osMajorCounts: [String: Int]? = nil, modelFamilyCounts: [String: Int]? = nil,
        mobileFormFactorCounts: [String: Int]? = nil, lastSeenBuckets: LastSeenBuckets? = nil
    ) -> DailySummary {
        DailySummary(
            date: "2026-11-12", totalDevices: 12, fileVaultPct: nil, compliancePct: nil,
            staleCount: nil, osCurrentPct: nil, crowdstrikePct: nil, patchPct: nil,
            osMajorCounts: osMajorCounts,
            modelFamilyCounts: modelFamilyCounts, mobileFormFactorCounts: mobileFormFactorCounts,
            lastSeenBuckets: lastSeenBuckets)
    }

    func testASummaryWithoutMapsDrawsNoTile() {
        XCTAssertEqual(FleetDeviceMapTile.tiles(nil), [])
        XCTAssertEqual(FleetDeviceMapTile.tiles(summary()), [])
        let empty = summary(
            osMajorCounts: ["macOS 26": 4], modelFamilyCounts: [:],
            lastSeenBuckets: LastSeenBuckets(computers: nil, mobile: nil))
        XCTAssertEqual(FleetDeviceMapTile.tiles(empty), [])
    }

    /// The OS, model and device-type maps are drawn per platform (`PlatformOverviewTests`);
    /// the tiles are the two last-seen halves.
    func testOnlyTheLastSeenHalvesAreTiles() {
        let tiles = FleetDeviceMapTile.tiles(summary(
            osMajorCounts: ["macOS 26": 7, "iOS 18": 3],
            modelFamilyCounts: ["MacBook Pro": 5],
            mobileFormFactorCounts: ["iPhone": 3],
            lastSeenBuckets: LastSeenBuckets(
                computers: .init(underOneDay: 10, sevenDaysOrMore: 2),
                mobile: .init(never: 3))))
        XCTAssertEqual(tiles.map(\.title), ["Macs last seen", "Mobile devices last seen"])
        // An unmeasured bucket is no row, never "0".
        XCTAssertEqual(tiles[0].rows, [Row(label: "Under a day", count: 10),
                                       Row(label: "7 days or more", count: 2)])
        XCTAssertEqual(tiles[1].rows, [Row(label: "Never", count: 3)])
    }

    /// Demo mode draws the tiles from the same 524 Macs and 25 mobile devices its screens list.
    func testTheDemoMapsCountTheDemoFleet() throws {
        let maps = DemoData.summaryDeviceMaps
        let macOS = try XCTUnwrap(maps.osMajor).filter { $0.key.hasPrefix("macOS") }
        XCTAssertEqual(macOS.values.reduce(0, +), DemoData.totalDevices)
        XCTAssertEqual(try XCTUnwrap(maps.modelFamily).values.reduce(0, +), DemoData.totalDevices)
        XCTAssertEqual(try XCTUnwrap(maps.lastSeen?.computers).total, DemoData.totalDevices)
        XCTAssertEqual(try XCTUnwrap(maps.formFactor).values.reduce(0, +),
                       MobileFleetView.makeDemoSnapshot().richDevices.count)
        XCTAssertEqual(DemoData.totalDevices, 524)
    }
}
