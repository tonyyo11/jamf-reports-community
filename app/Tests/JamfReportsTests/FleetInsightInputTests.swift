import XCTest
@testable import JamfReports

/// Phase 1b: the pure input builder that renders a fleet summary (plus prior
/// period) into prompt context. No FoundationModels dependency — runs on the
/// default toolchain.
final class FleetInsightInputTests: XCTestCase {

    private func summary(
        date: String, devices: Int = 100,
        fileVault: Double? = nil, patch: Double? = nil,
        security: Double? = nil, stale: Int? = nil,
        p0: Int? = nil, compliance: Double? = nil, complianceProxy: Bool? = nil
    ) -> DailySummary {
        DailySummary(
            date: date, totalDevices: devices, fileVaultPct: fileVault,
            compliancePct: compliance, staleCount: stale, osCurrentPct: nil,
            crowdstrikePct: nil, patchPct: patch,
            securityScore: security, actionItemsP0: p0,
            complianceIsProxy: complianceProxy
        )
    }

    // MARK: - Build

    func testBuildCarriesCurrentAndPrevious() {
        let current = summary(date: "2026-06-06")
        let previous = summary(date: "2026-06-05")
        let input = FleetInsightInput(current: current, previous: previous)
        XCTAssertEqual(input.current.date, "2026-06-06")
        XCTAssertEqual(input.previous?.date, "2026-06-05")
    }

    func testBuildAllowsNilPrevious() {
        let input = FleetInsightInput(current: summary(date: "2026-06-06"), previous: nil)
        XCTAssertNil(input.previous)
    }

    // MARK: - Prompt context

    func testContextIncludesPresentMetricsOnly() {
        let input = FleetInsightInput(
            current: summary(date: "2026-06-06", fileVault: 98.0, patch: nil),
            previous: nil
        )
        let context = input.promptContext()
        XCTAssertTrue(context.contains("Total managed devices: 100"))
        XCTAssertTrue(context.contains("FileVault encrypted: 98.0%"))
        XCTAssertFalse(context.contains("Patch compliance"), "nil metric must be omitted")
    }

    func testContextRendersDeltasVsPrior() {
        let input = FleetInsightInput(
            current: summary(date: "2026-06-06", fileVault: 98.0, stale: 12),
            previous: summary(date: "2026-06-05", fileVault: 95.0, stale: 20)
        )
        let context = input.promptContext()
        XCTAssertTrue(context.contains("+3.0% vs prior"), "fileVault delta up")
        XCTAssertTrue(context.contains("-8 vs prior"), "stale count delta down")
    }

    func testContextFlagsProxyCompliance() {
        let input = FleetInsightInput(
            current: summary(date: "2026-06-06", compliance: 88.0, complianceProxy: true),
            previous: nil
        )
        XCTAssertTrue(input.promptContext().contains("[proxy metric]"))
    }

    func testContextNotesMissingPriorPeriod() {
        let input = FleetInsightInput(current: summary(date: "2026-06-06"), previous: nil)
        XCTAssertTrue(input.promptContext().contains("deltas omitted"))
    }

    // MARK: - Token budget truncation

    func testBudgetTruncatesOnLineBoundary() {
        let lines = (0..<50).map { "- Metric \($0): 100.0%" }
        // ~5 tokens/line at 4 chars/token; a 6-token budget keeps ~1 line.
        let out = FleetInsightInput.budget(lines, maxApproxTokens: 6)
        XCTAssertFalse(out.isEmpty)
        XCTAssertFalse(out.contains("Metric 49"), "trailing lines dropped")
        // No partial line: every kept line ends cleanly (starts with the prefix).
        for line in out.split(separator: "\n") {
            XCTAssertTrue(line.hasPrefix("- Metric "))
        }
    }

    func testBudgetKeepsAtLeastOneLineEvenWhenOverBudget() {
        let out = FleetInsightInput.budget(["- A very long single metric line that exceeds the tiny budget"],
                                           maxApproxTokens: 1)
        XCTAssertFalse(out.isEmpty, "never drops the only line to empty")
    }

    func testContextRespectsSmallBudget() {
        let input = FleetInsightInput(
            current: summary(date: "2026-06-06", fileVault: 98, patch: 90, security: 95),
            previous: nil
        )
        let full = input.promptContext(maxApproxTokens: 10_000)
        let tight = input.promptContext(maxApproxTokens: 8)
        XCTAssertLessThan(tight.count, full.count)
    }
}
