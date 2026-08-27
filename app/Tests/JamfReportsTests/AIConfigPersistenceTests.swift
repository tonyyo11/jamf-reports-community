import Darwin
import Foundation
import XCTest
@testable import JamfReports

/// Round-trip tests for `AIConfigLoader`/`AIConfigWriter` — the Settings AI
/// panel's read/write seam. Uses `JRC_TEST_WORKSPACES_ROOT` to redirect
/// `ProfileService.workspaceURL` to a temp directory, same idiom as
/// `CLIBridgeRunNowTests`.
final class AIConfigPersistenceTests: XCTestCase {

    private func makeWorkspace(profile: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIConfigPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        addTeardownBlock {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: root)
        }
        let workspace = root.appendingPathComponent(profile, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return workspace
    }

    func testLoaderReturnsDisabledDefaultWhenNoConfigExists() throws {
        let profile = "ai-test-\(UUID().uuidString.lowercased())"
        _ = try makeWorkspace(profile: profile)

        let config = AIConfigLoader.load(profile: profile)
        XCTAssertFalse(config.isUsable)
        XCTAssertEqual(config.resolvedTier, .onDevice)
    }

    func testSaveThenLoadRoundTripsEnabledTierAndReasoning() throws {
        let profile = "ai-test-\(UUID().uuidString.lowercased())"
        _ = try makeWorkspace(profile: profile)

        var config = AIConfig()
        config.enabled = true
        config.tier = "on_device"
        config.reasoningLevel = "deep"

        try AIConfigWriter.save(config, profile: profile)

        let reloaded = AIConfigLoader.load(profile: profile)
        XCTAssertTrue(reloaded.isEnabled)
        XCTAssertEqual(reloaded.resolvedTier, .onDevice)
        XCTAssertEqual(reloaded.resolvedReasoningLevel, .deep)
    }

    /// The writer emits `resolvedTier`, so saving a config that still carries
    /// the removed `pcc` tier normalises it to `on_device` on disk and drops
    /// the dead `lock_on_device` key — the file self-heals on first save.
    func testSavingALegacyTierNormalisesItOnDisk() throws {
        let profile = "ai-test-\(UUID().uuidString.lowercased())"
        let workspace = try makeWorkspace(profile: profile)

        var config = AIConfig()
        config.enabled = true
        config.tier = "pcc"
        try AIConfigWriter.save(config, profile: profile)

        let text = try String(
            contentsOf: workspace.appendingPathComponent("config.yaml"), encoding: .utf8
        )
        XCTAssertTrue(text.contains("tier: on_device"), text)
        XCTAssertFalse(text.contains("pcc"), text)
        XCTAssertFalse(text.contains("lock_on_device"), text)
    }

    func testSavePreservesUnrelatedTopLevelKeys() throws {
        let profile = "ai-test-\(UUID().uuidString.lowercased())"
        let workspace = try makeWorkspace(profile: profile)
        let configURL = workspace.appendingPathComponent("config.yaml")
        try """
        columns:
          computer_name: Computer Name
        notify:
          enabled: true
          provider: teams
          url: https://example.com/webhook
        """.write(to: configURL, atomically: true, encoding: .utf8)

        var config = AIConfig()
        config.enabled = true
        try AIConfigWriter.save(config, profile: profile)

        let text = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(text.contains("computer_name: Computer Name"))
        XCTAssertTrue(text.contains("provider: teams"))
        XCTAssertTrue(text.contains("ai:"))

        let reloaded = try ConfigLoader.load(from: configURL)
        XCTAssertEqual(reloaded.notify?.isEnabled, true)
        XCTAssertEqual(reloaded.ai?.isEnabled, true)
    }

    func testSaveOverwritesPreviousAIBlockRatherThanDuplicating() throws {
        let profile = "ai-test-\(UUID().uuidString.lowercased())"
        _ = try makeWorkspace(profile: profile)

        var first = AIConfig()
        first.enabled = true
        first.tier = "on_device"
        try AIConfigWriter.save(first, profile: profile)

        var second = AIConfig()
        second.enabled = true
        second.tier = "external"
        try AIConfigWriter.save(second, profile: profile)

        let reloaded = AIConfigLoader.load(profile: profile)
        XCTAssertEqual(reloaded.resolvedTier, .external)

        guard let workspace = ProfileService.workspaceURL(for: profile) else {
            return XCTFail("expected a valid workspace URL")
        }
        let text = try String(contentsOf: workspace.appendingPathComponent("config.yaml"), encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: "\nai:").count - 1
            + (text.hasPrefix("ai:") ? 1 : 0), 1, "ai: block must appear exactly once")
    }

    func testWriterThrowsOnInvalidProfileName() {
        var config = AIConfig()
        config.enabled = true
        XCTAssertThrowsError(try AIConfigWriter.save(config, profile: "../not-a-slug")) { error in
            XCTAssertTrue(error is AIConfigWriter.WriteError)
        }
    }
}
