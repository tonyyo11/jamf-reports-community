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
            modelFamilyCounts: [:],
            lastSeenBuckets: LastSeenBuckets(computers: nil, mobile: nil))
        XCTAssertEqual(FleetDeviceMapTile.tiles(empty), [])
    }

    func testEachMapIsOneTileInOrder() {
        let tiles = FleetDeviceMapTile.tiles(summary(
            osMajorCounts: ["iPadOS 18": 2, "macOS 9": 1, "macOS 15": 4, "macOS 26": 7,
                            "iOS 18": 3],
            modelFamilyCounts: ["Other": 9, "MacBook Air": 2, "Mac mini": 2, "MacBook Pro": 5],
            mobileFormFactorCounts: ["iPhone": 3, "iPad": 2],
            lastSeenBuckets: LastSeenBuckets(
                computers: .init(underOneDay: 10, sevenDaysOrMore: 2), mobile: nil)))
        XCTAssertEqual(tiles.map(\.title),
                       ["Mac models", "Operating systems", "Mobile device types", "Macs last seen"])
        XCTAssertEqual(tiles[0].rows, [Row(label: "MacBook Pro", count: 5),
                                       Row(label: "Mac mini", count: 2),
                                       Row(label: "MacBook Air", count: 2),
                                       Row(label: "Other", count: 9)])
        XCTAssertEqual(tiles[1].rows.map(\.label),
                       ["macOS 26", "macOS 15", "macOS 9", "iOS 18", "iPadOS 18"])
        XCTAssertEqual(tiles[2].rows, [Row(label: "iPhone", count: 3), Row(label: "iPad", count: 2)])
        // An unmeasured bucket is no row, never "0".
        XCTAssertEqual(tiles[3].rows, [Row(label: "Under a day", count: 10),
                                       Row(label: "7 days or more", count: 2)])
    }

    /// Demo mode draws the tiles from the same 524 Macs and 25 mobile devices its screens list.
    func testTheDemoMapsCountTheDemoFleet() throws {
        let maps = DemoData.summaryDeviceMaps
        let macOS = try XCTUnwrap(maps.osMajor).filter { $0.key.hasPrefix("macOS") }
        XCTAssertEqual(macOS.values.reduce(0, +), DemoData.totalDevices)
        XCTAssertNil(maps.modelFamily, "the demo Macs carry no model, so no tile, never 0")
        XCTAssertEqual(try XCTUnwrap(maps.lastSeen?.computers).total, DemoData.totalDevices)
        XCTAssertEqual(try XCTUnwrap(maps.formFactor).values.reduce(0, +),
                       MobileFleetView.makeDemoSnapshot().richDevices.count)
        XCTAssertEqual(DemoData.totalDevices, 524)
    }
}
