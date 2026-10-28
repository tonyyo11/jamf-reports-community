import XCTest
@testable import JamfReports

/// The Jamf Pro half of a backup as an informed choice on synced storage
/// (`backup.pro_on_synced_storage`): the plan, the grace runs, the skip's honesty chain, the
/// manifest, retention and the config key. A shell script stands in for jamf-cli, under a name
/// that is not `jamf-cli` (`CLIBridge.codesignGate` keys on that filename).
@MainActor
final class ProBackupTests: XCTestCase {
    private let shared = "shared_workspace:\n  enabled: true\n"
    private let optIn = "backup:\n  pro_on_synced_storage: true\n"
    private let protectConfig = "protect:\n  enabled: true\n  profile: \"protect-login\"\n"

    // MARK: - Plan

    func test_plan_localStorageIsAsBeforeWhateverTheKeySays() {
        for setting in [ProBackup.Setting.notChosen, .allowed, .declined, .awaitingConfirmation] {
            XCTAssertEqual(
                ProBackup.plan(setting: setting, place: nil,
                               hasScheduledHistory: { true }, graceRunsUsed: { 3 }),
                .run)
        }
    }

    func test_plan_optInRunsAndNoRunsOnSyncedStorage() {
        XCTAssertEqual(
            ProBackup.plan(setting: .allowed, place: "on OneDrive",
                           hasScheduledHistory: { false }, graceRunsUsed: { 3 }),
            .runOnSyncedStorage(place: "on OneDrive"))
        guard case .skip(let reason, let kind) = ProBackup.plan(
            setting: .declined, place: "on OneDrive",
            hasScheduledHistory: { true }, graceRunsUsed: { 0 })
        else { return XCTFail("false is a no, whatever the history") }
        XCTAssertEqual(kind, .declined)
        XCTAssertFalse(kind.makesRunPartial, "the operator's no is a decision, not a gap")
        XCTAssertTrue(reason.contains("on OneDrive"), reason)
        XCTAssertTrue(reason.contains("backup.pro_on_synced_storage"), reason)
        XCTAssertTrue(reason.contains("storage policy"), reason)
    }

    func test_plan_absentKeyAsksAndGivesGraceOnlyToAWorkspaceWithHistory() {
        XCTAssertEqual(
            ProBackup.plan(setting: .notChosen, place: "on OneDrive",
                           hasScheduledHistory: { true }, graceRunsUsed: { 0 }),
            .runWhileAsking(place: "on OneDrive", runsLeft: 3))
        XCTAssertEqual(
            ProBackup.plan(setting: .notChosen, place: "on OneDrive",
                           hasScheduledHistory: { true }, graceRunsUsed: { 2 }),
            .runWhileAsking(place: "on OneDrive", runsLeft: 1))
        for (history, used) in [(true, 3), (false, 0)] {
            guard case .skip(_, let kind) = ProBackup.plan(
                setting: .notChosen, place: "on OneDrive",
                hasScheduledHistory: { history }, graceRunsUsed: { used })
            else { return XCTFail("history \(history), used \(used)") }
            XCTAssertEqual(kind, .asking)
            XCTAssertTrue(kind.makesRunPartial)
        }
    }

    func test_plan_aTrueWaitingForConfirmationHasItsOwnReasonAndStaysPartial() {
        guard case .skip(let reason, let kind) = ProBackup.plan(
            setting: .awaitingConfirmation, place: "on OneDrive",
            hasScheduledHistory: { true }, graceRunsUsed: { 0 })
        else { return XCTFail("a drifted true must not run") }
        XCTAssertEqual(kind, .awaitingConfirmation)
        XCTAssertTrue(kind.makesRunPartial, "the operator wants Jamf Pro backed up")
        XCTAssertTrue(reason.contains("waiting for confirmation on this Mac (Config Doctor)"),
                      reason)
    }

    func test_plan_anUndecodableConfigSkipsOnSyncedStorageAndNeverStartsTheGrace() {
        var read = 0
        guard case .skip(let reason, let kind) = ProBackup.plan(
            setting: .notChosen, place: "on OneDrive", decodeFailure: "thresholds: wrong type",
            hasScheduledHistory: { read += 1; return true }, graceRunsUsed: { read += 1; return 0 })
        else { return XCTFail("unknown must not back up") }
        XCTAssertEqual(kind, .declined)
        XCTAssertTrue(reason.contains("config.yaml could not be read"), reason)
        XCTAssertFalse(reason.contains("thresholds: wrong type"),
                       "the error text goes in the log line, not the reason")
        XCTAssertEqual(read, 0)
        XCTAssertEqual(
            ProBackup.plan(setting: .notChosen, place: nil, decodeFailure: "x",
                           hasScheduledHistory: { true }, graceRunsUsed: { 0 }),
            .run, "local storage never depends on config.yaml")
    }

    func test_plan_aNewWorkspaceNeverReadsTheGraceCount() {
        var read = 0
        _ = ProBackup.plan(setting: .allowed, place: "on OneDrive",
                           hasScheduledHistory: { read += 1; return true },
                           graceRunsUsed: { read += 1; return 0 })
        _ = ProBackup.plan(setting: .notChosen, place: nil,
                           hasScheduledHistory: { read += 1; return true },
                           graceRunsUsed: { read += 1; return 0 })
        XCTAssertEqual(read, 0)
    }

    // MARK: - Grace count

