import XCTest
@testable import JamfReports

/// Every other doctor family reports a workspace that is broken. This one reports
/// a workspace that is fine but not the one the operator expected — the state
/// after moving the workspace to a shared folder, where nothing is wrong and
/// everything looks empty.
final class WorkspaceContinuityTests: XCTestCase {

    private func inputs(
        activeSummaries: Int,
        rootIsCustom: Bool = false,
        configIsCustomised: Bool = false,
        elsewhere: [(String, Int)] = []
    ) -> WorkspaceContinuityInputs {
        WorkspaceContinuityInputs(
            activeRoot: URL(fileURLWithPath: "/Users/x/Shared/Jamf-Reports"),
            activeSummaryCount: activeSummaries,
            rootIsCustom: rootIsCustom,
            configIsCustomised: configIsCustomised,
            elsewhere: elsewhere.map {
                .init(profile: "prod", root: URL(fileURLWithPath: $0.0), summaryCount: $0.1)
            }
        )
    }

    private func rows(_ i: WorkspaceContinuityInputs) -> [DoctorRow] {
        ConfigDoctorService.evaluateWorkspaceContinuity(i)
    }

    private func row(_ i: WorkspaceContinuityInputs, id: String) -> DoctorRow? {
        rows(i).first { $0.id == id }
    }

    // MARK: - History elsewhere

    /// The workspace-move case: a fresh shared folder alongside the original.
    func testRicherHistoryElsewhereIsReported() throws {
        let r = try XCTUnwrap(row(inputs(activeSummaries: 2, rootIsCustom: true,
                                         elsewhere: [("/Users/x/Jamf-Reports", 180)]),
                                  id: "continuity.history-elsewhere"))
        XCTAssertEqual(r.severity, .suggest, "nothing is broken — this must not read as an error")
        XCTAssertTrue(r.detail.contains("180"), "must say how much is over there")
        XCTAssertTrue(r.detail.contains("/Users/x/Jamf-Reports"), "must name the folder")
        XCTAssertNotNil(r.hint)
    }

    /// A leftover folder with less history than the live one must stay quiet, or
    /// the check nags forever after a successful move.
    func testPoorerHistoryElsewhereIsNotReported() {
        XCTAssertNil(row(inputs(activeSummaries: 180,
                                elsewhere: [("/Users/x/Jamf-Reports", 2)]),
                         id: "continuity.history-elsewhere"))
    }

    /// Equal counts almost certainly mean the same data seen twice, not a loss.
    func testEqualHistoryElsewhereIsNotReported() {
        XCTAssertNil(row(inputs(activeSummaries: 90,
                                elsewhere: [("/Users/x/Jamf-Reports", 90)]),
                         id: "continuity.history-elsewhere"))
    }

    func testNoOtherWorkspaceIsSilent() {
        XCTAssertNil(row(inputs(activeSummaries: 40), id: "continuity.history-elsewhere"))
    }

    /// With several candidates it should name the richest, not the first found.
    func testReportsTheRichestCandidate() throws {
        let r = try XCTUnwrap(row(inputs(activeSummaries: 1,
                                         elsewhere: [("/a", 10), ("/b", 300), ("/c", 50)]),
                                  id: "continuity.history-elsewhere"))
        XCTAssertTrue(r.detail.contains("300"))
        XCTAssertTrue(r.detail.contains("/b"))
    }

    func testSingularSummaryWording() throws {
        let r = try XCTUnwrap(row(inputs(activeSummaries: 1, elsewhere: [("/a", 9)]),
                                  id: "continuity.history-elsewhere"))
        XCTAssertTrue(r.detail.contains("1 daily summary"), "got: \(r.detail)")
    }

    // MARK: - Fresh workspace

    func testFreshWorkspaceIsReported() throws {
        let r = try XCTUnwrap(row(inputs(activeSummaries: 0), id: "continuity.fresh-workspace"))
        XCTAssertEqual(r.severity, .suggest)
    }

    /// After a deliberate move the advice must say that moving does not carry data.
    func testFreshWorkspaceAtACustomRootExplainsTheMove() throws {
        let r = try XCTUnwrap(row(inputs(activeSummaries: 0, rootIsCustom: true),
                                  id: "continuity.fresh-workspace"))
        let hint = try XCTUnwrap(r.hint)
        XCTAssertTrue(hint.contains("does not") || hint.contains("copy"),
                      "must say a location change does not move existing data")
    }

    /// An operator who has configured EAs knows where their workspace is; telling
    /// them "settings are defaults" would be both wrong and noisy.
    func testCustomisedConfigSuppressesTheFreshNotice() {
        XCTAssertNil(row(inputs(activeSummaries: 0, configIsCustomised: true),
                         id: "continuity.fresh-workspace"))
    }

    /// Any real history means this is not a fresh workspace.
    func testWorkspaceWithHistoryIsNotCalledFresh() {
        XCTAssertNil(row(inputs(activeSummaries: 1), id: "continuity.fresh-workspace"))
    }

    // MARK: - Overall quietness

    /// The common case — an established workspace, nothing elsewhere — must emit
    /// nothing at all. A family that always speaks trains operators to skim.
    func testEstablishedWorkspaceEmitsNothing() {
        XCTAssertTrue(rows(inputs(activeSummaries: 200, configIsCustomised: true)).isEmpty)
    }

    /// Neither row may ever be .fail: only .fail reaches the run log, and a
    /// perfectly healthy scheduled run must not go red because a second copy of
    /// the workspace exists on disk.
    func testNeitherCheckCanFailARun() {
        let noisy = inputs(activeSummaries: 0, rootIsCustom: true,
                           elsewhere: [("/Users/x/Jamf-Reports", 400)])
        XCTAssertEqual(rows(noisy).count, 2, "both checks should fire here")
        for r in rows(noisy) {
            XCTAssertEqual(r.severity, .suggest, "\(r.id) must never be .fail or .warn")
        }
    }
}
