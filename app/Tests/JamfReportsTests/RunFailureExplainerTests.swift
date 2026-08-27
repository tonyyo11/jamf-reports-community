import XCTest
@testable import JamfReports

/// F2 seam: construction-time redaction, on-device pinning, stub, and factory.
/// All assertions run on the default toolchain — they exercise the UNGATED
/// seam/stub/factory and the pure selection path, never constructing a
/// FoundationModels type.
final class RunFailureExplainerTests: XCTestCase {

    private func input(rawLog: String, label: String = "managed-reports") -> RunFailureInput {
        RunFailureInput.build(
            label: label, exitCode: 3, runDate: Date(timeIntervalSince1970: 1_770_000_000),
            rawLog: rawLog
        )
    }

    // MARK: - Privacy invariant 1: redaction at construction

    func testStoredExcerptNeverContainsTokenOrHostname() {
        let token = "sekrettokenABCDEF1234567890"
        let secret = "supersecretvalue123"
        let host = "jamf.prod-example.gov"
        let raw = """
        [info] collecting from https://\(host)/api/v1/auth/token
        [fail] Authorization: Bearer \(token)
        [fail] client_secret: \(secret)
        [fail] jamf-cli failed (3)
        """
        let built = input(rawLog: raw)

        XCTAssertFalse(built.redactedLogExcerpt.contains(token))
        XCTAssertFalse(built.redactedLogExcerpt.contains(secret))
        XCTAssertFalse(built.redactedLogExcerpt.contains(host))
        XCTAssertTrue(built.redactedLogExcerpt.contains("REDACTED_BEARER"))
        XCTAssertTrue(built.redactedLogExcerpt.contains("REDACTED_CLIENT_SECRET"))
        // The non-sensitive failure line survives redaction.
        XCTAssertTrue(built.redactedLogExcerpt.contains("jamf-cli failed (3)"))

        // The prompt is built from the stored excerpt only, so it inherits
        // the same guarantee.
        let prompt = built.promptContext()
        XCTAssertFalse(prompt.contains(token))
        XCTAssertFalse(prompt.contains(secret))
        XCTAssertFalse(prompt.contains(host))
    }

    func testExcerptIsTailTruncatedTo200Lines() {
        let raw = (1...250).map { "line-\($0)" }.joined(separator: "\n")
        let built = input(rawLog: raw)
        let lines = built.redactedLogExcerpt.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, RunFailureInput.maxExcerptLines)
        XCTAssertEqual(lines.first, "line-51")
        XCTAssertEqual(lines.last, "line-250")
    }

    func testLabelIsCappedAndDateIsFormatterDerived() {
        let built = input(rawLog: "x", label: String(repeating: "a", count: 300))
        XCTAssertEqual(built.label.count, 120)
        // dateRange comes from a Date via the strict formatter — never free text.
        XCTAssertNotNil(
            built.dateRange.range(
                of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$"#, options: .regularExpression
            )
        )
    }

    // MARK: - Prompt budgeting (tail-weighted)

    func testPromptBudgetKeepsNewestExcerptLines() {
        let raw = (1...100).map { "log line number \($0) with some padding text" }
            .joined(separator: "\n")
        let built = input(rawLog: raw)
        let prompt = built.promptContext(maxApproxTokens: 100)  // ~400 chars
        XCTAssertTrue(prompt.contains("log line number 100"))
        XCTAssertFalse(prompt.contains("log line number 1 "))
        // Header always survives budgeting.
        XCTAssertTrue(prompt.contains("Exit code: 3."))
        XCTAssertTrue(prompt.contains("managed-reports"))
    }

    func testBudgetTailAlwaysKeepsAtLeastOneExcerptLine() {
        let rendered = RunFailureInput.budgetTail(
            header: ["header"], excerpt: ["first", "the failure line"], maxApproxTokens: 1
        )
        XCTAssertTrue(rendered.contains("the failure line"))
    }

    // MARK: - Privacy invariant 2: on-device only (pure, provable ungated)

    func testNormalConfigResolvesOnDeviceForExplainer() {
        XCTAssertEqual(runFailureGeneratorKind(for: AIConfig(enabled: true)), .onDevice)
    }

    /// A legacy config still naming the removed `pcc` tier resolves to
    /// on-device, so log excerpts stay on the box without any migration.
    func testLegacyPCCTierResolvesOnDeviceForExplainer() {
        XCTAssertEqual(
            runFailureGeneratorKind(for: AIConfig(enabled: true, tier: "pcc")), .onDevice,
            "run-log explanation must never resolve off-box"
        )
    }

    /// The one config that does NOT resolve on-device. It must be refused, not
    /// served: the factory hands back the stub so no off-box model type is ever
    /// constructed for a log excerpt.
    @MainActor
    func testExternalTierIsRefusedRatherThanServedOffBox() {
        let config = AIConfig(enabled: true, tier: "external")
        XCTAssertEqual(runFailureGeneratorKind(for: config), .external)
        let explainer = makeRunFailureExplainer(config: config, availability: .available)
        XCTAssertTrue(
            explainer is StubRunFailureExplainer,
            "an off-box tier must never receive a run log"
        )
    }

    // MARK: - Stub determinism

    func testStubReturnsNeutralPlaceholder() async throws {
        let result = try await StubRunFailureExplainer().explain(input(rawLog: "x"))
        XCTAssertFalse(result.summary.isEmpty)
        XCTAssertTrue(result.likelyCause.isEmpty)
        XCTAssertTrue(result.firstStep.isEmpty)
    }

    func testStubSurfacesAvailabilityMessage() async throws {
        let result = try await StubRunFailureExplainer(availability: .disabledByConfig)
            .explain(input(rawLog: "x"))
        XCTAssertEqual(result.summary, ModelAvailability.disabledByConfig.message)
    }

    // MARK: - Factory routing

    @MainActor
    func testFactoryReturnsStubWhenDisabled() {
        let explainer = makeRunFailureExplainer(
            config: AIConfig(enabled: false), availability: .available
        )
        XCTAssertTrue(explainer is StubRunFailureExplainer)
    }

    @MainActor
    func testFactoryReturnsStubWhenUnavailable() {
        let explainer = makeRunFailureExplainer(
            config: AIConfig(enabled: true), availability: .requiresMacOS27
        )
        XCTAssertTrue(explainer is StubRunFailureExplainer)
    }

    @MainActor
    func testFactoryReturnsStubOnCurrentToolchain() {
        // On this host (Swift 6.3, compiler(>=6.4) false) the FM branch elides;
        // on macOS 27 this returns FoundationModelsRunFailureExplainer.
        let explainer = makeRunFailureExplainer(
            config: AIConfig(enabled: true), availability: .available
        )
        XCTAssertTrue(explainer is StubRunFailureExplainer)
    }
}
