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
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        try? fileManager.removeItem(at: root)
    }

    private func writeConfig(
        shared: Bool = true, outputDir: String = "", allowAbsolute: Bool = false,
        retentionMode: String = "archive", retentionArchiveDir: String = "",
        webhook: String = "https://hooks.example.com/a", detail: String = "full",
        historicalDir: String = "snapshots", protectProfile: String = "protect-a",
        heartbeat: Bool? = nil, protectBackup: String? = nil
    ) throws {
        let beat = heartbeat.map { "\n  heartbeat: \($0)" } ?? ""
        let backup = protectBackup.map { "\n  backup_on_synced_storage: \($0)" } ?? ""
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
          detail: \(detail)\(beat)
        charts:
          historical_csv_dir: "\(historicalDir)"
        protect:
          enabled: true
          profile: "\(protectProfile)"\(backup)
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

    func testASyncMarkerAboveTheWorkspacePinsIt() throws {
        try writeConfig(shared: false)
        XCTAssertNil(SharedConfigPin.load(profile: profile, appSupport: appSupport))
        _ = check()
        XCTAssertNil(SharedConfigPin.load(profile: profile, appSupport: appSupport))

        try fileManager.createDirectory(
            at: root.appendingPathComponent(".stfolder"), withIntermediateDirectories: true)
        _ = check()
        XCTAssertNotNil(SharedConfigPin.load(profile: profile, appSupport: appSupport))
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
            sharedEnabled: true, onSharedStorage: false, pinExists: false))
        XCTAssertTrue(SharedConfigPin.appliesTo(
            sharedEnabled: false, onSharedStorage: true, pinExists: false))
        XCTAssertTrue(SharedConfigPin.appliesTo(
            sharedEnabled: false, onSharedStorage: false, pinExists: true))
        XCTAssertFalse(SharedConfigPin.appliesTo(
            sharedEnabled: false, onSharedStorage: false, pinExists: false))
        XCTAssertFalse(SharedConfigPin.appliesTo(
            sharedEnabled: nil, onSharedStorage: false, pinExists: false))
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

    func testAPinWrittenBeforeAKeyWasAddedPinsThatKeyAtItsFirstSight() throws {
        try writeConfig(historicalDir: outside, protectProfile: "protect-a")
        _ = check()
        let store = SharedConfigPin.storeURL(profile: profile, appSupport: appSupport)
        let old = #"{"allowAbsolutePaths":false,"outputDir":"","archiveDir":"","dataDir":"","#
            + #""retentionEnabled":true,"retentionMode":"archive","#
            + #""notifyURLHost":"hooks.example.com"}"#
        try old.write(to: store, atomically: true, encoding: .utf8)
        guard case .pin(let pin) = SharedConfigPin.read(profile: profile, appSupport: appSupport)
        else { return XCTFail("an older pin should still decode") }
        XCTAssertEqual(pin.notifyURLHost, "hooks.example.com")
        XCTAssertFalse(pin.pinnedKeys.contains("protect.profile"))
        XCTAssertFalse(pin.pinnedKeys.contains("notify.url"), "it has no URL hash")

        // The keys it lacks are pinned now, not read as changed; the webhook keeps sending, and
        // an absolute folder that is new to the pin waits for a Confirm.
        let result = check()
        XCTAssertEqual(result.drifts.map(\.key), [.historicalDir])
        XCTAssertEqual(result.drifts.first?.pinned, SharedConfigPin.firstSightNote)
        XCTAssertNotNil(sendable())
        guard case .pin(let upgraded) = SharedConfigPin.read(
            profile: profile, appSupport: appSupport) else { return XCTFail("pin missing") }
        XCTAssertEqual(Set(upgraded.pinnedKeys), Set(SharedConfigPin.Key.allCases.map(\.rawValue)))
        XCTAssertEqual(upgraded.protectProfile, "protect-a")
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
        XCTAssertThrowsError(try SharedConfigPin.confirm(
            profile: profile, drifts: shown, appSupport: appSupport))
        XCTAssertEqual(check().drifts.map(\.key), [.notifyURL],
                       "the retention row no longer matched, the webhook was never shown")
        guard case .pin(let pin) = SharedConfigPin.read(profile: profile, appSupport: appSupport)
        else { return XCTFail("pin missing") }
        XCTAssertEqual(pin.retentionMode, "archive")
        XCTAssertEqual(pin.notifyURLHost, "hooks.example.com")
    }

    func testConfirmComparesTheFullWebhookHashNotTheShortFingerprint() throws {
        try writeConfig(webhook: "https://hooks.example.com/a")
        _ = check()
        try writeConfig(webhook: "https://collector.attacker.test/a")
        let shown = try XCTUnwrap(check().drifts.first)
        XCTAssertTrue(shown.current.contains("URL fingerprint"))
        XCTAssertEqual(shown.currentToken.split(separator: " ").last?.count, 64)

        // A drift whose short form matches but whose full hash does not is not confirmed.
        let forged = SharedConfigPin.Drift(
            key: .notifyURL, pinned: shown.pinned, current: shown.current,
            currentToken: shown.currentToken + "0")
        XCTAssertThrowsError(try SharedConfigPin.confirm(
            profile: profile, drifts: [forged], appSupport: appSupport))
        XCTAssertEqual(check().drifts.map(\.key), [.notifyURL])
        try SharedConfigPin.confirm(profile: profile, drifts: [shown], appSupport: appSupport)
        XCTAssertTrue(check().drifts.isEmpty)
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

    @MainActor
    func testConnectingProtectOnThisMacConfirmsTheProfileItWrote() throws {
        try writeConfig(protectProfile: "protect-a")
        _ = check()
        let flow = OnboardingFlow()
        try flow.writeProtectConfig(profileSlug: profile, protectProfileName: "protect-b")
        XCTAssertTrue(check().drifts.isEmpty, "\(check().drifts)")
        XCTAssertTrue(SharedConfigPin.protectAllowed(profile: profile, appSupport: appSupport))
        XCTAssertEqual(SharedConfigPin.load(profile: profile, appSupport: appSupport)?
            .protectProfile, "protect-b")
    }

    @MainActor
    func testConnectingTheProfileAPeerAlsoWroteConfirmsOnlyThatKey() throws {
        try writeConfig(protectProfile: "protect-a")
        _ = check()
        try writeConfig(retentionMode: "delete", protectProfile: "peers")
        let flow = OnboardingFlow()
        // The operator typed the same name here, so it is theirs; the peer's other edit is not.
        try flow.writeProtectConfig(profileSlug: profile, protectProfileName: "peers")
        XCTAssertEqual(check().drifts.map(\.key), [.retentionMode])
    }

    func testFirstSightKeepsAnAbsoluteFolderAndDeleteUnconfirmedUntilOneConfirm() throws {
        try writeConfig(outputDir: outside, allowAbsolute: true, retentionMode: "delete")
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
        XCTAssertTrue(rows[0].detail.contains("pinned: (first seen, not confirmed)"))

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

    func testAWrittenConfigConfirmsExactlyTheKeysItSets() throws {
        XCTAssertEqual(SharedConfigPin.keysSet(inYAML: """
        jamf_cli:
          data_dir: "jamf-cli-data"
        output:
          output_dir: "Generated Reports"
        retention:
          mode: delete
        """), [.dataDir, .outputDir, .retentionMode])
        XCTAssertEqual(SharedConfigPin.keysSet(inYAML: "thresholds:\n  stale_device_days: 30\n"),
                       [])

        // Onboarding on a Mac joining a shared folder: the written file sets the two folders.
        try writeConfig(outputDir: outside, allowAbsolute: true, retentionMode: "archive")
        _ = check()
        try ScaffoldService.writeMinimalConfig(
            to: workspace.appendingPathComponent("config.yaml"), profile: profile)
        let before = Set(check().drifts.map(\.key))
        XCTAssertTrue(before.contains(.outputDir))
        SharedConfigPin.confirmWrittenConfig(
            at: workspace.appendingPathComponent("config.yaml"), profile: profile,
            appSupport: appSupport)
        let after = Set(check().drifts.map(\.key))
        XCTAssertFalse(after.contains(.outputDir))
        XCTAssertFalse(after.contains(.dataDir))
        XCTAssertEqual(after, before.subtracting([.outputDir, .dataDir]),
                       "keys the write did not set stay as they were")
        XCTAssertFalse(after.isEmpty, "retention, webhook and Protect are not accepted")
    }

    func testTheProfileOfAWorkspaceConfigPath() {
        let url = ProfileService.workspaceURL(for: profile)!
            .appendingPathComponent("config.yaml")
        XCTAssertEqual(SharedConfigPin.profile(forConfigAt: url), profile)
        XCTAssertNil(SharedConfigPin.profile(forConfigAt: root.appendingPathComponent("config.yaml")))
        XCTAssertNil(SharedConfigPin.profile(
            forConfigAt: url.deletingLastPathComponent().appendingPathComponent("other.yaml")))
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

    func testANonLocalVolumeCountsAsSharedForCoordination() {
        XCTAssertFalse(SharedWorkspace.isEffectivelyShared(
            workspace: workspace, config: nil, volumeIsLocal: { _ in true }))
        XCTAssertTrue(SharedWorkspace.isEffectivelyShared(
            workspace: workspace, config: nil, volumeIsLocal: { _ in false }))
    }

    func testAnICloudDesktopAndDocumentsWorkspaceIsPinnedAndCoordinated() throws {
        try writeConfig(shared: false, outputDir: outside, allowAbsolute: true)
        let local = CloudStorage.SyncProbe(
            fileProviderDomain: { _ in nil }, isUbiquitous: { _ in false })
        XCTAssertNil(SharedConfigPin.check(
            profile: profile, appSupport: appSupport, syncProbe: local).pinned)
        // First sight on synced storage: the absolute output folder waits for a Confirm.
        let synced = SharedConfigPin.check(
            profile: profile, appSupport: appSupport, syncProbe: .iCloudEverywhere)
        XCTAssertEqual(synced.drifts.map(\.key), [.outputDir])

        XCTAssertTrue(SharedWorkspace.isEffectivelyShared(
            workspace: workspace, config: nil, volumeIsLocal: { _ in true },
            syncProbe: .iCloudEverywhere))
    }

    // MARK: - Headless folders

    func testChangedOutputDirFallsBackToTheWorkspaceWithOneWarn() async throws {
        try writeConfig(outputDir: outside, allowAbsolute: true)
        _ = check()
        try confirmAll()
        XCTAssertEqual(try WorkspacePaths.outputDir(for: profile).path, outside)

        try writeConfig(outputDir: outside + "-peer", allowAbsolute: true)
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
        let drifted = SharedConfigPin.checkpoint(
            profile: profile, appSupport: appSupport, onLine: nil)
        XCTAssertEqual(drifted.drifts.map(\.key), [.allowAbsolutePaths, .dataDir])
        XCTAssertEqual(try WorkspacePaths.dataDir(for: profile).lastPathComponent, "jamf-cli-data")
    }

    func testAChangedFolderReadsAsTheSafeValueForAPersonsOwnActionWithNoCheckpoint() throws {
        try writeConfig(outputDir: outside, allowAbsolute: true)
        _ = check()
        try confirmAll()
        XCTAssertEqual(try WorkspacePaths.outputDir(for: profile).path, outside)
        try writeConfig(outputDir: outside + "-peer", allowAbsolute: true)
        XCTAssertEqual(try WorkspacePaths.outputDir(for: profile).lastPathComponent,
                       WorkspacePaths.generatedReportsDirName)
    }

    func testASymlinkedProfileFolderStillReadsTheSafeFolder() throws {
        let real = root.appendingPathComponent("real-folder", isDirectory: true)
        try fileManager.moveItem(at: workspace, to: real)
        try fileManager.createSymbolicLink(at: workspace, withDestinationURL: real)
        try writeConfig(outputDir: outside, allowAbsolute: true)
        _ = check()
        try confirmAll()
        XCTAssertEqual(try WorkspacePaths.outputDir(for: profile).path, outside)
        try writeConfig(outputDir: outside + "-peer", allowAbsolute: true)
        XCTAssertEqual(try WorkspacePaths.outputDir(for: profile).lastPathComponent,
                       WorkspacePaths.generatedReportsDirName)
    }

    func testAnInPlaceEditThatKeepsSizeAndTimeStillReadsAsDrift() throws {
        try writeConfig(outputDir: outside + "-aaaa", allowAbsolute: true)
        _ = check()
        try confirmAll()
        let config = workspace.appendingPathComponent("config.yaml")
        XCTAssertEqual(try WorkspacePaths.outputDir(for: profile).path, outside + "-aaaa")
        let stamp = try fileManager.attributesOfItem(atPath: config.path)[.modificationDate]
        let text = try String(contentsOf: config, encoding: .utf8)
        let handle = try FileHandle(forWritingTo: config)
        let edited = text.replacingOccurrences(of: "-aaaa", with: "-bbbb")
        try handle.write(contentsOf: Data(edited.utf8))
        try handle.close()
        try fileManager.setAttributes([.modificationDate: stamp as Any], ofItemAtPath: config.path)
        XCTAssertEqual(try WorkspacePaths.outputDir(for: profile).lastPathComponent,
                       WorkspacePaths.generatedReportsDirName)
    }

    func testAnExportSaysWhenThePinReplacedItsFolder() throws {
        try writeConfig(outputDir: outside, allowAbsolute: true)
        _ = check()
        try confirmAll()
        let confirmed = try WorkspacePaths.outputDir(for: profile)
        XCTAssertNil(SharedConfigPin.outputFolderNote(profile: profile, folder: confirmed))
        try writeConfig(outputDir: outside + "-peer", allowAbsolute: true)
        let fallback = try WorkspacePaths.outputDir(for: profile)
        let note = try XCTUnwrap(
            SharedConfigPin.outputFolderNote(profile: profile, folder: fallback))
        XCTAssertTrue(note.contains("output.output_dir"), note)
        XCTAssertTrue(note.contains("not confirmed on this Mac"), note)
    }

    func testConfirmingAValueThatChangedSinceItWasShownSaysSo() throws {
        try writeConfig(outputDir: outside, allowAbsolute: true)
        _ = check()
        try confirmAll()
        try writeConfig(outputDir: outside + "-shown", allowAbsolute: true)
        let shown = check().drifts
        try writeConfig(outputDir: outside + "-later", allowAbsolute: true)
        XCTAssertThrowsError(try SharedConfigPin.confirm(
            profile: profile, drifts: shown, appSupport: appSupport)) { error in
            XCTAssertEqual(error as? SharedConfigPin.ConfirmError, .changedSinceShown)
        }
        XCTAssertTrue(check().isDrifted(.outputDir), "nothing was pinned")
    }

    func testAValueWithHiddenCharactersIsLabelledAndCannotBeConfirmedFromTheRow() throws {
        try writeConfig(outputDir: outside, allowAbsolute: true)
        _ = check()
        try confirmAll()
        try writeConfig(outputDir: outside + "\u{200B}-peer", allowAbsolute: true)
        let row = try XCTUnwrap(ConfigDoctorService.sharedConfigRows(
            profile: profile, appSupport: appSupport).first)
        let item = try XCTUnwrap(
            row.items.first { $0.id == SharedConfigPin.Key.outputDir.rawValue })
        XCTAssertTrue(item.text.contains("contains hidden characters"), item.text)
        XCTAssertNil(item.action)
    }

    func testTheSafeFolderHoldsUntilConfirmedWhateverRanBefore() throws {
        try writeConfig(outputDir: outside, allowAbsolute: true)
        _ = check()
        try confirmAll()
        try writeConfig(outputDir: outside + "-peer", allowAbsolute: true)
        for _ in 0..<3 {
            XCTAssertEqual(try WorkspacePaths.outputDir(for: profile).lastPathComponent,
                           WorkspacePaths.generatedReportsDirName)
            SharedConfigPin.checkpoint(profile: profile, appSupport: appSupport, onLine: nil)
        }
        try confirmAll()
        XCTAssertEqual(try WorkspacePaths.outputDir(for: profile).path, outside + "-peer")
    }

    func testALocalWorkspaceKeepsReadingConfigYamlAsTyped() throws {
        try writeConfig(shared: false, outputDir: outside, allowAbsolute: true)
        try writeConfig(shared: false, outputDir: outside + "-other", allowAbsolute: true)
        XCTAssertEqual(try WorkspacePaths.outputDir(for: profile).path, outside + "-other")
        XCTAssertNil(SharedConfigPin.load(profile: profile, appSupport: appSupport))
    }

    func testManyReadsNeverRewriteThePin() throws {
        try writeConfig(outputDir: outside, allowAbsolute: true)
        _ = check()
        try confirmAll()
        let pin = SharedConfigPin.storeURL(profile: profile, appSupport: appSupport)
        let before = try Data(contentsOf: pin)
        for _ in 0..<50 { _ = try WorkspacePaths.outputDir(for: profile) }
        XCTAssertEqual(try Data(contentsOf: pin), before, "a read never rewrites the pin")
    }

    func testAReadBeforeTheFirstCheckpointDoesNotWriteThePin() throws {
        try writeConfig(outputDir: outside, allowAbsolute: true)
        XCTAssertEqual(try WorkspacePaths.outputDir(for: profile).lastPathComponent,
                       WorkspacePaths.generatedReportsDirName,
                       "an absolute folder is unconfirmed at first sight")
        XCTAssertNil(SharedConfigPin.load(profile: profile, appSupport: appSupport))
    }

    @MainActor
    func testGUIGenerateLogsTheDriftOnceAndFallsBackToTheWorkspace() async throws {
        try writeConfig(outputDir: outside, allowAbsolute: true)
        _ = check()
        try confirmAll()
        try writeConfig(outputDir: outside + "-peer", allowAbsolute: true)
        let lines = LineBox()
        _ = await CLIBridge().generateAll(
            types: [], outputDir: nil, profile: profile, onLine: { lines.add($0.text) })
        let dir = WorkspacePaths.reportsDir(for: profile, onLine: { lines.add($0.text) })
        XCTAssertEqual(lines.all, [
            "[warn] shared config changed output.output_dir: confirm on this Mac (Config Doctor)",
        ])
        XCTAssertEqual(dir?.lastPathComponent, WorkspacePaths.generatedReportsDirName)
    }

    func testARefusedFolderNamesTheUnconfirmedOptInNotAMissingOne() throws {
        try writeConfig(outputDir: outside, allowAbsolute: true)
        _ = check()
        try confirmAll()
        try writeConfig(outputDir: outside, allowAbsolute: false)
        let lines = LineBox()
        let dir = WorkspacePaths.reportsDir(for: profile, onLine: { lines.add($0.text) })
        XCTAssertEqual(dir?.lastPathComponent, WorkspacePaths.generatedReportsDirName)
        let line = try XCTUnwrap(lines.all.first)
        XCTAssertTrue(line.contains("changed in the shared config.yaml, not confirmed on this Mac"),
                      line)
        XCTAssertFalse(line.contains("is not true"), line)
    }

    func testConfirmingEndsTheFallback() throws {
        try writeConfig(outputDir: outside, allowAbsolute: true)
        _ = check()
        try writeConfig(outputDir: outside + "-peer", allowAbsolute: true)
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
                schoolCollect: { _, _, _, _, _ in },
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

    func testDoctorRowIsAWarningWithAConfirmPerKeyAndShowsTheHostOnly() throws {
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
        XCTAssertNil(row.action, "a readable pin confirms one key at a time")
        let drifts = check().drifts
        XCTAssertEqual(row.items.map(\.action), drifts.map { .confirmSharedConfig([$0]) })
        XCTAssertTrue(row.detail.contains(
            "retention.mode\n  pinned: \"archive\"\n  now:    \"delete\""))
        XCTAssertTrue(row.detail.contains("hooks.example.com"))
        XCTAssertTrue(row.detail.contains("collector.attacker.test"))
        XCTAssertFalse(row.detail.contains("secret-token"))

        try confirmAll()
        XCTAssertTrue(ConfigDoctorService.sharedConfigRows(
            profile: profile, appSupport: appSupport).isEmpty)
    }

    func testConfirmingOneKeyThroughTheDoctorActionLeavesTheOthersDrifted() throws {
        try writeConfig()
        _ = check()
        try writeConfig(retentionMode: "delete", webhook: "https://collector.example.org/a")
        let row = try XCTUnwrap(ConfigDoctorService.sharedConfigRows(
            profile: profile, appSupport: appSupport).first)
        let item = try XCTUnwrap(row.items.first { $0.id == "retention.mode" })
        guard case .confirmSharedConfig(let drifts)? = item.action else {
            return XCTFail("no action")
        }
        try SharedConfigPin.confirm(profile: profile, drifts: drifts, appSupport: appSupport)
        XCTAssertEqual(check().drifts.map(\.key), [.notifyURL])
    }

    func testAnUnreadablePinOffersOneConfirmAllAndNoPerKeyButton() throws {
        try writeConfig()
        _ = check()
        let store = SharedConfigPin.storeURL(profile: profile, appSupport: appSupport)
        try "not json".write(to: store, atomically: true, encoding: .utf8)
        let row = try XCTUnwrap(ConfigDoctorService.sharedConfigRows(
            profile: profile, appSupport: appSupport).first)
        XCTAssertEqual(row.action, .confirmSharedConfig(check().drifts))
        XCTAssertTrue(row.items.allSatisfy { $0.action == nil })
        XCTAssertEqual(row.items.count, SharedConfigPin.Key.allCases.count)
        XCTAssertTrue(row.detail.contains("pinned: (pin unreadable)"))
        let one = try XCTUnwrap(check().drifts.first)
        XCTAssertThrowsError(try SharedConfigPin.confirm(
            profile: profile, drifts: [one], appSupport: appSupport))
    }

    private func driftText(_ key: String) throws -> String {
        let row = try XCTUnwrap(ConfigDoctorService.sharedConfigRows(
            profile: profile, appSupport: appSupport).first)
        return try XCTUnwrap(row.items.first { $0.id == key }).text
    }

    func testAPaddedPathShowsWholeAndWhereItLands() throws {
        let padded = "/" + String(repeating: "a", count: 59) + "/../../Volumes/x"
        try writeConfig(outputDir: padded, allowAbsolute: true)
        let text = try driftText("output.output_dir")
        XCTAssertTrue(text.contains("now:    \"\(padded)\""), "shown whole, not cut at 60")
        XCTAssertTrue(text.contains("lands:  /Volumes/x (outside this workspace)"), text)
        XCTAssertTrue(text.contains("pinned: \(SharedConfigPin.firstSightNote)"), text)
    }

    func testARelativeFolderLandsInsideTheWorkspaceAndASymlinkedParentResolves() throws {
        try writeConfig(outputDir: "reports/2026")
        _ = check()
        let target = root.appendingPathComponent("elsewhere", isDirectory: true)
        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        let link = workspace.appendingPathComponent("linked")
        try fileManager.createSymbolicLink(at: link, withDestinationURL: target)
        try writeConfig(outputDir: "other/dir")
        let inside = try driftText("output.output_dir")
        let home = workspace.resolvingSymlinksInPath().path
        XCTAssertTrue(inside.contains("lands:  \(home)/other/dir (inside this workspace)"), inside)

        try writeConfig(outputDir: "linked/new-sub")
        let escaped = try driftText("output.output_dir")
        let real = target.resolvingSymlinksInPath().path
        XCTAssertTrue(escaped.contains("lands:  \(real)/new-sub (outside this workspace)"), escaped)
    }

    func testAMissingTailResolvesThroughItsDeepestExistingAncestor() throws {
        let realParent = root.appendingPathComponent("real-parent", isDirectory: true)
        try fileManager.createDirectory(at: realParent, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias")
        try fileManager.createSymbolicLink(at: alias, withDestinationURL: realParent)
        try writeConfig(outputDir: alias.path + "/not/yet/made", allowAbsolute: true)
        let text = try driftText("output.output_dir")
        let real = realParent.resolvingSymlinksInPath().path
        XCTAssertTrue(text.contains("lands:  \(real)/not/yet/made (outside this workspace)"), text)
    }

    func testAValueThatLooksLikeANoteIsShownAsAValueWithControlCharactersRemoved() throws {
        try writeConfig(outputDir: "a")
        _ = check()
        try writeConfig(outputDir: "(pin unreadable)\u{202E}x\u{1B}[31my")
        let text = try driftText("output.output_dir")
        XCTAssertTrue(text.contains("now:    \"(pin unreadable)x[31my\""), text)
        XCTAssertFalse(text.contains("\u{1B}"))
        XCTAssertFalse(text.contains("\u{202E}"))
        XCTAssertTrue(text.contains("pinned: \"a\""), text)
    }

    func testAValueOverTheLimitIsCutWithANote() throws {
        try writeConfig(outputDir: "a")
        _ = check()
        try writeConfig(outputDir: String(repeating: "b", count: 1500))
        let text = try driftText("output.output_dir")
        let now = try XCTUnwrap(text.components(separatedBy: "\n").first { $0.hasPrefix("  now:") })
        XCTAssertTrue(now.hasSuffix(String(repeating: "b", count: 1024) + "\" (truncated)"), "")
        XCTAssertFalse(now.contains(String(repeating: "b", count: 1025)))
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

    func testAPeerSwitchingTheHeartbeatDoesNotChangeWhatThisMacSends() throws {
        try writeConfig()
        _ = check()
        try writeConfig(heartbeat: true)
        XCTAssertEqual(check().drifts.map(\.key), [.notifyHeartbeat])
        XCTAssertFalse(try XCTUnwrap(sendable()).sendsHeartbeat)
        try confirmAll()
        XCTAssertTrue(check().drifts.isEmpty)
        XCTAssertTrue(try XCTUnwrap(sendable()).sendsHeartbeat)
        try writeConfig(heartbeat: false)
        XCTAssertTrue(try XCTUnwrap(sendable()).sendsHeartbeat, "the pinned setting stands")
    }

    func testAPinWrittenBeforeTheHeartbeatKeyPinsItAtFirstSight() throws {
        try writeConfig(heartbeat: true)
        _ = check()
        let url = SharedConfigPin.storeURL(profile: profile, appSupport: appSupport)
        var pin = try XCTUnwrap(SharedConfigPin.load(profile: profile, appSupport: appSupport))
        pin.notifyHeartbeat = false
        pin.pinnedKeys.removeAll { $0 == SharedConfigPin.Key.notifyHeartbeat.rawValue }
        try JSONEncoder().encode(pin).write(to: url)
        XCTAssertTrue(check().drifts.isEmpty)
        XCTAssertTrue(try XCTUnwrap(sendable()).sendsHeartbeat)
    }

    func testASaveConfirmsTheHeartbeatOnlyWhenItChangedIt() {
        XCTAssertEqual(SharedConfigPin.changedNotifyKeys(
            previousURL: "", newURL: "", previousDetail: nil, newDetail: "full",
            previousHeartbeat: false, newHeartbeat: true), [.notifyHeartbeat])
        XCTAssertEqual(SharedConfigPin.changedNotifyKeys(
            previousURL: "", newURL: "", previousDetail: nil, newDetail: "full",
            previousHeartbeat: true, newHeartbeat: true), [])
        XCTAssertEqual(SharedConfigPin.changedNotifyKeys(
            previousURL: "", newURL: "", previousDetail: nil, newDetail: "full"), [])
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

    // MARK: - protect.backup_on_synced_storage

    /// What a backup on this workspace may do with Protect, as the backup path asks it.
    private func protectOnSynced() throws -> Bool {
        let config = try ConfigLoader.load(from: workspace.appendingPathComponent("config.yaml"))
        return SharedConfigPin.protectBackupOnSyncedStorage(
            config.protect?.backsUpOnSyncedStorage ?? false,
            profile: profile, appSupport: appSupport)
    }

    func testProtectBackupsOnSyncedStorageTurnedOnAtFirstSightWaitForAConfirm() throws {
        try writeConfig(protectBackup: "true")
        XCTAssertEqual(check().drifts.map(\.key), [.protectBackupOnSyncedStorage])
        XCTAssertTrue(check().drifts[0].pinnedIsNote)
        XCTAssertFalse(try protectOnSynced(), "a value a peer may have written stays off")
        try confirmAll()
        XCTAssertTrue(check().drifts.isEmpty)
        XCTAssertTrue(try protectOnSynced())
    }

    func testAPeerTurningProtectBackupsOnIsDriftAndStaysOff() throws {
        try writeConfig()
        _ = check()
        XCTAssertFalse(try protectOnSynced())
        try writeConfig(protectBackup: "true")
        XCTAssertEqual(check().drifts.map(\.key), [.protectBackupOnSyncedStorage])
        XCTAssertFalse(try protectOnSynced())
        let config = try ConfigLoader.load(from: workspace.appendingPathComponent("config.yaml"))
        guard case .skip = ProtectBackup.plan(
            config: config, workspaceProfile: profile, pinAllows: { true },
            sharedStorage: { "in a shared workspace" },
            syncedStorageAllowed: { (try? self.protectOnSynced()) ?? true })
        else { return XCTFail("a drifted opt-in must not run the Protect backup") }
    }

    func testTurningAConfirmedOptInOffAppliesAtOnceAndBackOnNeedsAConfirm() throws {
        try writeConfig(protectBackup: "true")
        try confirmAll()
        XCTAssertTrue(try protectOnSynced())
        try writeConfig(protectBackup: "false")
        XCTAssertFalse(try protectOnSynced(), "a change to false is honoured without a confirm")
        XCTAssertTrue(check().drifts.isEmpty, "the safe value is pinned, not shown as drift")
        XCTAssertEqual(
            SharedConfigPin.load(profile: profile, appSupport: appSupport)?
                .protectBackupOnSyncedStorage, false)
        try writeConfig(protectBackup: "true")
        XCTAssertFalse(try protectOnSynced(), "a peer's later true waits for a confirm")
        XCTAssertEqual(check().drifts.map(\.key), [.protectBackupOnSyncedStorage])
        try confirmAll()
        XCTAssertTrue(try protectOnSynced())
        try writeConfig(protectBackup: "\"maybe\"")
        XCTAssertFalse(try protectOnSynced(), "a non-boolean reads as false")
        XCTAssertTrue(check().drifts.isEmpty)
        try writeConfig(protectBackup: "true")
        XCTAssertFalse(try protectOnSynced(), "true after a non-boolean waits for a confirm")
    }

    func testAnUnconfirmedOptInTurnedOffIsNoLongerWaiting() throws {
        try writeConfig(protectBackup: "true")
        XCTAssertEqual(check().drifts.map(\.key), [.protectBackupOnSyncedStorage])
        try writeConfig(protectBackup: "false")
        XCTAssertTrue(check().drifts.isEmpty)
        try writeConfig(protectBackup: "true")
        XCTAssertEqual(check().drifts.map(\.key), [.protectBackupOnSyncedStorage])
        XCTAssertFalse(try protectOnSynced())
    }

    func testTurningTheSwitchOnOverAnUnconfirmedTrueConfirmsIt() throws {
        try writeConfig(protectBackup: "true")
        _ = check()
        XCTAssertFalse(try protectOnSynced())
        try BackupChoiceConfigWriter.save(
            .protect, on: true, profile: profile, appSupport: appSupport)
        XCTAssertTrue(try protectOnSynced())
    }

    func testTheBackupsSwitchWritesTheKeyCopiesTheFileAndConfirmsOnThisMac() throws {
        try writeConfig()
        let url = workspace.appendingPathComponent("config.yaml")
        try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(
                of: "protect:\n", with: "protect:\n  # set by the security team\n")
            .write(to: url, atomically: true, encoding: .utf8)
        _ = check()
        XCTAssertFalse(try protectOnSynced())

        let report = try BackupChoiceConfigWriter.save(
            .protect, on: true, profile: profile, appSupport: appSupport)
        XCTAssertTrue(try protectOnSynced(), "the switch confirms the value it wrote")
        XCTAssertTrue(check().drifts.isEmpty)
        let backup = try XCTUnwrap(report.backupName)
        XCTAssertTrue(backup.hasPrefix("config.yaml.bak-"), backup)
        XCTAssertTrue(fileManager.fileExists(
            atPath: workspace.appendingPathComponent(backup).path))
        let saved = try ConfigLoader.load(from: url)
        XCTAssertEqual(saved.protect?.resolvedProfile, "protect-a", "other protect keys stay")
        XCTAssertTrue(saved.protect?.isEnabled ?? false)

        try BackupChoiceConfigWriter.save(
            .protect, on: false, profile: profile, appSupport: appSupport)
        XCTAssertEqual(try ConfigLoader.load(from: url).protect?.backupOnSyncedStorage, false)
        XCTAssertFalse(try protectOnSynced())
        XCTAssertTrue(check().drifts.isEmpty)
    }

    func testTheSyncedStorageChoiceAndItsDoctorRowFollowThePin() throws {
        try writeConfig()
        let url = workspace.appendingPathComponent("config.yaml")
        let load = { try ConfigLoader.load(from: url) }
        let choice = try XCTUnwrap(ProtectBackup.syncedStorageChoice(
            profile: profile, config: try load(), appSupport: appSupport))
        XCTAssertEqual(choice, .init(place: "in a shared workspace", allowed: false))
        let rows = ConfigDoctorService.protectSyncedBackupRows(choice)
        XCTAssertEqual(rows.map(\.id), ["protect.backup_synced_storage"])
        XCTAssertEqual(rows.first?.severity, .suggest)
        XCTAssertTrue(rows.first?.hint?.contains("protect.backup_on_synced_storage") ?? false)

        try BackupChoiceConfigWriter.save(
            .protect, on: true, profile: profile, appSupport: appSupport)
        let allowed = try XCTUnwrap(ProtectBackup.syncedStorageChoice(
            profile: profile, config: try load(), appSupport: appSupport))
        XCTAssertTrue(allowed.allowed)
        XCTAssertEqual(ConfigDoctorService.protectSyncedBackupRows(allowed), [])
        XCTAssertEqual(ConfigDoctorService.protectSyncedBackupRows(nil), [])
    }

    func testALocalWorkspaceHasNoSyncedStorageChoice() throws {
        try writeConfig(shared: false, protectBackup: "true")
        XCTAssertNil(ProtectBackup.syncedStorageChoice(
            profile: profile, config: try ConfigLoader.load(
                from: workspace.appendingPathComponent("config.yaml")), appSupport: appSupport))
    }
}
