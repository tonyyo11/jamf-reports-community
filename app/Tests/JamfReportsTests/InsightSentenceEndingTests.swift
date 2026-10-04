import XCTest
@testable import JamfReports

/// Live: the last bullet of an insight stopped mid-sentence. A finished insight ends on a
/// sentence; the card's corner label keeps the project's macOS name and its case.
@MainActor
final class InsightSentenceEndingTests: XCTestCase {

    private func bullet(
        _ text: String, _ severity: InsightBullet.Severity = .info
    ) -> InsightBullet {
        InsightBullet(text: text, severity: severity)
    }

    // MARK: - Pure cut

    func testCompleteSentencesKeepsWhatEndsOnAFullStop() {
        XCTAssertEqual(FleetInsight.completeSentences(of: "FileVault is on for 98.5% of Macs."),
                       "FileVault is on for 98.5% of Macs.")
        XCTAssertEqual(FleetInsight.completeSentences(of: "  Patch now!  "), "Patch now!")
        XCTAssertEqual(FleetInsight.completeSentences(of: "Is it fixed? "), "Is it fixed?")
        XCTAssertEqual(FleetInsight.completeSentences(of: #"He said "patch." "#),
                       #"He said "patch.""#)
    }

    func testCompleteSentencesCutsBackToTheLastFullStop() {
        XCTAssertEqual(
            FleetInsight.completeSentences(
                of: "FileVault is at 98.5%. Firewall is off on 12 Macs and the next"),
            "FileVault is at 98.5%.")
    }

    /// A decimal point is not the end of a sentence: nothing complete is left.
    func testADecimalPointIsNotASentenceEnd() {
        XCTAssertNil(FleetInsight.completeSentences(of: "Patch compliance is at 58.0% and the"))
        XCTAssertNil(FleetInsight.completeSentences(of: "   "))
        XCTAssertNil(FleetInsight.completeSentences(of: ""))
    }

    // MARK: - Finished insight

    func testOnlyTheLastBulletIsCut() {
        let insight = FleetInsight(headline: "Fleet is mostly healthy.", bullets: [
            bullet("Gatekeeper is off on 4 Macs"),
            bullet("Patch compliance is 58.0%. Update the titles that lag and then"),
        ])
        let finished = insight.endingOnSentence()
        XCTAssertEqual(finished.bullets.map(\.text), [
            "Gatekeeper is off on 4 Macs",
            "Patch compliance is 58.0%.",
        ], "an earlier bullet was followed by another, so the model finished it")
        XCTAssertEqual(finished.headline, insight.headline)
    }

    func testALastBulletWithNoCompleteSentenceIsDropped() {
        let insight = FleetInsight(headline: "Fleet is mostly healthy.", bullets: [
            bullet("Firewall is off on 12 Macs.", .warning),
            bullet("Stale devices fell from 20 to"),
        ])
        XCTAssertEqual(insight.endingOnSentence().bullets.map(\.text),
                       ["Firewall is off on 12 Macs."])
        XCTAssertEqual(insight.endingOnSentence().bullets.first?.severity, .warning)
    }

    func testAnInsightWithNoBulletsIsUnchanged() {
        let insight = FleetInsight(headline: "AI insights are not enabled", bullets: [])
        XCTAssertEqual(insight.endingOnSentence(), insight)
    }

    // MARK: - The card

    private struct ControlledGenerator: FleetInsightGenerator {
        let stream: AsyncThrowingStream<FleetInsight, Error>
        let continuation: AsyncThrowingStream<FleetInsight, Error>.Continuation

        init() { (stream, continuation) = AsyncThrowingStream.makeStream() }

        func generate(_ input: FleetInsightInput) async throws -> FleetInsight {
            FleetInsight(headline: "", bullets: [])
        }

        func generateStream(
            _ input: FleetInsightInput
        ) -> AsyncThrowingStream<FleetInsight, Error> { stream }
    }

    /// The stream shows its partials as they arrive; the finished insight is the one cut.
    func testTheCardCutsTheLastBulletOnlyWhenTheStreamFinishes() async {
        let generator = ControlledGenerator()
        let model = AIInsightCardModel { _ in
            .init(config: AIConfig(enabled: true), availability: .available, generator: generator)
        }
        model.select("p")
        model.setInput(FleetInsightInput(title: "t", focus: "f", facts: [], notes: []))
        let run = Task { await model.generate() }

        let cut = FleetInsight(headline: "Fleet is mostly healthy.", bullets: [
            bullet("Firewall is off on 12 Macs."), bullet("Stale devices fell from 20 to"),
        ])
        generator.continuation.yield(cut)
        for _ in 0..<1_000 where model.insight == nil { await Task.yield() }
        XCTAssertEqual(model.insight?.bullets.count, 2, "a partial renders as it arrives")

        generator.continuation.finish()
        await run.value
        XCTAssertEqual(model.insight?.bullets.map(\.text), ["Firewall is off on 12 Macs."])
        XCTAssertFalse(model.isGenerating)
    }

    // MARK: - Corner label

    /// Live: "MACOS 27", because the label was a `Kicker`, which upper-cases its text.
    func testBadgeNamesTheMacOSReleaseInTheProjectFormAndCase() {
        XCTAssertEqual(AIInsightCard.badgeText, "On-device · macOS Golden Gate 27")
        XCTAssertNotEqual(AIInsightCard.badgeText, AIInsightCard.badgeText.uppercased())
    }
}
