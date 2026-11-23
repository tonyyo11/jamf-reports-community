import XCTest
@testable import JamfReports

/// A save on this Mac through the real writers must leave no drift for the key it wrote:
/// otherwise the user's own change reads as a peer's and reports/webhooks fall back.
final class SharedConfigPinSaveTests: XCTestCase {

    private let fileManager = FileManager.default
    private var root: URL!
    private var workspace: URL!
    private var profile = ""
    /// Read after setUp sets the test root, as the writers read it.
    private var appSupport: URL { AppSupport.directory() }

    override func setUpWithError() throws {
        profile = "pinsave\(UUID().uuidString.prefix(8).lowercased())"
        root = fileManager.temporaryDirectory
            .appendingPathComponent("jrc-pinsave-\(UUID().uuidString)", isDirectory: true)
        workspace = root.appendingPathComponent(profile, isDirectory: true)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        try? fileManager.removeItem(at: root)
        if let url = SharedConfigPin.storeURL(workspace: profile, appSupport: appSupport) {
            try? fileManager.removeItem(at: url)
        }
    }

    private func write(_ body: String) throws {
        try ("shared_workspace:\n  enabled: true\n" + body).write(
            to: workspace.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
    }

    private func drifts() -> [SharedConfigPin.Key] {
        SharedConfigPin.check(profile: profile, appSupport: appSupport).drifts.map(\.key)
    }

    /// First sight pins the file as it is.
    private func pinFirstSight() {
        XCTAssertEqual(drifts(), [])
    }

    /// `WorkspaceStore.saveConfig`'s sequence: load, edit, `ConfigService.save`, then confirm
    /// the keys that changed with the values the screen wrote.
    private func saveConfig(_ edit: (inout ConfigState) -> Void) throws {
        let loaded = try ConfigService.load(profile: profile)
        var state = loaded.state
        edit(&state)
        let folders = SharedConfigPin.changedFolderKeys(
            before: (loaded.state.outputDir, loaded.state.archiveDir),
            after: (state.outputDir, state.archiveDir))
        let branding = SharedConfigPin.changedBrandingKeys(
            before: loaded.state.logoPath, after: state.logoPath)
        _ = try ConfigService.save(
            profile: profile, state: state, existingDocument: loaded.document,
            ifUnchangedSince: loaded.stamp)
        let written: [SharedConfigPin.Key: String] = [
            .outputDir: state.outputDir, .archiveDir: state.archiveDir,
            .brandingLogoPath: state.logoPath,
        ]
        SharedConfigPin.confirmWritten(
            written.filter { folders.union(branding).contains($0.key) },
            profile: profile, appSupport: appSupport)
    }

    func testOutputDirRelative() throws {
        try write("output:\n  output_dir: \"Generated Reports\"\n")
        pinFirstSight()
        try saveConfig { $0.outputDir = "Reports/Team A" }
        XCTAssertEqual(drifts(), [])
    }

    func testOutputDirTildeAbsoluteWithOptIn() throws {
        try write("output:\n  allow_absolute_paths: true\n  output_dir: \"Generated Reports\"\n")
        pinFirstSight()
        try saveConfig { $0.outputDir = "~/Documents/jrc-pinsave-out" }
        XCTAssertEqual(drifts(), [])
    }

    func testArchiveDir() throws {
        try write("output:\n  archive_dir: \"\"\n")
        pinFirstSight()
        try saveConfig { $0.archiveDir = "old-runs" }
        XCTAssertEqual(drifts(), [])
    }

    func testLogoPathSetThenCleared() throws {
        try write("branding:\n  logo_path: \"\"\n")
        pinFirstSight()
        try saveConfig { $0.logoPath = "~/Pictures/logo.png" }
        XCTAssertEqual(drifts(), [])
        try saveConfig { $0.logoPath = "" }
        XCTAssertEqual(drifts(), [])
    }

    private func saveNotify(
        url: String, detail: String = "full", heartbeat: Bool? = nil
    ) throws {
        try NotifyConfigWriter.save(
            enabled: true, provider: "teams", url: url, detail: detail, heartbeat: heartbeat,
            profile: profile)
    }

    private let notifyBlock = "notify:\n  enabled: true\n  provider: teams\n"
        + "  url: \"https://hooks.example.com/a\"\n  detail: full\n"

    func testWebhookChanged() throws {
        try write(notifyBlock)
        pinFirstSight()
        try saveNotify(url: " https://other.example.com/b?t=1 ")
        XCTAssertEqual(drifts(), [])
    }

    func testWebhookCleared() throws {
        try write(notifyBlock)
        pinFirstSight()
        try saveNotify(url: "")
        XCTAssertEqual(drifts(), [])
    }

    func testDetailMinimal() throws {
        try write(notifyBlock)
        pinFirstSight()
        try saveNotify(url: "https://hooks.example.com/a", detail: "minimal")
        XCTAssertEqual(drifts(), [])
    }

    func testHeartbeatOn() throws {
        try write(notifyBlock)
        pinFirstSight()
        try saveNotify(url: "https://hooks.example.com/a", heartbeat: true)
        XCTAssertEqual(drifts(), [])
    }

    func testHeartbeatOffWhereFileHadTrue() throws {
        try write(notifyBlock + "  heartbeat: true\n")
        pinFirstSight()
        try saveNotify(url: "https://hooks.example.com/a", heartbeat: false)
        XCTAssertEqual(drifts(), [])
    }

    func testHeartbeatOffWhereFileNeverSetIt() throws {
        try write(notifyBlock)
        pinFirstSight()
        try saveNotify(url: "https://hooks.example.com/a", heartbeat: false)
        XCTAssertEqual(drifts(), [])
    }
}
