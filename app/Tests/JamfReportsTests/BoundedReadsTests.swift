import XCTest
@testable import JamfReports

/// Reads of files a peer on a shared workspace can write refuse a link, a FIFO and an
/// oversize file, and never block (#284). Each blocking call runs on its own thread with a
/// deadline, so a regression fails the test instead of hanging the run.
final class BoundedReadsTests: XCTestCase {

    private let fm = FileManager.default
    private let profile = "boundedreads"
    private let deadline: TimeInterval = 5
    nonisolated(unsafe) private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = fm.temporaryDirectory
            .appendingPathComponent("jrc-bounded-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        if let root { try? fm.removeItem(at: root) }
        root = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func workspace() throws -> URL {
        let url = try XCTUnwrap(ProfileService.workspaceURL(for: profile))
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func fifo(at url: URL) throws {
        try fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertEqual(mkfifo(url.path, 0o600), 0)
    }

    private func link(_ url: URL, to target: URL) throws {
        try fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: url, withDestinationURL: target)
    }

    private func sparse(_ url: URL, bytes: UInt64) throws {
        try fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertTrue(fm.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: bytes)
        try handle.close()
    }

    /// `body`'s result, or nil when it had not returned after `deadline` seconds.
    private func within<T: Sendable>(_ body: @escaping @Sendable () -> T) -> T? {
        let box = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { box.value = body(); done.signal() }
        return done.wait(timeout: .now() + deadline) == .success ? box.value : nil
    }

    private final class ResultBox<T: Sendable>: @unchecked Sendable { var value: T? }

    // MARK: - BoundedFile.readTail

    func testReadTailReturnsTheEndAndSaysItCutTheFile() throws {
        let file = root.appendingPathComponent("big.log")
        try Data("0123456789".utf8).write(to: file)
        let whole = try BoundedFile.readTail(file, limit: 20)
        XCTAssertEqual(String(decoding: whole.data, as: UTF8.self), "0123456789")
        XCTAssertFalse(whole.truncated)
        let cut = try BoundedFile.readTail(file, limit: 4)
        XCTAssertEqual(String(decoding: cut.data, as: UTF8.self), "6789")
        XCTAssertTrue(cut.truncated)
    }

    func testReadTailRefusesALinkAndAFIFO() throws {
        let real = root.appendingPathComponent("real.log")
        try Data("x".utf8).write(to: real)
        let linked = root.appendingPathComponent("linked.log")
        try link(linked, to: real)
        XCTAssertThrowsError(try BoundedFile.readTail(linked, limit: 10))
        let pipe = root.appendingPathComponent("pipe.log")
        try fifo(at: pipe)
        let outcome = within { (try? BoundedFile.readTail(pipe, limit: 10)) == nil }
        XCTAssertEqual(outcome, true, "a FIFO must be refused without blocking")
    }

    func testAHardLinkIsRefusedAndLoggedOnlyWhenNotFollowingLinks() throws {
        let dir = root.appendingPathComponent("links", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let plain = dir.appendingPathComponent("plain.json")
        try Data("[1]".utf8).write(to: plain)
        XCTAssertEqual(try BoundedFile.read(plain, limit: 10, followSymlinks: false),
                       Data("[1]".utf8))

        let original = dir.appendingPathComponent("original.json")
        try Data("[2]".utf8).write(to: original)
        let second = dir.appendingPathComponent("second.json")
        try fm.linkItem(at: original, to: second)
        XCTAssertThrowsError(try BoundedFile.read(second, limit: 10, followSymlinks: false)) {
            XCTAssertEqual($0 as? BoundedFile.Failure, .unreadable(EMLINK))
        }
        XCTAssertThrowsError(
            try BoundedFile.read(second, limit: 10, followSymlinks: false, inside: root))
        XCTAssertNil(BoundedFile.stateData(original))
        XCTAssertTrue(logged("second.json not read: it has 2 hard links"))
        XCTAssertEqual(try BoundedFile.read(second, limit: 10), Data("[2]".utf8))
    }

    // MARK: - BoundedFile.read inside a root

    /// `jamf-cli-data/computers` swapped for a link to a folder outside the workspace after the
    /// path was validated: refused when not following, and caught by the kernel's path when
    /// following.
    func testReadInsideARootRefusesAFolderSwappedForALinkOutsideIt() throws {
        let workspace = root.appendingPathComponent("ws", isDirectory: true)
        let kind = workspace.appendingPathComponent("jamf-cli-data/computers", isDirectory: true)
        let file = kind.appendingPathComponent("s.json")
        try fm.createDirectory(at: kind, withIntermediateDirectories: true)
        try Data("[1]".utf8).write(to: file)
        XCTAssertEqual(
            try BoundedFile.read(file, limit: 10, followSymlinks: false, inside: workspace),
            Data("[1]".utf8))

        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("[2]".utf8).write(to: outside.appendingPathComponent("s.json"))
        try fm.removeItem(at: kind)
        try link(kind, to: outside)
        XCTAssertEqual(try BoundedFile.read(file, limit: 10), Data("[2]".utf8), "the swap worked")
        for follow in [false, true] {
            XCTAssertThrowsError(
                try BoundedFile.read(file, limit: 10, followSymlinks: follow, inside: workspace)
            ) { XCTAssertEqual($0 as? BoundedFile.Failure, .unreadable(ELOOP)) }
        }
    }

    /// The temp dir sits under `/var` -> `/private/var`, which `O_NOFOLLOW_ANY` on the whole path
    /// would refuse; links above the root, a linked root included, are trusted.
    func testReadInsideARootUnderSystemAndRootLinksStillReads() throws {
        let workspace = root.appendingPathComponent("ws", isDirectory: true)
        let file = workspace.appendingPathComponent("jamf-cli-data/computers/s.json")
        try fm.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("[1]".utf8).write(to: file)
        let linkedRoot = root.appendingPathComponent("linked-ws")
        try link(linkedRoot, to: workspace)
        let throughLink = linkedRoot.appendingPathComponent("jamf-cli-data/computers/s.json")
        XCTAssertEqual(
            try BoundedFile.read(throughLink, limit: 10, followSymlinks: false, inside: linkedRoot),
            Data("[1]".utf8))
        XCTAssertNoThrow(
            try BoundedFile.read(file, limit: 10, followSymlinks: false, inside: workspace))

        // Below the root a link is refused unless following, even one that stays inside.
        let alias = workspace.appendingPathComponent("jamf-cli-data/alias")
        try link(alias, to: file.deletingLastPathComponent())
        let viaAlias = alias.appendingPathComponent("s.json")
        XCTAssertThrowsError(
            try BoundedFile.read(viaAlias, limit: 10, followSymlinks: false, inside: workspace))
        XCTAssertNoThrow(
            try BoundedFile.read(viaAlias, limit: 10, followSymlinks: true, inside: workspace))
    }

    func testReadInsideARootRefusesAPathNotBelowIt() throws {
        let workspace = root.appendingPathComponent("ws", isDirectory: true)
        try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
        let sibling = root.appendingPathComponent("other.json")
        try Data("[]".utf8).write(to: sibling)
        let escaping = workspace.appendingPathComponent("../other.json")
        for url in [sibling, escaping, workspace] {
            XCTAssertThrowsError(
                try BoundedFile.read(url, limit: 10, followSymlinks: false, inside: workspace))
        }
    }

    // MARK: - Run logs

    private func logsDir() throws -> URL {
        try workspace().appendingPathComponent("automation/logs", isDirectory: true)
    }

    func testRunHistoryTailReadRefusesALinkAndAFIFO() throws {
        let logs = try logsDir()
        try fm.createDirectory(at: logs, withIntermediateDirectories: true)
        let real = logs.appendingPathComponent("real.log")
        try Data("exit 0 after 1s\n".utf8).write(to: real)
        XCTAssertEqual(RunHistoryService.parseLogTail(from: real).0, 0)

        let linked = logs.appendingPathComponent("linked.log")
        try link(linked, to: real)
        XCTAssertNil(RunHistoryService.parseLogTail(from: linked).0)

        let pipe = logs.appendingPathComponent("pipe.log")
        try fifo(at: pipe)
        let exit = within { RunHistoryService.parseLogTail(from: pipe).0 }
        XCTAssertNotNil(exit, "parseLogTail must not block on a FIFO")
        XCTAssertNil(exit ?? nil)
    }

    func testRunHistoryLoadLogRefusesALinkAndAFIFO() throws {
        let logs = try logsDir()
        try fm.createDirectory(at: logs, withIntermediateDirectories: true)
        let real = logs.appendingPathComponent("real.log")
        try Data("[ok] done\nexit 0 after 1s\n".utf8).write(to: real)
        XCTAssertFalse(RunHistoryService.loadLog(real).isEmpty)

        let linked = logs.appendingPathComponent("linked.log")
        try link(linked, to: real)
        XCTAssertTrue(RunHistoryService.loadLog(linked).isEmpty)

        let pipe = logs.appendingPathComponent("pipe.log")
        try fifo(at: pipe)
        let lines = within { RunHistoryService.loadLog(pipe).count }
        XCTAssertEqual(lines, 0, "loadLog must not block on a FIFO")
    }

    func testRunHistoryLoadLogKeepsOnlyTheTailOfAHugeLog() throws {
        let logs = try logsDir()
        try fm.createDirectory(at: logs, withIntermediateDirectories: true)
        let file = logs.appendingPathComponent("huge.log")
        try sparse(file, bytes: 6 * 1024 * 1024)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\nlast line\n".utf8))
        try handle.close()
        let lines = RunHistoryService.loadLog(file)
        XCTAssertEqual(lines.first?.text, "[truncated — showing tail]")
        XCTAssertEqual(lines.last?.text, "last line")
    }

    func testLaunchAgentTailReadRefusesALinkAndAFIFO() throws {
        let logs = try logsDir()
        try fm.createDirectory(at: logs, withIntermediateDirectories: true)
        let real = logs.appendingPathComponent("real.log")
        try Data("exit 0 after 1s\n".utf8).write(to: real)
        XCTAssertEqual(LaunchAgentService.parseLogTail(from: real).exitCode, 0)

        let linked = logs.appendingPathComponent("linked.log")
        try link(linked, to: real)
        XCTAssertNil(LaunchAgentService.parseLogTail(from: linked).exitCode)

        let pipe = logs.appendingPathComponent("pipe.log")
        try fifo(at: pipe)
        let exit = within { LaunchAgentService.parseLogTail(from: pipe).exitCode }
        XCTAssertNotNil(exit, "parseLogTail must not block on a FIFO")
        XCTAssertNil(exit ?? nil)
    }

    // MARK: - Per-run summary beside the log

    private func summaryURL(for log: URL) -> URL {
        log.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("snapshots/computers/summaries")
            .appendingPathComponent("summary_\(log.deletingPathExtension().lastPathComponent).json")
    }

    func testPartialRunSummaryIsReadOnlyFromARegularFile() throws {
        let logs = try logsDir()
        let log = logs.appendingPathComponent("run.log")
        let summary = summaryURL(for: log)
        try fm.createDirectory(at: summary.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        let partial = Data(#"{"status":"partial"}"#.utf8)
        try partial.write(to: summary)
        XCTAssertTrue(RunHistoryService.isPartialRun(logURL: log, logTailText: ""))

        let elsewhere = root.appendingPathComponent("elsewhere.json")
        try partial.write(to: elsewhere)
        try fm.removeItem(at: summary)
        try link(summary, to: elsewhere)
        XCTAssertFalse(RunHistoryService.isPartialRun(logURL: log, logTailText: ""))

        try fm.removeItem(at: summary)
        try fifo(at: summary)
        let result = within { RunHistoryService.isPartialRun(logURL: log, logTailText: "") }
        XCTAssertEqual(result, false, "a FIFO summary must be ignored without blocking")

        try fm.removeItem(at: summary)
        try sparse(summary, bytes: UInt64(BoundedFile.documentLimit) + 1)
        XCTAssertFalse(RunHistoryService.isPartialRun(logURL: log, logTailText: ""))
    }

    // MARK: - Run status file

    private func status(_ ws: URL, label: String) -> URL {
        ws.appendingPathComponent("automation/\(label)_status.json")
    }

    private static func lastRunSuccess(profile: String, label: String) -> Bool? {
        let schedule = Schedule(
            name: "n", profile: profile, schedule: "Daily 06:20", cadence: "custom",
            mode: .snapshotOnly, next: "—", last: "—", lastStatus: .ok, artifacts: [],
            enabled: true, launchAgentLabel: label)
        return LaunchAgentService.healthInputs(
            schedules: [schedule], statusProfile: nil).first?.lastRunSuccess
    }

    func testRunStatusFileRefusesALinkAFIFOAndAnOversizeFile() throws {
        let ws = try workspace()
        let label = "com.github.tonyyo11.jamf-reports-community.\(profile).daily"
        let file = status(ws, label: label)
        let body = Data(#"{"success": true, "finished_at": "2026-09-07T10:00:00Z"}"#.utf8)
        try fm.createDirectory(at: file.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try body.write(to: file)
        XCTAssertEqual(Self.lastRunSuccess(profile: profile, label: label), true)

        let elsewhere = ws.appendingPathComponent("automation/other.json")
        try body.write(to: elsewhere)
        try fm.removeItem(at: file)
        try link(file, to: elsewhere)
        XCTAssertNil(Self.lastRunSuccess(profile: profile, label: label))

        try fm.removeItem(at: file)
        try fifo(at: file)
        let profile = self.profile
        let fromFIFO = within { Self.lastRunSuccess(profile: profile, label: label) }
        XCTAssertNotNil(fromFIFO, "a FIFO status file must not block the read")
        XCTAssertNil(fromFIFO ?? nil)

        try fm.removeItem(at: file)
        try sparse(file, bytes: UInt64(BoundedFile.documentLimit) + 1)
        XCTAssertNil(Self.lastRunSuccess(profile: profile, label: label))
    }

    // MARK: - Retention marker

    private func retentionWorkspace() throws -> URL {
        let ws = try workspace()
        try "retention:\n  enabled: true\n  snapshot_keep_days: 30\n".write(
            to: ws.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
        return ws
    }

    func testRetentionMarkerFIFOIsNotReadAndDoesNotBlock() throws {
        let ws = try retentionWorkspace()
        try fifo(at: ws.appendingPathComponent(".retention-last"))
        let profile = self.profile
        let finished: Int? = within { SnapshotRetentionService.sweepIfDue(profile: profile) }
        XCTAssertNotNil(finished, "sweepIfDue must not block on a FIFO marker")
    }

    func testRetentionMarkerLinkToToday_DoesNotSkipTheSweep() throws {
        let ws = try retentionWorkspace()
        let today = DateFormatter()
        today.dateFormat = "yyyy-MM-dd"
        let target = root.appendingPathComponent("today.txt")
        try today.string(from: .testNoon).write(to: target, atomically: true, encoding: .utf8)
        try link(ws.appendingPathComponent(".retention-last"), to: target)
        // An old snapshot is archived only when the sweep runs.
        let dir = ws.appendingPathComponent("jamf-cli-data/computers", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let old = dir.appendingPathComponent("computers_20250101T000000.json")
        try "[]".write(to: old, atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -90 * 86_400)],
                             ofItemAtPath: old.path)
        SnapshotRetentionService.sweepIfDue(profile: profile, now: .testNoon)
        XCTAssertFalse(fm.fileExists(atPath: old.path), "a linked marker is not a record")
    }

    func testRetentionMarkerOversizeIsNotARecord() throws {
        let ws = try retentionWorkspace()
        try sparse(ws.appendingPathComponent(".retention-last"),
                   bytes: UInt64(BoundedFile.stateFileLimit) + 1)
        XCTAssertNil(BoundedFile.stateText(ws.appendingPathComponent(".retention-last")))
    }

    // MARK: - Cached snapshots (Audit screen)

    private func snapshotDir() throws -> URL {
        let dir = try workspace().appendingPathComponent("jamf-cli-data/audit", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testCachedSnapshotsSkipALinkAFIFOAndAnOversizeFile() async throws {
        let dir = try snapshotDir()
        let good = Data(#"[{"section":"summary"}]"#.utf8)
        try good.write(to: dir.appendingPathComponent("audit_20260101T000000.json"))
        let elsewhere = root.appendingPathComponent("elsewhere.json")
        try good.write(to: elsewhere)
        try link(dir.appendingPathComponent("audit_20260102T000000.json"), to: elsewhere)
        try fifo(at: dir.appendingPathComponent("audit_20260103T000000.json"))
        try sparse(dir.appendingPathComponent("audit_20260104T000000.json"),
                   bytes: UInt64(BoundedFile.snapshotLimit) + 1)

        let profile = self.profile
        let found = expectation(description: "snapshots read")
        let box = ResultBox<[CLIBridge.CachedJSONSnapshot]>()
        Task.detached { [box] in
            box.value = await CLIBridge().cachedJSONSnapshots(
                profile: profile, type: "audit", limit: 10)
            found.fulfill()
        }
        await fulfillment(of: [found], timeout: deadline)
        XCTAssertEqual(box.value?.map(\.data), [good])
    }

    // MARK: - Device-detail cache

    private func stub() throws -> URL {
        let stub = root.appendingPathComponent("stub-\(UUID().uuidString.prefix(6))")
        try "#!/bin/sh\nprintf '%s' '{\"id\":\"1\"}'\n".write(
            to: stub, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        return stub
    }

    private func detail(live stub: URL?) async -> CLIBridge.DeviceDetailResult? {
        let profile = self.profile
        let finished = expectation(description: "device detail")
        let box = ResultBox<CLIBridge.DeviceDetailResult>()
        Task.detached { [box] in
            box.value = await CLIBridge().singleDeviceDetail(
                profile: profile, deviceID: "C02TEST", cacheSubdir: "devices",
                jamfCLIArgs: { ["pro", "device", $0] }, locateJamfCLI: { stub })
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: deadline)
        return box.value
    }

    func testDeviceCacheIsNotReadThroughALinkAFIFOOrWhenOversize() async throws {
        _ = try workspace()
        let seeded = await detail(live: try stub())
        let cache = try XCTUnwrap(seeded?.cacheURL)
        let cached = await detail(live: nil)
        XCTAssertEqual(cached?.fromCache, true, "a regular cache is still read")

        let elsewhere = root.appendingPathComponent("elsewhere.json")
        try Data(#"{"id":"planted"}"#.utf8).write(to: elsewhere)
        try fm.removeItem(at: cache)
        try link(cache, to: elsewhere)
        let viaLink = await detail(live: nil)
        XCTAssertNil(viaLink)

        try fm.removeItem(at: cache)
        try fifo(at: cache)
        let viaFIFO = await detail(live: nil)
        XCTAssertNil(viaFIFO)

        try fm.removeItem(at: cache)
        try sparse(cache, bytes: UInt64(BoundedFile.deviceDetailLimit) + 1)
        let oversize = await detail(live: nil)
        XCTAssertNil(oversize)
    }

    // MARK: - 2.11 snapshot and manifest readers

    func testGroupSnapshotsAreNotReadFromAFIFOOrALink() throws {
        let dir = root.appendingPathComponent("groups", isDirectory: true)
        let pipe = dir.appendingPathComponent("searches.json")
        try fifo(at: pipe)
        let real = dir.appendingPathComponent("real.json")
        try Data("[]".utf8).write(to: real)
        let linked = dir.appendingPathComponent("linked.json")
        try link(linked, to: real)
        let snapshot = within {
            GroupInventoryService.load(
                searchesURL: pipe, computerGroupsURL: linked, mobileGroupsURL: nil)
        }
        XCTAssertEqual(snapshot?.decodedAnySource, false)
    }

    func testBackupManifestFIFOIsNotReadByTheProtectOrPruneReaders() throws {
        let backup = root.appendingPathComponent("backup", isDirectory: true)
        try fifo(at: backup.appendingPathComponent("manifest.json"))
        let finished = within { BackupProductResult.protect(inBackup: backup) == nil }
        XCTAssertEqual(finished, true)
    }

    func testLatestSnapshotAndEACandidatesRefuseAPlantedFIFO() throws {
        let kind = root.appendingPathComponent("ea-results", isDirectory: true)
        try fifo(at: kind.appendingPathComponent("ea-results_20991231T000000.json"))
        let dataDir: URL = root
        let threw = within {
            (try? ReportEngine.loadLatestSnapshotData(kind: "ea-results", dataDir: dataDir)) == nil
        }
        XCTAssertEqual(threw, true)
        let candidates = within { CollectedEACandidates.load(dataDir: dataDir, tracked: []) }
        XCTAssertEqual(candidates?.isEmpty, true)
    }

    private func logged(_ text: String) -> Bool {
        LogBuffer.shared.snapshot(minLevel: .debug, limit: 2000).contains { $0.message == text }
    }

    func testAFIFOAtTheSOFACacheReturnsQuicklyWithAWarning() throws {
        let dataDir = root.appendingPathComponent("sofa-data", isDirectory: true)
        try fifo(at: dataDir.appendingPathComponent("sofa/macos_data_feed.json"))
        let snapshot = try XCTUnwrap(within { SOFAFeedService.load(dataDir: dataDir) })
        XCTAssertEqual(snapshot.warnings, ["Could not decode SOFA cache for macos"])
        XCTAssertTrue(logged("macos_data_feed.json not read: not a regular file"))
    }

    func testAMobileListFIFOOrOversizeFileIsNotReadAndIsLogged() throws {
        let pipe = root.appendingPathComponent("mobile/list.json")
        try fifo(at: pipe)
        let snapshot = within {
            MobileFleetService.load(listURL: pipe, inventoryURL: nil, profilesURL: nil)
        }
        XCTAssertNotNil(snapshot)
        XCTAssertTrue(logged("list.json not read: not a regular file"))

        let big = root.appendingPathComponent("mobile/big.json")
        try Data("[]".utf8).write(to: big)
        XCTAssertNil(BoundedFile.readLogged(big, limit: 1, category: .collect))
        XCTAssertTrue(logged("big.json not read: over 0 MB"))
        XCTAssertEqual(BoundedFile.readLogged(big, limit: 2, category: .collect), Data("[]".utf8))
    }

    // MARK: - Daily summaries, run-in-progress probe, backup and snapshot manifests

    func testSummaryParseRefusesAFIFOALinkAndAnOversizeFile() throws {
        let dir = root.appendingPathComponent("summaries", isDirectory: true)
        let real = dir.appendingPathComponent("summary_2026-04-01.json")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = #"{"date":"2026-04-01","totalDevices":5,"source":"jamf-cli"}"#
        try Data(json.utf8).write(to: real)
        try link(dir.appendingPathComponent("summary_2026-04-02.json"), to: real)
        try fifo(at: dir.appendingPathComponent("summary_2026-04-03.json"))
        let big = dir.appendingPathComponent("summary_2026-04-04.json")
        try sparse(big, bytes: UInt64(SummaryJSONParser.maxSummaryFileBytes) + 1)
        XCTAssertThrowsError(try SummaryJSONParser.parse(big)) {
            XCTAssertEqual(($0 as? CocoaError)?.code, .fileReadTooLarge)
        }
        let dates = within { SummaryJSONParser.parseDirectory(dir).map(\.date) }
        XCTAssertEqual(dates, ["2026-04-01"])
    }

    func testRunInProgressProbeReadsAFIFOOrALinkAsNotRunning() throws {
        let logs = try logsDir()
        let pipe = logs.appendingPathComponent("pipe.log")
        try fifo(at: pipe)
        XCTAssertEqual(within { ScheduledRunRecorder.isRunInProgress(logURL: pipe) }, false)
        let real = logs.appendingPathComponent("real.log")
        try Data("x\n".utf8).write(to: real)
        let linked = logs.appendingPathComponent("linked.log")
        try link(linked, to: real)
        XCTAssertFalse(ScheduledRunRecorder.isRunInProgress(logURL: linked))
    }

    func testBackupLibraryReadsAFIFOOrOversizeManifestAsNoManifest() throws {
        let backups = try workspace().appendingPathComponent("backups", isDirectory: true)
        try fifo(at: backups.appendingPathComponent("20260601T214020/manifest.json"))
        let big = backups.appendingPathComponent("20260602T214020/manifest.json")
        try sparse(big, bytes: UInt64(BoundedFile.documentLimit) + 1)
        let profile = profile
        let labels = within { BackupLibrary().list(profile: profile).map(\.label) }
        XCTAssertEqual(labels, ["", ""])
    }

    func testSnapshotManifestReadsAFIFOOrLinkAsAbsentAndSkipsThem() throws {
        let kind = root.appendingPathComponent("data/computers", isDirectory: true)
        let snapshot = kind.appendingPathComponent("computers_20260601T000000.json")
        try fm.createDirectory(at: kind, withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: snapshot)
        try fifo(at: kind.appendingPathComponent(SnapshotManifest.fileName))
        let result = within { SnapshotManifest.verify(snapshot: snapshot, data: Data("[]".utf8)) }
        XCTAssertEqual(result, .absent)

        let flat = root.appendingPathComponent("flat", isDirectory: true)
        try fifo(at: flat.appendingPathComponent("summary_2026-04-01.json"))
        try link(flat.appendingPathComponent("summary_2026-04-02.json"), to: snapshot)
        try fifo(at: flat.appendingPathComponent("computers.last"))
        let flatDir: URL = flat
        XCTAssertEqual(within { SnapshotManifest.scanFlatDir(flatDir).unverified }, 0)
        XCTAssertEqual(within { SnapshotManifest.scanStateDir(flatDir).unverified }, 0)
    }

    // MARK: - The one snapshot reader (`BoundedFile.readLogged`) at its callers

    func testReadLoggedReadsARegularFileAndSaysNothingAboutAMissingOne() throws {
        let file = root.appendingPathComponent("snap/regular-gone.json")
        XCTAssertNil(BoundedFile.readLogged(file))
        XCTAssertFalse(logged("regular-gone.json not read: could not be read: No such file or directory"))
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("[1]".utf8).write(to: file)
        XCTAssertEqual(BoundedFile.readLogged(file), Data("[1]".utf8))
    }

    func testReadLoggedRefusesAFIFOAtTheNewestNameWithoutHangingAndNamesItThroughDisplayText() throws {
        let dir = root.appendingPathComponent("ddm-device-status", isDirectory: true)
        let pipe = dir.appendingPathComponent("ddm-device-status_20991231T000000\u{7}.json")
        try fifo(at: pipe)
        let url = try XCTUnwrap(FileManager.newestJSONFile(in: dir))
        let data = within { BoundedFile.readLogged(url) }
        XCTAssertEqual(data, .some(nil))
        XCTAssertTrue(logged("ddm-device-status_20991231T000000.json not read: not a regular file"))
        // A service behind the picker reads it as unreadable, not as an empty snapshot.
        let snapshot = try XCTUnwrap(within { DDMDeviceStatusService.load(url: url) })
        XCTAssertTrue(snapshot.readFailed)
    }

    func testReadLoggedRefusesALinkAndAnOversizeSnapshot() throws {
        let dir = root.appendingPathComponent("policy-status", isDirectory: true)
        let real = dir.appendingPathComponent("policy-status_20260601T000000.json")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: real)
        let linked = dir.appendingPathComponent("policy-status_20260602T000000.json")
        try link(linked, to: real)
        XCTAssertNil(BoundedFile.readLogged(linked))
        XCTAssertTrue(logged("policy-status_20260602T000000.json not read: could not be read: "
            + String(cString: strerror(ELOOP))))
        let big = dir.appendingPathComponent("policy-status_20260603T000000.json")
        try sparse(big, bytes: UInt64(BoundedFile.documentLimit) + 1)
        XCTAssertNil(BoundedFile.readLogged(big, limit: BoundedFile.documentLimit))
        XCTAssertTrue(logged("policy-status_20260603T000000.json not read: over 1 MB"))
    }

    func testDeviceDetailSidecarFIFOFallsBackToTheCacheFilesDate() throws {
        let cache = root.appendingPathComponent("device-detail/computer-1.json")
        try fm.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: cache)
        try fifo(at: cache.appendingPathExtension("meta"))
        let date = within { freshnessTimestamp(for: cache) }
        XCTAssertNotNil(date.flatMap { $0 })
    }

    func testBundleSeedingSkipsAFIFOSnapshotAndReadsTheRest() throws {
        let dir = root.appendingPathComponent("seed-data", isDirectory: true)
        try fifo(at: dir.appendingPathComponent("computers/computers_20991231T000000.json"))
        let count = within { DiagnosticRedactor().seedFromWorkspace(dir) }
        XCTAssertEqual(count, 0)
    }
}
