import XCTest
@testable import JamfReports

/// F3 report-narrative seam: the timebox guarantee (a report must NEVER block on
/// the model), the fail-closed-to-omitted contract, and HTML escaping of model
/// output. All default-toolchain (no FoundationModels types constructed).
@MainActor
final class ReportNarrativeTests: XCTestCase {

    /// Configurable seam double.
    private struct FakeGenerator: ReportNarrativeGenerating {
        enum Behavior: Sendable { case text(String), fail, slow(Duration) }
        let behavior: Behavior
        func narrative(_ input: ReportNarrativeInput) async throws -> String {
            switch behavior {
            case .text(let t): return t
            case .fail: throw FleetInsightError.generationFailed("boom")
            case .slow(let d): try await Task.sleep(for: d); return "late"
            }
        }
    }

    private var input: ReportNarrativeInput {
        var m = CoreDashboard.ExecutiveSummaryMetrics()
        m.totalDevices = 662
        return ReportNarrativeInput(metrics: m)
    }

    func testGenerateReturnsTrimmedText() async {
        let out = await ReportNarrative.generate(
            generator: FakeGenerator(behavior: .text("  Fleet is healthy.\n")),
            input: input, timeout: .seconds(5))
        XCTAssertEqual(out, "Fleet is healthy.")
    }

    func testGenerateReturnsNilOnError() async {
        let out = await ReportNarrative.generate(
            generator: FakeGenerator(behavior: .fail), input: input, timeout: .seconds(5))
        XCTAssertNil(out, "a failed narrative omits the section rather than embedding text")
    }

    func testGenerateReturnsNilOnEmptyOutput() async {
        let out = await ReportNarrative.generate(
            generator: FakeGenerator(behavior: .text("   \n  ")), input: input, timeout: .seconds(5))
        XCTAssertNil(out)
    }

    /// The report must NEVER block on the model: a generation slower than the
    /// timebox resolves to nil (section omitted) without waiting for the model.
    func testGenerateTimeboxDoesNotBlock() async {
        let start = ContinuousClock.now
        let out = await ReportNarrative.generate(
            generator: FakeGenerator(behavior: .slow(.seconds(30))),
            input: input, timeout: .milliseconds(100))
        let elapsed = ContinuousClock.now - start
        XCTAssertNil(out)
        XCTAssertLessThan(elapsed, .seconds(5), "timebox must not wait for the slow generator")
    }

    func testHasAnyDataGating() {
        XCTAssertFalse(ReportNarrativeInput.hasAnyData(CoreDashboard.ExecutiveSummaryMetrics()))
        var m = CoreDashboard.ExecutiveSummaryMetrics()
        m.totalDevices = 1
        XCTAssertTrue(ReportNarrativeInput.hasAnyData(m))
    }

    /// The stub throws so stub output can never land inside a generated report.
    func testStubThrowsSoSectionIsOmitted() async {
        do {
            _ = try await StubReportNarrativeGenerator().narrative(input)
            XCTFail("stub must throw so a report never embeds placeholder text")
        } catch {
            // expected
        }
    }

    /// Model output is untrusted; the HTML narrative section must escape it.
    func testNarrativeSectionEscapesModelOutput() {
        let escaped = HtmlSectionFormatters.escapeHTML("<script>x</script> & \"q\"")
        XCTAssertFalse(escaped.contains("<script>"))
        XCTAssertTrue(escaped.contains("&lt;script&gt;"))
        XCTAssertTrue(escaped.contains("&amp;"))
    }
}