    func test_graceCountsPerProfileInTheGivenFolderAndFailsTowardSkipping() throws {
        let support = try tempDir()
        XCTAssertEqual(ProBackupGrace.used(profile: "a", appSupport: support), 0)
        try ProBackupGrace.record(profile: "a", appSupport: support)
        try ProBackupGrace.record(profile: "a", appSupport: support)
        XCTAssertEqual(ProBackupGrace.used(profile: "a", appSupport: support), 2)
        XCTAssertEqual(ProBackupGrace.used(profile: "b", appSupport: support), 0)
        let mode = try FileManager.default.attributesOfItem(
            atPath: ProBackupGrace.url(profile: "a", appSupport: support).path
        )[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)

        try "not json".write(to: ProBackupGrace.url(profile: "b", appSupport: support),
                             atomically: true, encoding: .utf8)
        XCTAssertEqual(ProBackupGrace.used(profile: "b", appSupport: support),
                       BackupMaintenance.graceRunsBeforeAsking,
                       "an unreadable count reads as used up")

        ProBackupGrace.exhaust(profile: "c", appSupport: support)
        XCTAssertEqual(ProBackupGrace.used(profile: "c", appSupport: support),
                       BackupMaintenance.graceRunsBeforeAsking)
    }

    // MARK: - backup()

    func test_backup_localStorageNeedsNoKey() async throws {
        let ctx = try makeContext(config: nil)
        let run = try await backup(ctx, label: "scheduled-t")
        XCTAssertEqual(run.exit, 0)
        XCTAssertEqual(try ctx.calls().count, 1)
        XCTAssertFalse(run.lines.contains { $0.contains("Jamf Pro not backed up") })
        XCTAssertNil(try ctx.manifest(of: try ctx.onlyBackup())["products"])
        XCTAssertEqual(run.changes[.proBackupChoiceNeeded], .cleared)
    }

    func test_backup_newWorkspaceOnSyncedStorageAsksBeforeTheFirstBackup() async throws {
        let ctx = try makeContext(config: shared)
        let run = try await backup(ctx, label: "scheduled-t")

        XCTAssertEqual(run.exit, 0, "a skip is not a failure")
        XCTAssertEqual(try ctx.calls().count, 0, "pro backup must not run")
        let warns = run.lines.filter { $0.hasPrefix("[warn] Jamf Pro not backed up") }
        XCTAssertEqual(warns.count, 1, "\(run.lines)")
        XCTAssertTrue(warns[0].contains("in a shared workspace"), warns[0])
        XCTAssertTrue(warns[0].contains("backup.pro_on_synced_storage"), warns[0])
        XCTAssertEqual(run.lines.filter { $0.hasPrefix("[partial]") }.count, 1, "\(run.lines)")
        XCTAssertFalse(run.lines.contains { $0.hasPrefix("[error]") }, "\(run.lines)")

        try assertNoBackupFolder(ctx, run)
        guard case .raised(let message)? = run.changes[.proBackupChoiceNeeded]
        else { return XCTFail("\(run.changes)") }
        XCTAssertTrue(message.contains("need a choice"), message)
    }

    func test_backup_theSkippedRunReadsAsPartialAndNeverRetries() async throws {
        let ctx = try makeContext(config: shared)
        let run = try await backup(ctx, label: "scheduled-t")
        let watcher = CollectHonestyWatcher()
        run.lines.forEach(watcher.observe)
        XCTAssertTrue(watcher.incomplete)
        let schedule = Schedule(
            name: "backup", profile: ctx.profile, schedule: "Mon 07:00", cadence: "custom",
            mode: .backup, next: "—", last: "—", lastStatus: .partial, artifacts: [],
            enabled: true, launchAgentLabel: "com.github.tonyyo11.jamf-reports-community.x.backup")
        var state = TickState()
        let fire = Date(timeIntervalSince1970: 1_788_000_000)
        state.lastStarted[schedule.launchAgentLabel!] = fire
        for hours in [1.0, 3.0, 9.0] {
            XCTAssertTrue(TickScheduler.due(
                schedules: [schedule], state: state, runNowLabels: [],
                now: fire.addingTimeInterval(hours * 3600)).isEmpty, "retry after \(hours) h")
        }
    }

    func test_backup_existingScheduledWorkspaceKeepsBackingUpForThreeRunsThenSkips() async throws {
        let ctx = try makeContext(config: shared)
        try addHistory(ctx, "20260101T010101")

        for left in [3, 2, 1] {
            let run = try await backup(ctx, label: "scheduled-t")
            XCTAssertEqual(run.exit, 0)
            let warn = try XCTUnwrap(run.lines.first { $0.contains("need a choice") })
            XCTAssertTrue(warn.hasPrefix("[warn]"), warn)
            XCTAssertTrue(warn.contains("\(left - 1) scheduled backup"), warn)
            XCTAssertFalse(run.lines.contains { $0.hasPrefix("[partial]") },
                           "grace runs back up fully: \(run.lines)")
            guard case .raised? = run.changes[.proBackupChoiceNeeded]
            else { return XCTFail("attention while asking: \(run.changes)") }
        }
        XCTAssertEqual(try ctx.calls().count, 3)

        let fourth = try await backup(ctx, label: "scheduled-t")
        XCTAssertEqual(try ctx.calls().count, 3, "the fourth scheduled run skips")
        XCTAssertTrue(fourth.lines.contains { $0.hasPrefix("[warn] Jamf Pro not backed up") })
        XCTAssertTrue(fourth.lines.contains { $0.hasPrefix("[partial]") })
        let folders = try backupFolders(ctx)
        XCTAssertEqual(folders.count, 4, "the history folder and the three grace runs: \(folders)")
    }

