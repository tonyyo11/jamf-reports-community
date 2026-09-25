import XCTest
@testable import JamfReports

/// jamf-cli's `dashboard` (1.31.0+) as a collect kind: the version gate, the Protect
/// profile, the `.html` snapshot it lands, and what a partial or refused run records.
/// The end-to-end cases drive `collect(tiers: [.inventory])` against a stub that is
/// NOT named `jamf-cli` (codesign gate) and answers `--version` and `dashboard`.
final class DashboardCollectTests: XCTestCase {

    private var root: URL!
    private var binDir: URL!
    private var answers: URL!
    private let profile = "dashprof"
    private let page = "<!DOCTYPE html><html><head><title>Jamf</title></head>"
        + "<body><h1>Fleet</h1></body></html>"

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("JRC-Dashboard-\(UUID().uuidString)", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("Jamf-Reports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspacesRoot.appendingPathComponent(profile, isDirectory: true),
            withIntermediateDirectories: true)
        binDir = root.appendingPathComponent("bin", isDirectory: true)
        answers = root.appendingPathComponent("answers", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: answers, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", workspacesRoot.path, 1)
        addTeardownBlock { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
        try writeConfig("jamf_cli:\n  profile: \"\(profile)\"\n")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    // MARK: - Pure rules

    func testDashboardNeedsJamfCLI131() {
        XCTAssertFalse(JamfCLIInstaller.supportsDashboard(nil), "unknown fails toward skipping")
        XCTAssertFalse(JamfCLIInstaller.supportsDashboard("not a version"))
        XCTAssertFalse(JamfCLIInstaller.supportsDashboard("1.30.2"))
        XCTAssertTrue(JamfCLIInstaller.supportsDashboard("1.31.0"))
        XCTAssertTrue(JamfCLIInstaller.supportsDashboard("1.31.1"))
        XCTAssertTrue(JamfCLIInstaller.supportsDashboard("2.0.0"))
    }

    func testMatrixRowAndTier() {
        let row = ReportEngine.collectCommandMatrix(profile: "p", specNames: true)
            .first { $0.kind == ReportEngine.dashboardKind }
        XCTAssertEqual(row?.args, ["-p", "p", "dashboard", "--output", "json"])
        XCTAssertEqual(CollectionTier.tier(forReport: "dashboard"), .inventory)
        XCTAssertTrue(ReportEngine.knownCollectKinds.contains("dashboard"))
    }

    func testProtectProfileIsAddedOnlyWhenProtectIsOnWithItsOwnProfile() {
        let base = ["-p", "prod", "dashboard", "--output", "json"]
        func args(_ protect: ProtectConfig?) -> [String] {
            ReportEngine.dashboardArguments(base: base, profile: "prod", protect: protect)
        }
        XCTAssertEqual(args(nil), base)
        XCTAssertEqual(args(ProtectConfig(enabled: false, profile: "prod-protect")), base)
        XCTAssertEqual(args(ProtectConfig(enabled: true, profile: "")), base)
        XCTAssertEqual(args(ProtectConfig(enabled: true, profile: "prod")), base,
                       "the same profile twice is refused by jamf-cli")
        XCTAssertEqual(args(ProtectConfig(enabled: true, profile: "-x")), base)
        XCTAssertEqual(args(ProtectConfig(enabled: true, profile: " prod-protect ")),
                       base + ["--include-profile=prod-protect"])
    }

    func testOnlyAnHTMLDocumentCountsAsAPage() {
        XCTAssertTrue(ReportEngine.isHTMLDocument(Data(page.utf8)))
        XCTAssertTrue(ReportEngine.isHTMLDocument(Data("\n  <html lang=\"en\"></html>".utf8)))
        XCTAssertTrue(ReportEngine.isHTMLDocument(Data("\u{FEFF}<!doctype html><html>".utf8)))
        XCTAssertFalse(ReportEngine.isHTMLDocument(Data(#"{"error":"permission denied"}"#.utf8)))
        XCTAssertFalse(ReportEngine.isHTMLDocument(Data()))
    }

    func testCollectSkipAcceptsTheDashboard() {
        XCTAssertEqual(ReportEngine.collectSkipKinds(["Dashboard "]), ["dashboard"])
    }

    func testFreshnessExpectsTheDashboardOnlyWhenThisJamfCLICanRunIt() {
        let without = WorkspaceStore.expectedKinds(skipExpensive: false, authMethod: "oauth2")
        XCTAssertFalse(without.contains("dashboard"))
        let with = WorkspaceStore.expectedKinds(
            skipExpensive: false, authMethod: "oauth2", dashboardSupported: true)
        XCTAssertTrue(with.contains("dashboard"))
        let listed = WorkspaceStore.expectedKinds(
            skipExpensive: false, authMethod: "oauth2", collectSkip: ["dashboard"],
            dashboardSupported: true)
        XCTAssertFalse(listed.contains("dashboard"))
    }

    func testAnHTMLSnapshotIsSavedAndPickedLikeAnyOther() throws {
        let dataDir = root.appendingPathComponent("data", isDirectory: true)
        try ReportEngine.saveSnapshot(
            data: Data(page.utf8), kind: "dashboard", dataDir: dataDir, fileExtension: "html")
        let dir = dataDir.appendingPathComponent("dashboard", isDirectory: true)
        let saved = try XCTUnwrap(FileManager.newestHTMLSnapshot(in: dir))
        XCTAssertTrue(saved.lastPathComponent.hasPrefix("dashboard_"))
        XCTAssertEqual(saved.pathExtension, "html")
        XCTAssertNotNil(CloudStorage.snapshotTimestamp(of: saved), "the filename stamp parses")
        XCTAssertNil(FileManager.newestJSONFile(in: dir), "a page is never picked as JSON")
        let perms = try FileManager.default.attributesOfItem(atPath: saved.path)[.posixPermissions]
        XCTAssertEqual((perms as? NSNumber)?.intValue, 0o600)
    }

    // MARK: - collect against a stub

    func testPageLandsAsAnHTMLSnapshot() async throws {
        try answer("dashboard.html", page)
        let log = try await runCollect()
        let saved = try XCTUnwrap(newestPage())
        XCTAssertEqual(try String(contentsOf: saved, encoding: .utf8), page)
        XCTAssertTrue(log.contains { $0.hasPrefix("[ok] dashboard:") }, "\(log)")
        let store = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
        XCTAssertNotNil(store.lastRun(report: "dashboard"))
        XCTAssertTrue(callsLog().contains("dashboard --output json --out-file "), callsLog())
    }

    func testAnOlderJamfCLISkipsItAndRecordsNothing() async throws {
        try answer("version", "jamf-cli version 1.30.2")
        try answer("dashboard.html", page)
        let log = try await runCollect()
        XCTAssertTrue(log.contains(
            "[skip] dashboard: needs jamf-cli 1.31.0 or later (installed: 1.30.2)"), "\(log)")
        XCTAssertNil(newestPage())
        XCTAssertFalse(callsLog().contains(" dashboard "), "never invoked")
        let store = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
        XCTAssertNil(store.lastRun(report: "dashboard"))
        XCTAssertNil(store.failures(report: "dashboard"))
    }

    func testExitSevenLandsThePageWithAWarning() async throws {
        try answer("dashboard.html", page)
        try answer("dashboard.exit", "7")
        let log = try await runCollect()
        XCTAssertNotNil(newestPage(), "a partial page is still the page")
        XCTAssertTrue(log.contains { $0.hasPrefix("[warn] dashboard: exit 7") }, "\(log)")
    }

    func testARefusedRunSavesNothingAndIsCounted() async throws {
        try answer("dashboard.stdout",
                   #"{"error":"permission denied","message":"permission denied (HTTP 403)"}"#)
        try answer("dashboard.exit", "5")
        _ = try await runCollect()
        XCTAssertNil(newestPage())
        let store = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
        XCTAssertEqual(store.failures(report: "dashboard")?.count, 1)
        XCTAssertEqual(store.lastFailureExitCode(for: "dashboard"), 5)
    }

    func testTheProtectProfileRidesAlong() async throws {
        try writeConfig("""
        jamf_cli:
          profile: "\(profile)"
        protect:
          enabled: true
          profile: "dashprof-protect"
        """)
        try answer("dashboard.html", page)
        _ = try await runCollect()
        XCTAssertTrue(callsLog().contains("--include-profile=dashprof-protect"), callsLog())
    }

    func testCollectSkipKeepsItFromRunning() async throws {
        try writeConfig("""
        jamf_cli:
          profile: "\(profile)"
          collect_skip: [dashboard]
        """)
        try answer("dashboard.html", page)
        let log = try await runCollect()
        XCTAssertTrue(log.contains("[skip] dashboard: listed in jamf_cli.collect_skip"), "\(log)")
        XCTAssertNil(newestPage())
    }

    // MARK: - Helpers

    private func writeConfig(_ yaml: String) throws {
        let ws = try XCTUnwrap(ProfileService.workspaceURL(for: profile))
        try yaml.write(to: ws.appendingPathComponent("config.yaml"),
                       atomically: true, encoding: .utf8)
    }

    private func answer(_ name: String, _ body: String) throws {
        try body.write(to: answers.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func callsLog() -> String {
        (try? String(contentsOf: answers.appendingPathComponent("calls.log"), encoding: .utf8))
            ?? ""
    }

    private func newestPage() -> URL? {
        guard let dataDir = try? WorkspacePaths.dataDir(for: profile) else { return nil }
        return FileManager.newestHTMLSnapshot(
            in: dataDir.appendingPathComponent("dashboard", isDirectory: true))
    }

    /// `--version` → answers/version (default 1.31.1). `dashboard … --out-file P` copies
    /// answers/dashboard.html to P when present, prints answers/dashboard.stdout, and
    /// exits with answers/dashboard.exit (default 0). Anything else prints [] and exits 0.
    private func makeStub() throws -> URL {
        let url = binDir.appendingPathComponent("stub-cli")
        let script = """
        #!/bin/sh
        A="\(answers.path)"
        printf '%s\\n' "$*" >> "$A/calls.log"
        case "$*" in
          --version)
            if [ -f "$A/version" ]; then cat "$A/version"; else echo "jamf-cli version 1.31.1"; fi
            exit 0 ;;
          *" dashboard "*)
            out=""; prev=""
            for a in "$@"; do
              if [ "$prev" = "--out-file" ]; then out="$a"; fi
              prev="$a"
            done
            if [ -f "$A/dashboard.html" ] && [ -n "$out" ]; then cp "$A/dashboard.html" "$out"; fi
            [ -f "$A/dashboard.stdout" ] && cat "$A/dashboard.stdout"
            if [ -f "$A/dashboard.exit" ]; then exit "$(cat "$A/dashboard.exit")"; fi
            exit 0 ;;
          *) printf '[]'; exit 0 ;;
        esac
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func runCollect() async throws -> [String] {
        let stub = try makeStub()
        let collector = LogTextCollector()
        try await ReportEngine.collect(
            profile: profile, workspacePaths: WorkspacePaths.self,
            tiers: [.inventory], force: true,
            locateJamfCLI: { stub }, onLine: collector.append)
        return collector.texts
    }
}
