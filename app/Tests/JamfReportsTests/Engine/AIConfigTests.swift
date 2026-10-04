import Foundation
import XCTest
@testable import JamfReports

final class AIConfigTests: XCTestCase {

    // MARK: - Defaults

    func testDisabledByDefault() {
        XCTAssertFalse(AIConfig().isEnabled)
        XCTAssertFalse(AIConfig().isUsable)
    }

    func testTierDefaultsToOnDevice() {
        XCTAssertEqual(AIConfig().resolvedTier, .onDevice)
        XCTAssertEqual(AIConfig(tier: nil).resolvedTier, .onDevice)
        XCTAssertEqual(AIConfig(tier: "bogus").resolvedTier, .onDevice, "unknown -> on_device")
    }

    func testTierParsesKnownValuesCaseInsensitively() {
        XCTAssertEqual(AIConfig(tier: "ON_DEVICE").resolvedTier, .onDevice)
    }

    /// The `external` tier was specced but never built, and its keys are gone.
    /// A config naming it must keep working rather than fail to decode — the
    /// unknown-value fallback lands it on on-device, the same way `pcc` does.
    func testRemovedExternalTierDecodesAsOnDevice() {
        XCTAssertEqual(AIConfig(tier: "external").resolvedTier, .onDevice)
        XCTAssertEqual(AIConfig(tier: "EXTERNAL").resolvedTier, .onDevice)
    }

    /// Apple Foundation Models is on-device only, so the `pcc` tier was
    /// removed. An existing workspace naming it must keep working rather than
    /// fail to decode — the unknown-value fallback lands it on on-device.
    func testLegacyPCCTierDecodesAsOnDevice() {
        XCTAssertEqual(AIConfig(tier: "pcc").resolvedTier, .onDevice)
    }

    func testReasoningLevelDefaultsToLight() {
        XCTAssertEqual(AIConfig().resolvedReasoningLevel, .light)
        XCTAssertEqual(AIConfig(reasoningLevel: "bogus").resolvedReasoningLevel, .light)
        XCTAssertEqual(AIConfig(reasoningLevel: "DEEP").resolvedReasoningLevel, .deep)
        XCTAssertEqual(AIConfig(reasoningLevel: "moderate").resolvedReasoningLevel, .moderate)
    }

    func testIsUsableTracksEnabledOnly() {
        XCTAssertFalse(AIConfig(enabled: false).isUsable)
        XCTAssertTrue(AIConfig(enabled: true).isUsable, "on-device needs no URL/key")
    }

    // MARK: - YAML decode

    func testDecodesFromYAML() throws {
        let yaml = """
        ai:
          enabled: true
          tier: "on_device"
          reasoning_level: "deep"
        """
        let config = try ConfigLoader.loadFromString(yaml)
        XCTAssertEqual(config.ai?.isEnabled, true)
        XCTAssertEqual(config.ai?.resolvedTier, .onDevice)
        XCTAssertEqual(config.ai?.resolvedReasoningLevel, .deep)
    }

    /// A config.yaml written by an older build still carries `tier: pcc` and
    /// `lock_on_device`. Decoding must ignore both rather than throw — an
    /// unknown key is not a parse error, and the removed tier falls back.
    func testLegacyAIBlockStillDecodes() throws {
        let yaml = """
        ai:
          enabled: true
          tier: "pcc"
          lock_on_device: true
          reasoning_level: "deep"
        """
        let config = try ConfigLoader.loadFromString(yaml)
        XCTAssertEqual(config.ai?.isEnabled, true)
        XCTAssertEqual(config.ai?.resolvedTier, .onDevice)
        XCTAssertEqual(config.ai?.resolvedReasoningLevel, .deep)
    }

    func testAbsentAIBlockDecodesNil() throws {
        let config = try ConfigLoader.loadFromString("columns:\n  computer_name: \"Name\"\n")
        XCTAssertNil(config.ai)
    }

    /// A config.yaml written while `external:` was a reserved block still carries
    /// it, filled in or not. Decoding must ignore the block and resolve the tier
    /// to on-device; nothing in it reaches the app.
    func testStaleExternalBlockIsIgnored() throws {
        let yaml = """
        ai:
          enabled: true
          tier: "external"
          reasoning_level: "deep"
          external:
            provider: "openai_compatible"
            endpoint: "https://llm.example.invalid/v1"
            keychain_key: "stale-item"
        """
        let config = try ConfigLoader.loadFromString(yaml)
        XCTAssertEqual(config.ai?.isEnabled, true)
        XCTAssertEqual(config.ai?.resolvedTier, .onDevice)
        XCTAssertEqual(config.ai?.resolvedReasoningLevel, .deep)
        XCTAssertTrue(config.ai?.isUsable ?? false)
    }

    // MARK: - Shipped example

    func testShippedExampleConfigParsesTheAIBlock() throws {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var example: URL?
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("config.example.yaml")
            if FileManager.default.fileExists(atPath: candidate.path) {
                example = candidate
                break
            }
            dir = dir.deletingLastPathComponent()
        }
        guard let example else { throw XCTSkip("config.example.yaml not found above \(#filePath)") }

        let config = try ConfigLoader.load(from: example)
        XCTAssertNotNil(config.ai, "shipped example must document the ai: block")
        XCTAssertFalse(config.ai?.isEnabled ?? true, "must ship disabled by default")
        XCTAssertEqual(config.ai?.resolvedTier, .onDevice)
    }
}
