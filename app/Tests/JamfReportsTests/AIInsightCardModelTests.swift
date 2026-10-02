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

    private func boundModel(
        enabled: Bool = true, generator: any FleetInsightGenerator
    ) -> AIInsightCardModel {
        let model = AIInsightCardModel()
        model.bind(profile: "p", config: AIConfig(enabled: enabled),
                   availability: .available, generator: generator)
        return model
    }

    // MARK: - Presence

    func testHiddenOffMacOS27AndInDemoMode() {
        let model = boundModel(generator: FixedGenerator(result: .success(shown)))
        XCTAssertEqual(model.presence(profile: "p", demoMode: false, platformSupported: true),
                       .shown)
        XCTAssertEqual(model.presence(profile: "p", demoMode: true, platformSupported: true),
                       .hidden)
        XCTAssertEqual(model.presence(profile: "p", demoMode: false, platformSupported: false),
                       .hidden)
    }

    func testHiddenWhenAIIsOff() {
        let model = boundModel(enabled: false, generator: StubInsightGenerator())
        XCTAssertEqual(model.presence(profile: "p", demoMode: false, platformSupported: true),
                       .hidden)
    }

    func testLoadingUntilThisProfilesConfigIsRead() {
        XCTAssertEqual(
            AIInsightCardModel().presence(profile: "p", demoMode: false, platformSupported: true),
            .loading)
        let model = boundModel(generator: StubInsightGenerator())
        XCTAssertEqual(model.presence(profile: "q", demoMode: false, platformSupported: true),
                       .loading, "a config read for another profile does not count")
    }

    // MARK: - Invalidation

    func testNewInputClearsAShownInsight() async {
        let model = boundModel(generator: FixedGenerator(result: .success(shown)))
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
        let model = boundModel(
            generator: FixedGenerator(result: .failure(.generationFailed("boom"))))
        model.setInput(input("Monday"))
        await model.generate()
        XCTAssertEqual(model.errorMessage, "boom")

        model.setInput(nil)
        XCTAssertNil(model.errorMessage)
    }

    func testStreamStartedBeforeAnInputChangeStopsWriting() async {
        let generator = ControlledGenerator()
        let model = boundModel(generator: generator)
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

    func testRebindingClearsTheInsight() async {
        let model = boundModel(generator: FixedGenerator(result: .success(shown)))
        model.setInput(input("Monday"))
        await model.generate()

        model.bind(profile: "q", config: AIConfig(enabled: true), availability: .available,
                   generator: StubInsightGenerator())
        XCTAssertNil(model.insight)
    }

    func testGenerateWithoutInputDoesNothing() async {
        let model = boundModel(generator: FixedGenerator(result: .success(shown)))
        await model.generate()
        XCTAssertNil(model.insight)
        XCTAssertFalse(model.isGenerating)
    }
}
