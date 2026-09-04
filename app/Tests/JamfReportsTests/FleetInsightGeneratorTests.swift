import XCTest
@testable import JamfReports

/// Phase 1b: the seam (protocol + stub + factory) and the lock_on_device
/// guarantee. All assertions run on the default toolchain: they exercise the
/// UNGATED seam/stub/factory and the pure `GeneratorKind.select` truth table,
/// never constructing a FoundationModels type.
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

    @MainActor
    func testFactoryReturnsStubForExternalTier() {
        // External tier is specced but not built — always the stub for now.
        let generator = makeInsightGenerator(
            config: AIConfig(enabled: true, tier: "external"), availability: .available
        )
        XCTAssertTrue(generator is StubInsightGenerator)
    }

    @MainActor
    func testFactoryReturnsStubOnCurrentToolchain() {
        // On this host (Swift 6.3, compiler(>=6.4) false) the FM branch elides,
        // so even an enabled+available config resolves to the stub. On macOS 27
        // hardware this returns FoundationModelsInsightGenerator.
        let generator = makeInsightGenerator(
            config: AIConfig(enabled: true), availability: .available
        )
        XCTAssertTrue(generator is StubInsightGenerator)
    }

    // MARK: - Selection truth table

    func testSelectOnDeviceTierResolvesOnDevice() {
        XCTAssertEqual(GeneratorKind.select(config: AIConfig(tier: "on_device")), .onDevice)
    }

    func testSelectDefaultsToOnDeviceWhenNoTierIsSet() {
        XCTAssertEqual(GeneratorKind.select(config: AIConfig()), .onDevice)
    }

    func testSelectExternalTierResolvesExternal() {
        XCTAssertEqual(
            GeneratorKind.select(config: AIConfig(tier: "external")), .external
        )
    }

    /// Backward compatibility: Apple Foundation Models is on-device only, so the
    /// `pcc` tier and the `lock_on_device` override that existed to refuse it
    /// were removed. A workspace whose config.yaml still names the old tier must
    /// keep working — `resolvedTier`'s unknown-value fallback lands it on
    /// on-device, which is now the only behaviour anyway.
    func testLegacyPCCTierFallsBackToOnDevice() {
        XCTAssertEqual(
            GeneratorKind.select(config: AIConfig(tier: "pcc")), .onDevice,
            "a config still naming the removed pcc tier must run on-device, not break"
        )
    }

    func testUnknownTierFallsBackToOnDevice() {
        XCTAssertEqual(GeneratorKind.select(config: AIConfig(tier: "nonsense")), .onDevice)
    }
}
