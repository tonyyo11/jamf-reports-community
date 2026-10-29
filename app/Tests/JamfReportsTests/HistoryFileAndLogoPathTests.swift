import XCTest
@testable import JamfReports

/// `html.history_file` and `branding.logo_path` are paths a peer can retarget in a shared
/// config.yaml: each is confined and pinned per Mac.
final class HistoryFileAndLogoPathTests: XCTestCase {

    private let fm = FileManager.default
    private let profile = "histlogo"
    private var root: URL!
    private var workspace: URL!
    private var appSupport: URL!
    private var away: URL!
    private let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func add(_ line: String) { lock.lock(); stored.append(line); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return stored }
    }

    override func setUpWithError() throws {
        root = fm.temporaryDirectory
            .appendingPathComponent("jrc-hl-\(UUID().uuidString.prefix(8))", isDirectory: true)
        workspace = root.appendingPathComponent(profile, isDirectory: true)
        appSupport = root.appendingPathComponent(".app-support", isDirectory: true)
        try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
        try fm.createDirectory(at: appSupport, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        // Under home, which is not a reserved folder (the temp folder is).
        away = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("jrc-hl-away-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try fm.createDirectory(at: away, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        try? fm.removeItem(at: root)
        try? fm.removeItem(at: away)
    }

    private func writeConfig(_ body: String) throws {
        try body.write(to: workspace.appendingPathComponent("config.yaml"),
                       atomically: true, encoding: .utf8)
    }

    private func config() throws -> ReportConfig {
        try ConfigLoader.load(from: workspace.appendingPathComponent("config.yaml"))
    }

    // MARK: - html.history_file

    func testTheReportFolderRuleRefusesUsersSharedEvenWithTheOptIn() throws {
        try writeConfig("""
        jamf_cli:
          profile: \(profile)
        output:
          allow_absolute_paths: true
        """)
        let lines = Lines()
        var report = HtmlReport(config: try config(),
                                dataDir: workspace.appendingPathComponent("jamf-cli-data"))
        report.workspace = WorkspaceID(profile)
        report.onLine = { lines.add($0.text) }
        let out = workspace.appendingPathComponent("Generated Reports/report.html")
        for typed in ["/Users/Shared/h.json", "/tmp/h.json", "~/Public/h.json"] {
            XCTAssertEqual(report.resolvedHistoryPath(typed, outputURL: out).lastPathComponent,
                           "html_history.json", typed)
        }
        XCTAssertEqual(lines.all.count, 3, "\(lines.all)")
    }

    func testANonDefaultDataDirStillFindsTheProfilesConfigYaml() throws {
        try writeConfig("""
        jamf_cli:
          profile: \(profile)
        html:
          track_history: true
          history_file: h.json
        """)
        var report = HtmlReport(config: try config(),
                                dataDir: root.appendingPathComponent("elsewhere/data"))
        report.workspace = WorkspaceID(profile)
        _ = report.buildHistorySection(
            security: [], outputURL: workspace.appendingPathComponent("Generated Reports/r.html"))
        XCTAssertTrue(fm.fileExists(atPath: workspace.appendingPathComponent("h.json").path),
                      "history_file is read from the profile's workspace and resolved against it")
    }

    func testAHistoryFileAPeerChangedIsWrittenBesideTheReportUntilConfirmed() throws {
        func body(_ file: String) -> String {
            """
            shared_workspace:
              enabled: true
            jamf_cli:
              profile: \(profile)
            html:
              track_history: true
              history_file: \(file)
            """
        }
        try writeConfig(body("h.json"))
        _ = SharedConfigPin.check(profile: profile, appSupport: appSupport)
        try writeConfig(body("peer.json"))
        let out = workspace.appendingPathComponent("Generated Reports/r.html")
        let reports = out.deletingLastPathComponent()
        try fm.createDirectory(at: reports, withIntermediateDirectories: true)

        var report = HtmlReport(config: try config(),
                                dataDir: workspace.appendingPathComponent("jamf-cli-data"))
        report.workspace = WorkspaceID(profile)
        _ = report.buildHistorySection(security: [], outputURL: out)
        XCTAssertFalse(fm.fileExists(atPath: workspace.appendingPathComponent("peer.json").path))
        XCTAssertTrue(fm.fileExists(
            atPath: reports.appendingPathComponent("html_history.json").path))

        let drifts = SharedConfigPin.check(profile: profile, appSupport: appSupport).drifts
        XCTAssertEqual(drifts.map(\.key), [.htmlHistoryFile])
        try SharedConfigPin.confirm(profile: profile, drifts: drifts, appSupport: appSupport)
        _ = report.buildHistorySection(security: [], outputURL: out)
        XCTAssertTrue(fm.fileExists(atPath: workspace.appendingPathComponent("peer.json").path))
    }

    // MARK: - branding.logo_path

    private func logoConfig(_ typed: String, shared: Bool = false) throws -> ReportConfig {
        try writeConfig("""
        \(shared ? "shared_workspace:\n  enabled: true" : "")
        jamf_cli:
          profile: \(profile)
        branding:
          logo_path: "\(typed)"
        """)
        return try config()
    }

    private func load(_ typed: String, shared: Bool = false) throws -> (Data?, [String]) {
        let lines = Lines()
        let data = ReportLogo.load(
            from: try logoConfig(typed, shared: shared), profile: profile,
            warn: { lines.add($0) })
        return (data, lines.all)
    }

    func testAnAbsoluteLogoOutsideTheWorkspaceStillLoadsWithoutTheOptIn() throws {
        let png = away.appendingPathComponent("logo.png")
        try pngBytes.write(to: png)
        let (data, warnings) = try load(png.path)
        XCTAssertEqual(data, pngBytes)
        XCTAssertTrue(warnings.isEmpty, "\(warnings)")
    }

    func testARelativeLogoIsTheWorkspacesAndATildeLogoIsTheHomes() throws {
        try pngBytes.write(to: workspace.appendingPathComponent("logo.png"))
        XCTAssertEqual(try load("logo.png").0, pngBytes)
        let name = "jrc-hl-tilde-\(UUID().uuidString.prefix(8)).png"
        let home = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(name)
        try pngBytes.write(to: home)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        XCTAssertEqual(try load("~/\(name)").0, pngBytes)
    }

    func testAFifoIsRefusedWithoutBlocking() throws {
        let fifo = away.appendingPathComponent("logo.png")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let (data, warnings) = try load(fifo.path)
        XCTAssertNil(data)
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("is not a regular file"), "\(warnings)")
    }

    func testADirectoryIsRefused() throws {
        let (data, warnings) = try load(away.path)
        XCTAssertNil(data)
        XCTAssertTrue(warnings.first?.contains("is not a regular file") == true, "\(warnings)")
    }

    func testALogoOverTwoMegabytesIsRefusedAndOneAtTheLimitLoads() throws {
        let png = away.appendingPathComponent("logo.png")
        var big = pngBytes
        big.append(Data(repeating: 0, count: ReportLogo.maxLogoBytes - pngBytes.count))
        try big.write(to: png)
        XCTAssertEqual(try load(png.path).0?.count, ReportLogo.maxLogoBytes)
        big.append(0)
        try big.write(to: png)
        let (data, warnings) = try load(png.path)
        XCTAssertNil(data)
        XCTAssertTrue(warnings.first?.contains("is over 2 MB") == true, "\(warnings)")
    }

    func testASystemOrCredentialsFolderIsRefusedBeforeAnyRead() throws {
        for typed in ["/etc/hosts", "~/Library/Preferences/jrc-logo.png", "~/.ssh/id_ed25519"] {
            let (data, warnings) = try load(typed)
            XCTAssertNil(data, typed)
            XCTAssertTrue(warnings.first?.contains("reserved by macOS") == true, "\(warnings)")
        }
    }

    func testAWarningShowsTheValueThroughDisplayText() throws {
        var config = try logoConfig("placeholder.png")
        config.branding?.logoPath = "missing\u{07}\u{1B}[31mname.png"
        let lines = Lines()
        XCTAssertNil(ReportLogo.load(
            from: config, profile: profile, warn: { lines.add($0) }))
        let warnings = lines.all
        XCTAssertEqual(warnings.count, 1)
        XCTAssertFalse(warnings[0].unicodeScalars.contains { $0.value < 0x20 }, "\(warnings)")
        XCTAssertTrue(warnings[0].contains("was not found"))
    }

    func testALogoAPeerChangedReadsAsNoLogoUntilConfirmed() throws {
        let mine = away.appendingPathComponent("mine.png")
        let theirs = away.appendingPathComponent("theirs.png")
        try pngBytes.write(to: mine)
        try pngBytes.write(to: theirs)
        _ = try logoConfig(mine.path, shared: true)
        _ = SharedConfigPin.check(profile: profile, appSupport: appSupport)

        let (data, warnings) = try load(theirs.path, shared: true)
        XCTAssertNil(data, "a changed logo path is not embedded")
        XCTAssertTrue(warnings.isEmpty, "the pin check, not the loader, reports the change")

        let drifts = SharedConfigPin.check(profile: profile, appSupport: appSupport).drifts
        XCTAssertEqual(drifts.map(\.key), [.brandingLogoPath])
        try SharedConfigPin.confirm(profile: profile, drifts: drifts, appSupport: appSupport)
        XCTAssertEqual(try load(theirs.path, shared: true).0, pngBytes)
    }

    func testAConfigScreenSaveThatChangedTheLogoConfirmsIt() {
        XCTAssertEqual(SharedConfigPin.changedBrandingKeys(before: "a.png", after: "b.png"),
                       [.brandingLogoPath])
        XCTAssertEqual(SharedConfigPin.changedBrandingKeys(before: " a.png", after: "a.png "), [])
        XCTAssertEqual(SharedConfigPin.changedBrandingKeys(before: nil, after: "b.png"), [])
    }

    // MARK: - The run's profile, not the one config.yaml names

    func testAPeerNamingAnotherProfileInConfigYamlDoesNotEscapeThePin() throws {
        let mine = away.appendingPathComponent("mine.png")
        let theirs = away.appendingPathComponent("theirs.png")
        try pngBytes.write(to: mine)
        try pngBytes.write(to: theirs)
        _ = try logoConfig(mine.path, shared: true)
        _ = SharedConfigPin.check(profile: profile, appSupport: appSupport)

        try writeConfig("""
        shared_workspace:
          enabled: true
        jamf_cli:
          profile: decoy
        branding:
          logo_path: "\(theirs.path)"
        html:
          track_history: true
          history_file: peer.json
        """)
        let decoyConfig = try config()
        XCTAssertNil(ReportLogo.load(
            from: decoyConfig, profile: profile, warn: { _ in }), "the pin holds the logo back")

        var report = HtmlReport(config: decoyConfig,
                                dataDir: workspace.appendingPathComponent("jamf-cli-data"))
        report.workspace = WorkspaceID(profile)
        let out = workspace.appendingPathComponent("Generated Reports/r.html")
        try fm.createDirectory(
            at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = report.buildHistorySection(security: [], outputURL: out)
        XCTAssertFalse(fm.fileExists(atPath: workspace.appendingPathComponent("peer.json").path))
    }

    func testARelativeLogoSwappedForASymlinkOutOfTheWorkspaceIsRefused() throws {
        let outside = away.appendingPathComponent("desktop.png")
        try pngBytes.write(to: outside)
        try fm.createSymbolicLink(
            at: workspace.appendingPathComponent("logo.png"), withDestinationURL: outside)
        let (data, warnings) = try load("logo.png")
        XCTAssertNil(data)
        XCTAssertTrue(warnings.first?.contains("resolves to a file outside it") == true,
                      "\(warnings)")
        // The same link to a PNG inside the workspace is fine.
        let inner = workspace.appendingPathComponent("brand/real.png")
        try fm.createDirectory(
            at: inner.deletingLastPathComponent(), withIntermediateDirectories: true)
        try pngBytes.write(to: inner)
        try fm.removeItem(at: workspace.appendingPathComponent("logo.png"))
        try fm.createSymbolicLink(
            at: workspace.appendingPathComponent("logo.png"), withDestinationURL: inner)
        XCTAssertEqual(try load("logo.png").0, pngBytes)
    }

    // MARK: - History file bounds

    private func reportWithHistory(_ file: String) throws -> (HtmlReport, URL, Lines) {
        try writeConfig("""
        jamf_cli:
          profile: \(profile)
        html:
          track_history: true
          history_file: \(file)
        """)
        let lines = Lines()
        var report = HtmlReport(config: try config(),
                                dataDir: workspace.appendingPathComponent("jamf-cli-data"))
        report.workspace = WorkspaceID(profile)
        report.onLine = { lines.add($0.text) }
        let out = workspace.appendingPathComponent("Generated Reports/r.html")
        try fm.createDirectory(
            at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (report, out, lines)
    }

    func testAHistoryFileOverTheBoundIsLeftAsItIsWithOneWarning() throws {
        let big = workspace.appendingPathComponent("h.json")
        try Data(repeating: UInt8(ascii: " "), count: HtmlReport.maxHistoryBytes + 1).write(to: big)
        let (report, out, lines) = try reportWithHistory("h.json")
        _ = report.buildHistorySection(security: [], outputURL: out)
        XCTAssertEqual(lines.all.count, 1, "\(lines.all)")
        XCTAssertTrue(lines.all[0].contains("is over 8 MB"), "\(lines.all)")
        let size = try fm.attributesOfItem(atPath: big.path)[.size] as? Int
        XCTAssertEqual(size, HtmlReport.maxHistoryBytes + 1)
    }

    func testAFifoAsTheHistoryFileIsRefusedWithoutBlocking() throws {
        let fifo = workspace.appendingPathComponent("h.json")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let (report, out, lines) = try reportWithHistory("h.json")
        _ = report.buildHistorySection(security: [], outputURL: out)
        XCTAssertEqual(lines.all.count, 1, "\(lines.all)")
        XCTAssertTrue(lines.all[0].contains("not a regular file"), "\(lines.all)")
    }
}
