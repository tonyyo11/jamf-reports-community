import XCTest
@testable import JamfReports

/// F1: the ungated streaming/prewarm seam additions. All assertions run on the
/// default toolchain — they exercise the protocol's default `prepare`/
/// `generateStream` extensions, the stub, and the consumption pattern
/// `AIInsightCard.generate()` uses (last yield wins; a throw discards partials).
final class FleetInsightStreamingTests: XCTestCase {

    private func summary(_ date: String = "2026-06-06") -> DailySummary {
        DailySummary(
            date: date, totalDevices: 100, fileVaultPct: 98,
            compliancePct: nil, staleCount: 0, osCurrentPct: nil,
            crowdstrikePct: nil, patchPct: nil
        )
    }

    private func input() -> FleetInsightInput {
        .build(current: summary(), previous: nil)
    }

    // MARK: - Test doubles

    /// Uses the DEFAULT `generateStream` extension over a throwing `generate`.
    private struct FailingGenerator: FleetInsightGenerator {
        func generate(_ input: FleetInsightInput) async throws -> FleetInsight {
            throw FleetInsightError.generationFailed("boom")
        }
    }

    /// Scripted multi-yield stream — the shape the real gated generator
    /// produces and the card consumes.
    private struct ScriptedStreamGenerator: FleetInsightGenerator {
        let partials: [FleetInsight]
        var failure: FleetInsightError?

        func generate(_ input: FleetInsightInput) async throws -> FleetInsight {
            if let failure { throw failure }
            return partials.last ?? FleetInsight(headline: "", bullets: [])
        }

        func generateStream(_ input: FleetInsightInput) -> AsyncThrowingStream<FleetInsight, Error> {
            AsyncThrowingStream { continuation in
                for partial in partials { continuation.yield(partial) }
                if let failure {
                    continuation.finish(throwing: failure)
                } else {
                    continuation.finish()
                }
            }
        }
    }

    // MARK: - Default extensions

    func testDefaultStreamYieldsExactlyTheOneShotResult() async throws {
        let generator = StubInsightGenerator(availability: .disabledByConfig)
        let oneShot = try await generator.generate(input())

        var yields: [FleetInsight] = []
        for try await partial in generator.generateStream(input()) {
            yields.append(partial)
        }
        XCTAssertEqual(yields, [oneShot], "default stream must yield the generate result once")
    }

    func testDefaultStreamPropagatesGenerateError() async {
        do {
            for try await _ in FailingGenerator().generateStream(input()) {
                XCTFail("failing generator must not yield")
            }
            XCTFail("stream should have thrown")
        } catch {
            XCTAssertEqual(error as? FleetInsightError, .generationFailed("boom"))
        }
    }

    func testStubPrepareIsANoOp() async throws {
        let generator = StubInsightGenerator()
        await generator.prepare()
        // Still generates deterministically after prepare.
        let result = try await generator.generate(input())
        XCTAssertFalse(result.headline.isEmpty)
    }

    // MARK: - Card consumption pattern (last yield wins; throw discards partials)

    func testScriptedStreamDeliversPartialsInOrder() async throws {
        let partials = [
            FleetInsight(headline: "Fleet", bullets: []),
            FleetInsight(headline: "Fleet health", bullets: [
                InsightBullet(text: "FileVault steady", severity: .info)
            ]),
        ]
        let generator = ScriptedStreamGenerator(partials: partials)

        var latest: FleetInsight?
        var count = 0
        for try await partial in generator.generateStream(input()) {
            latest = partial
            count += 1
        }
        XCTAssertEqual(count, 2)
        XCTAssertEqual(latest, partials.last, "the final yield is the complete insight")
    }

    func testScriptedStreamFailureAfterPartialsDiscardsThem() async {
        let generator = ScriptedStreamGenerator(
            partials: [FleetInsight(headline: "partial", bullets: [])],
            failure: .generationFailed("interrupted")
        )

        // Mirrors AIInsightCard.generate(): partials accumulate, a throw
        // clears them so the error state renders instead of a half insight.
        var latest: FleetInsight?
        do {
            for try await partial in generator.generateStream(input()) {
                latest = partial
            }
            XCTFail("stream should have thrown")
        } catch {
            latest = nil
            XCTAssertEqual(error as? FleetInsightError, .generationFailed("interrupted"))
        }
        XCTAssertNil(latest)
    }

    // MARK: - Factory-produced stub streams too

    @MainActor
    func testFactoryStubStreamsAvailabilityMessage() async throws {
        let generator = makeInsightGenerator(
            config: AIConfig(enabled: true), availability: .requiresMacOS27
        )
        var yields: [FleetInsight] = []
        for try await partial in generator.generateStream(input()) {
            yields.append(partial)
        }
        XCTAssertEqual(yields.count, 1)
        XCTAssertEqual(yields.first?.headline, ModelAvailability.requiresMacOS27.message)
    }
}
