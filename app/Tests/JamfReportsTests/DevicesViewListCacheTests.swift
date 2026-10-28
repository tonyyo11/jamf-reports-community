import XCTest
@testable import JamfReports

/// The Computers list is built once per input change, not once per redraw (#305), and what it
/// builds equals what the screen computed on every redraw before.
@MainActor
final class DevicesViewListCacheTests: XCTestCase {
    typealias Screen = DevicesView

    private let policy = SecurityControlPolicy.default
    private let rule = StaleRule(days: 30)

    private func fleet(_ count: Int) -> [DeviceInventoryRecord] {
        let versions = ["15.6", "15.7.3", "26.0", "26.1"]
        let states = ["Encrypted", "Not Encrypted", "Encrypted", ""]
        return (0..<count).map { i in
            var record = DeviceInventoryRecord.empty(id: "serial:C\(i)", source: "computers.json")
            record.name = "Mac-\((i * 7919) % count)"
            record.serial = "C\(i)"
            record.osVersion = versions[i % versions.count]
            record.fileVault = states[i % states.count]
            record.sip = i % 5 == 0 ? "Disabled" : "Enabled"
            record.daysSinceContact = i % 11 == 0 ? nil : i % 90
            record.patchFailures = (0..<(i % 4)).map {
                DevicePatchFailure(title: "T\($0)", status: "failed", date: "", latestVersion: "")
            }
            record.user = i % 3 == 0 ? "user\(i)" : ""
            return record
        }
    }

    private func risk(_ device: DeviceInventoryRecord) -> DeviceRisk {
        RiskScoringService.risk(for: device, policy: policy, staleRule: rule)
    }

    /// The pipeline the view ran per redraw before the cache: the same predicates, written
    /// out in full, then the shared sort.
    private func legacyRows(
        _ devices: [DeviceInventoryRecord], query: String, osFilter: String?,
        filter: Screen.DeviceFilter, sortOrder: [KeyPathComparator<DeviceSortRow>]
    ) -> [DeviceSortRow] {
        let matching = devices.filter { device in
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !device.searchableText.contains(query.lowercased()) { return false }
            if let osFilter, device.osVersion != osFilter { return false }
            switch filter {
            case .all: return true
            case .stale: return device.isStale(rule)
            case .contactGap: return device.contactGap(rule: rule, gapDays: 14) != nil
            case .binaryMissing: return device.isBinaryMissing
            case .patch: return device.patchFailureCount > 0
            case .security: return device.securityGapCount(policy: policy) > 0
            case .priorityAction: return risk(device).level >= .high
            }
        }
        return DeviceSortRow.sorted(
            matching, using: sortOrder,
            securityGaps: { $0.securityGapCount(policy: policy) }, riskScore: { risk($0).score })
    }

    private func cachedRows(
        _ devices: [DeviceInventoryRecord], query: String, osFilter: String?,
        filter: Screen.DeviceFilter, sortOrder: [KeyPathComparator<DeviceSortRow>]
    ) -> [DeviceSortRow] {
        Screen.buildRows(
            devices: devices, query: query, osFilter: osFilter, filter: filter,
            sortOrder: sortOrder, policy: policy, staleRule: rule, contactGapDays: 14,
            searchableText: { $0.searchableText }, risk: risk)
    }

    private let sorts: [KeyPathComparator<DeviceSortRow>] = [
        KeyPathComparator(\DeviceSortRow.device.displayName),
        KeyPathComparator(\DeviceSortRow.contactDays, order: .reverse),
        KeyPathComparator(\DeviceSortRow.patchFailures, order: .reverse),
        KeyPathComparator(\DeviceSortRow.securityGaps, order: .reverse),
        KeyPathComparator(\DeviceSortRow.riskScore, order: .reverse),
    ]

    func testEveryFilterSortAndSearchEqualsThePreviousPipeline() {
        let devices = fleet(300)
        for filter in Screen.DeviceFilter.allCases {
            for sort in sorts {
                for (query, os) in [("", nil), ("  ", nil), ("MAC-1", nil), ("", "26.0"), ("c2", "15.6")]
                    as [(String, String?)] {
                    let expected = legacyRows(
                        devices, query: query, osFilter: os, filter: filter, sortOrder: [sort])
                    let actual = cachedRows(
                        devices, query: query, osFilter: os, filter: filter, sortOrder: [sort])
                    XCTAssertEqual(
                        actual.map(\.device.id), expected.map(\.device.id),
                        "\(filter) \(sort.keyPath) \(query) \(os ?? "-")")
                    XCTAssertEqual(actual.map(\.riskScore), expected.map(\.riskScore))
                    XCTAssertEqual(actual.map(\.securityGaps), expected.map(\.securityGaps))
                }
            }
        }
    }

    // MARK: - Cache

    private func listKey(
        revision: Int = 0, query: String = "", os: String? = nil,
        filter: Screen.DeviceFilter = .all, staleDays: Int = 30,
        sort: KeyPathComparator<DeviceSortRow> = KeyPathComparator(\DeviceSortRow.device.displayName)
    ) -> Screen.ListKey {
        Screen.ListKey(
            data: Screen.DataKey(
                dataRevision: revision, demoMode: false, staleDays: staleDays,
                agentConnectedValue: nil),
            query: query, osFilter: os, filter: filter, sortOrder: [sort])
    }

