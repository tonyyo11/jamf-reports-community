import Foundation
import XCTest
@testable import JamfReports

/// A link a peer plants in a snapshot folder: the pickers drop it, which must not read as
/// "never collected" where the app claims something about the cache or the folder's age.
final class PlantedSnapshotTests: XCTestCase {

    private var root: URL!
    private var dataDir: URL {
        root.appendingPathComponent("acme/jamf-cli-data", isDirectory: true)
    }
    /// 2027-01-15; snapshot names are built from it, never from the clock.
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlantedSnapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        try? FileManager.default.removeItem(at: root)
    }

    private func folder(_ kind: String) throws -> URL {
        let dir = dataDir.appendingPathComponent(kind, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func plant(_ name: String, in dir: URL) throws {
        let target = root.appendingPathComponent("elsewhere.json")
        try "[]".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent(name), withDestinationURL: target)
    }

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var texts: [String] = []
        func add(_ text: String) { lock.withLock { texts.append(text) } }
        var all: [String] { lock.withLock { texts } }
    }

    private func failedCollect(kind: String) throws -> [String] {
        let lines = Lines()
        _ = try ReportEngine.recordUnlandedAttempt(
            kind: kind, exitCode: 1, data: Data(), useCachedData: true, dataDir: dataDir,
            stateStore: nil, collectStart: Date(timeIntervalSince1970: 1_800_000_000),
            onLine: { lines.add($0.text) })
        return lines.all
    }

    // MARK: - The collect's "using cached" claim

    func testAFailedCollectNamesALinkPlantedAtTheNewestJSONStamp() throws {
        let dir = try folder("computers")
        try "[]".write(to: dir.appendingPathComponent("computers_20260924T060000.json"),
                       atomically: true, encoding: .utf8)
        try plant("computers\u{7}_20260925T060000.json", in: dir)

        let warn = try XCTUnwrap(try failedCollect(kind: "computers").first {
            $0.hasPrefix("[warn] computers")
        })

        XCTAssertTrue(warn.contains(
            "cached snapshot not used (computers_20260925T060000.json: not a regular file)"), warn)
        XCTAssertFalse(warn.contains("using cached"), warn)
    }

    func testAFailedCollectKeepsItsWordingForRealAndMissingCaches() throws {
        let dir = try folder("computers")
        XCTAssertTrue(try failedCollect(kind: "computers").contains {
            $0.contains("no cached snapshot available")
        })
        try "[]".write(to: dir.appendingPathComponent("computers_20260924T060000.json"),
                       atomically: true, encoding: .utf8)
        XCTAssertTrue(try failedCollect(kind: "computers").contains {
            $0.contains("skipped (using cached)")
        })
    }

    func testAFailedCollectRefusesALinkedKindFolderWithOneWarning() throws {
        let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try "[]".write(to: elsewhere.appendingPathComponent("computers_20260924T060000.json"),
                       atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: dataDir.appendingPathComponent("computers"), withDestinationURL: elsewhere)

        let lines = try failedCollect(kind: "computers")

        XCTAssertEqual(lines.filter { $0.hasPrefix("[warn] computers is not used") }.count, 1,
                       "\(lines)")
        XCTAssertTrue(lines.contains { $0.contains("no cached snapshot available") }, "\(lines)")
    }

    /// The per-benchmark failure shares the note, so a planted link is named there too.
    func testAnUncollectableBenchmarkSelectionNamesAPlantedLink() throws {
        let kind = "compliance-rules"
        let dir = try folder(kind)
        try plant("\(kind)_20260925T060000.json", in: dir)
        let lines = Lines()
        let selection = ReportEngine.BenchmarkSelection(
            titles: [], missing: ["X"], ambiguous: [], listed: [])

        _ = try ReportEngine.recordUncollectableSelection(
            kind: kind, selection: selection, configuredTitles: ["X"], dataDir: dataDir,
            useCachedData: true, stateStore: nil,
            collectStart: Date(timeIntervalSince1970: 1_800_000_000),
            onLine: { lines.add($0.text) })

        let warn = try XCTUnwrap(lines.all.first { $0.hasPrefix("[warn] \(kind)") })
        XCTAssertTrue(warn.contains("\(kind)_20260925T060000.json: not a regular file"), warn)
        XCTAssertFalse(warn.contains("using cached"), warn)
    }

    // MARK: - Freshness

    private func age(_ kind: String = "policy-status") -> TimeInterval? {
        WorkspaceStore.newestSnapshotAge(profile: "acme", kind: kind, now: now)
    }

    private func land(_ kind: String, secondsAgo: TimeInterval) throws {
        let dir = try folder(kind)
        let name = "\(kind)_\(stamp(secondsAgo: secondsAgo)).json"
        try "[]".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func testALinkDoesNotMakeAKindLookFresh() throws {
        try plant("policy-status_\(stamp(secondsAgo: 0)).json", in: try folder("policy-status"))
        XCTAssertNil(age())

        try land("policy-status", secondsAgo: 86_400)
        XCTAssertEqual(try XCTUnwrap(age()), 86_400, accuracy: 1,
                       "the regular file's stamp, not the link's")
    }

    func testTheAgeIsTheStampNotARestampedMtime() throws {
        try land("policy-status", secondsAgo: 172_800)
        XCTAssertEqual(try XCTUnwrap(age()), 172_800, accuracy: 1)
    }

    /// A peer can name a file for the year 2999; it must not make the kind fresh for good.
    func testAFileStampedFarInTheFutureIsLeftOut() throws {
        let dir = try folder("policy-status")
        try "[]".write(to: dir.appendingPathComponent("policy-status_29991231T000000.json"),
                       atomically: true, encoding: .utf8)
        XCTAssertNil(age(), "the future file alone is no snapshot")

        try land("policy-status", secondsAgo: 172_800)
        XCTAssertEqual(try XCTUnwrap(age()), 172_800, accuracy: 1)

        try land("policy-status", secondsAgo: -SharedWorkspace.clockSkewTolerance / 2)
        XCTAssertEqual(try XCTUnwrap(age()), 0, accuracy: 1,
                       "a stamp within the skew tolerance still counts, clamped to now")
    }

    private func stamp(secondsAgo: TimeInterval) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: now.addingTimeInterval(-secondsAgo))
    }

    // MARK: - jamf-cli's config file

    func testTheConfigTextIsBoundedAndNeedsAFile() throws {
        let file = root.appendingPathComponent("config.yaml")
        try "profiles:\n  a:\n    url: https://x\n"
            .write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(ProfileService.readConfigFileText(at: file)?.hasPrefix("profiles:"), true)

        try Data(repeating: 0x20, count: ProfileService.maxConfigFileBytes + 1).write(to: file)
        XCTAssertNil(ProfileService.readConfigFileText(at: file))
        XCTAssertNil(ProfileService.readConfigFileText(at: root), "a folder is not read")
        XCTAssertNil(ProfileService.readConfigFileText(at: nil))
    }

    /// The bundle's scope-ID redaction used to read the file unbounded.
    func testTheBundleReadsTheConfigThroughTheBoundedReader() throws {
        let file = root.appendingPathComponent("config.yaml")
        let padding = String(repeating: "\n", count: ProfileService.maxConfigFileBytes + 1)
        try (padding + "profiles:\n  acme:\n    tenant-id: abc\n")
            .write(to: file, atomically: true, encoding: .utf8)
        let ids = DiagnosticBundleService.scopeIDs(
            profile: "acme", configURL: file,
            connections: ConnectionStore(url: root.appendingPathComponent("connections.json")))
        XCTAssertEqual(ids, [])
    }
}
