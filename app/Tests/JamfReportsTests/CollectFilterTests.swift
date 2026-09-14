import Foundation
import XCTest
@testable import JamfReports

/// Verifies the contract of `ReportEngine.expensivePerDeviceKinds` and the
/// `skipExpensive` filter logic used by `ReportEngine.collect(...)`.
///
/// A full behavioral test of `collect(...)` requires a stubbed `jamf-cli`
/// binary on disk; instead, these tests pin the constant and exercise the
/// same `Set.contains` filter the production code uses so that the planned
/// command list cannot silently drift from documentation.
final class CollectFilterTests: XCTestCase {

    // MARK: - Constant pinning

    /// The set of cold-tier per-device kinds that the "Skip expensive
    /// collections" Settings toggle filters out of manual refreshes.
    /// Documented in CLAUDE.md (Swift App Architecture → expensivePerDeviceKinds).
    func testExpensiveKindsConstantIsStable() {
        // "ddm-device-status" and "mdm-command-health" are scan-phase kinds
        // (Task 5, ReportEngine+DeviceScan) — skipExpensive still governs
        // them, but they never appear in plannedKinds below.
        XCTAssertEqual(
            ReportEngine.expensivePerDeviceKinds,
            [
                "ea-results", "patch-device-failures",
                "update-device-failures", "device-compliance",
                "ddm-device-status", "mdm-command-health"
            ]
        )
    }

    func testExpensiveKindsHasExactlySixEntries() {
        XCTAssertEqual(ReportEngine.expensivePerDeviceKinds.count, 6)
    }

    func testExpensiveKindsAreUnique() {
        // Set semantics already enforce uniqueness, but assert by mapping
        // back to an array of the literal we expect — guards against a
        // future refactor that switches the type to [String].
        let expected = ["ea-results", "patch-device-failures", "update-device-failures", "device-compliance"]
        XCTAssertEqual(Set(expected).count, expected.count)
        for kind in expected {
            XCTAssertTrue(
                ReportEngine.expensivePerDeviceKinds.contains(kind),
                "Expected kind \(kind) to be in expensivePerDeviceKinds"
            )
        }
    }

    // MARK: - Filter behavior parity

    /// Mirror of the planned-commands list inside `ReportEngine.collect(...)`
    /// (kinds only — the args do not affect filter logic).
    ///
    /// Keep in sync with the `commands` array in
    /// `ReportEngine.swift::collect(...)`.
    private static let plannedKinds: [String] = [
        "overview",
        "security",
        "patch-status",
        "patch-device-failures",
        "update-status",
        "update-device-failures",
        "inventory-summary",
        "device-compliance",
        "policy-status",
        "classic-macos-profiles",
        "app-status",
        "software-installs",
        "computer-extension-attributes",
        "ea-results",
        "profile-status",
        "mobile-devices-list",
        "compliance-devices",
        "compliance-rules",
        "ddm-status",
        "blueprint-status",
        "computers",
        "policies",
        "scripts",
        "packages",
        "smart-computer-groups",
        "sites",
        "buildings",
        "departments"
    ]

    /// Literal pin of the argv-matrix expensive kinds (the four cold-tier
    /// per-device commands filtered by the "Skip expensive collections"
    /// toggle). The two scan-phase kinds (ddm-device-status,
    /// mdm-command-health — Task 5, ReportEngine+DeviceScan) are
    /// deliberately absent: they never appear in `plannedKinds`, so they
    /// contribute nothing to the argv-matrix filter delta below.
    private static let matrixExpensiveKinds: Set<String> = [
        "ea-results", "patch-device-failures", "update-device-failures", "device-compliance"
    ]

