import Foundation
import XCTest
@testable import JamfReports

/// Tests for the `CollectionTier` enum (Refresh / Inventory / Scan).
final class CollectionTierLookupTests: XCTestCase {

    // MARK: - Total lookup contract

    /// PR-22 T-1 contract: every kind currently produced by
    /// `ReportEngine.collect` must have a tier assignment. If a future
    /// PR adds a new jamf-cli command to the collect loop without
    /// updating the tier map, this test fails with the missing kind
    /// in the assertion message.
    func testEveryKnownCollectKindHasATier() {
        let unmapped = ReportEngine.knownCollectKinds.filter {
            CollectionTier.tier(forReport: $0) == nil
        }
        XCTAssertTrue(
            unmapped.isEmpty,
            "These collect kinds have no tier assignment: \(unmapped.sorted()). " +
            "Update CollectionTier.tier(forReport:) to map them, or remove from " +
            "ReportEngine.knownCollectKinds if they're no longer collected."
        )
    }

    /// Inverse contract: tier assignments must reference real collect
    /// kinds, not invented names. Guards against drift where the tier
    /// map keeps entries for commands that have been deleted from
    /// `ReportEngine.collect`.
    func testEveryTieredKindIsKnownToReportEngine() {
        let known = Set(ReportEngine.knownCollectKinds)
        let orphans = CollectionTier.mappedKinds.filter { !known.contains($0) }
        XCTAssertTrue(
            orphans.isEmpty,
            "Tier map references unknown collect kinds: \(orphans.sorted()). " +
            "These commands aren't produced by ReportEngine.collect — either " +
            "remove the tier entry or wire the command up."
        )
    }

    /// Unknown report names must return nil rather than defaulting to
    /// a tier. Callers (CadenceResolver) need to distinguish "configured
    /// kind that's just not in this tier set" from "unknown kind that
    /// shouldn't even be considered."
    func testUnknownKindReturnsNil() {
        XCTAssertNil(CollectionTier.tier(forReport: "made-up-report"))
        XCTAssertNil(CollectionTier.tier(forReport: ""))
        XCTAssertNil(CollectionTier.tier(forReport: "OVERVIEW"))  // case-sensitive
    }

    // MARK: - Pinned tier assignments

    /// Refresh tier: cheap, summary-level reports the Overview KPIs and
    /// Trends summary depend on. Pinned because the Refresh tier defines
    /// what snapshot-only runs after PR-22; accidental moves to another
    /// tier would silently change snapshot-only behavior.
    func testRefreshTierContains() {
        let refresh: Set<String> = [
            "overview",
            "security",
            "inventory-summary",
            "patch-status",
            "policy-status",
        ]
        for kind in refresh {
            XCTAssertEqual(
                CollectionTier.tier(forReport: kind), .refresh,
                "\(kind) must be in the Refresh tier"
            )
        }
    }

    /// Scan tier: exactly the two `--scan-failures` per-device fan-out queries.
    /// Pinned so no additional expensive commands creep into the daily automation
    /// path and so daily (refresh+inventory) vs weekly (scan) stays expressible
    /// via `--tiers`.
    func testScanTierContainsExactly() {
        let expectedScan: Set<String> = [
            "patch-device-failures",
            "update-device-failures",
        ]
        // Every expected kind must be in .scan.
        for kind in expectedScan {
            XCTAssertEqual(
                CollectionTier.tier(forReport: kind), .scan,
                "\(kind) must be in the Scan tier"
            )
        }
        // The .scan set must contain ONLY those two kinds — no extras.
        let actualScan = Set(CollectionTier.mappedKinds.filter {
            CollectionTier.tier(forReport: $0) == .scan
        })
        XCTAssertEqual(
            actualScan, expectedScan,
            "Scan tier must contain exactly patch-device-failures and update-device-failures. " +
            "Extra: \(actualScan.subtracting(expectedScan).sorted()). " +
            "Missing: \(expectedScan.subtracting(actualScan).sorted())."
        )
    }

    /// The four formerly-scan kinds must now be in Inventory (daily-safe).
    func testFormerScanKindsAreNowInventory() {
        let movedToInventory: Set<String> = [
            "update-status",
            "device-compliance",
            "ea-results",
            "profile-status",
        ]
        for kind in movedToInventory {
            XCTAssertEqual(
                CollectionTier.tier(forReport: kind), .inventory,
                "\(kind) must be in the Inventory tier (daily-safe, no --scan-failures fan-out)"
            )
        }
    }

    /// Inventory tier: everything else — list-type endpoints feeding the
    /// Deep Dive screens. Spot-checked rather than enumerated because the
    /// total-lookup test above already proves no kind is unmapped.
    func testInventoryTierSpotChecks() {
        let inventorySamples = [
            "computers", "policies", "packages", "smart-computer-groups",
            "app-status", "classic-macos-profiles",
        ]
        for kind in inventorySamples {
            XCTAssertEqual(
                CollectionTier.tier(forReport: kind), .inventory,
                "\(kind) must be in the Inventory tier"
            )
        }
    }

    /// `audit` must be collected and in the Refresh tier. AuditView,
    /// HealthCheckView, and WorkspaceStore+Refresh all consume the "audit"
    /// snapshot; without this entry the scheduled Swift collect never writes
    /// the directory, leaving the audit manifest.json permanently stale.
    func testAuditKindIsCollectedAndRefreshTiered() {
        XCTAssertTrue(
            ReportEngine.knownCollectKinds.contains("audit"),
            "'audit' must be in knownCollectKinds so collect writes the snapshot"
        )
        XCTAssertEqual(
            CollectionTier.tier(forReport: "audit"), .refresh,
            "'audit' is a cheap single server call — must be Refresh tiered"
        )
    }

    /// `groups` must be collected (in knownCollectKinds) and assigned to the
    /// Inventory tier. Both `writeGroupHygiene` and `writeSmartGroups` read
    /// from the `groups` snapshot directory; without this entry collect never
    /// writes the directory and those sheets silently vanish on a fresh deploy.
    func testGroupsKindIsCollectedAndInventoryTiered() {
        XCTAssertTrue(
            ReportEngine.knownCollectKinds.contains("groups"),
            "'groups' must be in knownCollectKinds so collect writes the snapshot"
        )
        XCTAssertEqual(
            CollectionTier.tier(forReport: "groups"), .inventory,
            "'groups' is a list-type endpoint — must be Inventory tiered"
        )
    }

    // MARK: - Conformance

    func testCollectionTierIsCaseIterable() {
        XCTAssertEqual(Set(CollectionTier.allCases), [.refresh, .inventory, .scan])
    }

    /// Hashable conformance is load-bearing for `Set<CollectionTier>`
    /// usage in the tier filter (T-9). Verify the dictionary use case.
    func testCollectionTierIsHashable() {
        var byTier: [CollectionTier: Int] = [:]
        for kind in ReportEngine.knownCollectKinds {
            if let tier = CollectionTier.tier(forReport: kind) {
                byTier[tier, default: 0] += 1
            }
        }
        // Every tier should have at least one report — sanity check the
        // map isn't accidentally empty for one tier.
        XCTAssertGreaterThan(byTier[.refresh] ?? 0, 0)
        XCTAssertGreaterThan(byTier[.inventory] ?? 0, 0)
        XCTAssertGreaterThan(byTier[.scan] ?? 0, 0)
    }
}