    func test_backup_aManualBackupDuringGraceDoesNotUseItUp() async throws {
        let ctx = try makeContext(config: shared)
        try addHistory(ctx, "20260101T010101")
        for _ in 0..<2 { _ = try await backup(ctx, label: nil) }
        XCTAssertEqual(try ctx.calls().count, 2)
        XCTAssertEqual(ProBackupGrace.used(profile: ctx.profile), 0)
    }

    func test_backup_aSkippedOrFailedEarlierBackupIsNotHistory() async throws {
        let ctx = try makeContext(config: shared)
        try addHistory(ctx, "20260101T010101", pro: "skipped")
        try addHistory(ctx, "20260102T010101", pro: "failed")
        XCTAssertFalse(BackupMaintenance.hasScheduledJamfProBackup(profile: ctx.profile))
        let run = try await backup(ctx, label: "scheduled-t")
        XCTAssertEqual(try ctx.calls().count, 0, "\(run.lines)")
    }

    func test_backup_optInWaitsForAConfirmOnThisMacThenRunsAndLogsIt() async throws {
        let ctx = try makeContext(config: shared + optIn)
        let first = try await backup(ctx, label: "scheduled-t")
        XCTAssertEqual(try ctx.calls().count, 0, "an opt-in found at first sight is unconfirmed")
        let warn = try XCTUnwrap(first.lines.first { $0.hasPrefix("[warn] Jamf Pro not backed up") })
        XCTAssertTrue(warn.contains("waiting for confirmation on this Mac (Config Doctor)"), warn)
        XCTAssertTrue(first.lines.contains { $0.hasPrefix("[partial]") },
                      "the operator wants Jamf Pro backed up, so the gap shows")
        XCTAssertEqual(first.changes[.proBackupChoiceNeeded], .cleared,
                       "a written choice is not an open question")

        try SharedConfigPin.confirm(profile: ctx.profile, keys: [.proBackupOnSyncedStorage])
        let second = try await backup(ctx, label: "scheduled-t")
        XCTAssertEqual(second.exit, 0)
        XCTAssertEqual(try ctx.calls().count, 1)
        let audit = second.lines.filter { $0.hasPrefix("[info] backing up Jamf Pro to synced") }
        XCTAssertEqual(audit.count, 1, "\(second.lines)")
        XCTAssertTrue(audit[0].contains("backup.pro_on_synced_storage allows it"), audit[0])
        XCTAssertFalse(second.lines.contains { $0.hasPrefix("[partial]") })
        XCTAssertEqual(BackupProductResult.pro(inBackup: try newestBackup(ctx))?.state, nil,
                       "a workspace without Protect writes no products when Jamf Pro ran")
    }

    func test_backup_explicitFalseIsTheOperatorsDecisionNotAPartialRun() async throws {
        let ctx = try makeContext(config: shared + "backup:\n  pro_on_synced_storage: false\n")
        try addHistory(ctx, "20260101T010101")
        let run = try await backup(ctx, label: "scheduled-t")

        XCTAssertEqual(run.exit, 0)
        XCTAssertEqual(try ctx.calls().count, 0, "nothing is sent after an explicit no")
        XCTAssertEqual(run.lines.filter { $0.hasPrefix("[warn] Jamf Pro not backed up") }.count, 1)
        XCTAssertFalse(run.lines.contains { $0.hasPrefix("[partial]") }, "\(run.lines)")
        let watcher = CollectHonestyWatcher()
        run.lines.forEach(watcher.observe)
        XCTAssertFalse(watcher.incomplete)
        XCTAssertTrue(run.lines.contains { $0.hasPrefix("[info] no backup written") },
                      "\(run.lines)")
        XCTAssertEqual(run.changes[.proBackupChoiceNeeded], .cleared)
        XCTAssertEqual(try backupFolders(ctx), ["20260101T010101"], "an explicit no writes none")
    }

    func test_backup_aNonBooleanIsAnExplicitNoNotAGrace() async throws {
        for typed in ["\"maybe\"", "no", "yes please", "1"] {
            let ctx = try makeContext(
                config: shared + "backup:\n  pro_on_synced_storage: \(typed)\n")
            try addHistory(ctx, "20260101T010101")
            let run = try await backup(ctx, label: "scheduled-t")
            XCTAssertEqual(try ctx.calls().count, 0, "\(typed): \(run.lines)")
            XCTAssertEqual(run.changes[.proBackupChoiceNeeded], .cleared, typed)
            XCTAssertEqual(ProBackupGrace.used(profile: ctx.profile),
                           BackupMaintenance.graceRunsBeforeAsking, "\(typed) uses the grace up")
        }
    }

    func test_backup_aBackupBlockThatIsNotAMappingCostsThatBlockOnly() async throws {
        let ctx = try makeContext(config: shared + "backup: true\n")
        let config = try ConfigLoader.load(
            from: ctx.workspace.appendingPathComponent("config.yaml"))
        XCTAssertEqual(config.backup?.proOnSyncedStorage, false)
        XCTAssertEqual(config.sharedWorkspace?.enabled, true, "the rest of the file still decodes")
        try addHistory(ctx, "20260101T010101")
        _ = try await backup(ctx, label: "scheduled-t")
        XCTAssertEqual(try ctx.calls().count, 0)
    }