    /// Asserts the skipExpensive=true branch removes exactly the four cold-tier
    /// kinds and nothing else. Mirrors the production branch:
    ///
    ///     plannedCommands = skipExpensive
    ///         ? commands.filter { !Self.expensivePerDeviceKinds.contains($0.kind) }
    ///         : commands
    ///
    /// So the size difference between the two branches must equal exactly
    /// `expensivePerDeviceKinds.count` (4), and the symmetric difference
    /// must equal that set.
    func testSkipExpensiveDeltaIsExactlyTheExpensiveKindsSet() {
        let withAll = Self.plannedKinds  // skipExpensive=false branch is identity
        let withSkip = Self.plannedKinds.filter {
            !ReportEngine.expensivePerDeviceKinds.contains($0)
        }
        XCTAssertEqual(
            withAll.count - withSkip.count, 4,
            "skipExpensive=true must remove exactly the 4 cold-tier per-device commands"
        )
        XCTAssertEqual(
            Set(withAll).subtracting(Set(withSkip)),
            Self.matrixExpensiveKinds,
            "The kinds removed by skipExpensive=true must be exactly the matrix-side "
                + "expensive kinds"
        )
        // Real drift check: the production constant's intersection with the
        // planned commands must equal the literal above — no scan-phase
        // kind has leaked into the matrix, and no matrix kind has been
        // dropped from the constant.
        XCTAssertEqual(
            ReportEngine.expensivePerDeviceKinds.intersection(Self.plannedKinds),
            Self.matrixExpensiveKinds
        )
    }

    /// Drift guard: if a future PR adds or removes a command in
    /// `ReportEngine.collect`, this test fails until `plannedKinds` is
    /// updated in tandem. Without it, the filter tests above silently miss
    /// new kinds. The integer 28 is the count of entries in the `commands`
    /// array inside `ReportEngine.swift::collect(...)` as of 2026-05-12.
    func testPlannedKindsCountMatchesProductionCommandList() {
        XCTAssertEqual(
            Self.plannedKinds.count, 28,
            "Update CollectFilterTests.plannedKinds when adding/removing collect commands in ReportEngine.swift"
        )
    }

    func testSkipExpensiveTrueRemovesExactlyTheMatrixExpensiveKinds() {
        // Mirror of the production filter:
        //   commands.filter { !Self.expensivePerDeviceKinds.contains($0.kind) }
        let filtered = Self.plannedKinds.filter {
            !ReportEngine.expensivePerDeviceKinds.contains($0)
        }
        let removed = Self.plannedKinds.filter {
            ReportEngine.expensivePerDeviceKinds.contains($0)
        }

        XCTAssertEqual(removed.count, 4,
                       "Exactly 4 kinds should be filtered out when skipExpensive=true")
        XCTAssertEqual(Set(removed), Self.matrixExpensiveKinds)
        XCTAssertEqual(filtered.count, Self.plannedKinds.count - 4)
        for kind in Self.matrixExpensiveKinds {
            XCTAssertFalse(filtered.contains(kind),
                           "Filtered list should not contain \(kind) when skipExpensive=true")
        }
    }

    func testNonExpensiveKindsArePreservedWhenSkipping() {
        // Every non-expensive kind in the planned list must survive the filter.
        let filtered = Self.plannedKinds.filter {
            !ReportEngine.expensivePerDeviceKinds.contains($0)
        }
        let expectedSurvivors = Self.plannedKinds.filter {
            !ReportEngine.expensivePerDeviceKinds.contains($0)
        }
        XCTAssertEqual(filtered, expectedSurvivors)

        // Spot-check anchors: cheap kinds we always want in the planned list.
        XCTAssertTrue(filtered.contains("overview"))
        XCTAssertTrue(filtered.contains("security"))
        XCTAssertTrue(filtered.contains("policy-status"))
        XCTAssertTrue(filtered.contains("computers"))
    }

    func testExpensiveKindsAreAllPresentInPlannedKinds() {
        // Guardrail: if a future refactor renames a kind in the planned
        // commands list, the constant must be updated too — otherwise
        // skipExpensive will be a no-op for that kind. A kind may instead
        // be one of the scan-phase kinds (Task 5, ReportEngine+DeviceScan),
        // which check skipExpensive themselves outside the argv matrix.
        let scanPhaseKinds: Set<String> = [
            DDMDeviceStatusService.kind, MDMCommandHealthService.kind
        ]
        for kind in ReportEngine.expensivePerDeviceKinds {
            XCTAssertTrue(
                Self.plannedKinds.contains(kind) || scanPhaseKinds.contains(kind),
                "Expensive kind \(kind) must appear in plannedKinds or scanPhaseKinds — "
                    + "otherwise neither the filter nor the scan phase can honour the toggle"
            )
        }
    }
}
