import XCTest
@testable import JamfReports

/// `AIInsightCard`'s state, driven through its model rather than by rendering:
/// when the card shows at all, and that a new input clears a shown insight.
@MainActor
final class AIInsightCardModelTests: XCTestCase {

    /// A stream the test feeds by hand, to change the input mid-generation.
    private struct ControlledGenerator: FleetInsightGenerator {
        let stream: AsyncThrowingStream<FleetInsight, Error>
        let continuation: AsyncThrowingStream<FleetInsight, Error>.Continuation

        init() {
            (stream, continuation) = AsyncThrowingStream.makeStream()
        }

        func generate(_ input: FleetInsightInput) async throws -> FleetInsight {
            FleetInsight(headline: "", bullets: [])
        }

        func generateStream(
            _ input: FleetInsightInput
        ) -> AsyncThrowingStream<FleetInsight, Error> {
            stream
        }
    }

    private struct FixedGenerator: FleetInsightGenerator {
        let result: Result<FleetInsight, FleetInsightError>
        func generate(_ input: FleetInsightInput) async throws -> FleetInsight {
            try result.get()
        }
    }

    private var shown: FleetInsight { FleetInsight(headline: "Fleet is healthy.", bullets: []) }

    private func input(_ title: String) -> FleetInsightInput {
        FleetInsightInput(title: title, focus: "health", facts: [], notes: [])
    }

    /// A model for profile "p" whose config is never read from disk.
    private func selectedModel(
        enabled: Bool = true, generator: any FleetInsightGenerator
    ) -> AIInsightCardModel {
        let model = AIInsightCardModel { _ in
            .init(config: AIConfig(enabled: enabled), availability: .available,
                  generator: generator)
        }
        model.select("p")
        return model
    }

    // MARK: - Presence

    /// Decided while the view body runs, before any task: a card that is not
    /// present contributes nothing to its stack, not even spacing.
    func testPresenceIsKnownBeforeAnyTask() {
        let on = AIInsightCardModel { _ in
            .init(config: AIConfig(enabled: true), availability: .available,
                  generator: StubInsightGenerator())
        }
        let off = AIInsightCardModel { _ in
            .init(config: AIConfig(enabled: false), availability: .available,
                  generator: StubInsightGenerator())
        }
        XCTAssertTrue(on.isPresent(profile: "p", demoMode: false, platformSupported: true))
        XCTAssertFalse(off.isPresent(profile: "p", demoMode: false, platformSupported: true),
                       "ai.enabled off hides the card")
        XCTAssertFalse(on.isPresent(profile: "p", demoMode: true, platformSupported: true))
        XCTAssertFalse(on.isPresent(profile: "p", demoMode: false, platformSupported: false))
    }

    func testConfigIsReadOncePerProfile() {
        var reads: [String] = []
        let model = AIInsightCardModel { profile in
            reads.append(profile)
            return .init(config: AIConfig(enabled: true), availability: .available,
                         generator: StubInsightGenerator())
        }
        _ = model.isPresent(profile: "p", demoMode: true, platformSupported: true)
        XCTAssertEqual(reads, [], "demo mode never reads a workspace")
        _ = model.isPresent(profile: "p", demoMode: false, platformSupported: true)
        _ = model.isPresent(profile: "p", demoMode: false, platformSupported: true)
        _ = model.setup(for: "p")
        _ = model.isPresent(profile: "q", demoMode: false, platformSupported: true)
        XCTAssertEqual(reads, ["p", "q"])
    }

    // MARK: - Invalidation

    func testNewInputClearsAShownInsight() async {
        let model = selectedModel(generator: FixedGenerator(result: .success(shown)))
        model.setInput(input("Monday"))
        await model.generate()
        XCTAssertEqual(model.insight, shown)

        model.setInput(input("Monday"))
        XCTAssertEqual(model.insight, shown, "the same input keeps the insight")

        model.setInput(input("Tuesday"))
        XCTAssertNil(model.insight)
        XCTAssertFalse(model.isGenerating)
    }

    func testNewInputClearsAnError() async {
        let model = selectedModel(
            generator: FixedGenerator(result: .failure(.generationFailed("boom"))))
        model.setInput(input("Monday"))
        await model.generate()
        XCTAssertEqual(model.errorMessage, "boom")

        model.setInput(nil)
        XCTAssertNil(model.errorMessage)
    }

    func testStreamStartedBeforeAnInputChangeStopsWriting() async {
        let generator = ControlledGenerator()
        let model = selectedModel(generator: generator)
        model.setInput(input("Monday"))
        let run = Task { await model.generate() }

        generator.continuation.yield(FleetInsight(headline: "Monday partial", bullets: []))
        for _ in 0..<1_000 where model.insight == nil { await Task.yield() }
        XCTAssertEqual(model.insight?.headline, "Monday partial")

        model.setInput(input("Tuesday"))
        generator.continuation.yield(FleetInsight(headline: "Monday final", bullets: []))
        generator.continuation.finish()
        await run.value

        XCTAssertNil(model.insight, "Monday's stream must not fill Tuesday's card")
        XCTAssertFalse(model.isGenerating)
    }

    func testSelectingAnotherProfileClearsTheInsight() async {
        let model = selectedModel(generator: FixedGenerator(result: .success(shown)))
        model.setInput(input("Monday"))
        await model.generate()

        model.select("p")
        XCTAssertEqual(model.insight, shown, "selecting the same profile keeps it")
        model.select("q")
        XCTAssertNil(model.insight)
        XCTAssertEqual(model.profile, "q")
    }

    func testGenerateWithoutInputDoesNothing() async {
        let model = selectedModel(generator: FixedGenerator(result: .success(shown)))
        await model.generate()
        XCTAssertNil(model.insight)
        XCTAssertFalse(model.isGenerating)
    }
}