    func test_backup_anUndecodableConfigOnSyncedStorageSkipsAndStartsNoGrace() async throws {
        let ctx = try makeContext(config: shared)
        _ = SharedConfigPin.check(profile: ctx.profile)  // the pin says this workspace is shared
        try addHistory(ctx, "20260101T010101")
        try "thresholds: not-a-mapping\n".write(
            to: ctx.workspace.appendingPathComponent("config.yaml"),
            atomically: true, encoding: .utf8)

        let run = try await backup(ctx, label: "scheduled-t")
        XCTAssertEqual(try ctx.calls().count, 0, "\(run.lines)")
        let warn = try XCTUnwrap(run.lines.first { $0.hasPrefix("[warn] Jamf Pro not backed up") })
        XCTAssertTrue(warn.contains("config.yaml could not be read"), warn)
        XCTAssertTrue(warn.contains("thresholds"), "the log line keeps the detail: \(warn)")
        XCTAssertEqual(try backupFolders(ctx), ["20260101T010101"], "no manifest to carry a reason")
        XCTAssertEqual(ProBackupGrace.used(profile: ctx.profile), 0)
        XCTAssertNil(run.changes[.proBackupChoiceNeeded].flatMap {
            if case .raised = $0 { return $0 } else { return nil }
        })
    }

    func test_backup_aPeerWritingSharedFalseOrBreakingTheFileDoesNotMakeItLocal() async throws {
        let ctx = try makeContext(config: shared)
        _ = SharedConfigPin.check(profile: ctx.profile)
        try "shared_workspace:\n  enabled: false\n".write(
            to: ctx.workspace.appendingPathComponent("config.yaml"),
            atomically: true, encoding: .utf8)
        _ = try await backup(ctx, label: "scheduled-t")
        XCTAssertEqual(try ctx.calls().count, 0, "this Mac's pin says the workspace was shared")

        let local = try makeContext(config: "shared_workspace:\n  enabled: false\n")
        _ = try await backup(local, label: "scheduled-t")
        XCTAssertEqual(try local.calls().count, 1, "no pin, no shared signal: local as before")
    }

    func test_backup_anExplicitChoiceUsesUpTheGraceSoDeletingTheKeyBuysNothing() async throws {
        let ctx = try makeContext(config: shared + "backup:\n  pro_on_synced_storage: false\n")
        try addHistory(ctx, "20260101T010101")
        _ = try await backup(ctx, label: "scheduled-t")
        try shared.write(to: ctx.workspace.appendingPathComponent("config.yaml"),
                         atomically: true, encoding: .utf8)
        let run = try await backup(ctx, label: "scheduled-t")
        XCTAssertEqual(try ctx.calls().count, 0, "\(run.lines)")
        XCTAssertTrue(run.lines.contains { $0.hasPrefix("[partial]") }, "absent asks again")
    }

    func test_backup_onlyThisMacsStampedBackupsAreHistory() async throws {
        let ctx = try makeContext(config: shared)
        try addHistory(ctx, "20260101T010101", stamped: false)
        let planted = ctx.workspace.appendingPathComponent("backups/20260102T010101")
        try FileManager.default.createDirectory(at: planted, withIntermediateDirectories: true)
        try Data("some-other-mac".utf8).write(
            to: planted.appendingPathComponent(BackupMaintenance.ownerStampName))
        try JSONSerialization.data(withJSONObject: ["label": "scheduled-x"])
            .write(to: planted.appendingPathComponent("manifest.json"))
        XCTAssertFalse(BackupMaintenance.hasScheduledJamfProBackup(profile: ctx.profile))

        let run = try await backup(ctx, label: "scheduled-t")
        XCTAssertEqual(try ctx.calls().count, 0, "a planted folder buys no grace: \(run.lines)")

        try addHistory(ctx, "20260103T010101")
        XCTAssertTrue(BackupMaintenance.hasScheduledJamfProBackup(profile: ctx.profile))
    }

    func test_backup_aGraceCountThatCannotBeSavedSkipsWithAFixedManifestReason() async throws {
        let ctx = try makeContext(config: shared)
        try addHistory(ctx, "20260101T010101")
        // A count file nothing can replace: it reads as zero runs, and the save fails.
        var count = ProBackupGrace.url(profile: ctx.profile, appSupport: AppSupport.directory())
        try Data("{\"runs\": 0}".utf8).write(to: count)
        var immutable = URLResourceValues()
        immutable.isUserImmutable = true
        try count.setResourceValues(immutable)
        defer {
            immutable.isUserImmutable = false
            try? count.setResourceValues(immutable)
        }
        let run = try await backup(ctx, label: "scheduled-t")
        XCTAssertEqual(try ctx.calls().count, 0, "\(run.lines)")
        let warn = try XCTUnwrap(run.lines.first { $0.hasPrefix("[warn] Jamf Pro not backed up") })
        XCTAssertTrue(warn.contains("could not be saved on this Mac: "), warn)
        XCTAssertEqual(try backupFolders(ctx), ["20260101T010101"])
    }

