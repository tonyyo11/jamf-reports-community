import Foundation
import XCTest
@testable import JamfReports

/// State-machine tests for `SmartGroupApplySheetViewModel`. The view-model is
/// the only place that orchestrates preview-then-apply for the smart-group
/// destructive surface, so this is where the "no apply without preview" and
/// "explicit consent gates the write" invariants get enforced.
@MainActor
final class SmartGroupApplySheetViewModelTests: XCTestCase {

    // MARK: - Fixtures

    private func template(
        slug: String = "stale-checkin",
        params: [SmartGroupTemplateParam] = []
    ) -> SmartGroupTemplate {
        SmartGroupTemplate(
            slug: slug,
            category: "mdm",
            description: "Computers that have not checked in for 90+ days.",
            params: params
        )
    }

    private func makeViewModel(
        template: SmartGroupTemplate? = nil,
        previewExecutor: CLIExecutor,
        applyExecutor: CLIExecutor? = nil
    ) -> SmartGroupApplySheetViewModel {
        let tmpl = template ?? self.template()
        return SmartGroupApplySheetViewModel(
            template: tmpl,
            profile: "harbor",
            templateService: SmartGroupTemplateService(executor: previewExecutor),
            applyService: SmartGroupApplyService(executor: applyExecutor ?? previewExecutor)
        )
    }

    // MARK: - Default name

    func testDefaultNameDerivedFromSlug() {
        let tmpl = template(slug: "not-encrypted")
        XCTAssertEqual(
            SmartGroupApplySheetViewModel.defaultName(for: tmpl),
            "Not Encrypted (Jamf Reports)"
        )
    }

    func testDefaultNameHandlesMultiWordSlug() {
        let tmpl = template(slug: "major-version-behind")
        XCTAssertEqual(
            SmartGroupApplySheetViewModel.defaultName(for: tmpl),
            "Major Version Behind (Jamf Reports)"
        )
    }

    // MARK: - loadPreview transitions

