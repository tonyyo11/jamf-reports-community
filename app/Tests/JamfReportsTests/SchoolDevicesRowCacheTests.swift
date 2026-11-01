import XCTest
@testable import JamfReports

/// The School device list sorts once per data change and filters once per filter change, and
/// what it builds equals the old per-redraw filter-then-sort.
@MainActor
final class SchoolDevicesRowCacheTests: XCTestCase {
    typealias Screen = SchoolDevicesView
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func fleet() -> [SchoolFleetService.Device] {
        var devices: [SchoolFleetService.Device] = []
        for i in 0..<40 {
            let even = i % 2 == 0
            let managed: Bool? = i % 3 == 0 ? nil : i % 3 == 1
            devices.append(SchoolFleetService.Device(
                id: "d\(i)", name: "iPad \((i * 7) % 40)", serial: "S\(i)",
                model: even ? "iPad9" : "Mac14", os: even ? "iPadOS 18" : "macOS 15",
                isManaged: managed, isSupervised: true,
                lastCheckin: now.addingTimeInterval(-Double(i) * 5 * 86_400), inTrash: false))
        }
        return devices
    }

    private func key(
        _ filter: Screen.Filter = .all, query: String = "", reloads: Int = 0
    ) -> Screen.RowCache.Key {
        Screen.RowCache.Key(
            data: .init(source: "false|p", reloads: reloads, collectedAt: now, count: 40),
            filter: filter, query: query, staleDays: 30, hourBucket: 1)
    }

    func testCachedRowsMatchTheFilterThenSortPipeline() {
        let devices = fleet()
        let cache = Screen.RowCache()
        for filter in Screen.Filter.allCases {
            let expected = Screen.sortedByName(
                Screen.filtered(devices, filter: filter, query: "ipad", staleDays: 30, now: now))
            let got = cache.rows(for: key(filter, query: "ipad"), devices: devices, now: now)
            XCTAssertEqual(got, expected, "\(filter)")
        }
    }

    func testSearchKeystrokeDoesNotSortAgain() {
        let devices = fleet()
        let cache = Screen.RowCache()
        _ = cache.rows(for: key(), devices: devices, now: now)
        _ = cache.rows(for: key(query: "i"), devices: devices, now: now)
        _ = cache.rows(for: key(query: "ip"), devices: devices, now: now)
        XCTAssertEqual(cache.sortBuilds, 1)
        XCTAssertEqual(cache.filterBuilds, 3)
    }

    func testSameKeyReusesTheListAndNewDataRebuilds() {
        let devices = fleet()
        let cache = Screen.RowCache()
        _ = cache.rows(for: key(), devices: devices, now: now)
        _ = cache.rows(for: key(), devices: devices, now: now)
        XCTAssertEqual(cache.filterBuilds, 1)
        _ = cache.rows(for: key(reloads: 1), devices: devices, now: now)
        XCTAssertEqual(cache.sortBuilds, 2)
        XCTAssertEqual(cache.filterBuilds, 2)
    }
}
