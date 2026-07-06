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
        // so even an enabled+available PCC config resolves to the stub. On
        // macOS 27 hardware this returns FoundationModelsInsightGenerator.
        let generator = makeInsightGenerator(
            config: AIConfig(enabled: true, tier: "pcc"), availability: .available
        )
        XCTAssertTrue(generator is StubInsightGenerator)
    }

    // MARK: - lock_on_device guarantee (pure selection truth table)

    func testSelectOnDeviceTierResolvesOnDevice() {
        XCTAssertEqual(GeneratorKind.select(config: AIConfig(tier: "on_device")), .onDevice)
    }

    func testSelectPCCTierResolvesPCCWhenUnlocked() {
        XCTAssertEqual(
            GeneratorKind.select(config: AIConfig(tier: "pcc", lockOnDevice: false)),
            .privateCloudCompute
        )
    }

    func testSelectExternalTierResolvesExternalWhenUnlocked() {
        XCTAssertEqual(
            GeneratorKind.select(config: AIConfig(tier: "external", lockOnDevice: false)),
            .external
        )
    }

    /// THE guarantee: a locked config NEVER selects a non-on-device kind, even
    /// when the tier explicitly requests PCC — so no PCC/external model type is
    /// ever constructed. Proven on the pure selection function, no FM types.
    func testLockOnDevicePinsPCCTierToOnDevice() {
        XCTAssertEqual(
            GeneratorKind.select(config: AIConfig(tier: "pcc", lockOnDevice: true)),
            .onDevice,
            "lock_on_device must override a pcc tier selection"
        )
    }

    func testLockOnDevicePinsExternalTierToOnDevice() {
        XCTAssertEqual(
            GeneratorKind.select(config: AIConfig(tier: "external", lockOnDevice: true)),
            .onDevice,
            "lock_on_device must override an external tier selection"
        )
    }
}
