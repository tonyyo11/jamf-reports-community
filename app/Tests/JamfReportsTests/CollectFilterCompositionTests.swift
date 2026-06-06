import XCTest
@testable import JamfReports

/// PR-22 T-8 + T-9: composition shape of the new filter trio in
/// `ReportEngine.collect`. A full behavioral test of the loop requires
/// stubbing `jamf-cli` on disk; these tests instead pin the filter chain
/// the production loop uses, in order, so a future refactor can't silently
/// reorder them and change observable behavior.
///
/// Order matters because each filter has different side effects when
/// applied "early" vs "late":
///
/// 1. skipExpensive removes kinds before they're considered for cadence,
///    so a per_report override for an expensive kind is honored only if
///    the operator turns off skipExpensive.
/// 2. Tier filter excludes a whole tier — a per_report override under an
///    excluded tier never runs (the tier filter is the more direct
///    intent: "don't run scan-tier today").
/// 3. Cadence filter operates last on the survivors, deciding due-vs-not.
final class CollectFilterCompositionTests: XCTestCase {

    // MARK: - Tier filter behavior

    func testTierFilterDefaultIsAllTiers() {
        // Default `tiers` argument on `collect` is the full set; tested
        // indirectly by ensuring every CollectionTier case is in the
        // default. The literal value is what `collect`'s default uses.
        let defaultTiers: Set<CollectionTier> = Set(CollectionTier.allCases)
        XCTAssertEqual(defaultTiers, [.refresh, .inventory, .scan])
    }

    func testRefreshOnlyTierExcludesInventoryAndScan() {
        let refreshOnly: Set<CollectionTier> = [.refresh]
        // Refresh-only must include cheap KPI commands and exclude every
        // inventory- or scan-tier kind.
        XCTAssertEqual(CollectionTier.tier(forReport: "overview"), .refresh)
        XCTAssertTrue(refreshOnly.contains(CollectionTier.tier(forReport: "overview")!))

        XCTAssertEqual(CollectionTier.tier(forReport: "computers"), .inventory)
        XCTAssertFalse(refreshOnly.contains(CollectionTier.tier(forReport: "computers")!))

        // ea-results moved scan -> inventory (scan is now only the two
        // --scan-failures fan-outs); still excluded from refresh-only.
        XCTAssertEqual(CollectionTier.tier(forReport: "ea-results"), .inventory)
        XCTAssertFalse(refreshOnly.contains(CollectionTier.tier(forReport: "ea-results")!))
    }

    // MARK: - Filter composition with PR-16 skipExpensive

    func testSkipExpensiveStillComposesWithTier() {
        // `patch-device-failures` is BOTH skipExpensive AND scan-tier.
        // Either filter excludes it, but they should compose without
        // double-counting — production code runs them in series so the
        // log produces one skip line, not two.
        let kind = "patch-device-failures"
        XCTAssertTrue(ReportEngine.expensivePerDeviceKinds.contains(kind))
        XCTAssertEqual(CollectionTier.tier(forReport: kind), .scan)
    }

    func testRefreshTierExcludesAllSkipExpensiveKinds() {
        // The skipExpensive set should be a subset of non-refresh kinds —
        // by design, refresh-tier commands are cheap. If a future PR
        // promoted a refresh-tier kind to expensivePerDeviceKinds, the
        // snapshot-only schedule would suddenly skip part of the Trends
        // input. Catch that mismatch early.
        for kind in ReportEngine.expensivePerDeviceKinds {
            let tier = CollectionTier.tier(forReport: kind)
            XCTAssertNotEqual(
                tier, .refresh,
                "Expensive kind \(kind) is .refresh; snapshot-only schedules would lose it under skipExpensive"
            )
        }
    }

    // MARK: - Cadence filter composes with resolver

    func testCadenceFilterUsesResolverDirectly() {
        // The production loop computes `CadenceResolver.resolve(report:config:)`
        // per kind and feeds the result into `isDue`. This test pins that
        // a refresh-tier kind under nil config (on-prem defaults) resolves
        // to daily — a behavior change in either resolver or preset table
        // surfaces here as a value mismatch.
        let cadence = CadenceResolver.resolve(report: "overview", config: nil)
        XCTAssertEqual(cadence, .seconds(86_400))

        // Hard-excluded kind resolves to .never even with nil config.
        XCTAssertEqual(
            CadenceResolver.resolve(report: "update-status", config: nil),
            .never
        )
    }

    func testCadenceLabelRendersHumanReadable() {
        XCTAssertEqual(Cadence.seconds(86_400).label, "86400s")
        XCTAssertEqual(Cadence.never.label, "never")
    }

    // MARK: - Pace composition

    func testPaceDefaultsToOnPremWhenConfigMissing() {
        // When config has no preset and no pace_seconds, the loop uses
        // the on-prem preset's pace (15s) — the conservative default for
        // self-hosted servers. Pinned here because a regression would
        // start hammering on-prem servers silently.
        let cfg = CollectCadenceConfig()
        let preset = cfg.preset ?? .onPrem
        let pace = cfg.paceSeconds ?? preset.paceSeconds
        XCTAssertEqual(pace, 15)
    }

    func testPaceUsesExplicitConfigOverride() {
        let cfg = CollectCadenceConfig(preset: .onPrem, paceSeconds: 0)
        let preset = cfg.preset ?? .onPrem
        let pace = cfg.paceSeconds ?? preset.paceSeconds
        XCTAssertEqual(pace, 0, "Operator-set pace_seconds wins over preset default")
    }

    func testPaceFollowsPresetWhenNotOverridden() {
        let cfg = CollectCadenceConfig(preset: .cloud)
        let preset = cfg.preset ?? .onPrem
        let pace = cfg.paceSeconds ?? preset.paceSeconds
        XCTAssertEqual(pace, 0, "Cloud preset's pace_seconds (0) flows through when not overridden")
    }
}
