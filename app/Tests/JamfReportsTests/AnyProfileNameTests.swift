import Foundation
import XCTest
@testable import JamfReports

/// From 2.8.3 the app uses every profile name jamf-cli accepts (jamf-cli 1.31.1 resolves all of
/// these). Each gets its own workspace folder, reads back from that folder exactly, and gets a
/// schedule label and a Run History record.
@MainActor
final class AnyProfileNameTests: XCTestCase {

    private nonisolated(unsafe) var tempRoot: URL!

    private let names = [
        "Acme Prod", "acme.prod", "Zürich", "a,b", "a:b", "a/b", "-lead", "#hash", "it's",
        "..", "_fleet-reports", "R&D (EU)", "true", "2024", #"say "hi""#, #"back\slash"#,
    ]

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-any-name-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", tempRoot.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
    }

    #if DEBUG
    /// The real workspace initializer and config binding; only the network collect is stubbed.
    func testSetupInitializesAWorkspaceForEveryName() async throws {
        let flow = ExistingCLISetupFlow(profileNames: names)
        XCTAssertEqual(flow.unusable, [:])
        XCTAssertEqual(flow.selected, Set(names))
        await flow.run(collect: { _, _ in 0 })

        for name in names {
            XCTAssertEqual(flow.statuses[name], .done, name)
            let folder = tempRoot.appendingPathComponent(ProfileName.pathComponent(name))
            let config = folder.appendingPathComponent("config.yaml")
            XCTAssertEqual(try ConfigLoader.load(from: config).jamfCli?.profile, name,
                           "config.yaml records the name jamf-cli is called with")
        }
        let folders = try FileManager.default.contentsOfDirectory(atPath: tempRoot.path)
        XCTAssertEqual(folders.count, names.count, "one folder per name, nothing outside the root")
        XCTAssertEqual(
            Set(ProfileService.localOnlyWorkspaces(under: tempRoot, cliNames: [])), Set(names),
            "discovery reads every folder back to its profile"
        )
    }

    func testRunHistoryRecordsARunForEveryName() throws {
        for name in names {
            let workspace = try XCTUnwrap(ProfileService.workspaceURL(for: name))
            let label = CLIRunSignals.cliLabel(profile: name, kind: .collect)
            let recorder = try XCTUnwrap(
                ScheduledRunRecorder(workspace: workspace, label: label), "\(name): \(label)"
            )
            _ = recorder
            let logs = workspace.appendingPathComponent("automation/logs")
            XCTAssertTrue(FileManager.default.fileExists(atPath: logs.path), name)
            XCTAssertEqual(logs.deletingLastPathComponent().deletingLastPathComponent().path,
                           workspace.path, name)
        }
    }
    #endif

    /// Run History reads a log only inside a workspace folder: `100%` is no profile's folder.
    func testRunHistoryReadsLogsOnlyInsideWorkspaceFolders() throws {
        let workspace = try XCTUnwrap(ProfileService.workspaceURL(for: "a/b"))
        let stray = tempRoot.appendingPathComponent("100%", isDirectory: true)
        for folder in [workspace, stray] {
            let logs = folder.appendingPathComponent("automation/logs", isDirectory: true)
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            try Data("[ok] collected\nexit 0 after 1s\n".utf8)
                .write(to: logs.appendingPathComponent("run.log"))
        }
        let log = "automation/logs/run.log"
        XCTAssertFalse(RunHistoryService.loadLog(workspace.appendingPathComponent(log)).isEmpty)
        XCTAssertTrue(RunHistoryService.loadLog(stray.appendingPathComponent(log)).isEmpty)
    }

    /// The Devices screen reads jamf-cli inventory from an encoded workspace folder.
    func testDevicesReadInventoryFromAnEncodedWorkspace() throws {
        let workspace = try XCTUnwrap(ProfileService.workspaceURL(for: "a/b"))
        let kind = workspace.appendingPathComponent("jamf-cli-data/computers", isDirectory: true)
        try FileManager.default.createDirectory(at: kind, withIntermediateDirectories: true)
        try Data(#"[{"general": {"name": "Mac", "id": "42"}, "hardware": {"serialNumber": "E1"}}]"#
            .utf8).write(to: kind.appendingPathComponent("computers_20260825T090000.json"))
        let snapshot = DeviceInventoryService.load(profile: "a/b", demoMode: false)
        XCTAssertEqual(snapshot.devices.map(\.serial), ["E1"])
    }

    /// A copied folder (Finder's `prod copy`) still records `prod`, so it is not a workspace
    /// of its own that every all-profiles run would then try and fail.
    func testACopiedWorkspaceFolderIsNotAProfile() throws {
        for (folder, recorded) in [
            ("prod", "prod"), ("prod copy", "prod"), ("lab", "lab"), ("bare", ""),
        ] {
            let dir = tempRoot.appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("jamf_cli:\n  profile: \"\(recorded)\"\n".utf8)
                .write(to: dir.appendingPathComponent("config.yaml"))
        }
        XCTAssertEqual(
            Set(ProfileService.localOnlyWorkspaces(under: tempRoot, cliNames: ["prod"])),
            ["lab", "bare"]
        )
    }

    func testShownPathsNameTheRealFolder() {
        XCTAssertTrue(WorkspaceRootStore.displayPath(profile: "a/b").hasSuffix("/a%2Fb"))
        XCTAssertTrue(WorkspaceRootStore.displayPath(profile: "Acme Prod", subpath: "backups")
            .hasSuffix("/Acme Prod/backups"))
        XCTAssertTrue(ExistingCLISetupFlow.missingWorkspaceMessage(root: "~/R", profiles: ["a/b"])
            .contains("~/R/a%2Fb/config.yaml"))
    }

    func testAuthHintsQuoteTheProfile() {
        let error = ReportEngineError.authExpired(profile: "Acme Prod", failedCount: 3)
        XCTAssertTrue(error.errorDescription?.contains("jamf-cli -p 'Acme Prod' pro auth token")
            == true, error.errorDescription ?? "")
    }

    func testProfileOptionsParseBack() {
        XCTAssertEqual(ProfileName.profileOption("acme"), "--profile acme")
        XCTAssertEqual(ProfileName.profileOption("Acme Prod"), "--profile 'Acme Prod'")
        XCTAssertEqual(ProfileName.profileOption("-lead"), "--profile=-lead")
        let run = ["JamfReports", "--scheduled-run"]
        XCTAssertEqual(ProfileService.profileArgument(in: run + ["--profile", "Acme Prod"]),
                       "Acme Prod")
        XCTAssertEqual(ProfileService.profileArgument(in: run + ["--profile=--lead"]), "--lead")
        XCTAssertNil(ProfileService.profileArgument(in: run + ["--profile", "--all-profiles"]))
        XCTAssertNil(ProfileService.profileArgument(in: run))
    }

    func testCaseAndAccentVariantsShareOneFolder() {
        XCTAssertEqual(
            ProfileService.unusableProfiles(
                in: ["Zürich", "zürich"], recordedOwner: { _ in nil }
            ),
            ["Zürich": .sharesFolder(with: "zürich")]
        )
        XCTAssertTrue(ProfileService.isCaseVariant("ACME PROD", of: "Acme Prod"))
        // Checked on APFS: a folder named Straße also answers to STRASSE (full case folding).
        XCTAssertTrue(ProfileService.isCaseVariant("STRASSE", of: "Straße"))
        XCTAssertFalse(ProfileService.isCaseVariant("Acme Prod", of: "Acme-Prod"))
    }

    func testExportFileNamesKeepTheName() {
        let date = Date(timeIntervalSince1970: 0)
        let stamp = ExportNaming.timestamp(date)
        func name(_ profile: String) -> String {
            ExportNaming.filename(kind: "devices", profile: profile, ext: "csv", now: date)
        }
        XCTAssertEqual(name("Acme Prod"), "devices-Acme Prod-\(stamp).csv")
        XCTAssertEqual(name("a/b"), "devices-a%2Fb-\(stamp).csv")
        XCTAssertEqual(ReportsView.profile(fromReportFilename: "devices-a%2Fb-\(stamp).csv"), "a/b")
    }

    func testShellWordsQuoteOnlyWhatNeedsIt() {
        XCTAssertEqual(ProfileName.shellWord("Acme-Dev_2.prod"), "Acme-Dev_2.prod")
        XCTAssertEqual(ProfileName.shellWord("Acme Prod"), "'Acme Prod'")
        XCTAssertEqual(ProfileName.shellWord("it's"), #"'it'\''s'"#)
        XCTAssertEqual(ProfileName.shellWord("$HOME"), "'$HOME'")
    }

    /// The loader turns a quoted "true" into a bool for every other key, so a hand-edited
    /// `use_cached_data: "false"` still works; a profile name is never re-typed.
    func testConfigKeepsProfileNamesThatLookLikeBooleansOrNull() throws {
        for name in ["true", "False", "null", "~", "NULL", "2024"] {
            let yaml = "jamf_cli:\n  profile: \"\(name)\"\n"
            XCTAssertEqual(try ConfigLoader.loadFromString(yaml).jamfCli?.profile, name, yaml)
        }
        let quoted = try ConfigLoader.loadFromString("jamf_cli:\n  use_cached_data: \"false\"\n")
        XCTAssertEqual(quoted.jamfCli?.useCachedData, false)
    }

    func testFallbackReaderUnquotesKeys() {
        XCTAssertEqual(ProfileService.unquotedYAMLKey(#""a \"b\"""#), #"a "b""#)
        XCTAssertEqual(ProfileService.unquotedYAMLKey("'#hash'"), "#hash")
        XCTAssertEqual(ProfileService.unquotedYAMLKey("'it''s'"), "it's")
        XCTAssertEqual(ProfileService.unquotedYAMLKey("Acme Prod"), "Acme Prod")
        XCTAssertEqual(ProfileService.unquotedYAMLKey("\""), "\"")
    }
}
