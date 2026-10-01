import XCTest
@testable import JamfReports

/// Phase 1b: the seam (protocol + stub + factory). All assertions run on the
/// default toolchain: they exercise the UNGATED seam/stub/factory and never
/// construct a FoundationModels type.
final class FleetInsightGeneratorTests: XCTestCase {

    private func summary(_ date: String = "2026-06-06") -> DailySummary {
        DailySummary(
            date: date, totalDevices: 100, fileVaultPct: 98,
            compliancePct: nil, staleCount: 0, osCurrentPct: nil,
            crowdstrikePct: nil, patchPct: nil
        )
    }

    // MARK: - Stub determinism

    func testStubReturnsDeterministicPlaceholder() async throws {
        let result = try await StubInsightGenerator().generate(
            FleetInsightInput(current: summary(), previous: nil)
        )
        XCTAssertTrue(result.bullets.isEmpty)
        XCTAssertFalse(result.headline.isEmpty)
    }

    func testStubSurfacesAvailabilityMessage() async throws {
        let result = try await StubInsightGenerator(availability: .disabledByConfig).generate(
            FleetInsightInput(current: summary(), previous: nil)
        )
        XCTAssertEqual(result.headline, ModelAvailability.disabledByConfig.message)
    }

    // MARK: - Factory routing

    @MainActor
    func testFactoryReturnsStubWhenDisabled() {
        let generator = makeInsightGenerator(config: AIConfig(enabled: false), availability: .available)
        XCTAssertTrue(generator is StubInsightGenerator)
    }

    @MainActor
    func testFactoryReturnsStubWhenUnavailable() {
        let generator = makeInsightGenerator(
            config: AIConfig(enabled: true), availability: .requiresMacOS27
        )
        XCTAssertTrue(generator is StubInsightGenerator)
    }

    /// The factory follows the same gate the views use: a Swift 6.4 toolchain on
    /// macOS 27 constructs the on-device generator; anything else elides the
    /// FoundationModels branch and resolves to the stub. Asserting the stub by
    /// toolchain assumption broke the day CI's Xcode 27 runner moved to macOS 27.
    @MainActor
    func testFactoryFollowsThePlatformGate() {
        let generator = makeInsightGenerator(
            config: AIConfig(enabled: true), availability: .available
        )
        if ModelAvailability.platformSupported {
            XCTAssertFalse(generator is StubInsightGenerator,
                           "macOS 27 with Swift 6.4 must construct the on-device generator")
        } else {
            XCTAssertTrue(generator is StubInsightGenerator,
                          "a pre-27 host or pre-6.4 toolchain elides the FoundationModels branch")
        }
    }

    // MARK: - Removed tiers

    /// Apple Foundation Models is on-device only: `pcc` was removed in 2.7.0 and
    /// `external` was never built. A workspace whose config.yaml still names
    /// either, or any other unknown tier, must keep working — `resolvedTier`'s
    /// unknown-value fallback gives it the same generator as a default config.
    @MainActor
    func testRemovedAndUnknownTiersGetTheOnDeviceGenerator() {
        for tier in ["external", "pcc", "nonsense"] {
            let generator = makeInsightGenerator(
                config: AIConfig(enabled: true, tier: tier), availability: .available
            )
            XCTAssertEqual(
                generator is StubInsightGenerator, !ModelAvailability.platformSupported,
                "a config naming the \(tier) tier must be served like a default config"
            )
        }
    }
}
