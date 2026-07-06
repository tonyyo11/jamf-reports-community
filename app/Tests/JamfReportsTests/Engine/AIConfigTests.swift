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
        XCTAssertEqual(AIConfig(tier: "pcc").resolvedTier, .pcc)
        XCTAssertEqual(AIConfig(tier: "external").resolvedTier, .external)
        XCTAssertEqual(AIConfig(tier: "ON_DEVICE").resolvedTier, .onDevice)
    }

    func testLockOnDeviceDefaultsFalse() {
        XCTAssertFalse(AIConfig().isLockedOnDevice)
        XCTAssertTrue(AIConfig(lockOnDevice: true).isLockedOnDevice)
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
        XCTAssertTrue(AIConfig(enabled: true, tier: "pcc").isUsable)
    }

    // MARK: - YAML decode

    func testDecodesFromYAML() throws {
        let yaml = """
        ai:
          enabled: true
          tier: "pcc"
          lock_on_device: true
          reasoning_level: "deep"
        """
        let config = try ConfigLoader.loadFromString(yaml)
        XCTAssertEqual(config.ai?.isEnabled, true)
        XCTAssertEqual(config.ai?.resolvedTier, .pcc)
        XCTAssertEqual(config.ai?.isLockedOnDevice, true)
        XCTAssertEqual(config.ai?.resolvedReasoningLevel, .deep)
    }

    func testAbsentAIBlockDecodesNil() throws {
        let config = try ConfigLoader.loadFromString("columns:\n  computer_name: \"Name\"\n")
        XCTAssertNil(config.ai)
    }

    func testEmptyExternalBlockIsInert() throws {
        let yaml = """
        ai:
          enabled: true
          external:
            provider: ""
            endpoint: ""
            keychain_key: ""
        """
        let config = try ConfigLoader.loadFromString(yaml)
        XCTAssertNotNil(config.ai?.external, "the reserved block still decodes")
        XCTAssertEqual(config.ai?.external?.provider, "")
        XCTAssertEqual(config.ai?.external?.endpoint, "")
        XCTAssertEqual(config.ai?.external?.keychainKey, "")
        // The reserved external block must not change usability today.
        XCTAssertTrue(config.ai?.isUsable ?? false)
        XCTAssertEqual(config.ai?.resolvedTier, .onDevice)
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
