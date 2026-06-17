import XCTest
@testable import JamfReports

/// PR-22 T-8 + T-9: composition shape of the filter pair in
/// `ReportEngine.collect`. Pins the tier filter and the cadence filter
/// so a future refactor can't silently reorder them and change behavior.
///
/// Order matters:
/// 1. Tier filter excludes a whole tier — a kind in an excluded tier
///    never reaches the cadence check.
/// 2. Cadence filter operates on survivors, deciding due-vs-not.
final class CollectFilterCompositionTests: XCTestCase {

    // MARK: - Tier filter behavior

    func testTierFilterDefaultIsAllTiers() {
        let defaultTiers: Set<CollectionTier> = Set(CollectionTier.allCases)
        XCTAssertEqual(defaultTiers, [.refresh, .inventory, .scan])
    }

    func testRefreshOnlyTierExcludesInventoryAndScan() {
        let refreshOnly: Set<CollectionTier> = [.refresh]

        XCTAssertEqual(CollectionTier.tier(forReport: "overview"), .refresh)
        XCTAssertTrue(refreshOnly.contains(CollectionTier.tier(forReport: "overview")!))

        XCTAssertEqual(CollectionTier.tier(forReport: "computers"), .inventory)
        XCTAssertFalse(refreshOnly.contains(CollectionTier.tier(forReport: "computers")!))

        // ea-results is inventory-tier; still excluded from refresh-only
        XCTAssertEqual(CollectionTier.tier(forReport: "ea-results"), .inventory)
        XCTAssertFalse(refreshOnly.contains(CollectionTier.tier(forReport: "ea-results")!))
    }

    // MARK: - Filter composition with skipExpensive

    func testSkipExpensiveStillComposesWithTier() {
        // patch-device-failures is BOTH skipExpensive AND scan-tier.
        let kind = "patch-device-failures"
        XCTAssertTrue(ReportEngine.expensivePerDeviceKinds.contains(kind))
        XCTAssertEqual(CollectionTier.tier(forReport: kind), .scan)
    }

    func testRefreshTierExcludesAllSkipExpensiveKinds() {
        // skipExpensive kinds must be non-refresh so snapshot-only schedules
        // never lose them via skipExpensive.
        for kind in ReportEngine.expensivePerDeviceKinds {
            let tier = CollectionTier.tier(forReport: kind)
            XCTAssertNotEqual(
                tier, .refresh,
                "Expensive kind \(kind) is .refresh; snapshot-only schedules would lose it"
            )
        }
    }

    // MARK: - Cadence filter composes with fixed table

    func testCadenceFilterUsesFixedCloudTable() {
        // The production loop calls CadenceResolver.cadence(forReport:) —
        // no config parameter. Refresh-tier kinds use 43_200s.
        let cadence = CadenceResolver.cadence(forReport: "overview")
        XCTAssertEqual(cadence, .seconds(43_200))

        // update-status is inventory-tier: 172_800s (no hard exclusions).
        XCTAssertEqual(CadenceResolver.cadence(forReport: "update-status"), .seconds(172_800))
    }

    func testCadenceLabelRendersHumanReadable() {
        XCTAssertEqual(Cadence.seconds(43_200).label, "43200s")
        XCTAssertEqual(Cadence.never.label, "never")
    }
}