    func testLoadPreviewSuccessTransitionsToPreviewReady() async {
        let executor = StubExecutor(canned: [
            (.proSmartGroupPreview(profile: "harbor", templateSlug: "stale-checkin", params: [:]),
             .success(Data(#"{"body": {"name": "x"}, "estimated_match_count": 3}"#.utf8))),
        ])
        let vm = makeViewModel(previewExecutor: executor)

        await vm.loadPreview()

        guard case .previewReady(let preview) = vm.phase else {
            return XCTFail("expected previewReady, got \(vm.phase)")
        }
        XCTAssertEqual(preview.estimatedMatchCount, 3)
    }

    func testLoadPreviewFeatureMissingTransitionsToPreviewFailed() async {
        let executor = StubExecutor(canned: [
            (.proSmartGroupPreview(profile: "harbor", templateSlug: "stale-checkin", params: [:]),
             .failure(CLIExecutorError.binaryNotFound("jamf-cli"))),
        ])
        let vm = makeViewModel(previewExecutor: executor)

        await vm.loadPreview()

        guard case .previewFailed(let message) = vm.phase else {
            return XCTFail("expected previewFailed, got \(vm.phase)")
        }
        XCTAssertTrue(message.contains("PR #205"), "operator should see upgrade hint: \(message)")
    }

    func testLoadPreviewUnknownTemplateSurfacesUsefulMessage() async {
        let executor = StubExecutor(canned: [
            (.proSmartGroupPreview(profile: "harbor", templateSlug: "stale-checkin", params: [:]),
             .failure(CLIExecutorError.nonZeroExit(code: 2, stderr: "Error: unknown template: stale-checkin"))),
        ])
        let vm = makeViewModel(previewExecutor: executor)

        await vm.loadPreview()

        guard case .previewFailed(let message) = vm.phase else {
            return XCTFail("expected previewFailed, got \(vm.phase)")
        }
        XCTAssertTrue(message.contains("Unknown template"))
    }

    // MARK: - canApply gate

    func testCanApplyFalseInLoadingPhase() {
        let executor = StubExecutor(canned: [])
        let vm = makeViewModel(previewExecutor: executor)
        XCTAssertFalse(vm.canApply, "must not be applyable before preview loads")
    }

    func testCanApplyTrueOncePreviewReady() async {
        let executor = StubExecutor(canned: [
            (.proSmartGroupPreview(profile: "harbor", templateSlug: "stale-checkin", params: [:]),
             .success(Data(#"{"body": {}, "estimated_match_count": 0}"#.utf8))),
        ])
        let vm = makeViewModel(previewExecutor: executor)
        await vm.loadPreview()
        XCTAssertTrue(vm.canApply)
    }

    func testCanApplyFalseWhenNameIsBlank() async {
        let executor = StubExecutor(canned: [
            (.proSmartGroupPreview(profile: "harbor", templateSlug: "stale-checkin", params: [:]),
             .success(Data(#"{}"#.utf8))),
        ])
        let vm = makeViewModel(previewExecutor: executor)
        await vm.loadPreview()
        vm.smartGroupName = "   "
        XCTAssertFalse(vm.canApply)
    }

    func testCanApplyFalseWhenRequiredParamMissing() async {
        let param = SmartGroupTemplateParam(
            name: "version", required: true, description: "OS threshold", default: nil
        )
        let tmpl = template(slug: "os-version-below", params: [param])
        let executor = StubExecutor(canned: [
            (.proSmartGroupPreview(profile: "harbor", templateSlug: "os-version-below", params: [:]),
             .success(Data(#"{}"#.utf8))),
        ])
        let vm = makeViewModel(template: tmpl, previewExecutor: executor)
        await vm.loadPreview()
        // No value provided for the required `version` param.
        XCTAssertFalse(vm.canApply)
        vm.paramValues["version"] = "15.0"
        XCTAssertTrue(vm.canApply)
    }

    func testOptionalParamWithDefaultPrePopulates() {
        let param = SmartGroupTemplateParam(
            name: "platform", required: false, description: "macOS or iOS", default: "macOS"
        )
        let tmpl = template(slug: "os-version-below", params: [param])
        let vm = makeViewModel(
            template: tmpl,
            previewExecutor: StubExecutor(canned: [])
        )
        XCTAssertEqual(vm.paramValues["platform"], "macOS")
    }

    // MARK: - apply transitions

    func testApplySuccessTransitionsToApplied() async {
        let executor = StubExecutor(canned: [
            (.proSmartGroupPreview(profile: "harbor", templateSlug: "stale-checkin", params: [:]),
             .success(Data(#"{}"#.utf8))),
            (.proSmartGroupApply(
                profile: "harbor", templateSlug: "stale-checkin",
                smartGroupName: "Stale Checkin (Jamf Reports)", params: [:],
                recalculate: false, dryRun: false
             ),
             .success(Data(#"{"id": 42, "name": "Stale Checkin (Jamf Reports)", "member_count": 12, "created": true}"#.utf8))),
        ])
        let vm = makeViewModel(previewExecutor: executor)
        await vm.loadPreview()
        await vm.apply()

        guard case .applied(let result) = vm.phase else {
            return XCTFail("expected applied, got \(vm.phase)")
        }
        XCTAssertEqual(result.smartGroupID, 42)
        XCTAssertEqual(result.memberCount, 12)
        XCTAssertTrue(result.created)
    }

    func testApplyAPIErrorPreservesPreviewInFailedPhase() async {
        let previewJSON = Data(#"{"body": {"name": "x"}, "estimated_match_count": 5}"#.utf8)
        let executor = StubExecutor(canned: [
            (.proSmartGroupPreview(profile: "harbor", templateSlug: "stale-checkin", params: [:]),
             .success(previewJSON)),
            (.proSmartGroupApply(
                profile: "harbor", templateSlug: "stale-checkin",
                smartGroupName: "Stale Checkin (Jamf Reports)", params: [:],
                recalculate: false, dryRun: false
             ),
             .failure(CLIExecutorError.nonZeroExit(code: 3, stderr: "Error: HTTP 401: Unauthorized"))),
        ])
        let vm = makeViewModel(previewExecutor: executor)
        await vm.loadPreview()
        await vm.apply()

        guard case .applyFailed(let preview, let message) = vm.phase else {
            return XCTFail("expected applyFailed, got \(vm.phase)")
        }
        // The preview the user just approved must still be available so they
        // don't lose context — the failure screen renders preview + error.
        XCTAssertEqual(preview.estimatedMatchCount, 5)
        XCTAssertTrue(message.contains("401"), "should include HTTP status: \(message)")
        XCTAssertTrue(message.contains("Unauthorized"), "should include API message: \(message)")
    }

    func testApplyIsNoOpBeforePreviewLoads() async {
        // Guard against any code path that calls apply() before loadPreview() —
        // canApply protects this, but the apply() method also short-circuits.
        let executor = StubExecutor(canned: [])
        let vm = makeViewModel(previewExecutor: executor)
        // Don't load preview. Calling apply() should be a no-op (still loadingPreview).
        await vm.apply()
        guard case .loadingPreview = vm.phase else {
            return XCTFail("expected phase unchanged, got \(vm.phase)")
        }
    }

    func testApplyNoOpsWhenCanApplyIsFalse() async {
        // Preview ready but name is blank → canApply false → apply() is no-op.
        let executor = StubExecutor(canned: [
            (.proSmartGroupPreview(profile: "harbor", templateSlug: "stale-checkin", params: [:]),
             .success(Data(#"{}"#.utf8))),
        ])
        let vm = makeViewModel(previewExecutor: executor)
        await vm.loadPreview()
        vm.smartGroupName = ""
        await vm.apply()
        // Phase should remain previewReady, not transition to applying.
        guard case .previewReady = vm.phase else {
            return XCTFail("expected previewReady to be preserved, got \(vm.phase)")
        }
    }

    // MARK: - Default initial state

    func testInitialNameAndParams() {
        let param = SmartGroupTemplateParam(
            name: "platform", required: false, description: "", default: "macOS"
        )
        let tmpl = template(slug: "os-version-below", params: [param])
        let vm = SmartGroupApplySheetViewModel(
            template: tmpl,
            profile: "harbor",
            templateService: SmartGroupTemplateService(executor: StubExecutor(canned: [])),
            applyService: SmartGroupApplyService(executor: StubExecutor(canned: []))
        )
        XCTAssertEqual(vm.smartGroupName, "Os Version Below (Jamf Reports)")
        XCTAssertEqual(vm.paramValues["platform"], "macOS")
    }

    func testSuggestedNameOverridesDefault() {
        let tmpl = template(slug: "stale-checkin")
        let vm = SmartGroupApplySheetViewModel(
            template: tmpl,
            profile: "harbor",
            templateService: SmartGroupTemplateService(executor: StubExecutor(canned: [])),
            applyService: SmartGroupApplyService(executor: StubExecutor(canned: [])),
            suggestedName: "Outreach: Stale 90d"
        )
        XCTAssertEqual(vm.smartGroupName, "Outreach: Stale 90d")
    }
}

// MARK: - Stub executor

/// Reuses the argv-key trick from the Stage-1 tests. Multiple commands can be
/// canned in one executor instance — the view-model needs preview + apply
/// in the same lifecycle.
private final class StubExecutor: CLIExecutor, @unchecked Sendable {
    enum Outcome { case success(Data); case failure(CLIExecutorError) }
    private let byArgv: [[String]: Outcome]

    init(canned: [(CLICommand, Outcome)]) {
        var d: [[String]: Outcome] = [:]
        for (cmd, outcome) in canned { d[cmd.argv] = outcome }
        self.byArgv = d
    }

    func execute(_ command: CLICommand) async throws -> Data {
        guard let outcome = byArgv[command.argv] else {
            throw CLIExecutorError.nonZeroExit(
                code: -1,
                stderr: "no canned outcome for argv: \(command.argv)"
            )
        }
        switch outcome {
        case .success(let data): return data
        case .failure(let error): throw error
        }
    }
}
