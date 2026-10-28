import XCTest
@testable import JamfReports

/// Jamf Protect configuration in backups: the call, the skip rules, the manifest, retention
/// and file permissions. Nothing here runs jamf-cli: a shell script stands in for it, under a
/// name that is not `jamf-cli` (`CLIBridge.codesignGate` keys on that filename).
@MainActor
final class ProtectBackupTests: XCTestCase {

    private enum ProtectMode { case ok, partial, failed, hang, empty }

    private let connectedConfig = """
    protect:
      enabled: true
      profile: "protect-login"
    """

    /// The Jamf Pro opt-in a shared workspace needs before Jamf Pro (and so these Protect
    /// checks) runs at all; confirmed on this Mac with `confirmProOptIn`.
    private let proOptIn = "backup:\n  pro_on_synced_storage: true\n"

    private func confirmProOptIn(_ ctx: Context) throws {
        try SharedConfigPin.confirm(profile: ctx.profile, keys: [.proBackupOnSyncedStorage])
    }

    // MARK: - Argument building and the plan

    func test_arguments_carryProfileNoInputAndOutput() {
        XCTAssertEqual(
            ProtectBackup.arguments(profile: "protect-login", outputDirectory: "/stage/protect"),
            ["-p", "protect-login", "--no-input", "protect", "backup",
             "--output", "/stage/protect"])
        // A profile that looks like a flag is still the value of -p.
        XCTAssertEqual(
            ProtectBackup.arguments(profile: "--output", outputDirectory: "/s").prefix(2),
            ["-p", "--output"])
    }

    func test_plan_notConnectedNeverEvaluatesThePinOrStorage() throws {
        var evaluated = 0
        let none = ProtectBackup.plan(
            config: nil, workspaceProfile: "ws",
            pinAllows: { evaluated += 1; return true },
            sharedStorage: { evaluated += 1; return nil })
        XCTAssertEqual(none, .notConnected)
        for yaml in ["protect:\n  enabled: false\n  profile: \"p\"\n",
                     "output:\n  output_dir: x\n",
                     "school_cli:\n  enabled: true\nprotect:\n  enabled: true\n  profile: \"p\"\n"] {
            let config = try loadConfig(yaml)
            XCTAssertEqual(
                ProtectBackup.plan(
                    config: config, workspaceProfile: "ws",
                    pinAllows: { evaluated += 1; return true },
                    sharedStorage: { evaluated += 1; return nil }),
                .notConnected, yaml)
        }
        XCTAssertEqual(evaluated, 0)
    }

    func test_plan_runsWhenConnectedLocalAndPinned() throws {
        let config = try loadConfig(connectedConfig)
        XCTAssertEqual(
            ProtectBackup.plan(config: config, workspaceProfile: "ws",
                               pinAllows: { true }, sharedStorage: { nil }),
            .run(profile: "protect-login"))
    }

    func test_plan_skipsOnDriftEmptyProfileAndSharedStorage() throws {
        let config = try loadConfig(connectedConfig)
        guard case .skip(let drift) = ProtectBackup.plan(
            config: config, workspaceProfile: "ws",
            pinAllows: { false }, sharedStorage: { nil }) else { return XCTFail("drift") }
        XCTAssertTrue(drift.contains("protect.profile changed"), drift)

        guard case .skip(let shared) = ProtectBackup.plan(
            config: config, workspaceProfile: "ws",
            pinAllows: { true }, sharedStorage: { "on OneDrive" }) else { return XCTFail("shared") }
        XCTAssertTrue(shared.contains("on OneDrive"), shared)

        let blank = try loadConfig("protect:\n  enabled: true\n  profile: \"\"\n")
        guard case .skip(let empty) = ProtectBackup.plan(
            config: blank, workspaceProfile: "ws",
            pinAllows: { true }, sharedStorage: { nil }) else { return XCTFail("empty") }
        XCTAssertTrue(empty.contains("protect.profile is empty"), empty)
    }

    func test_plan_skipsOnAnICloudDesktopAndDocumentsFolder() throws {
        let config = try loadConfig(connectedConfig)
        let folder = try makeTempDir()
        guard case .skip(let reason) = ProtectBackup.plan(
            config: config, workspaceProfile: "ws", pinAllows: { true },
            sharedStorage: {
                BackupMaintenance.sharedStorageDescription(
                    folder, profile: "ws", volumeIsLocal: { _ in true },
                    syncProbe: .iCloudEverywhere)
            }) else { return XCTFail("synced") }
        XCTAssertTrue(reason.contains("on iCloud Desktop & Documents"), reason)
    }

    func test_plan_onSyncedStorageSkipsByDefaultAndRunsWhenThisMacAllowsIt() throws {
        let config = try loadConfig(connectedConfig)
        guard case .skip(let reason) = ProtectBackup.plan(
            config: config, workspaceProfile: "ws",
            pinAllows: { true }, sharedStorage: { "on a network volume" })
        else { return XCTFail("skip by default") }
        XCTAssertEqual(reason, ProtectBackup.syncedStorageReason(place: "on a network volume"))
        for text in ["this workspace is on a network volume", "request headers",
                     "data-forwarding", "storage policy", "protect.backup_on_synced_storage"] {
            XCTAssertTrue(reason.contains(text), text)
        }
        XCTAssertFalse(reason.contains("OneDrive"))

        XCTAssertEqual(
            ProtectBackup.plan(
                config: config, workspaceProfile: "ws", pinAllows: { true },
                sharedStorage: { "on a network volume" }, syncedStorageAllowed: { true }),
            .run(profile: "protect-login"))

        var asked = false
        XCTAssertEqual(
            ProtectBackup.plan(
                config: config, workspaceProfile: "ws", pinAllows: { true },
                sharedStorage: { nil }, syncedStorageAllowed: { asked = true; return false }),
            .run(profile: "protect-login"))
        XCTAssertFalse(asked, "local storage never asks for the opt-in")
    }

