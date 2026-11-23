import Foundation
import XCTest
@testable import JamfReports

/// The folders kept directly under the workspaces root (`_fleet-reports`,
/// `_archived-launchagents`), the per-kind folders below an archive root and the device-detail
/// cache are refused when a peer on a shared root plants a symbolic link at them.
final class RootLevelConfinementTests: XCTestCase {

    private let fm = FileManager.default
    private var base: URL!
    private var workspaces: URL!
    private var elsewhere: URL!

    override func setUpWithError() throws {
        base = fm.temporaryDirectory
            .appendingPathComponent("jrc-rootconf-\(UUID().uuidString.prefix(8))",
                                    isDirectory: true)
        workspaces = base.appendingPathComponent("Jamf-Reports", isDirectory: true)
        elsewhere = base.appendingPathComponent("elsewhere", isDirectory: true)
        try fm.createDirectory(at: workspaces, withIntermediateDirectories: true)
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", workspaces.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        try? fm.removeItem(at: base)
    }

    private func isEmpty(_ dir: URL) -> Bool {
        ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).isEmpty
    }

    private func link(_ url: URL, to target: URL) throws {
        try fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: url, withDestinationURL: target)
    }

    // MARK: - _fleet-reports

    func testASymlinkedFleetReportsFolderIsRefusedAndWritesNothing() throws {
        try link(workspaces.appendingPathComponent("_fleet-reports"), to: elsewhere)

        XCTAssertThrowsError(try FleetReportEmitter.consolidatedDir())
        let group = ReportGroup(name: "g", workspaces: ["a"])
        let summary = DailySummary(
            date: "2026-10-10", totalDevices: 10, fileVaultPct: 90, compliancePct: 80,
            staleCount: 1, osCurrentPct: nil, crowdstrikePct: nil, patchPct: nil,
            sipPct: nil, firewallPct: nil, gatekeeperPct: nil, securityScore: nil)
        XCTAssertThrowsError(try FleetReportEmitter.emit(
            group: group, lookbackDays: 1, timestamp: "t", summariesFor: { _ in [summary] }))
        XCTAssertThrowsError(try FleetWorkbookEmitter.emit(
            group: group, lookbackDays: 1, timestamp: "t", summariesFor: { _ in [summary] }))
        XCTAssertTrue(isEmpty(elsewhere))
    }

    func testAFleetLogPlantedAsASymlinkIsNotAppendedThrough() throws {
        let folder = workspaces.appendingPathComponent("_fleet-reports", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = elsewhere.appendingPathComponent("victim.txt")
        try "keep\n".write(to: target, atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(
            at: folder.appendingPathComponent("fleet-reports.log"), withDestinationURL: target)

        XCTAssertThrowsError(try FleetReportEmitter.appendLog("line", in: folder))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep\n")
    }

    /// A FIFO at the log path would block an open for writing until a reader showed up.
    func testAFifoAtTheFleetLogPathReturnsPromptlyAndWritesNothing() throws {
        let folder = workspaces.appendingPathComponent("_fleet-reports", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent("fleet-reports.log").path
        XCTAssertEqual(mkfifo(path, 0o600), 0)

        let started = Date()
        XCTAssertThrowsError(try FleetReportEmitter.appendLog("no reader", in: folder))

        let reader = open(path, O_RDONLY | O_NONBLOCK)
        XCTAssertGreaterThanOrEqual(reader, 0)
        defer { close(reader) }
        XCTAssertThrowsError(try FleetReportEmitter.appendLog("with reader", in: folder))
        var buffer = [UInt8](repeating: 0, count: 64)
        XCTAssertLessThanOrEqual(read(reader, &buffer, buffer.count), 0, "nothing was written")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testTheFleetLogAppendsPrivatelyAndEmptiesItselfWhenOverTheLimit() throws {
        let folder = try FleetReportEmitter.consolidatedDir()
        try FleetReportEmitter.appendLog("one", in: folder)
        try FleetReportEmitter.appendLog("two", in: folder)
        let log = folder.appendingPathComponent("fleet-reports.log")
        let lines = try String(contentsOf: log, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasSuffix(" one") && lines[1].hasSuffix(" two"), "\(lines)")
        let mode = try fm.attributesOfItem(atPath: log.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)

        try FleetReportEmitter.appendLog("three", in: folder, maxBytes: 10)
        let after = try String(contentsOf: log, encoding: .utf8)
        XCTAssertEqual(after.split(separator: "\n").count, 1)
        XCTAssertTrue(after.contains("three"))
    }

    // MARK: - Retired LaunchAgents

    /// The archive is per Mac, so a link planted at the workspaces root's old folder is moot.
    func testARetiredAgentIsArchivedInAppSupportAndItsPlistRemoved() throws {
        try link(workspaces.appendingPathComponent("_archived-launchagents"), to: elsewhere)
        let agents = base.appendingPathComponent("LaunchAgents", isDirectory: true)
        try fm.createDirectory(at: agents, withIntermediateDirectories: true)
        let label = "com.github.tonyyo11.jamf-reports-community.legacy.daily-report"
        let plist = agents.appendingPathComponent("\(label).plist")
        try PropertyListSerialization.data(
            fromPropertyList: ["Label": label, "ProgramArguments": ["/bin/true"]],
            format: .xml, options: 0).write(to: plist)

        let result = LaunchAgentService.archiveAndRemove(
            labels: [label], includingManaged: true, in: agents)

        XCTAssertEqual(result.removed, [label])
        XCTAssertEqual(result.archiveDir, LaunchAgentService.archivedAgentsDir())
        XCTAssertFalse(fm.fileExists(atPath: plist.path), "the plist is retired")
        let archived = try fm.contentsOfDirectory(
            atPath: LaunchAgentService.archivedAgentsDir().path)
        XCTAssertEqual(archived.count, 1)
        XCTAssertTrue(archived.first?.hasPrefix(label) == true)
        XCTAssertTrue(isEmpty(elsewhere))
    }

    // MARK: - Archive subfolders

    func testASymlinkedArchiveKindFolderArchivesNothing() throws {
        let data = base.appendingPathComponent("data", isDirectory: true)
        let kind = data.appendingPathComponent("computers", isDirectory: true)
        try fm.createDirectory(at: kind, withIntermediateDirectories: true)
        let old = kind.appendingPathComponent("computers_20200101T000000.json")
        try "[]".write(to: old, atomically: true, encoding: .utf8)
        let archive = base.appendingPathComponent("_archive", isDirectory: true)
        try link(archive.appendingPathComponent("jamf-cli-data/computers"), to: elsewhere)
        let policy = SnapshotRetentionService.Policy(
            enabled: true, mode: .archive, keepDays: 1, keepCount: 0, includeSummaries: false)
        let lines = LineBox()

        let result = SnapshotRetentionService.sweepWithResult(
            dataDir: data, summariesDir: nil, archiveRoot: archive, policy: policy,
            onLine: lines.add)

        XCTAssertEqual(result.acted, 0)
        XCTAssertEqual(result.failed, 1)
        XCTAssertTrue(fm.fileExists(atPath: old.path), "the snapshot stays where it is")
        XCTAssertTrue(isEmpty(elsewhere))
        let warnings = lines.all.filter {
            $0.hasPrefix("[warn] retention: jamf-cli-data/computers")
        }
        XCTAssertEqual(warnings.count, 1, "\(lines.all)")
    }

    /// A refused folder that no file is due for neither warns nor holds back the day's marker.
    func testARefusedArchiveKindFolderWithNothingDueFailsNothingAndStampsTheDay() throws {
        let workspace = workspaces.appendingPathComponent("retn", isDirectory: true)
        try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
        try """
        retention:
          enabled: true
          mode: archive
          snapshot_keep_days: 365
        """.write(to: workspace.appendingPathComponent("config.yaml"),
                  atomically: true, encoding: .utf8)
        let kind = workspace.appendingPathComponent("jamf-cli-data/computers", isDirectory: true)
        try fm.createDirectory(at: kind, withIntermediateDirectories: true)
        let stampFormatter = DateFormatter()
        stampFormatter.locale = Locale(identifier: "en_US_POSIX")
        stampFormatter.dateFormat = "yyyyMMdd'T'HHmmss"
        let recent = kind.appendingPathComponent(
            "computers_\(stampFormatter.string(from: Date())).json")
        try "[]".write(to: recent, atomically: true, encoding: .utf8)
        try link(workspace.appendingPathComponent("_archive/jamf-cli-data/computers"),
                 to: elsewhere)
        let lines = LineBox()

        let acted = SnapshotRetentionService.sweepIfDue(
            profile: "retn", onLine: lines.add)

        XCTAssertEqual(acted, 0)
        let marker = workspace.appendingPathComponent(".retention-last")
        XCTAssertTrue(fm.fileExists(atPath: marker.path), "no failure, so the day is stamped")
        XCTAssertFalse(lines.all.contains { $0.contains("is not used as an archive") },
                       "\(lines.all)")
        XCTAssertTrue(isEmpty(elsewhere))
    }

    func testARealArchiveKindFolderStillArchives() throws {
        let data = base.appendingPathComponent("data", isDirectory: true)
        let kind = data.appendingPathComponent("computers", isDirectory: true)
        try fm.createDirectory(at: kind, withIntermediateDirectories: true)
        try "[]".write(to: kind.appendingPathComponent("computers_20200101T000000.json"),
                       atomically: true, encoding: .utf8)
        let archive = base.appendingPathComponent("_archive", isDirectory: true)
        let policy = SnapshotRetentionService.Policy(
            enabled: true, mode: .archive, keepDays: 1, keepCount: 0, includeSummaries: false)

        let result = SnapshotRetentionService.sweepWithResult(
            dataDir: data, summariesDir: nil, archiveRoot: archive, policy: policy)

        XCTAssertEqual(result.acted, 1)
        XCTAssertTrue(fm.fileExists(atPath: archive.appendingPathComponent(
            "jamf-cli-data/computers/computers_20200101T000000.json").path))
    }
}

private final class LineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func add(_ line: CLIBridge.LogLine) { lock.lock(); stored.append(line.text); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return stored }
}

// MARK: - Device-detail cache

/// The cache lives in the profile's data folder, `jamf_cli.data_dir` included, and a link at its
/// kind folder is refused. The stubs are not named `jamf-cli` (`CLIBridge.codesignGate`).
@MainActor
final class DeviceCacheConfinementTests: XCTestCase {

    nonisolated(unsafe) private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeviceCacheConf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.appendingPathComponent("workspaces").path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        try super.tearDownWithError()
    }

    private func workspace(dataDir: String? = nil) throws -> (profile: String, url: URL) {
        let profile = "devcache-\(UUID().uuidString.prefix(8).lowercased())"
        let url = try XCTUnwrap(ProfileService.workspaceURL(for: profile))
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if let dataDir {
            try "jamf_cli:\n  data_dir: \(dataDir)\n".write(
                to: url.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
        }
        return (profile, url)
    }

    private func stub() throws -> URL {
        let stub = root.appendingPathComponent("stub-\(UUID().uuidString.prefix(6))")
        try "#!/bin/sh\nprintf '%s' '{\"id\":\"1\"}'\n".write(
            to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        return stub
    }

    private func fetch(_ profile: String, _ stub: URL) async -> CLIBridge.DeviceDetailResult? {
        await CLIBridge().singleDeviceDetail(
            profile: profile, deviceID: "C02TEST", cacheSubdir: "devices",
            jamfCLIArgs: { ["pro", "device", $0] }, locateJamfCLI: { stub })
    }

    func testTheCacheFollowsACustomDataDir() async throws {
        let (profile, workspace) = try workspace(dataDir: "custom-data")
        let result = await fetch(profile, try stub())

        let cache = try XCTUnwrap(result?.cacheURL)
        XCTAssertEqual(
            cache.deletingLastPathComponent().resolvingSymlinksInPath().path,
            workspace.appendingPathComponent("custom-data/devices")
                .resolvingSymlinksInPath().path)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent("jamf-cli-data").path))
    }

    /// A refused folder still gives a live lookup, with no cache read or written.
    func testASymlinkedCacheFolderIsRefusedButTheLookupRunsLive() async throws {
        let (profile, workspace) = try workspace()
        let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let data = workspace.appendingPathComponent("jamf-cli-data", isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: data.appendingPathComponent("devices"), withDestinationURL: elsewhere)
        let lines = LineBox()
        let liveStub = try stub()

        let result = await CLIBridge().singleDeviceDetail(
            profile: profile, deviceID: "C02TEST", cacheSubdir: "devices",
            jamfCLIArgs: { ["pro", "device", $0] }, locateJamfCLI: { liveStub },
            onLine: lines.add)

        let live = try XCTUnwrap(result)
        XCTAssertFalse(live.fromCache)
        XCTAssertNil(live.cacheURL)
        XCTAssertEqual(String(decoding: live.data, as: UTF8.self), #"{"id":"1"}"#)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path), [])
        XCTAssertEqual(lines.all.filter { $0.contains("cache folder is not used") }.count, 1)
    }

    /// A cache written under the fixed folder before the cache followed `data_dir` is still
    /// read, and nothing is written there or to the new folder by a read.
    func testACacheUnderTheOldFixedFolderIsReadWhenTheNewOneHasNone() async throws {
        let (profile, workspace) = try workspace()
        let seeded = await fetch(profile, try stub())
        let old = try XCTUnwrap(seeded?.cacheURL)
        XCTAssertTrue(old.path.contains("/jamf-cli-data/devices/"))
        try "jamf_cli:\n  data_dir: custom-data\n".write(
            to: workspace.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)

        let result = await CLIBridge().singleDeviceDetail(
            profile: profile, deviceID: "C02TEST", cacheSubdir: "devices",
            jamfCLIArgs: { ["pro", "device", $0] }, locateJamfCLI: { nil })

        let cached = try XCTUnwrap(result)
        XCTAssertTrue(cached.fromCache)
        XCTAssertEqual(cached.cacheURL?.standardizedFileURL, old.standardizedFileURL)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent("custom-data/devices").path))
    }

    func testTheOldFolderIsNotReadThroughALink() async throws {
        let (profile, workspace) = try workspace()
        let seeded = await fetch(profile, try stub())
        let old = try XCTUnwrap(seeded?.cacheURL).deletingLastPathComponent()
        let moved = root.appendingPathComponent("moved", isDirectory: true)
        try FileManager.default.moveItem(at: old, to: moved)
        try FileManager.default.createSymbolicLink(at: old, withDestinationURL: moved)
        try "jamf_cli:\n  data_dir: custom-data\n".write(
            to: workspace.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)

        let result = await CLIBridge().singleDeviceDetail(
            profile: profile, deviceID: "C02TEST", cacheSubdir: "devices",
            jamfCLIArgs: { ["pro", "device", $0] }, locateJamfCLI: { nil })

        XCTAssertNil(result)
    }
}
