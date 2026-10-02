import XCTest
@testable import JamfReports

/// #207 G12: what one Generate press in the sheet asks for, and the order it runs in. The run
/// takes the Overview's order (`CLIBridge.runCollectThenGenerate`), so the AI narrative reads the
/// snapshots the collect just wrote. Every step is injected; no jamf-cli runs here.
@MainActor
final class GenerateSheetRequestTests: XCTestCase {

    private let busy = "A scheduled run is in progress — try again when it finishes"

    private final class Events {
        var log: [String] = []
    }

    private func run(
        _ request: GenerateSheetState.Request,
        events: Events,
        collect: @escaping () async throws -> Int32 = { 0 },
        result: GenerateAllResult = GenerateAllResult(succeeded: [.xlsx])
    ) async -> (count: Int, message: String?) {
        await GenerateSheetState.perform(
            request,
            collect: {
                events.log.append("collect")
                return try await collect()
            },
            narrative: {
                events.log.append("narrative")
                return "Fleet is healthy."
            },
            generate: { narrative in
                events.log.append("generate: \(narrative ?? "nil")")
                return result
            }
        )
    }

    // MARK: - The request

    func testEachTemplateInThePickerIsTheOneGenerated() {
        let state = GenerateSheetState()
        for template in TemplateResolver.allTemplates where template.identifier != "custom" {
            state.selectedTemplateID = template.identifier
            XCTAssertEqual(state.request().template.identifier, template.identifier)
        }
    }

    func testCustomGeneratesExactlyTheSelectedSheets() {
        let state = GenerateSheetState()
        state.selectedTemplateID = "custom"
        state.customSelectedSheets = [.patchCompliance, .executiveSummary]
        defer { UserDefaults.standard.removeObject(forKey: GenerateSheetState.customSheetsKey) }
        let template = state.request().template
        XCTAssertEqual(template.identifier, "custom")
        XCTAssertEqual(template.includedSheets, [.executiveSummary, .patchCompliance])
    }

    func testTheRequestCarriesTheFormatsFolderAndCollectChoice() {
        let state = GenerateSheetState()
        let folder = URL(fileURLWithPath: "/tmp/reports-\(UUID().uuidString)")
        state.selectedTypes = [.html, .pdf]
        state.customOutputDir = folder
        state.collectFresh = false
        var request = state.request()
        XCTAssertEqual(request.types, [.html, .pdf])
        XCTAssertEqual(request.outputDir, folder)
        XCTAssertFalse(request.collectFirst)
        state.collectFresh = true
        request = state.request()
        XCTAssertTrue(request.collectFirst)
    }

    func testTheAuditRunsOnlyWhenAskedFor() {
        UserDefaults.standard.removeObject(forKey: GenerateSheetState.includeAuditKey)
        defer { UserDefaults.standard.removeObject(forKey: GenerateSheetState.includeAuditKey) }
        let state = GenerateSheetState()
        XCTAssertFalse(state.request().runsAudit)
        state.includeAudit = true
        XCTAssertTrue(state.request().runsAudit)
    }

    /// School has its own workbook generator and no narrative; its HTML and PDF still take the
    /// School template's sections, not Full Instance's.
    func testSchoolUsesTheSchoolGeneratorWithoutANarrative() {
        let state = GenerateSheetState()
        state.selectedTemplateID = SchoolTemplate().identifier
        var request = state.request()
        XCTAssertTrue(request.schoolMode)
        XCTAssertFalse(request.asksForNarrative)
        XCTAssertEqual(request.template.identifier, SchoolTemplate().identifier)
        state.selectedTemplateID = FullInstanceTemplate().identifier
        request = state.request()
        XCTAssertFalse(request.schoolMode)
        XCTAssertTrue(request.asksForNarrative)
    }

    // MARK: - The run

    func testCollectFreshCollectsThenAsksForTheNarrativeThenGenerates() async {
        let state = GenerateSheetState()
        state.collectFresh = true
        let events = Events()
        let outcome = await run(state.request(), events: events)
        XCTAssertEqual(events.log, ["collect", "narrative", "generate: Fleet is healthy."])
        XCTAssertEqual(outcome.count, 1)
        XCTAssertNil(outcome.message)
    }

    func testWithoutCollectFreshNothingIsCollected() async {
        let state = GenerateSheetState()
        state.collectFresh = false
        let events = Events()
        _ = await run(state.request(), events: events)
        XCTAssertEqual(events.log, ["narrative", "generate: Fleet is healthy."])
    }

    /// A tick holding the lock refuses the collect; that is not a failed run, so nothing is
    /// generated or counted and the sheet shows the refusal.
    func testARefusedCollectShowsTheRefusalAndGeneratesNothing() async {
        let state = GenerateSheetState()
        let events = Events()
        let outcome = await run(state.request(), events: events,
                                collect: { throw CLIBridgeError.tickLockHeld })
        XCTAssertEqual(events.log, ["collect"])
        XCTAssertEqual(outcome.count, 0)
        XCTAssertEqual(outcome.message, busy)
    }

    func testAFailedCollectExplainsItsExitAndGeneratesNothing() async {
        let state = GenerateSheetState()
        let events = Events()
        let outcome = await run(state.request(), events: events,
                                collect: { CLIBridge.exitCodeUnauthorized })
        XCTAssertEqual(events.log, ["collect"])
        XCTAssertEqual(outcome.count, 0)
        XCTAssertEqual(outcome.message,
                       CLIBridge.explainExit(CLIBridge.exitCodeUnauthorized, operation: "Collect"))
    }

    func testSchoolAsksForNoNarrative() async {
        let state = GenerateSheetState()
        state.selectedTemplateID = SchoolTemplate().identifier
        let events = Events()
        _ = await run(state.request(), events: events)
        XCTAssertEqual(events.log, ["collect", "generate: nil"])
    }

    func testAPartlyFailedGenerateIsSummarized() async {
        let state = GenerateSheetState()
        let partial = GenerateAllResult(succeeded: [.xlsx], failed: [(.html, 1)])
        let outcome = await run(state.request(), events: Events(), result: partial)
        let expected = GenerateSheetState.summarize(partial)
        XCTAssertEqual(outcome.count, expected.count)
        XCTAssertEqual(outcome.message, expected.message)
    }

    // MARK: - Dismissal

    func testTheSheetClosesWhileIdleButNotMidRun() {
        let state = GenerateSheetState()
        XCTAssertTrue(state.canDismiss)
        state.isRunning = true
        XCTAssertFalse(state.canDismiss)
    }
}
