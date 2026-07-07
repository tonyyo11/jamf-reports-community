import Foundation
import XCTest
@testable import JamfReports

/// Round-trip tests for `NotifyConfigLoader`/`NotifyConfigWriter` — the Automation
/// screen's Notifications panel read/write seam. Redirects
/// `ProfileService.workspaceURL` to a temp directory via
/// `JRC_TEST_WORKSPACES_ROOT`, the same idiom as `AIConfigPersistenceTests`.
final class NotifyConfigStoreTests: XCTestCase {

    private func makeWorkspace(profile: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotifyConfigStoreTests-\(UUID().uuidString)", isDirectory: true)
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

    private func profileName() -> String { "notify-test-\(UUID().uuidString.lowercased())" }

    func testLoaderReturnsDisabledDefaultWhenNoConfigExists() throws {
        let profile = profileName()
        _ = try makeWorkspace(profile: profile)

        let config = NotifyConfigLoader.load(profile: profile)
        XCTAssertFalse(config.isEnabled)
        XCTAssertFalse(config.isUsable)
        XCTAssertEqual(config.resolvedProvider, .teams)
        XCTAssertEqual(config.resolvedDetail, .full)
    }

    func testSaveThenLoadRoundTripsAllFields() throws {
        let profile = profileName()
        _ = try makeWorkspace(profile: profile)

        try NotifyConfigWriter.save(
            enabled: true,
            provider: "slack",
            url: "https://hooks.example.com/webhook",
            detail: "minimal",
            profile: profile
        )

        let reloaded = NotifyConfigLoader.load(profile: profile)
        XCTAssertTrue(reloaded.isEnabled)
        XCTAssertEqual(reloaded.resolvedProvider, .slack)
        XCTAssertEqual(reloaded.resolvedURL, "https://hooks.example.com/webhook")
        XCTAssertEqual(reloaded.resolvedDetail, .minimal)
        XCTAssertTrue(reloaded.isUsable)
    }

    func testDetailRoundTripsThroughResolvedDetail() throws {
        let profile = profileName()
        _ = try makeWorkspace(profile: profile)

        try NotifyConfigWriter.save(
            enabled: true, provider: "teams", url: "https://x.example.com", detail: "minimal",
            profile: profile
        )
        XCTAssertEqual(NotifyConfigLoader.load(profile: profile).resolvedDetail, .minimal)

        try NotifyConfigWriter.save(
            enabled: true, provider: "teams", url: "https://x.example.com", detail: "full",
            profile: profile
        )
        XCTAssertEqual(NotifyConfigLoader.load(profile: profile).resolvedDetail, .full)
    }

    func testSaveTrimsURLWhitespace() throws {
        let profile = profileName()
        _ = try makeWorkspace(profile: profile)

        try NotifyConfigWriter.save(
            enabled: true, provider: "teams", url: "  https://trim.example.com/hook  ",
            detail: "full", profile: profile
        )
        XCTAssertEqual(NotifyConfigLoader.load(profile: profile).resolvedURL,
                       "https://trim.example.com/hook")
    }

    func testSavePreservesUnrelatedTopLevelKeys() throws {
        let profile = profileName()
        let workspace = try makeWorkspace(profile: profile)
        let configURL = workspace.appendingPathComponent("config.yaml")
        try """
        columns:
          computer_name: Computer Name
        thresholds:
          stale_device_days: 30
        """.write(to: configURL, atomically: true, encoding: .utf8)

        try NotifyConfigWriter.save(
            enabled: true, provider: "teams", url: "https://example.com/webhook",
            detail: "full", profile: profile
        )

        let text = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(text.contains("computer_name: Computer Name"))
        XCTAssertTrue(text.contains("stale_device_days: 30"))
        XCTAssertTrue(text.contains("notify:"))

        let reloaded = try ConfigLoader.load(from: configURL)
        XCTAssertEqual(reloaded.notify?.isEnabled, true)
        XCTAssertEqual(reloaded.columns?.computerName, "Computer Name")
        XCTAssertEqual(reloaded.thresholds?.staleDeviceDays, 30)
    }

    func testSaveOverwritesPreviousNotifyBlockRatherThanDuplicating() throws {
        let profile = profileName()
        let workspace = try makeWorkspace(profile: profile)

        try NotifyConfigWriter.save(
            enabled: true, provider: "teams", url: "https://first.example.com",
            detail: "full", profile: profile
        )
        try NotifyConfigWriter.save(
            enabled: true, provider: "slack", url: "https://second.example.com",
            detail: "minimal", profile: profile
        )

        let reloaded = NotifyConfigLoader.load(profile: profile)
        XCTAssertEqual(reloaded.resolvedProvider, .slack)
        XCTAssertEqual(reloaded.resolvedURL, "https://second.example.com")

        let text = try String(
            contentsOf: workspace.appendingPathComponent("config.yaml"), encoding: .utf8
        )
        let occurrences = text.components(separatedBy: "\nnotify:").count - 1
            + (text.hasPrefix("notify:") ? 1 : 0)
        XCTAssertEqual(occurrences, 1, "notify: block must appear exactly once")
    }

    func testWriterThrowsOnInvalidProfileName() {
        XCTAssertThrowsError(
            try NotifyConfigWriter.save(
                enabled: true, provider: "teams", url: "https://x.example.com",
                detail: "full", profile: "../not-a-slug"
            )
        ) { error in
            guard case NotifyConfigWriter.WriteError.invalidProfile = error else {
                return XCTFail("expected invalidProfile, got \(error)")
            }
        }
    }

    func testInsecureURLWarningPredicate() {
        XCTAssertFalse(NotifyConfigWriter.showsInsecureURLWarning(enabled: false, url: "http://x"),
                       "disabled never warns")
        XCTAssertFalse(NotifyConfigWriter.showsInsecureURLWarning(enabled: true, url: "  "),
                       "empty URL never warns")
        XCTAssertFalse(NotifyConfigWriter.showsInsecureURLWarning(enabled: true, url: "https://x.com"),
                       "https URL does not warn")
        XCTAssertTrue(NotifyConfigWriter.showsInsecureURLWarning(enabled: true, url: "http://x.com"),
                      "enabled non-https warns")
        XCTAssertTrue(NotifyConfigWriter.showsInsecureURLWarning(enabled: true, url: "example.com"),
                      "enabled schemeless warns")
    }
}