    func test_backupOnSyncedStorage_decodesAndANonBooleanReadsAsOff() throws {
        XCTAssertFalse(try loadConfig(connectedConfig).protect?.backsUpOnSyncedStorage ?? true)
        XCTAssertTrue(try loadConfig(connectedConfig + "\n  backup_on_synced_storage: true\n")
            .protect?.backsUpOnSyncedStorage ?? false)
        let typo = try loadConfig(connectedConfig + "\n  backup_on_synced_storage: sometimes\n")
        XCTAssertFalse(typo.protect?.backsUpOnSyncedStorage ?? true)
        XCTAssertEqual(typo.protect?.resolvedProfile, "protect-login")
    }

    func test_plan_skipsAProfileOfAnotherProduct() throws {
        let config = try loadConfig(connectedConfig)
        let plan = ProtectBackup.plan(
            config: config, workspaceProfile: "ws", pinAllows: { true },
            protectRefusal: { "'\($0)' is a Jamf Pro profile, not a Jamf Protect profile" },
            sharedStorage: { nil })
        XCTAssertEqual(plan, .skip(
            reason: "'protect-login' is a Jamf Pro profile, not a Jamf Protect profile"))
    }

    func test_result_classifiesExitCodesAgainstWhatWasWritten() throws {
        let dir = try makeTempDir()
        // Nothing written: any non-zero exit is a failure, timeout included.
        XCTAssertEqual(ProtectBackup.result(exit: 3, directory: dir).state, .failed)
        XCTAssertEqual(ProtectBackup.result(exit: 7, directory: dir).state, .failed)
        try write("name: a", to: dir.appendingPathComponent("plans/a.yaml"))
        try write("name: c", to: dir.appendingPathComponent("connections.yaml"))
        XCTAssertEqual(ProtectBackup.result(exit: 0, directory: dir).objectCounts,
                       ["plans": 1, "connections": 1])
        XCTAssertEqual(ProtectBackup.result(exit: 7, directory: dir).state, .partial)
        XCTAssertEqual(ProtectBackup.result(exit: 3, directory: dir).state, .failed)
        XCTAssertEqual(
            ProtectBackup.result(exit: CLIBridge.exitCodeTimedOut, directory: dir).state, .failed)
        try write("plans: boom", to: dir.appendingPathComponent("_failures.yaml"))
        let withFailures = ProtectBackup.result(exit: 1, directory: dir)
        XCTAssertEqual(withFailures.state, .partial)
        XCTAssertTrue(withFailures.hasFailuresFile)
        XCTAssertNil(withFailures.objectCounts["_failures"], "_failures.yaml is not a resource")
        // Exit 0 with a failures file is still not a whole backup.
        XCTAssertEqual(ProtectBackup.result(exit: 0, directory: dir).state, .partial)
    }

    func test_result_cleanExitWithNoObjectsIsPartial() throws {
        let missing = try makeTempDir().appendingPathComponent("never-created")
        let empty = try makeTempDir()
        for dir in [missing, empty] {
            let result = ProtectBackup.result(exit: 0, directory: dir)
            XCTAssertEqual(result.state, .partial)
            XCTAssertEqual(result.reason, "no objects exported")
            XCTAssertTrue(result.isIncomplete)
        }
        try write("name: a", to: empty.appendingPathComponent("plans/a.yaml"))
        XCTAssertEqual(ProtectBackup.result(exit: 0, directory: empty).state, .ok)
    }

    func test_backup_protectExitingCleanWithNothingExportedReportsComplete() async throws {
        let ctx = try makeContext(config: connectedConfig, protect: .empty)
        let lines = Lines()
        let exit = try await CLIBridge().backup(
            profile: ctx.profile, label: "scheduled-20260101", _testExecutable: ctx.stub
        ) { lines.append($0) }

        XCTAssertEqual(exit, 0)
        let protect = try XCTUnwrap(BackupProductResult.protect(inBackup: try ctx.onlyBackup()))
        XCTAssertEqual(protect.state, .partial)
        XCTAssertEqual(protect.reason, "no objects exported")
        XCTAssertTrue(protect.isComplete, "retention reads it as complete")
        let texts = lines.texts
        XCTAssertTrue(texts.contains("[ok] Jamf Protect backed up: it has no objects to export"),
                      "\(texts)")
        XCTAssertFalse(texts.contains { $0.hasPrefix("[partial]") || $0.contains("PARTIAL") },
                       "an empty tenant is not a partial backup: \(texts)")
    }

    // MARK: - Needs attention

    private func attention(
        config: String?, protect: ProtectMode
    ) async throws -> [AttentionCode: AttentionChange] {
        let ctx = try makeContext(config: config, protect: protect)
        let log = AttentionLog(profile: ctx.profile, usesAppRecord: false)
        _ = try await AttentionLog.$current.withValue(log) {
            try await CLIBridge().backup(
                profile: ctx.profile, label: "scheduled-t", _testExecutable: ctx.stub) { _ in }
        }
        return log.changes
    }

    func test_attention_eachProtectOutcomeRecordsOrClearsItsCode() async throws {
        let ok = try await attention(config: connectedConfig, protect: .ok)
        let protectCleared: [AttentionCode: AttentionChange] = [
            .protectBackupSkipped: .cleared, .protectBackupPartial: .cleared,
            .proBackupChoiceNeeded: .cleared,
        ]
        XCTAssertEqual(ok, protectCleared)
        let empty = try await attention(config: connectedConfig, protect: .empty)
        XCTAssertEqual(empty, protectCleared,
                       "an empty export leaves nothing to fix")
        let failed = try await attention(config: connectedConfig, protect: .failed)
        XCTAssertEqual(failed[.protectBackupPartial], .raised("Protect backup failed"))
        let undecodable = try await attention(config: "thresholds: not-a-mapping\n", protect: .ok)
        XCTAssertEqual(undecodable, [
            .protectBackupSkipped: .raised("Protect not backed up: config.yaml does not decode"),
            .proBackupChoiceNeeded: .cleared,
        ])
        let none = try await attention(config: nil, protect: .ok)
        XCTAssertEqual(none, protectCleared,
                       "a workspace without Protect has nothing left to fix")
    }