    func testTenRedrawsWithUnchangedInputsBuildTheListOnce() {
        let devices = fleet(200)
        let cache = Screen.ListCache()
        let key = listKey()
        var results: [Screen.DerivedList] = []
        for _ in 0..<10 {
            results.append(cache.list(for: key) {
                cachedRows(devices, query: "", osFilter: nil, filter: .all, sortOrder: key.sortOrder)
            })
        }
        XCTAssertEqual(cache.listBuilds, 1)
        XCTAssertEqual(Set(results.map { $0.devices.map(\.id) }).count, 1)
    }

    func testEachInputRebuildsTheListAndNothingElseDoes() {
        let cache = Screen.ListCache()
        let keys = [
            listKey(), listKey(query: "mac"), listKey(os: "26.0"), listKey(filter: .stale),
            listKey(sort: KeyPathComparator(\DeviceSortRow.riskScore)), listKey(staleDays: 45),
            listKey(revision: 1),
        ]
        for (index, key) in keys.enumerated() {
            _ = cache.list(for: key) { [] }
            _ = cache.list(for: key) { [] }
            XCTAssertEqual(cache.listBuilds, index + 1, "\(key)")
        }
    }

    func testFiguresSurviveAListChangeButNotADataChange() {
        let cache = Screen.ListCache()
        let snapshot = DeviceInventorySnapshot(
            devices: fleet(50), patchTitles: [], sourceFiles: [], warnings: [],
            generatedAt: "", generatedDate: nil, isDemo: false)
        let first = listKey()
        func figures(_ key: Screen.ListKey) -> Screen.Figures {
            cache.figures(for: key.data) { Screen.Figures(snapshot: snapshot, rule: rule) }
        }
        let built = figures(first)
        _ = figures(listKey(query: "mac"))
        _ = figures(listKey(filter: .patch))
        XCTAssertEqual(cache.figureBuilds, 1, "typing in the search box leaves the figures alone")
        XCTAssertEqual(built.patchIssueCount, snapshot.patchIssueCount)
        XCTAssertEqual(built.osDistribution, snapshot.osDistribution)
        XCTAssertEqual(built.fileVaultPercent, snapshot.fileVaultPercent)
        _ = figures(listKey(staleDays: 60))
        _ = figures(listKey(revision: 1))
        XCTAssertEqual(cache.figureBuilds, 3)
    }

    func testARiskIsRatedOncePerDataAndRatedAgainWhenTheDataMoves() {
        let cache = Screen.ListCache()
        let device = fleet(1)[0]
        var rated = 0
        func read(_ key: Screen.DataKey) {
            _ = cache.risk(of: device, key: key) { rated += 1; return risk(device) }
        }
        let key = listKey().data
        (0..<5).forEach { _ in read(key) }
        XCTAssertEqual(rated, 1)
        read(listKey(revision: 1).data)
        XCTAssertEqual(rated, 2)
        read(listKey(staleDays: 60).data)
        XCTAssertEqual(rated, 3, "the stale window is a factor of the rating")
    }

    func testListLookupFindsTheSelectedRowAndTheFirstOtherwise() {
        let devices = fleet(5)
        let list = Screen.DerivedList(
            rows: cachedRows(devices, query: "", osFilter: nil, filter: .all, sortOrder: sorts))
        XCTAssertEqual(list.device(withID: "serial:C3")?.serial, "C3")
        XCTAssertNil(list.device(withID: "serial:nope"))
        XCTAssertNil(list.device(withID: nil))
        XCTAssertEqual(list.devices.count, 5)
    }

    // MARK: - Measurement

    /// Before: a redraw ran the filter and sort about eight times (the header, the filter
    /// strip, the table, its overlay, the detail panel). After: once per input change. The
    /// times are printed for the report; the assertions are the build counts.
    func testTimingOfARedrawBurstOn2000Records() {
        let devices = fleet(2_000)
        let passesPerRedraw = 8
        let redraws = 5
        let clock = ContinuousClock()
        // The Priority filter sorted by risk rates every Mac; All sorted by name rates none.
        let cases: [(String, Screen.DeviceFilter, String, KeyPathComparator<DeviceSortRow>)] = [
            ("priority/risk", .priorityAction, "mac", KeyPathComparator(\DeviceSortRow.riskScore, order: .reverse)),
            ("all/name", .all, "", KeyPathComparator(\DeviceSortRow.device.displayName)),
        ]
        for (label, filter, query, sort) in cases {
            let before = clock.measure {
                for _ in 0..<(redraws * passesPerRedraw) {
                    _ = legacyRows(devices, query: query, osFilter: nil, filter: filter, sortOrder: [sort])
                }
            }
            let cache = Screen.ListCache()
            let key = listKey(query: query, filter: filter, sort: sort)
            let after = clock.measure {
                for _ in 0..<(redraws * passesPerRedraw) {
                    _ = cache.list(for: key) {
                        Screen.buildRows(
                            devices: devices, query: query, osFilter: nil, filter: filter,
                            sortOrder: [sort], policy: policy, staleRule: rule, contactGapDays: 14,
                            searchableText: { cache.searchableText(of: $0, key: key.data) },
                            risk: { device in
                                cache.risk(of: device, key: key.data) { self.risk(device) }
                            })
                    }
                }
            }
            XCTAssertEqual(cache.listBuilds, 1)
            print("[6.5 timing] \(label), \(redraws) redraws x \(passesPerRedraw) passes, "
                  + "2000 records: before \(before), after \(after)")
        }
    }
}
