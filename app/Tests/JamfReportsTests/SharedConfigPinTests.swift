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
        appSupport = root.appendingPathComponent(".app-support", isDirectory: true)
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
        retentionMode: String = "archive", retentionArchiveDir: String = "",
        webhook: String = "https://hooks.example.com/a", detail: String = "full",
        historicalDir: String = "snapshots", protectProfile: String = "protect-a"
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
          snapshot_keep_days: 30
          archive_dir: "\(retentionArchiveDir)"
        notify:
          enabled: true
          url: "\(webhook)"
          detail: \(detail)
        charts:
          historical_csv_dir: "\(historicalDir)"
        protect:
          enabled: true
          profile: "\(protectProfile)"
        """
        try body.write(to: workspace.appendingPathComponent("config.yaml"),
                       atomically: true, encoding: .utf8)
    }

    /// What the Doctor's Confirm button does: re-pin every drift as it is shown now.
    private func confirmAll() throws {
        try SharedConfigPin.confirm(
            profile: profile, drifts: check().drifts, appSupport: appSupport)
    }

    /// The notify block as this Mac may use it, read from the workspace's config.yaml.
    private func sendable() -> NotifyConfig? {
        let config = try? ConfigLoader.load(from: workspace.appendingPathComponent("config.yaml"))
        return SharedConfigPin.effectiveNotify(
            config?.notify ?? NotifyConfig(), profile: profile, appSupport: appSupport)
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
        XCTAssertFalse(text.contains("https://"))
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

    func testAnOptOutWrittenIntoTheSharedFileDoesNotSwitchPinningOff() throws {
        try writeConfig(shared: true, retentionMode: "archive")
        _ = check()
        try writeConfig(shared: false, retentionMode: "delete")
        let result = check()
        XCTAssertEqual(result.drifts.map(\.key), [.retentionMode, .sharedEnabled])
        let drift = try XCTUnwrap(result.drifts.last)
        XCTAssertEqual(drift.pinned, "true")
        XCTAssertEqual(drift.current, "false")
        let config = try ConfigLoader.load(from: workspace.appendingPathComponent("config.yaml"))
        XCTAssertEqual(
            SharedConfigPin.effectiveRetention(config.retention, check: result)?.resolvedMode,
            .archive)
    }

    func testPinningAppliesOnOptInProviderOrExistingPinNeverOnAnOptOutAlone() {
        XCTAssertTrue(SharedConfigPin.appliesTo(
            sharedEnabled: true, onSyncProvider: false, pinExists: false))
        XCTAssertTrue(SharedConfigPin.appliesTo(
            sharedEnabled: false, onSyncProvider: true, pinExists: false))
        XCTAssertTrue(SharedConfigPin.appliesTo(
            sharedEnabled: false, onSyncProvider: false, pinExists: true))
        XCTAssertFalse(SharedConfigPin.appliesTo(
            sharedEnabled: false, onSyncProvider: false, pinExists: false))
        XCTAssertFalse(SharedConfigPin.appliesTo(
            sharedEnabled: nil, onSyncProvider: false, pinExists: false))
    }

    func testAnUnreadablePinFailsClosedWithEveryKeyDrifted() throws {
        try writeConfig(retentionMode: "archive")
        _ = check()
        let store = SharedConfigPin.storeURL(profile: profile, appSupport: appSupport)
        try "not json".write(to: store, atomically: true, encoding: .utf8)

        let result = check()
        XCTAssertEqual(Set(result.drifts.map(\.key)), Set(SharedConfigPin.Key.allCases))
        XCTAssertEqual(try String(contentsOf: store, encoding: .utf8), "not json",
                       "the file is not replaced by what config.yaml holds")
        let config = try ConfigLoader.load(from: workspace.appendingPathComponent("config.yaml"))
        let safe = SharedConfigPin.effectiveRetention(config.retention, check: result)
        XCTAssertEqual(safe?.resolvedMode, .archive)
        XCTAssertEqual(safe?.isEnabled, false)
        XCTAssertNil(sendable())
        XCTAssertEqual(ConfigDoctorService.sharedConfigRows(
            profile: profile, appSupport: appSupport).count, 1)
    }

    func testAPinWrittenBeforeAKeyWasAddedStillReads() throws {
        try writeConfig()
        _ = check()
        let store = SharedConfigPin.storeURL(profile: profile, appSupport: appSupport)
        let old = #"{"allowAbsolutePaths":false,"outputDir":"","archiveDir":"","dataDir":"","#
            + #""retentionEnabled":true,"retentionMode":"archive","notifyURLHost":"hooks.example.com"}"#
        try old.write(to: store, atomically: true, encoding: .utf8)
        guard case .pin(let pin) = SharedConfigPin.read(profile: profile, appSupport: appSupport)
        else { return XCTFail("an older pin should still decode") }
        XCTAssertEqual(pin.notifyURLHost, "hooks.example.com")
        XCTAssertEqual(pin.retentionArchiveDir, "")
        XCTAssertEqual(Set(check().drifts.map(\.key)),
                       [.sharedEnabled, .historicalDir, .protectProfile, .notifyURL],
                       "only the keys the old pin lacks, and that config.yaml sets, read as changed")
    }

    func testAFirstSightSaveFailureIsLoggedOnTheRun() throws {
        try writeConfig()
        let missing = root.appendingPathComponent("no-such-folder/support", isDirectory: true)
        let lines = LineBox()
        SharedConfigPin.checkpoint(
            profile: profile, appSupport: missing, onLine: { lines.add($0.text) })
        XCTAssertEqual(lines.all.count, 1)
        XCTAssertTrue(lines.all[0].hasPrefix("[warn] shared config could not be pinned"),
                      lines.all[0])
    }

    func testConfirmRepinsAKeyOnlyWhileConfigYamlStillHoldsTheShownValue() throws {
        try writeConfig(retentionMode: "archive")
        _ = check()
        try writeConfig(retentionMode: "delete")
        let shown = check().drifts
        XCTAssertEqual(shown.map(\.key), [.retentionMode])

        // A peer edits again after the row was shown.
        try writeConfig(retentionMode: "archive", webhook: "https://collector.attacker.test/a")
        try SharedConfigPin.confirm(profile: profile, drifts: shown, appSupport: appSupport)
        XCTAssertEqual(check().drifts.map(\.key), [.notifyURL],
                       "the retention row no longer matched, the webhook was never shown")
        guard case .pin(let pin) = SharedConfigPin.read(profile: profile, appSupport: appSupport)
        else { return XCTFail("pin missing") }
        XCTAssertEqual(pin.retentionMode, "archive")
        XCTAssertEqual(pin.notifyURLHost, "hooks.example.com")
    }

    func testConfirmingAnUnreadablePinNeedsEveryKeyToStillMatch() throws {
        try writeConfig()
        _ = check()
        let store = SharedConfigPin.storeURL(profile: profile, appSupport: appSupport)
        try "not json".write(to: store, atomically: true, encoding: .utf8)
        let shown = check().drifts
        try writeConfig(retentionMode: "delete")
        XCTAssertThrowsError(try SharedConfigPin.confirm(
            profile: profile, drifts: shown, appSupport: appSupport))
        XCTAssertEqual(Set(check().drifts.map(\.key)), Set(SharedConfigPin.Key.allCases))
        try SharedConfigPin.confirm(profile: profile, drifts: check().drifts, appSupport: appSupport)
        XCTAssertTrue(check().drifts.isEmpty)
    }

    func testAChangedNotifyDetailSendsMinimalAndAChangedHistoricalDirReadsAsDefault() throws {
        try writeConfig(detail: "minimal", historicalDir: "snaps")
        _ = check()
        try writeConfig(detail: "full", historicalDir: outside)
        SharedConfigPin.markHeadless()
        let result = SharedConfigPin.checkpoint(
            profile: profile, appSupport: appSupport, onLine: nil)
        XCTAssertEqual(result.drifts.map(\.key), [.historicalDir, .notifyDetail])
        XCTAssertEqual(sendable()?.resolvedDetail, .minimal)
        XCTAssertEqual(try WorkspacePaths.historicalDir(for: profile).lastPathComponent,
                       "snapshots")
    }

    func testAChangedProtectProfileSkipsProtectAndTheDashboardInclude() async throws {
        try writeConfig(protectProfile: "protect-a")
        _ = check()
        try writeConfig(protectProfile: "someone-elses")
        let config = try ConfigLoader.load(from: workspace.appendingPathComponent("config.yaml"))
        let lines = LineBox()
        let protectRuns = LineBox()
        try await CollectRouter.run(
            profile: profile, config: config,
            proCollect: { _, _, _, _, _, _ in .collected },
            protectCollect: { name, _, _ in protectRuns.add(name) },
            onLine: { lines.add($0.text) })
        XCTAssertTrue(protectRuns.all.isEmpty)
        XCTAssertTrue(lines.all.contains { $0.hasPrefix("[skip] protect: protect.profile changed") })
        XCTAssertFalse(lines.all.contains { $0.contains("[partial]") })
        XCTAssertFalse(SharedConfigPin.protectAllowed(profile: profile, appSupport: appSupport))
        XCTAssertEqual(ReportEngine.dashboardArguments(
            base: ["x"], profile: profile,
            protect: SharedConfigPin.protectAllowed(profile: profile, appSupport: appSupport)
                ? config.protect : nil), ["x"])
    }

    func testFirstSightKeepsAnAbsoluteFolderAndDeleteUnconfirmedUntilOneConfirm() throws {
        try writeConfig(outputDir: outside, allowAbsolute: true, retentionMode: "delete")
        SharedConfigPin.markHeadless()
        let lines = LineBox()
        let result = SharedConfigPin.checkpoint(
            profile: profile, appSupport: appSupport, onLine: { lines.add($0.text) })
        XCTAssertEqual(result.drifts.map(\.key), [.outputDir, .retentionMode])
        XCTAssertEqual(result.drifts[0].pinned, SharedConfigPin.firstSightNote)
        XCTAssertEqual(lines.all.count, 2)
        XCTAssertEqual(try WorkspacePaths.outputDir(for: profile).lastPathComponent,
                       WorkspacePaths.generatedReportsDirName)
        let config = try ConfigLoader.load(from: workspace.appendingPathComponent("config.yaml"))
        XCTAssertEqual(
            SharedConfigPin.effectiveRetention(config.retention, check: result)?.resolvedMode,
            .archive)
        let rows = ConfigDoctorService.sharedConfigRows(profile: profile, appSupport: appSupport)
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows[0].detail.contains("pinned (first seen, not confirmed)"))

        try confirmAll()
        XCTAssertTrue(check().drifts.isEmpty)
        SharedConfigPin.checkpoint(profile: profile, appSupport: appSupport, onLine: nil)
        XCTAssertEqual(try WorkspacePaths.outputDir(for: profile).path, outside)
    }

    func testAFolderThatIsASymlinkOutOfTheWorkspaceIsUnconfirmedAtFirstSight() throws {
        let target = root.appendingPathComponent("elsewhere", isDirectory: true)
        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        let link = workspace.appendingPathComponent("reports-link")
        try fileManager.createSymbolicLink(at: link, withDestinationURL: target)
        try writeConfig(outputDir: link.path, allowAbsolute: true)
        XCTAssertEqual(check().drifts.map(\.key), [.outputDir])
    }

    func testFirstSightOfAFolderInsideTheWorkspaceOrADefaultNeedsNoConfirm() throws {
        try writeConfig(outputDir: workspace.path + "/reports", allowAbsolute: true)
        XCTAssertTrue(check().drifts.isEmpty)
    }

    func testASaveOnThisMacConfirmsAFirstSightFolderItChanged() throws {
        try writeConfig(outputDir: outside, allowAbsolute: true)
        XCTAssertEqual(check().drifts.map(\.key), [.outputDir])
        try SharedConfigPin.confirm(profile: profile, keys: [.outputDir], appSupport: appSupport)
        XCTAssertTrue(check().drifts.isEmpty)
    }

    func testWithoutARunEveryCheckpointReportsAgain() throws {
        try writeConfig()
        _ = check()
        try writeConfig(retentionMode: "delete")
        let lines = LineBox()
        for _ in 0..<2 {
            SharedConfigPin.checkpoint(
                profile: profile, appSupport: appSupport, onLine: { lines.add($0.text) })
        }
        XCTAssertEqual(lines.all.count, 2, "a second collect in a long-lived app warns again")
    }

    func testDiffNamesEachChangedKeyInConfigYamlSpelling() {
        let base = SharedConfigPin(
            allowAbsolutePaths: false, outputDir: "", archiveDir: "", dataDir: "",
            retentionEnabled: true, retentionMode: "archive", retentionArchiveDir: "",
            sharedEnabled: "true", historicalDir: "", protectProfile: "", notifyDetail: "full",
            notifyURLHost: "a.example.com", notifyURLHash: "")
        var changed = base
        changed.outputDir = "/Volumes/x"
        changed.retentionMode = "delete"
        changed.retentionArchiveDir = "/Volumes/y"
        changed.notifyURLHost = "b.example.com"
        let drifts = SharedConfigPin.diff(pinned: base, current: changed)
        XCTAssertEqual(drifts.map(\.key.rawValue), [
            "output.output_dir", "retention.mode", "retention.archive_dir", "notify.url",
        ])
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

    func testChangedRetentionArchiveDirReadsAsTheDefaultAndWarnsOnce() throws {
        try writeConfig(retentionArchiveDir: "old-archive")
        _ = check()
        try writeConfig(retentionArchiveDir: "peer-archive")
        let lines = LineBox()
        let result = SharedConfigPin.checkpoint(
            profile: profile, appSupport: appSupport, onLine: { lines.add($0.text) })
        XCTAssertEqual(lines.all, [
            "[warn] shared config changed retention.archive_dir: "
                + "confirm on this Mac (Config Doctor)",
        ])
        let config = try ConfigLoader.load(from: workspace.appendingPathComponent("config.yaml"))
        XCTAssertEqual(config.retention?.resolvedArchiveDir, "peer-archive")
        let safe = SharedConfigPin.effectiveRetention(config.retention, check: result)
        XCTAssertEqual(safe?.resolvedArchiveDir, "")
        let root = SnapshotRetentionService.resolvedArchiveRoot(config: safe, workspace: workspace)
        XCTAssertEqual(root.lastPathComponent, "_archive")

        try confirmAll()
        XCTAssertTrue(check().drifts.isEmpty)
    }

    func testAChangedWebhookHostPortOrURLBlocksTheSend() throws {
        try writeConfig(webhook: "https://hooks.example.com/a")
        _ = check()
        XCTAssertNotNil(sendable())
        for changed in ["https://hooks.example.com/other-path", "https://hooks.example.com:8443/a",
                        "https://collector.attacker.test/a"] {
            try writeConfig(webhook: changed)
            XCTAssertNil(sendable(), changed)
        }
        try writeConfig(webhook: "https://hooks.example.com/a")
        XCTAssertNotNil(sendable())
    }

    func testConfirmRepinsAndPartialConfirmLeavesOtherKeysDrifted() throws {
        try writeConfig()
        _ = check()
        try writeConfig(outputDir: "reports2", retentionMode: "delete",
                        webhook: "https://collector.attacker.test/a")
        XCTAssertEqual(check().drifts.count, 3)

        try SharedConfigPin.confirm(profile: profile, keys: [.outputDir], appSupport: appSupport)
        XCTAssertEqual(check().drifts.map(\.key), [.retentionMode, .notifyURL])

        try confirmAll()
        XCTAssertTrue(check().drifts.isEmpty)
    }

    func testCheckpointLogsOneWarnPerDriftedKeyAndNoPartialMarker() async throws {
        try writeConfig()
        _ = check()
        try writeConfig(retentionMode: "delete", webhook: "https://collector.attacker.test/a")
        let lines = LineBox()
        let appSupport = self.appSupport!
        let profile = self.profile
        await SharedConfigPin.announcingOnce {
            for _ in 0..<2 {
                SharedConfigPin.checkpoint(
                    profile: profile, appSupport: appSupport, onLine: { lines.add($0.text) })
            }
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

    // MARK: - Headless folders

    func testHeadlessChangedOutputDirFallsBackToTheWorkspaceWithOneWarn() async throws {
        try writeConfig(outputDir: outside, allowAbsolute: true)
        _ = check()
        XCTAssertEqual(try WorkspacePaths.outputDir(for: profile).path, outside)

        try writeConfig(outputDir: outside + "-peer", allowAbsolute: true)
        SharedConfigPin.markHeadless()
        let lines = LineBox()
        let appSupport = self.appSupport!
        let profile = self.profile
        await SharedConfigPin.announcingOnce {
            for _ in 0..<2 {
                SharedConfigPin.checkpoint(
                    profile: profile, appSupport: appSupport, onLine: { lines.add($0.text) })
            }
        }
        XCTAssertEqual(lines.all, [
            "[warn] shared config changed output.output_dir: confirm on this Mac (Config Doctor)",
        ])
        let dir = WorkspacePaths.reportsDir(for: profile, onLine: { lines.add($0.text) })
        XCTAssertEqual(dir?.lastPathComponent, WorkspacePaths.generatedReportsDirName)
        XCTAssertEqual(dir?.deletingLastPathComponent().resolvingSymlinksInPath().path,
                       workspace.resolvingSymlinksInPath().path)
        XCTAssertEqual(lines.all.count, 1, "the fallback adds no second warning")
    }

    func testAChangedOptInAndDataDirAreReadAsSafeValues() throws {
        try writeConfig()
        _ = check()
        let body = try String(contentsOf: workspace.appendingPathComponent("config.yaml"),
                              encoding: .utf8)
        try (body + "\njamf_cli:\n  data_dir: \"\(outside!)-data\"\n").replacingOccurrences(
            of: "allow_absolute_paths: false", with: "allow_absolute_paths: true")
            .write(to: workspace.appendingPathComponent("config.yaml"),
                   atomically: true, encoding: .utf8)
        SharedConfigPin.markHeadless()
        let drifted = SharedConfigPin.checkpoint(
            profile: profile, appSupport: appSupport, onLine: nil)
        XCTAssertEqual(drifted.drifts.map(\.key), [.allowAbsolutePaths, .dataDir])
        XCTAssertEqual(try WorkspacePaths.dataDir(for: profile).lastPathComponent, "jamf-cli-data")
    }

    func testTheGUIKeepsReadingConfigYamlAsTyped() throws {
        try writeConfig(outputDir: outside, allowAbsolute: true)
        _ = check()
        try writeConfig(outputDir: outside + "-peer", allowAbsolute: true)
        SharedConfigPin.checkpoint(profile: profile, appSupport: appSupport, onLine: nil)
        XCTAssertEqual(try WorkspacePaths.outputDir(for: profile).path, outside + "-peer")
    }

    func testAnAutomaticGUICollectUsesSafeFoldersOnlyWhileItRuns() async throws {
        try writeConfig(outputDir: outside, allowAbsolute: true)
        _ = check()
        try writeConfig(outputDir: outside + "-peer", allowAbsolute: true)
        let appSupport = self.appSupport!
        let profile = self.profile

        let during = try await SharedConfigPin.unattended(profile: profile) {
            SharedConfigPin.checkpoint(profile: profile, appSupport: appSupport, onLine: nil)
            return try WorkspacePaths.outputDir(for: profile).lastPathComponent
        }
        XCTAssertEqual(during, WorkspacePaths.generatedReportsDirName)
        XCTAssertEqual(try WorkspacePaths.outputDir(for: profile).path, outside + "-peer",
                       "a person's own action reads the typed value again afterwards")
    }

    func testConfirmingEndsTheFallback() throws {
        try writeConfig(outputDir: outside, allowAbsolute: true)
        _ = check()
        try writeConfig(outputDir: outside + "-peer", allowAbsolute: true)
        SharedConfigPin.markHeadless()
        SharedConfigPin.checkpoint(profile: profile, appSupport: appSupport, onLine: nil)
        XCTAssertNotEqual(try WorkspacePaths.outputDir(for: profile).path, outside + "-peer")
        try confirmAll()
        XCTAssertEqual(try WorkspacePaths.outputDir(for: profile).path, outside + "-peer")
    }

    // MARK: - Retention sweep and collect

    func testSweepArchivesRatherThanDeletesAfterTheModeChanges() throws {
        try writeConfig(retentionMode: "archive")
        _ = check()
        try writeConfig(retentionMode: "delete")
        let dir = workspace.appendingPathComponent("jamf-cli-data/computers", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let old = dir.appendingPathComponent("computers_20250101T000000.json")
        try "[]".write(to: old, atomically: true, encoding: .utf8)
        try fileManager.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -400 * 86_400)], ofItemAtPath: old.path)

        XCTAssertEqual(SnapshotRetentionService.sweepIfDue(profile: profile), 1)

        XCTAssertFalse(fileManager.fileExists(atPath: old.path))
        XCTAssertTrue(fileManager.fileExists(atPath: workspace.appendingPathComponent(
            "_archive/jamf-cli-data/computers/\(old.lastPathComponent)").path))
    }

    func testEveryCollectRouteLogsTheDriftFirst() async throws {
        for school in [false, true] {
            try writeConfig()
            try? fileManager.removeItem(
                at: SharedConfigPin.storeURL(profile: profile, appSupport: appSupport))
            _ = check()
            try writeConfig(retentionMode: school ? "archive" : "delete",
                            retentionArchiveDir: school ? "peer" : "")
            if school {
                let url = workspace.appendingPathComponent("config.yaml")
                try (String(contentsOf: url, encoding: .utf8) + "\nschool_cli:\n  enabled: true\n")
                    .write(to: url, atomically: true, encoding: .utf8)
            }
            let config = try ConfigLoader.load(from: workspace.appendingPathComponent("config.yaml"))
            let lines = LineBox()
            try await CollectRouter.run(
                profile: profile, config: config,
                proCollect: { _, _, _, _, _, _ in .collected },
                schoolCollect: { _, _, _ in },
                onLine: { lines.add($0.text) })
            XCTAssertEqual(
                lines.all.first,
                "[warn] shared config changed "
                    + (school ? "retention.archive_dir" : "retention.mode")
                    + ": confirm on this Mac (Config Doctor)",
                school ? "Jamf School route" : "Jamf Pro route")
        }
    }

    // MARK: - Config Doctor and confirming

    func testDoctorRowIsAWarningWithConfirmAndShowsTheHostOnly() throws {
        try writeConfig(retentionMode: "archive", webhook: "https://hooks.example.com/a")
        _ = check()
        XCTAssertTrue(ConfigDoctorService.sharedConfigRows(
            profile: profile, appSupport: appSupport).isEmpty)

        try writeConfig(retentionMode: "delete",
                        webhook: "https://collector.attacker.test/hook/secret-token")
        let rows = ConfigDoctorService.sharedConfigRows(profile: profile, appSupport: appSupport)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(row.severity, .warn)
        XCTAssertEqual(row.action, .confirmSharedConfig(check().drifts))
        XCTAssertTrue(row.detail.contains("retention.mode: pinned \"archive\", now \"delete\""))
        XCTAssertTrue(row.detail.contains("hooks.example.com"))
        XCTAssertTrue(row.detail.contains("collector.attacker.test"))
        XCTAssertFalse(row.detail.contains("secret-token"))

        try confirmAll()
        XCTAssertTrue(ConfigDoctorService.sharedConfigRows(
            profile: profile, appSupport: appSupport).isEmpty)
    }

    func testConfirmOnALocalWorkspaceWritesNoPin() throws {
        try writeConfig(shared: false)
        try confirmAll()
        XCTAssertNil(SharedConfigPin.load(profile: profile, appSupport: appSupport))
    }

    func testSavingTheNotificationSettingsConfirmsOnlyTheWebhook() throws {
        try writeConfig()
        _ = check()
        try writeConfig(retentionMode: "delete", webhook: "https://collector.example.org/a")
        try NotifyConfigWriter.save(
            enabled: true, provider: "teams", url: "https://hooks.example.com/mine",
            detail: "full", profile: profile)
        XCTAssertEqual(check().drifts.map(\.key), [.retentionMode])
    }

    func testTogglingNotificationsWithTheURLAsItWasDoesNotConfirmAPeersURL() throws {
        try writeConfig()
        _ = check()
        try writeConfig(webhook: "https://collector.example.org/a")
        try NotifyConfigWriter.save(
            enabled: false, provider: "teams", url: "https://collector.example.org/a",
            detail: "minimal", profile: profile)
        XCTAssertEqual(check().drifts.map(\.key), [.notifyURL])
    }

    func testASaveConfirmsAFolderOnlyWhenItChangedIt() {
        let loaded = (outputDir: "/Volumes/a", archiveDir: "")
        XCTAssertEqual(SharedConfigPin.changedFolderKeys(
            before: loaded, after: (outputDir: "/Volumes/a ", archiveDir: "")), [])
        XCTAssertEqual(SharedConfigPin.changedFolderKeys(
            before: loaded, after: (outputDir: "/Volumes/a", archiveDir: "old")), [.archiveDir])
        XCTAssertEqual(SharedConfigPin.changedFolderKeys(
            before: loaded, after: (outputDir: "/Volumes/b", archiveDir: "old")),
            [.outputDir, .archiveDir])
        XCTAssertEqual(SharedConfigPin.changedFolderKeys(
            before: nil, after: (outputDir: "/Volumes/b", archiveDir: "")), [])
    }
}