    // MARK: - backup(): connected

    func test_backup_connectedWorkspaceBacksUpProtectIntoTheSameFolder() async throws {
        let ctx = try makeContext(config: connectedConfig, protect: .ok)
        let lines = Lines()
        let exit = try await CLIBridge().backup(
            profile: ctx.profile, label: "scheduled-t", _testExecutable: ctx.stub
        ) { lines.append($0) }

        XCTAssertEqual(exit, 0)
        let calls = try ctx.calls()
        XCTAssertEqual(calls.count, 2, "\(calls)")
        XCTAssertTrue(calls[0].contains("pro backup"), calls[0])
        let protectCall = calls[1]
        XCTAssertTrue(protectCall.hasPrefix("-p protect-login --no-input protect backup --output "),
                      protectCall)
        XCTAssertTrue(protectCall.hasSuffix("/protect"), protectCall)
        XCTAssertTrue(protectCall.contains("/backups/.tmp-"), "staging folder: \(protectCall)")

        let final = try ctx.onlyBackup()
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: final.appendingPathComponent("computers.json").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: final.appendingPathComponent("protect/plans/a.yaml").path))
        let manifest = try ctx.manifest(of: final)
        let products = try XCTUnwrap(manifest["products"] as? [String: Any])
        XCTAssertEqual((products["pro"] as? [String: Any])?["state"] as? String, "ok")
        XCTAssertEqual((products["pro"] as? [String: Any])?["exit_code"] as? Int, 0)
        let protect = try XCTUnwrap(BackupProductResult.protect(inManifest: manifest))
        XCTAssertEqual(protect, BackupProductResult(
            state: .ok, exitCode: 0,
            objectCounts: ["plans": 2, "action-configs": 1]))
        XCTAssertEqual(manifest["file_count"] as? Int, 4, "the count covers both products")
        XCTAssertEqual(try XCTUnwrap(BackupLibrary().list(profile: ctx.profile).first).protect,
                       protect)
        XCTAssertTrue(lines.texts.contains { $0.hasPrefix("[ok] Jamf Protect") }, "\(lines.texts)")
        XCTAssertFalse(lines.texts.contains { $0.hasPrefix("[partial]") })
        XCTAssertFalse(lines.texts.contains { $0.contains("to synced storage") },
                       "local storage logs no synced-storage audit line")
    }

    func test_backup_workspaceWithoutProtectIsAsBefore() async throws {
        for config in [nil, "output:\n  output_dir: \"Generated Reports\"\n",
                       "protect:\n  enabled: false\n  profile: \"protect-login\"\n"] {
            let ctx = try makeContext(config: config, protect: .ok)
            let lines = Lines()
            let exit = try await CLIBridge().backup(
                profile: ctx.profile, label: nil, _testExecutable: ctx.stub
            ) { lines.append($0) }
            XCTAssertEqual(exit, 0)
            XCTAssertEqual(try ctx.calls().count, 1, "only pro backup runs")
            let final = try ctx.onlyBackup()
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: final.appendingPathComponent("protect").path))
            let manifest = try ctx.manifest(of: final)
            XCTAssertNil(manifest["products"], "a workspace without Protect writes no products")
            XCTAssertEqual(Set(manifest.keys), ["label", "created_at", "file_count", "size_bytes"])
            XCTAssertFalse(lines.texts.contains { $0.contains("Protect") }, "\(lines.texts)")
        }
    }

    // MARK: - backup(): skipped

    func test_backup_skipsProtectWhenTheProfileDriftedOnASharedWorkspace() async throws {
        let shared = "shared_workspace:\n  enabled: true\n" + proOptIn
        let ctx = try makeContext(
            config: shared + "protect:\n  enabled: true\n  profile: \"protect-a\"\n",
            protect: .ok)
        _ = SharedConfigPin.check(profile: ctx.profile)  // this Mac pins protect-a
        try confirmProOptIn(ctx)
        try (shared + "protect:\n  enabled: true\n  profile: \"protect-b\"\n")
            .write(to: ctx.workspace.appendingPathComponent("config.yaml"),
                   atomically: true, encoding: .utf8)
        let lines = Lines()
        let exit = try await CLIBridge().backup(
            profile: ctx.profile, label: "scheduled-t", _testExecutable: ctx.stub
        ) { lines.append($0) }

        XCTAssertEqual(exit, 0, "the Jamf Pro backup stands")
        let calls = try ctx.calls()
        XCTAssertEqual(calls.count, 1, "protect backup must not run: \(calls)")
        let warns = lines.texts.filter { $0.hasPrefix("[warn] Jamf Protect not backed up") }
        XCTAssertEqual(warns.count, 1, "\(lines.texts)")
        XCTAssertTrue(warns[0].contains("protect.profile changed"), warns[0])
        let manifest = try ctx.manifest(of: try ctx.onlyBackup())
        let result = try XCTUnwrap(BackupProductResult.protect(inManifest: manifest))
        XCTAssertEqual(result.state, .skipped)
        XCTAssertFalse(result.isIncomplete, "a skip is not a failure")
        XCTAssertFalse(lines.texts.contains { $0.hasPrefix("[partial]") })
    }

    func test_backup_skipsProtectWithOneWarningWhenConfigDoesNotDecode() async throws {
        let ctx = try makeContext(config: "thresholds: not-a-mapping\n", protect: .ok)
        let lines = Lines()
        let exit = try await CLIBridge().backup(
            profile: ctx.profile, label: "scheduled-t", _testExecutable: ctx.stub
        ) { lines.append($0) }

        XCTAssertEqual(exit, 0, "the Jamf Pro backup stands")
        XCTAssertEqual(try ctx.calls().count, 1, "protect backup must not run")
        let warns = lines.texts.filter { $0.contains("config.yaml does not decode") }
        XCTAssertEqual(warns.count, 1, "\(lines.texts)")
        XCTAssertTrue(warns[0].hasPrefix("[warn] Jamf Protect not backed up"), warns[0])
        let result = try XCTUnwrap(BackupProductResult.protect(inBackup: try ctx.onlyBackup()))
        XCTAssertEqual(result.state, .skipped)
        XCTAssertTrue(try XCTUnwrap(result.reason).contains("config.yaml does not decode"))
        XCTAssertFalse(lines.texts.contains { $0.hasPrefix("[partial]") })
    }

    func test_backup_skipsProtectOnSharedStorage() async throws {
        let ctx = try makeContext(
            config: "shared_workspace:\n  enabled: true\n" + proOptIn + connectedConfig + "\n",
            protect: .ok)
        try confirmProOptIn(ctx)
        let lines = Lines()
        let exit = try await CLIBridge().backup(
            profile: ctx.profile, label: nil, _testExecutable: ctx.stub
        ) { lines.append($0) }

        XCTAssertEqual(exit, 0)
        let calls = try ctx.calls()
        XCTAssertEqual(calls.count, 1, "\(calls)")
        let warns = lines.texts.filter { $0.hasPrefix("[warn] Jamf Protect not backed up") }
        XCTAssertEqual(warns.count, 1, "\(lines.texts)")
        XCTAssertTrue(warns[0].contains("in a shared workspace"), warns[0])
        XCTAssertTrue(warns[0].contains("request headers"), warns[0])
        XCTAssertTrue(warns[0].contains("protect.backup_on_synced_storage"), warns[0])
        let final = try ctx.onlyBackup()
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: final.appendingPathComponent("protect").path))
        XCTAssertEqual(
            BackupProductResult.protect(inBackup: final)?.state, .skipped)
    }

    /// The opt-in found already on at first sight waits for this Mac; once confirmed, the backup
    /// includes Protect and jamf-cli's 0600 on credential files survives.
    func test_backup_onSharedStorageRunsProtectOnlyOnceTheOptInIsConfirmed() async throws {
        let ctx = try makeContext(
            config: "shared_workspace:\n  enabled: true\n" + proOptIn + connectedConfig
                + "\n  backup_on_synced_storage: true\n", protect: .ok)
        try confirmProOptIn(ctx)
        let first = Lines()
        _ = try await CLIBridge().backup(
            profile: ctx.profile, label: nil, _testExecutable: ctx.stub) { first.append($0) }
        XCTAssertEqual(try ctx.calls().count, 1, "unconfirmed: Jamf Pro only")
        XCTAssertTrue(first.texts.contains { $0.hasPrefix("[warn] Jamf Protect not backed up") })
        let skipped = try ctx.onlyBackup()
        try FileManager.default.removeItem(at: skipped)

        try SharedConfigPin.confirm(profile: ctx.profile, keys: [.protectBackupOnSyncedStorage])
        let second = Lines()
        let exit = try await CLIBridge().backup(
            profile: ctx.profile, label: nil, _testExecutable: ctx.stub) { second.append($0) }
        XCTAssertEqual(exit, 0)
        let calls = try ctx.calls()
        XCTAssertEqual(calls.count, 3, "\(calls)")
        XCTAssertFalse(second.texts.contains { $0.hasPrefix("[warn] Jamf Protect not backed up") })
        let audit = second.texts.filter { $0.hasPrefix("[info] backing up Jamf Protect to synced") }
        XCTAssertEqual(audit.count, 1, "\(second.texts)")
        XCTAssertTrue(audit[0].contains("in a shared workspace"), audit[0])
        XCTAssertTrue(audit[0].contains("protect.backup_on_synced_storage allows it"), audit[0])
        let final = try ctx.onlyBackup()
        XCTAssertEqual(BackupProductResult.protect(inBackup: final)?.state, .ok)
        let hook = final.appendingPathComponent("protect/action-configs/hook.yaml")
        let mode = try FileManager.default.attributesOfItem(atPath: hook.path)[.posixPermissions]
        XCTAssertEqual(mode as? Int, 0o600)
    }

    // MARK: - backup(): Protect fails, Pro stands

    func test_backup_partialProtectKeepsProMarksManifestAndRunPartialAndBlocksPruning() async throws {
        let ctx = try makeContext(config: connectedConfig, protect: .partial)
        let lines = Lines()
        let exit = try await CLIBridge().backup(
            profile: ctx.profile, label: "scheduled-20260101", _testExecutable: ctx.stub
        ) { lines.append($0) }

        XCTAssertEqual(exit, 0, "Protect never changes the Jamf Pro backup's exit")
        let final = try ctx.onlyBackup()
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: final.appendingPathComponent("computers.json").path))
        let protect = try XCTUnwrap(BackupProductResult.protect(inBackup: final))
        XCTAssertEqual(protect.state, .partial)
        XCTAssertEqual(protect.exitCode, 7)
        XCTAssertTrue(protect.hasFailuresFile)
        XCTAssertTrue(protect.isIncomplete)

        let texts = lines.texts
        let warn = try XCTUnwrap(texts.first { $0.hasPrefix("[warn] Jamf Protect backup is PARTIAL") })
        XCTAssertTrue(warn.contains("protect/_failures.yaml"), warn)
        XCTAssertEqual(texts.filter { $0.hasPrefix("[partial]") }.count, 1, "\(texts)")

        // The scheduled run's watcher reads that line as an incomplete run; backup mode has no
        // same-day retry, so Partial does not repeat the run.
        let watcher = CollectHonestyWatcher()
        texts.forEach(watcher.observe)
        XCTAssertTrue(watcher.incomplete)
        let backupSchedule = Schedule(
            name: "backup", profile: ctx.profile, schedule: "Mon 07:00", cadence: "custom",
            mode: .backup, next: "—", last: "—", lastStatus: .partial, artifacts: [],
            enabled: true, launchAgentLabel: "com.github.tonyyo11.jamf-reports-community.x.backup")
        var state = TickState()
        let fire = Date(timeIntervalSince1970: 1_788_000_000)
        state.lastStarted[backupSchedule.launchAgentLabel!] = fire
        for hours in [1.0, 3.0, 9.0] {
            XCTAssertTrue(TickScheduler.due(
                schedules: [backupSchedule], state: state, runNowLabels: [],
                now: fire.addingTimeInterval(hours * 3600)).isEmpty,
                "no retry \(hours) h after a Partial backup")
        }
    }

    func test_pruneHoldsAnIncompleteProtectPartUntilANewerOneCompletes() throws {
        let ctx = try makeContext(config: connectedConfig, protect: .ok)
        let backups = ctx.workspace.appendingPathComponent("backups", isDirectory: true)
        func make(_ name: String, protect: BackupProductResult?) throws {
            var manifest: [String: Any] = ["label": "scheduled-x"]
            if let protect { manifest["products"] = ["protect": protect.manifestValue] }
            let dir = backups.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: manifest)
                .write(to: dir.appendingPathComponent("manifest.json"))
        }
        try make("20260501T010101", protect: nil)
        try make("20260502T010101", protect: BackupProductResult(state: .partial, exitCode: 7))
        try make("20260503T010101", protect: BackupProductResult(state: .ok, exitCode: 0))
        try make("20260504T010101", protect: BackupProductResult(state: .failed, exitCode: 3))
        try make("20260505T010101", protect: BackupProductResult(state: .skipped, reason: "x"))
        try make("20260506T010101", protect: BackupProductResult(state: .partial, exitCode: 7))

        let lines = Lines()
        BackupMaintenance.pruneScheduledBackups(profile: ctx.profile, keep: 1) { lines.append($0) }

        let left = try FileManager.default.contentsOfDirectory(atPath: backups.path).sorted()
        XCTAssertEqual(left, ["20260504T010101", "20260505T010101", "20260506T010101"],
                       "incomplete parts newer than the last complete one stay; the partial "
                       + "older than it is counted and pruned; of the rest the newest is kept")
        XCTAssertTrue(lines.texts.contains { $0.contains("keeping 2 scheduled backup(s) with an incomplete") },
                      "\(lines.texts)")
    }

    func test_pruneRemovesOldBackupsWhoseProtectPartExportedNothing() throws {
        let ctx = try makeContext(config: connectedConfig, protect: .ok)
        let backups = ctx.workspace.appendingPathComponent("backups", isDirectory: true)
        let empty = ProtectBackup.result(
            exit: 0, directory: try makeTempDir().appendingPathComponent("none"))
        XCTAssertEqual(empty.state, .partial, "still reported as partial")
        func make(_ name: String, protect: BackupProductResult) throws {
            let manifest: [String: Any] = [
                "label": "scheduled-x", "products": ["protect": protect.manifestValue]]
            let dir = backups.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: manifest)
                .write(to: dir.appendingPathComponent("manifest.json"))
        }
        try make("20260501T010101", protect: empty)
        try make("20260502T010101", protect: empty)
        try make("20260503T010101", protect: empty)
        try make("20260504T010101", protect: BackupProductResult(
            state: .partial, exitCode: 0, reason: "no objects exported", hasFailuresFile: true))

        BackupMaintenance.pruneScheduledBackups(profile: ctx.profile, keep: 1)

        let left = try FileManager.default.contentsOfDirectory(atPath: backups.path).sorted()
        XCTAssertEqual(left, ["20260503T010101", "20260504T010101"],
                       "empty exports are counted and pruned; a real Protect failure stays")
        XCTAssertEqual(empty.protectSummary,
                       "The latest backup includes Jamf Protect: it has no objects.")
    }

    func test_backup_failedProtectDiscardsItsFilesAndKeepsPro() async throws {
        let ctx = try makeContext(config: connectedConfig, protect: .failed)
        let lines = Lines()
        let exit = try await CLIBridge().backup(
            profile: ctx.profile, label: nil, _testExecutable: ctx.stub
        ) { lines.append($0) }

        XCTAssertEqual(exit, 0)
        let final = try ctx.onlyBackup()
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: final.appendingPathComponent("protect").path),
            "files of a failed Protect run are not kept")
        let protect = try XCTUnwrap(BackupProductResult.protect(inBackup: final))
        XCTAssertEqual(protect.state, .failed)
        XCTAssertEqual(protect.exitCode, 3)
        XCTAssertTrue(protect.objectCounts.isEmpty)
        XCTAssertTrue(lines.texts.contains { $0.hasPrefix("[partial]") })
        XCTAssertTrue(lines.texts.contains { $0.hasPrefix("[error]") && $0.contains("authentication failed") },
                      "\(lines.texts)")
    }

    func test_backup_protectHasItsOwnTimeout() async throws {
        let ctx = try makeContext(config: connectedConfig, protect: .hang)
        let lines = Lines()
        let exit = try await CLIBridge().backup(
            profile: ctx.profile, label: nil, protectTimeout: 1, _testExecutable: ctx.stub
        ) { lines.append($0) }

        XCTAssertEqual(exit, 0, "pro backup was not under the 1 s protect limit")
        let protect = try XCTUnwrap(BackupProductResult.protect(inBackup: try ctx.onlyBackup()))
        XCTAssertEqual(protect.state, .failed)
        XCTAssertEqual(protect.exitCode, CLIBridge.exitCodeTimedOut)
        XCTAssertTrue(lines.texts.contains {
            $0.hasPrefix("[error] protect backup stopped after the 1 s limit") }, "\(lines.texts)")
    }

    // MARK: - backup(): Jamf Pro failed

    func test_backup_proFailedKeepsAFolderHoldingOnlyTheProtectPart() async throws {
        let ctx = try makeContext(config: connectedConfig, protect: .ok, proExit: 1)
        let lines = Lines()
        let exit = try await CLIBridge().backup(
            profile: ctx.profile, label: "scheduled-t", _testExecutable: ctx.stub
        ) { lines.append($0) }

        XCTAssertEqual(exit, 1, "the run's exit stays Jamf Pro's")
        XCTAssertEqual(try ctx.calls().count, 2, "Protect still runs")
        let final = try ctx.onlyBackup()
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: final.appendingPathComponent("computers.json").path),
            "the unfinished Jamf Pro files are not kept")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: final.appendingPathComponent("protect/plans/a.yaml").path))
        let pro = try XCTUnwrap(BackupProductResult.pro(inBackup: final))
        XCTAssertEqual(pro.state, .failed)
        XCTAssertEqual(pro.exitCode, 1)
        XCTAssertEqual(BackupProductResult.protect(inBackup: final)?.state, .ok)
        XCTAssertEqual(BackupMaintenance.ownerHostID(of: final), SharedWorkspace.currentHost.id)
        XCTAssertTrue(lines.texts.contains {
            $0.hasPrefix("[error] Jamf Pro backup failed; kept the Jamf Protect part") },
            "\(lines.texts)")
    }

    func test_backup_protectPartialLineSaysHowTheJamfProBackupEnded() async throws {
        for (proExit, clause) in [
            (Int32(0), "the Jamf Pro backup is complete"),
            (7, "the Jamf Pro backup is partial too"),
            (1, "the Jamf Pro backup failed too"),
        ] {
            let ctx = try makeContext(config: connectedConfig, protect: .failed, proExit: proExit)
            let lines = Lines()
            _ = try await CLIBridge().backup(
                profile: ctx.profile, label: "scheduled-t", _testExecutable: ctx.stub
            ) { lines.append($0) }
            let partial = lines.texts.filter { $0.hasPrefix("[partial] Jamf Protect") }
            XCTAssertEqual(partial.count, 1, "exit \(proExit): \(lines.texts)")
            XCTAssertTrue(partial.first?.hasSuffix(clause) == true, "exit \(proExit): \(partial)")
        }
    }

    func test_pruneHoldsAtMostTenIncompleteBackups() throws {
        let ctx = try makeContext(config: connectedConfig, protect: .ok)
        let backups = ctx.workspace.appendingPathComponent("backups", isDirectory: true)
        let failed = BackupProductResult(state: .failed, exitCode: 3)
        let names = (1...12).map { String(format: "202605%02dT010101", $0) }
        for name in names {
            let dir = backups.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: [
                "label": "scheduled-x", "products": ["protect": failed.manifestValue],
            ]).write(to: dir.appendingPathComponent("manifest.json"))
        }

        let lines = Lines()
        BackupMaintenance.pruneScheduledBackups(profile: ctx.profile, keep: 1) { lines.append($0) }

        let left = try FileManager.default.contentsOfDirectory(atPath: backups.path).sorted()
        XCTAssertEqual(left, Array(names.dropFirst()),
                       "the newest 10 are held; of the 2 older ones keep 1 is kept")
        XCTAssertTrue(lines.texts.contains { $0.contains("2 older backup(s) with an incomplete") },
                      "\(lines.texts)")
    }

    func test_backup_proFailedWithNoProtectObjectsLeavesNoFolder() async throws {
        for (config, protect) in [(connectedConfig, ProtectMode.failed),
                                  (connectedConfig, .empty), (nil, .ok)] {
            let ctx = try makeContext(config: config, protect: protect, proExit: 5)
            let exit = try await CLIBridge().backup(
                profile: ctx.profile, label: nil, _testExecutable: ctx.stub) { _ in }
            XCTAssertEqual(exit, 5)
            let backups = ctx.workspace.appendingPathComponent("backups", isDirectory: true)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: backups.path), [],
                           "staging removed, nothing kept (\(protect))")
        }
    }

    func test_diffRefusesABackupWhoseJamfProPartFailed() async throws {
        let ctx = try makeContext(config: connectedConfig, protect: .ok)
        let backups = ctx.workspace.appendingPathComponent("backups", isDirectory: true)
        func make(_ name: String, pro: String) throws -> URL {
            let dir = backups.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: [
                "label": "x", "products": ["pro": ["state": pro, "exit_code": 0]]])
                .write(to: dir.appendingPathComponent("manifest.json"))
            return dir
        }
        let good = try make("20260501T010101", pro: "ok")
        let failed = try make("20260502T010101", pro: "failed")
        do {
            _ = try await CLIBridge().diffBackups(
                profile: ctx.profile, left: good, right: failed) { _ in }
            XCTFail("diff ran against a backup with no Jamf Pro part")
        } catch CLIBridgeError.backupWithoutPro(let name) {
            XCTAssertEqual(name, "20260502T010101")
        }
    }

    func test_pruneHoldsAProFailedBackupThenRemovesItWithoutCountingIt() throws {
        let ctx = try makeContext(config: connectedConfig, protect: .ok)
        let backups = ctx.workspace.appendingPathComponent("backups", isDirectory: true)
        let ok = BackupProductResult(state: .ok, exitCode: 0, objectCounts: ["plans": 1])
        func make(_ name: String, pro: String) throws {
            let manifest: [String: Any] = ["label": "scheduled-x", "products": [
                "pro": ["state": pro, "exit_code": pro == "ok" ? 0 : 1],
                "protect": ok.manifestValue]]
            let dir = backups.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: manifest)
                .write(to: dir.appendingPathComponent("manifest.json"))
        }
        try make("20260501T010101", pro: "ok")
        try make("20260502T010101", pro: "ok")
        try make("20260503T010101", pro: "failed")
        try make("20260504T010101", pro: "failed")

        BackupMaintenance.pruneScheduledBackups(profile: ctx.profile, keep: 2)

        let left = try FileManager.default.contentsOfDirectory(atPath: backups.path).sorted()
        XCTAssertEqual(left, ["20260501T010101", "20260502T010101", "20260504T010101"],
                       "the newest Pro-failed one is held, the superseded one is removed, and "
                       + "neither takes a place from the two Jamf Pro backups")
    }

    func test_pruneKeepsAProFailedBackupThatHoldsJamfProFilesAndRemovesAGenuineOne() throws {
        let ctx = try makeContext(config: connectedConfig, protect: .ok)
        let backups = ctx.workspace.appendingPathComponent("backups", isDirectory: true)
        let ok = BackupProductResult(state: .ok, exitCode: 0, objectCounts: ["plans": 1])
        func make(_ name: String, pro: String, extra: [String]) throws {
            let manifest: [String: Any] = ["label": "scheduled-x", "products": [
                "pro": ["state": pro, "exit_code": pro == "ok" ? 0 : 1],
                "protect": ok.manifestValue]]
            let dir = backups.appendingPathComponent(name, isDirectory: true)
            for folder in extra {
                try FileManager.default.createDirectory(
                    at: dir.appendingPathComponent(folder), withIntermediateDirectories: true)
            }
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: manifest)
                .write(to: dir.appendingPathComponent("manifest.json"))
            try write("host", to: dir.appendingPathComponent(".jrc-host"))
        }
        try make("20260501T010101", pro: "ok", extra: ["computers"])
        try make("20260502T010101", pro: "failed", extra: ["protect/plans"])
        try make("20260503T010101", pro: "failed", extra: ["protect/plans", "computers"])
        try make("20260504T010101", pro: "ok", extra: ["computers", "protect/plans"])
        let lines = Lines()

        BackupMaintenance.pruneScheduledBackups(profile: ctx.profile, keep: 2, onLine: lines.append)

        let left = try FileManager.default.contentsOfDirectory(atPath: backups.path).sorted()
        XCTAssertEqual(left, ["20260501T010101", "20260503T010101", "20260504T010101"],
                       "the genuine Pro-failed backup is removed; the edited one is kept and "
                       + "takes no place from the Jamf Pro backups")
        XCTAssertTrue(lines.texts.contains(
            "[warn] backup 20260503T010101: manifest says the Jamf Pro part failed or was "
                + "skipped but the folder holds Jamf Pro files — kept"), "\(lines.texts)")
    }

    // MARK: - Manifest compatibility

    func test_olderManifestsStillRead() throws {
        let ctx = try makeContext(config: nil, protect: .ok)
        let backups = ctx.workspace.appendingPathComponent("backups", isDirectory: true)
        let dir = backups.appendingPathComponent("20260601T214020", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try write("{}", to: dir.appendingPathComponent("computers.json"))
        let old = """
        {"label": "scheduled-20260601", "created_at": "2026-06-01T21:40:20Z",
         "file_count": 7, "size_bytes": 1234}
        """
        try write(old, to: dir.appendingPathComponent("manifest.json"))

        let record = try XCTUnwrap(BackupLibrary().list(profile: ctx.profile).first)
        XCTAssertEqual(record.label, "scheduled-20260601")
        XCTAssertEqual(record.fileCount, 7)
        XCTAssertNil(record.protect)
        XCTAssertNil(BackupProductResult.protect(inBackup: dir))
        XCTAssertNil(BackupProductResult.protect(inManifest: ["products": ["pro": ["state": "ok"]]]))
        XCTAssertNil(BackupProductResult.protect(
            inManifest: ["products": ["protect": ["state": "from-the-future"]]]),
            "an unknown state reads as no record, never as ok")
    }

    func test_productResultRoundTripsThroughTheManifest() throws {
        let original = BackupProductResult(
            state: .partial, exitCode: 7, reason: nil,
            objectCounts: ["plans": 3], hasFailuresFile: true)
        let data = try JSONSerialization.data(withJSONObject: ["protect": original.manifestValue])
        let decoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(BackupProductResult(manifestValue: decoded["protect"]), original)
        let skipped = BackupProductResult(state: .skipped, reason: "shared")
        XCTAssertEqual(BackupProductResult(manifestValue: skipped.manifestValue), skipped)
    }

    func test_plantedManifestCountsAreRangeCheckedNotSummedIntoATrap() throws {
        let manifest = """
        {"products": {"protect": {"state": "ok", "object_counts":
         {"a": 9223372036854775807, "b": 1, "c": -4, "d": 2.5, "e": 3, "f": "7",
          "g": 2147483648, "h": 2147483647}}}}
        """
        let object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(manifest.utf8)) as? [String: Any])
        let result = try XCTUnwrap(BackupProductResult.protect(inManifest: object))
        XCTAssertEqual(result.objectCounts, ["b": 1, "e": 3, "h": Int(Int32.max)])
        XCTAssertEqual(result.objectTotal, Int(Int32.max) + 4)
        XCTAssertFalse(result.protectSummary.isEmpty)
    }

    // MARK: - Backups screen text

    func test_summaryNamesWhatTheLatestBackupHolds() {
        let ok = BackupProductResult(
            state: .ok, exitCode: 0, objectCounts: ["plans": 2, "analytics": 1])
        XCTAssertEqual(ok.protectSummary,
                       "The latest backup includes Jamf Protect: 3 objects (analytics 1, plans 2).")
        let partial = BackupProductResult(
            state: .partial, exitCode: 7, objectCounts: ["plans": 1], hasFailuresFile: true)
        XCTAssertTrue(partial.protectSummary.contains("protect/_failures.yaml"))
        XCTAssertTrue(partial.protectSummary.contains("is kept until a later backup"))
        let failed = BackupProductResult(state: .failed, exitCode: 3)
        XCTAssertTrue(failed.protectSummary.contains("failed (exit 3)"))
        XCTAssertEqual(
            BackupProductResult(state: .skipped, reason: "shared").protectSummary,
            "Jamf Protect was not backed up: shared.")
    }

    func test_onlyABackupWithProtectObjectsNotesThatDiffSkipsThem() {
        func record(_ protect: BackupProductResult?) -> BackupRecord {
            BackupRecord(name: "n", label: "", created: Date(), sizeBytes: 1, fileCount: 1,
                         url: URL(fileURLWithPath: "/tmp/n"), protect: protect)
        }
        XCTAssertFalse(record(nil).includesProtectFiles)
        XCTAssertFalse(record(BackupProductResult(state: .skipped, reason: "x")).includesProtectFiles)
        XCTAssertFalse(record(BackupProductResult(state: .failed, exitCode: 3)).includesProtectFiles)
        XCTAssertTrue(record(BackupProductResult(
            state: .ok, exitCode: 0, objectCounts: ["plans": 1])).includesProtectFiles)
    }

    // MARK: - Permissions

    func test_backupKeepsCredentialFilesOwnerOnly() async throws {
        let ctx = try makeContext(config: connectedConfig, protect: .ok)
        _ = try await CLIBridge().backup(
            profile: ctx.profile, label: nil, _testExecutable: ctx.stub) { _ in }

        let final = try ctx.onlyBackup()
        let credential = final.appendingPathComponent("protect/action-configs/hook.yaml")
        XCTAssertEqual(try mode(of: credential), 0o600, "jamf-cli's 0600 survives the move")
        let subpaths = try FileManager.default.subpathsOfDirectory(atPath: final.path)
        for sub in subpaths {
            let url = final.appendingPathComponent(sub)
            let bits = try mode(of: url)
            XCTAssertEqual(bits & 0o077, 0, "\(sub) is \(String(bits, radix: 8))")
        }
        XCTAssertGreaterThanOrEqual(subpaths.count, 7)
        XCTAssertEqual(try mode(of: final.appendingPathComponent("protect")), 0o700)
    }

    // MARK: - Helpers

    private struct Context {
        let profile: String
        let workspace: URL
        let stub: URL
        let log: URL

        func calls() throws -> [String] {
            guard let text = try? String(contentsOf: log, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").map(String.init)
        }

        func onlyBackup() throws -> URL {
            let backups = workspace.appendingPathComponent("backups", isDirectory: true)
            let names = try FileManager.default.contentsOfDirectory(atPath: backups.path)
            XCTAssertEqual(names.count, 1, "\(names)")
            return backups.appendingPathComponent(try XCTUnwrap(names.first), isDirectory: true)
        }

        func manifest(of backup: URL) throws -> [String: Any] {
            let data = try Data(contentsOf: backup.appendingPathComponent("manifest.json"))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
    }

    private func makeContext(
        config: String?, protect: ProtectMode, proExit: Int32 = 0
    ) throws -> Context {
        let root = try makeTempDir()
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        addTeardownBlock { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
        let profile = "pbk-\(UUID().uuidString.prefix(8).lowercased())"
        let workspace = try XCTUnwrap(ProfileService.workspaceURL(for: profile))
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        if let config {
            try config.write(to: workspace.appendingPathComponent("config.yaml"),
                             atomically: true, encoding: .utf8)
        }
        let scripts = try makeTempDir()
        let log = scripts.appendingPathComponent("calls.log")
        let stub = try makeStub(in: scripts, log: log, protect: protect, proExit: proExit)
        return Context(profile: profile, workspace: workspace, stub: stub, log: log)
    }

    /// Records each call's arguments, then behaves as `pro backup` or `protect backup`.
    private func makeStub(
        in dir: URL, log: URL, protect: ProtectMode, proExit: Int32
    ) throws -> URL {
        let protectBody: String
        let writeFiles = """
        mkdir -p "$out/plans" "$out/action-configs"
        echo 'name: a' > "$out/plans/a.yaml"
        echo 'name: b' > "$out/plans/b.yaml"
        echo 'headers: secret' > "$out/action-configs/hook.yaml"
        chmod 644 "$out/plans/a.yaml" "$out/plans/b.yaml"
        chmod 600 "$out/action-configs/hook.yaml"
        """
        switch protect {
        case .ok:
            protectBody = writeFiles + "\nexit 0"
        case .partial:
            protectBody = writeFiles + "\necho 'plans: boom' > \"$out/_failures.yaml\"\nexit 7"
        case .failed:
            protectBody = writeFiles + "\nexit 3"
        case .hang:
            protectBody = writeFiles + "\nexec /bin/sleep 30"
        case .empty:
            protectBody = "mkdir -p \"$out\"\nexit 0"
        }
        let script = """
        #!/bin/sh
        printf '%s\\n' "$*" >> '\(log.path)'
        prev=""; out=""
        for a in "$@"; do
          if [ "$prev" = "--output" ]; then out="$a"; fi
          prev="$a"
        done
        case " $* " in
        *" protect backup "*)
        \(protectBody)
        ;;
        *)
        mkdir -p "$out"
        echo '{"a":1}' > "$out/computers.json"
        chmod 644 "$out/computers.json"
        exit \(proExit)
        ;;
        esac
        """
        let url = dir.appendingPathComponent("stub-cli-\(UUID().uuidString)")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func loadConfig(_ yaml: String) throws -> ReportConfig {
        let url = try makeTempDir().appendingPathComponent("config.yaml")
        try yaml.write(to: url, atomically: true, encoding: .utf8)
        return try ConfigLoader.load(from: url)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func mode(of url: URL) throws -> Int {
        try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProtectBackupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }
}

private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [CLIBridge.LogLine] = []

    func append(_ line: CLIBridge.LogLine) { lock.withLock { stored.append(line) } }
    var texts: [String] { lock.withLock { stored.map(\.text) } }
}