    /// The manifest reason of a skipped Jamf Pro part, which only a run that kept Jamf Protect
    /// objects writes.
    func test_backup_aGraceCountThatCannotBeSavedLeavesAFixedManifestReason() async throws {
        let ctx = try protectContext()
        try addHistory(ctx, "20260101T010101")
        var count = ProBackupGrace.url(profile: ctx.profile, appSupport: AppSupport.directory())
        try Data("{\"runs\": 0}".utf8).write(to: count)
        var immutable = URLResourceValues()
        immutable.isUserImmutable = true
        try count.setResourceValues(immutable)
        defer {
            immutable.isUserImmutable = false
            try? count.setResourceValues(immutable)
        }
        _ = try await backup(ctx, label: "scheduled-t")
        let reason = try XCTUnwrap(
            BackupProductResult.pro(inBackup: try newestBackup(ctx))?.reason)
        XCTAssertTrue(reason.hasSuffix("could not be saved on this Mac"), reason)
        XCTAssertFalse(reason.contains(":"), "the error text stays out of the manifest")
    }

    func test_backup_protectStillBacksUpWhenJamfProIsSkipped() async throws {
        let ctx = try protectContext()
        let run = try await backup(ctx, label: "scheduled-t")

        XCTAssertEqual(run.exit, 0)
        let calls = try ctx.calls()
        XCTAssertEqual(calls.count, 1, "\(calls)")
        XCTAssertTrue(calls[0].contains("protect backup"), calls[0])
        let final = try ctx.onlyBackup()
        XCTAssertEqual(BackupProductResult.pro(inBackup: final)?.state, .skipped)
        XCTAssertEqual(BackupProductResult.protect(inBackup: final)?.state, .ok)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: final.appendingPathComponent("protect/plans/a.yaml").path))
        XCTAssertTrue(run.lines.contains { $0.hasPrefix("[warn] Jamf Pro not backed up") })
    }

    /// The run names the folder it finished, so housekeeping stamps that one and no other.
    func test_backupRun_namesTheFolderOnlyWhenOneWasWritten() async throws {
        let none = try makeContext(config: shared)
        let skipped = try await CLIBridge().backupRun(
            profile: none.profile, label: "scheduled-t", _testExecutable: none.stub) { _ in }
        XCTAssertEqual(skipped.exit, 0)
        XCTAssertNil(skipped.folder)
        XCTAssertEqual(try backupFolders(none), [])

        let kept = try protectContext()
        let run = try await CLIBridge().backupRun(
            profile: kept.profile, label: "scheduled-t", _testExecutable: kept.stub) { _ in }
        XCTAssertEqual(run.folder?.lastPathComponent, try kept.onlyBackup().lastPathComponent)
    }

    func test_backup_aConfigThatDoesNotDecodeOnLocalStorageStillBacksUpJamfPro() async throws {
        let ctx = try makeContext(config: "thresholds: not-a-mapping\n")
        let run = try await backup(ctx, label: "scheduled-t")
        XCTAssertEqual(try ctx.calls().count, 1, "\(run.lines)")
        XCTAssertFalse(run.lines.contains { $0.contains("Jamf Pro not backed up") })
    }

    func test_backup_theClosingLineKeepsTheProtectGapWhenJamfProIsDeclined() async throws {
        let ctx = try makeContext(
            config: shared + "backup:\n  pro_on_synced_storage: false\n" + protectConfig
                + "  backup_on_synced_storage: true\n", protectPartial: true)
        _ = SharedConfigPin.check(profile: ctx.profile)
        try SharedConfigPin.confirm(profile: ctx.profile, keys: [.protectBackupOnSyncedStorage])
        let run = try await backup(ctx, label: "scheduled-t")

        XCTAssertEqual(run.exit, 0)
        let closing = try XCTUnwrap(run.lines.last { $0.contains("backup written") }, "\(run.lines)")
        XCTAssertTrue(closing.hasPrefix("[warn] backup written without a complete Jamf Protect part"),
                      closing)
        XCTAssertTrue(run.lines.contains { $0.hasPrefix("[partial]") }, "Protect's gap shows")
    }

    func test_backup_protectIsSkippedTooWhenAPeerMakesASharedWorkspaceLookLocal() async throws {
        let ctx = try makeContext(config: shared + optIn + protectConfig)
        _ = SharedConfigPin.check(profile: ctx.profile)
        try SharedConfigPin.confirm(profile: ctx.profile, keys: [.proBackupOnSyncedStorage])
        try ("shared_workspace:\n  enabled: false\n" + optIn + protectConfig).write(
            to: ctx.workspace.appendingPathComponent("config.yaml"),
            atomically: true, encoding: .utf8)

        let run = try await backup(ctx, label: "scheduled-t")
        let calls = try ctx.calls()
        XCTAssertEqual(calls.count, 1, "only Jamf Pro (opted in) runs: \(calls)")
        XCTAssertFalse(calls[0].contains("protect backup"), calls[0])
        XCTAssertTrue(run.lines.contains { $0.hasPrefix("[warn] Jamf Protect not backed up") },
                      "\(run.lines)")
    }

    // MARK: - Records, retention, diff

    func test_backupRecordMarksTheSkippedPartAndRefusesToDiffIt() async throws {
        let ctx = try protectContext()
        _ = try await backup(ctx, label: "scheduled-t")
        let record = try XCTUnwrap(BackupLibrary().list(profile: ctx.profile).first)
        XCTAssertTrue(record.proSkipped)
        XCTAssertFalse(record.proFailed)
        XCTAssertTrue(record.lacksJamfPro)
        XCTAssertTrue(record.accessibilityLabel.contains("Jamf Pro part skipped"))
        let other = BackupRecord(
            name: "other", label: "", created: Date(), sizeBytes: 1, fileCount: 3, url: record.url)
        XCTAssertFalse(BackupRecord.canDiff(other, against: record))
        XCTAssertFalse(BackupRecord.canDiff(record, against: other))
    }

    func test_prune_aSkippedPartIsHeldThenRemovedAndNeverCounted() throws {
        let ctx = try makeContext(config: nil)
        let backups = ctx.workspace.appendingPathComponent("backups", isDirectory: true)
        func make(_ name: String, pro: String) throws {
            let pro: [String: Any] = pro == "ok"
                ? ["state": "ok", "exit_code": 0]
                : BackupProductResult(state: .skipped, reason: "x").manifestValue
            let ok = BackupProductResult(state: .ok, exitCode: 0, objectCounts: ["plans": 1])
            let manifest: [String: Any] = [
                "label": "scheduled-x", "products": ["pro": pro, "protect": ok.manifestValue]]
            let dir = backups.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent("protect"), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: manifest)
                .write(to: dir.appendingPathComponent("manifest.json"))
        }
        func make(_ name: String, jamfPro: Bool) throws {
            try make(name, pro: jamfPro ? "ok" : "skipped")
            if jamfPro {
                try Data("{}".utf8).write(
                    to: backups.appendingPathComponent(name)
                        .appendingPathComponent("computers.json"))
            }
        }
        try make("20260501T010101", jamfPro: true)
        try make("20260502T010101", jamfPro: true)
        try make("20260503T010101", jamfPro: false)
        try make("20260504T010101", jamfPro: false)

        BackupMaintenance.pruneScheduledBackups(profile: ctx.profile, keep: 2)

        let left = try FileManager.default.contentsOfDirectory(atPath: backups.path).sorted()
        XCTAssertEqual(left, ["20260501T010101", "20260502T010101", "20260504T010101"],
                       "the older skipped backup goes once a newer Protect part completed; the "
                       + "newest is held; neither takes a place from the Jamf Pro backups")
    }

    func test_prune_aSkippedManifestOverAFolderHoldingJamfProFilesIsKept() throws {
        let ctx = try makeContext(config: nil)
        let backups = ctx.workspace.appendingPathComponent("backups", isDirectory: true)
        func make(_ name: String, files: Bool) throws {
            let dir = backups.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let pro = BackupProductResult(state: .skipped, reason: "x").manifestValue
            let protect = BackupProductResult(state: .ok, exitCode: 0).manifestValue
            try JSONSerialization.data(withJSONObject: [
                "label": "scheduled-x", "products": ["pro": pro, "protect": protect]])
                .write(to: dir.appendingPathComponent("manifest.json"))
            if files { try Data("{}".utf8).write(to: dir.appendingPathComponent("computers.json")) }
        }
        try make("20260501T010101", files: true)
        try make("20260502T010101", files: false)
        BackupMaintenance.pruneScheduledBackups(profile: ctx.profile, keep: 1)
        let left = try FileManager.default.contentsOfDirectory(atPath: backups.path).sorted()
        XCTAssertEqual(left, ["20260501T010101", "20260502T010101"])
    }

    // MARK: - The key

    func test_theKeyIsReadAndKnown() throws {
        XCTAssertEqual(
            try loadConfig("backup:\n  pro_on_synced_storage: true\n").backup?.proOnSyncedStorage,
            true)
        XCTAssertNil(try loadConfig("output:\n  output_dir: x\n").backup)
        XCTAssertEqual(
            try loadConfig("backup:\n  pro_on_synced_storage: sometimes\n")
                .backup?.proOnSyncedStorage, false, "a non-boolean reads as false")
        XCTAssertEqual(try loadConfig("backup: true\n").backup?.proOnSyncedStorage, false)
        XCTAssertNil(try loadConfig("backup:\n  pro_on_synced_storage:\n")
            .backup?.proOnSyncedStorage, "an empty value is not chosen")
        XCTAssertTrue(ConfigSchema.knownKeys(at: ["backup"])?.contains("pro_on_synced_storage")
                      ?? false)
        XCTAssertTrue(ConfigEditedKeys.paths.contains(["backup", "pro_on_synced_storage"]))
    }

    func test_doctorNamesANonBooleanAndSuggestsTheSettingWhileBackupsSkipJamfPro() throws {
        let root = try ConfigLoader.rawMapping(
            fromYAML: "backup:\n  pro_on_synced_storage: yes please\n")
        let rows = ConfigDoctorService.fileReadBooleanRows(root)
        XCTAssertEqual(rows.map(\.id), ["config.value.backup.pro_on_synced_storage"])

        XCTAssertEqual(ConfigDoctorService.proSyncedBackupRows(nil), [])
        XCTAssertEqual(ConfigDoctorService.proSyncedBackupRows(
            .init(place: "on OneDrive", setting: .allowed)), [])
        for setting in [ProBackup.Setting.notChosen, .declined, .awaitingConfirmation] {
            let found = ConfigDoctorService.proSyncedBackupRows(
                .init(place: "on OneDrive", setting: setting))
            XCTAssertEqual(found.map(\.id), ["backup.pro_synced_storage"])
            XCTAssertEqual(found.first?.severity, .suggest)
            let text = (found.first?.detail ?? "") + (found.first?.hint ?? "")
            XCTAssertTrue(text.contains("backup.pro_on_synced_storage"), text)
            XCTAssertEqual(text.contains("Partial"), setting != .declined,
                           "an explicit no is not Partial: \(text)")
        }
    }

    func test_theBackupsSwitchWritesEitherKeyAndKeepsTheOtherBlock() throws {
        let ctx = try makeContext(
            config: shared + "protect:\n  enabled: true\n  profile: \"protect-login\"\n")
        _ = SharedConfigPin.check(profile: ctx.profile)
        XCTAssertEqual(try currentSetting(ctx), .notChosen)

        try BackupChoiceConfigWriter.save(.pro, on: true, profile: ctx.profile)
        XCTAssertEqual(try currentSetting(ctx), .allowed, "the switch confirms what it wrote")
        let config = try ConfigLoader.load(
            from: ctx.workspace.appendingPathComponent("config.yaml"))
        XCTAssertEqual(config.backup?.proOnSyncedStorage, true)
        XCTAssertEqual(config.protect?.resolvedProfile, "protect-login", "other blocks stay")
        XCTAssertNil(config.protect?.backupOnSyncedStorage, "the Protect key is not touched")

        try BackupChoiceConfigWriter.save(.pro, on: false, profile: ctx.profile)
        XCTAssertEqual(try currentSetting(ctx), .declined)
        XCTAssertTrue(SharedConfigPin.check(profile: ctx.profile).drifts.isEmpty)
    }

    func test_aPeersOptInIsDriftAndAFalseAppliesAtOnce() throws {
        let ctx = try makeContext(config: shared)
        _ = SharedConfigPin.check(profile: ctx.profile)
        XCTAssertEqual(try currentSetting(ctx), .notChosen, "absent is not chosen")
        func write(_ block: String) throws {
            try (shared + block).write(
                to: ctx.workspace.appendingPathComponent("config.yaml"),
                atomically: true, encoding: .utf8)
        }
        try write(optIn)
        XCTAssertEqual(try currentSetting(ctx), .awaitingConfirmation,
                       "a peer's true waits for a confirm")
        XCTAssertEqual(SharedConfigPin.check(profile: ctx.profile).drifts.map(\.key),
                       [.proBackupOnSyncedStorage])
        try SharedConfigPin.confirm(profile: ctx.profile, keys: [.proBackupOnSyncedStorage])
        XCTAssertEqual(try currentSetting(ctx), .allowed)
        try write("backup:\n  pro_on_synced_storage: false\n")
        XCTAssertEqual(try currentSetting(ctx), .declined, "a change to false applies at once")
        XCTAssertTrue(SharedConfigPin.check(profile: ctx.profile).drifts.isEmpty)
        try write(optIn)
        XCTAssertEqual(try currentSetting(ctx), .awaitingConfirmation,
                       "a later true is drift again")
    }

    func test_theBackupsCardReadsAnUndecodableConfigAsTheEngineDoes() throws {
        let ctx = try makeContext(config: shared)
        _ = SharedConfigPin.check(profile: ctx.profile)
        try "thresholds: not-a-mapping\n".write(
            to: ctx.workspace.appendingPathComponent("config.yaml"),
            atomically: true, encoding: .utf8)
        let read = ProBackup.readConfig(profile: ctx.profile)
        XCTAssertNil(read.config)
        XCTAssertNotNil(read.failure)
        let choice = try XCTUnwrap(ProBackup.syncedStorageChoice(
            profile: ctx.profile, config: read.config, decodeFailure: read.failure))
        XCTAssertEqual(choice.setting, .configUnreadable)
        XCTAssertEqual(ConfigDoctorService.proSyncedBackupRows(choice), [],
                       "Doctor has its own decode rows")
    }

    func test_doctorNamesABackupBlockThatIsNotAMapping() throws {
        for yaml in ["backup: true\n", "backup: \"on\"\n", "backup:\n  - a\n"] {
            let rows = ConfigDoctorService.fileReadBooleanRows(
                try ConfigLoader.rawMapping(fromYAML: yaml))
            XCTAssertEqual(rows.map(\.id), ["config.value.backup"], yaml)
        }
        for yaml in ["backup:\n  pro_on_synced_storage: true\n", "backup:\n", "output: {}\n"] {
            XCTAssertEqual(ConfigDoctorService.fileReadBooleanRows(
                try ConfigLoader.rawMapping(fromYAML: yaml)), [], yaml)
        }
    }

    func test_theSyncedStorageChoiceFollowsTheStorageAndTheProduct() throws {
        let ctx = try makeContext(config: shared)
        let url = ctx.workspace.appendingPathComponent("config.yaml")
        XCTAssertEqual(
            ProBackup.syncedStorageChoice(
                profile: ctx.profile, config: try ConfigLoader.load(from: url)),
            .init(place: "in a shared workspace", setting: .notChosen))
        try "shared_workspace:\n  enabled: false\n"
            .write(to: url, atomically: true, encoding: .utf8)
        XCTAssertNil(ProBackup.syncedStorageChoice(
            profile: ctx.profile, config: try ConfigLoader.load(from: url)), "local storage")
        try (shared + "school_cli:\n  enabled: true\n").write(
            to: url, atomically: true, encoding: .utf8)
        XCTAssertNil(ProBackup.syncedStorageChoice(
            profile: ctx.profile, config: try ConfigLoader.load(from: url)),
            "a School workspace has no Jamf Pro backup")
    }

    // MARK: - Helpers

    private func currentSetting(_ ctx: Context) throws -> ProBackup.Setting {
        let config = try ConfigLoader.load(
            from: ctx.workspace.appendingPathComponent("config.yaml"))
        return SharedConfigPin.proBackupSetting(
            config.backup?.proOnSyncedStorage, profile: ctx.profile)
    }

    /// Shared storage with Jamf Protect connected and allowed there, so a skipped Jamf Pro part
    /// still leaves a folder holding the Protect objects.
    private func protectContext() throws -> Context {
        let ctx = try makeContext(
            config: shared + "protect:\n  enabled: true\n  profile: \"protect-login\"\n"
                + "  backup_on_synced_storage: true\n")
        _ = SharedConfigPin.check(profile: ctx.profile)
        try SharedConfigPin.confirm(profile: ctx.profile, keys: [.protectBackupOnSyncedStorage])
        return ctx
    }

    private func backupFolders(_ ctx: Context) throws -> [String] {
        let backups = ctx.workspace.appendingPathComponent("backups", isDirectory: true)
        return try FileManager.default.contentsOfDirectory(atPath: backups.path).sorted()
    }

    /// A skipped Jamf Pro part with no Jamf Protect objects writes no folder, and no staging
    /// folder stays behind. The skip is still said, and still not a failure.
    private func assertNoBackupFolder(
        _ ctx: Context, _ run: Run, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        XCTAssertEqual(try backupFolders(ctx), [], file: file, line: line)
        XCTAssertEqual(run.exit, 0, file: file, line: line)
        XCTAssertTrue(run.lines.contains { $0.hasPrefix("[warn] no backup written") },
                      "\(run.lines)", file: file, line: line)
        XCTAssertFalse(run.lines.contains { $0.hasPrefix("[error]") },
                       "\(run.lines)", file: file, line: line)
    }

    private struct Run {
        let exit: Int32
        let lines: [String]
        let changes: [AttentionCode: AttentionChange]
    }

    private func backup(_ ctx: Context, label: String?) async throws -> Run {
        let lines = Lines()
        let log = AttentionLog(profile: ctx.profile, usesAppRecord: false)
        let exit = try await AttentionLog.$current.withValue(log) {
            try await CLIBridge().backup(
                profile: ctx.profile, label: label, _testExecutable: ctx.stub
            ) { lines.append($0) }
        }
        return Run(exit: exit, lines: lines.texts, changes: log.changes)
    }

    /// A scheduled backup made before the choice existed, stamped as this Mac's unless
    /// `stamped` is false (a folder a peer planted, or another Mac's).
    private func addHistory(
        _ ctx: Context, _ name: String, pro: String? = nil, stamped: Bool = true
    ) throws {
        let dir = ctx.workspace.appendingPathComponent("backups", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var manifest: [String: Any] = ["label": "scheduled-old"]
        if let pro { manifest["products"] = ["pro": ["state": pro]] }
        try JSONSerialization.data(withJSONObject: manifest)
            .write(to: dir.appendingPathComponent("manifest.json"))
        if stamped { BackupMaintenance.stampOwnership(of: dir) }
    }

    private func newestBackup(_ ctx: Context) throws -> URL {
        let backups = ctx.workspace.appendingPathComponent("backups", isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: backups.path)
            .filter { !$0.hasPrefix(".") }.sorted()
        return backups.appendingPathComponent(try XCTUnwrap(names.last), isDirectory: true)
    }

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

    private func makeContext(config: String?, protectPartial: Bool = false) throws -> Context {
        let root = try tempDir()
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        addTeardownBlock { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
        let profile = "pro-\(UUID().uuidString.prefix(8).lowercased())"
        let workspace = try XCTUnwrap(ProfileService.workspaceURL(for: profile))
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        if let config {
            try config.write(to: workspace.appendingPathComponent("config.yaml"),
                             atomically: true, encoding: .utf8)
        }
        let scripts = try tempDir()
        let log = scripts.appendingPathComponent("calls.log")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$*" >> '\(log.path)'
        prev=""; out=""
        for a in "$@"; do
          if [ "$prev" = "--output" ]; then out="$a"; fi
          prev="$a"
        done
        mkdir -p "$out"
        case " $* " in
        *" protect backup "*)
        mkdir -p "$out/plans"
        echo 'name: a' > "$out/plans/a.yaml"
        \(protectPartial ? "echo 'plans: boom' > \"$out/_failures.yaml\"; exit 7" : "")
        ;;
        *)
        echo '{"a":1}' > "$out/computers.json"
        ;;
        esac
        exit 0
        """
        let stub = scripts.appendingPathComponent("stub-cli-\(UUID().uuidString)")
        try script.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        return Context(profile: profile, workspace: workspace, stub: stub, log: log)
    }

    private func loadConfig(_ yaml: String) throws -> ReportConfig {
        let url = try tempDir().appendingPathComponent("config.yaml")
        try yaml.write(to: url, atomically: true, encoding: .utf8)
        return try ConfigLoader.load(from: url)
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProBackupTests-\(UUID().uuidString)", isDirectory: true)
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
