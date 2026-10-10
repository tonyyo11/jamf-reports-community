import XCTest
@testable import JamfReports

/// A shared workspace's config.yaml is writable by every Mac; `SharedConfigPin` keeps the
/// values that matter per Mac and stops following a change until it is confirmed here.
final class SharedConfigPinTests: XCTestCase {

    private let fileManager = FileManager.default
    private let profile = "pinprofile"
    private var root: URL!
    private var workspace: URL!
    private var appSupport: URL!
    private var outside: String!

    private final class LineBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func add(_ line: String) { lock.lock(); stored.append(line); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return stored }
    }

    override func setUpWithError() throws {
        root = fileManager.temporaryDirectory
            .appendingPathComponent("jrc-pin-\(UUID().uuidString)", isDirectory: true)
        workspace = root.appendingPathComponent(profile, isDirectory: true)
        appSupport = root.appendingPathComponent("support", isDirectory: true)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: appSupport, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        outside = NSHomeDirectory() + "/jrc-pin-out-\(UUID().uuidString)"
    }

    override func tearDownWithError() throws {
        SharedConfigPin.markHeadless(false)
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        try? fileManager.removeItem(at: root)
    }

    private func writeConfig(
        shared: Bool = true, outputDir: String = "", allowAbsolute: Bool = false,
        retentionMode: String = "archive", webhook: String = "https://hooks.example.com/a"
    ) throws {
        let body = """
        shared_workspace:
          enabled: \(shared)
        output:
          allow_absolute_paths: \(allowAbsolute)
          output_dir: "\(outputDir)"
        retention:
          enabled: true
          mode: \(retentionMode)
        notify:
          enabled: true
          url: "\(webhook)"
        """
        try body.write(to: workspace.appendingPathComponent("config.yaml"),
                       atomically: true, encoding: .utf8)
    }

    private func check() -> SharedConfigPin.Check {
        SharedConfigPin.check(profile: profile, appSupport: appSupport)
    }

    func testFirstSightPinsTheCurrentValuesAndReportsNoDrift() throws {
        try writeConfig()
        XCTAssertNil(SharedConfigPin.load(profile: profile, appSupport: appSupport))
        XCTAssertTrue(check().drifts.isEmpty)
        let pinned = try XCTUnwrap(SharedConfigPin.load(profile: profile, appSupport: appSupport))
        XCTAssertEqual(pinned.retentionMode, "archive")
        XCTAssertEqual(pinned.notifyURLHost, "hooks.example.com")
        let url = SharedConfigPin.storeURL(profile: profile, appSupport: appSupport)
        let permissions = try fileManager.attributesOfItem(atPath: url.path)[.posixPermissions]
        XCTAssertEqual(permissions as? Int, 0o600)
    }

    func testPinHoldsTheWebhookHostNeverTheURL() throws {
        try writeConfig(webhook: "https://hooks.example.com/services/T0/B0/secret-token")
        _ = check()
        let url = SharedConfigPin.storeURL(profile: profile, appSupport: appSupport)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("hooks.example.com"))
        XCTAssertFalse(text.contains("secret-token"))
    }

    func testUnchangedConfigReportsNoDriftAndLogsNothing() throws {
        try writeConfig()
        _ = check()
        let lines = LineBox()
        let result = SharedConfigPin.checkpoint(
            profile: profile, appSupport: appSupport, onLine: { lines.add($0.text) })
        XCTAssertTrue(result.drifts.isEmpty)
        XCTAssertTrue(lines.all.isEmpty)
    }

    func testLocalWorkspaceIsNeverPinned() throws {
        try writeConfig(shared: false)
        XCTAssertTrue(check().drifts.isEmpty)
        XCTAssertNil(SharedConfigPin.load(profile: profile, appSupport: appSupport))
        try writeConfig(shared: false, retentionMode: "delete")
        XCTAssertTrue(check().drifts.isEmpty)
    }

    func testDiffNamesEachChangedKeyInConfigYamlSpelling() {
        let base = SharedConfigPin(
            allowAbsolutePaths: false, outputDir: "", archiveDir: "", dataDir: "",
            retentionEnabled: true, retentionMode: "archive", notifyURLHost: "a.example.com")
        var changed = base
        changed.outputDir = "/Volumes/x"
        changed.retentionMode = "delete"
        changed.notifyURLHost = "b.example.com"
        let drifts = SharedConfigPin.diff(pinned: base, current: changed)
        XCTAssertEqual(drifts.map(\.key.rawValue),
                       ["output.output_dir", "retention.mode", "notify.url"])
        XCTAssertEqual(drifts[1].pinned, "archive")
        XCTAssertEqual(drifts[1].current, "delete")
        XCTAssertTrue(SharedConfigPin.diff(pinned: base, current: base).isEmpty)
    }

    func testChangedRetentionModeIsPutBackToArchive() throws {
        try writeConfig(retentionMode: "archive")
        _ = check()
        try writeConfig(retentionMode: "delete")
        let result = check()
        XCTAssertEqual(result.drifts.map(\.key), [.retentionMode])
        let config = try ConfigLoader.load(from: workspace.appendingPathComponent("config.yaml"))
        XCTAssertEqual(config.retention?.resolvedMode, .delete)
        let safe = SharedConfigPin.effectiveRetention(config.retention, check: result)
        XCTAssertEqual(safe?.resolvedMode, .archive)
        XCTAssertEqual(safe?.isEnabled, true)
    }

    func testChangedWebhookHostBlocksTheSendButAChangedPathDoesNot() throws {
        try writeConfig(webhook: "https://hooks.example.com/a")
        _ = check()
        try writeConfig(webhook: "https://hooks.example.com/other-path")
        XCTAssertTrue(SharedConfigPin.webhookAllowed(profile: profile, appSupport: appSupport))
        try writeConfig(webhook: "https://collector.attacker.test/a")
        XCTAssertFalse(SharedConfigPin.webhookAllowed(profile: profile, appSupport: appSupport))
    }

    func testConfirmRepinsAndPartialConfirmLeavesOtherKeysDrifted() throws {
        try writeConfig()
        _ = check()
        try writeConfig(outputDir: "reports2", retentionMode: "delete",
                        webhook: "https://collector.attacker.test/a")
        XCTAssertEqual(check().drifts.count, 3)

        try SharedConfigPin.confirm(profile: profile, keys: [.outputDir], appSupport: appSupport)
        XCTAssertEqual(check().drifts.map(\.key), [.retentionMode, .notifyURL])

        try SharedConfigPin.confirm(profile: profile, appSupport: appSupport)
        XCTAssertTrue(check().drifts.isEmpty)
    }

    func testCheckpointLogsOneWarnPerDriftedKeyAndNoPartialMarker() throws {
        try writeConfig()
        _ = check()
        try writeConfig(retentionMode: "delete", webhook: "https://collector.attacker.test/a")
        let lines = LineBox()
        for _ in 0..<2 {
            SharedConfigPin.checkpoint(
                profile: profile, appSupport: appSupport, onLine: { lines.add($0.text) })
        }
        XCTAssertEqual(lines.all, [
            "[warn] shared config changed retention.mode: confirm on this Mac (Config Doctor)",
            "[warn] shared config changed notify.url: confirm on this Mac (Config Doctor)",
        ])
        XCTAssertFalse(lines.all.contains { $0.contains("[partial]") })
    }

    func testSharedRuleIsTheCoordinationGateRule() {
        let local = workspace!
        XCTAssertFalse(SharedWorkspace.isEffectivelyShared(workspace: local, config: nil))
        var forced = SharedWorkspaceConfig()
        forced.enabled = true
        XCTAssertTrue(SharedWorkspace.isEffectivelyShared(workspace: local, config: forced))
        let synced = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/CloudStorage/OneDrive-Org/jr/p")
        XCTAssertTrue(SharedWorkspace.isEffectivelyShared(workspace: synced, config: nil))
        forced.enabled = false
        XCTAssertFalse(SharedWorkspace.isEffectivelyShared(workspace: synced, config: forced))
    }
}
