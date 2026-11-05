import XCTest

@testable import JamfReports

final class WorkspaceMergePlanTests: XCTestCase {
    private var root: URL!
    private let src = "Cloud", tgt = "OnPrem"
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory
            .appendingPathComponent("jrc-merge-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        for name in [src, tgt] { try write("", name, "config.yaml") }
    }

    override func tearDownWithError() throws {
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        try? fm.removeItem(at: root)
    }

    private func write(_ text: String, _ ws: String, _ rel: String) throws {
        let url = root.appendingPathComponent(ws).appendingPathComponent(rel)
        try fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func plan() throws -> WorkspaceMergePlan {
        try WorkspaceMergePlan.make(source: src, target: tgt, root: root)
    }

    private func steps(_ p: WorkspaceMergePlan, _ area: WorkspaceMergePlan.Area)
        -> [WorkspaceMergePlan.Step] { p.steps.filter { $0.area == area } }

    func testSnapshotRules() throws {
        let d = "jamf-cli-data/computers/"
        try write("a", src, d + "computers_2026-01-01_000000.json")
        try write("b", src, d + "computers_2026-01-02_000000.json")
        try write("same", src, d + "computers_2026-01-03_000000.json")
        try write("same", tgt, d + "computers_2026-01-03_000000.json")
        try write("x", src, d + "computers_2026-01-04_000000.json")
        try write("y", tgt, d + "computers_2026-01-04_000000.json")
        let p = try plan()
        let counts = try XCTUnwrap(p.counts()[.snapshots])
        XCTAssertEqual(counts["copy"], 2)
        XCTAssertEqual(counts["skipIdentical"], 1)
        XCTAssertEqual(counts["archiveSource"], 1)
        let archived = try XCTUnwrap(steps(p, .snapshots).first { $0.action == .archiveSource })
        XCTAssertTrue(archived.archive?.contains("/archive/snapshots/computers/") == true)
        XCTAssertTrue(archived.archive?.hasPrefix(p.mergedFolder) == true)
    }

    func testSummaries() throws {
        try write("{}", src, "snapshots/summaries/summary_2026-01-01.json")
        try write("{}", src, "snapshots/summaries/summary_2026-01-02.json")
        try write("{}", tgt, "snapshots/summaries/summary_2026-01-02.json")
        let s = steps(try plan(), .summaries)
        XCTAssertEqual(s.filter { $0.action == .copy }.count, 1)
        let fill = try XCTUnwrap(s.first {
            if case .fillSummary = $0.action { return true }
            return false
        })
        XCTAssertTrue(fill.archive?.hasSuffix("summaries/target/summary_2026-01-02.json") == true)
        guard case .fillSummary(let sourceArchive) = fill.action else { return XCTFail() }
        XCTAssertTrue(sourceArchive.hasSuffix("summaries/source/summary_2026-01-02.json"))
    }

    func testStateNewerSourceWins() throws {
        let st = "jamf-cli-data/state/"
        try write("2026-02-01T00:00:00Z", src, st + "overview.last")
        try write("2026-01-01T00:00:00Z", tgt, st + "overview.last")
        try write("1 x", tgt, st + "overview.fail")
        try write("2026-01-01T00:00:00Z", src, st + "policies.last")
        try write("2026-02-01T00:00:00Z", tgt, st + "policies.last")
        try write("1 x", tgt, st + "policies.fail")
        let s = steps(try plan(), .state)
        XCTAssertEqual(s.filter { $0.action == .replaceState }.count, 1)
        XCTAssertTrue(s.contains {
            $0.action == .archiveTarget && $0.target.hasSuffix("overview.fail")
        })
        XCTAssertFalse(s.contains { $0.target.contains("policies") })
    }

    func testRunHistoryAndBackups() throws {
        try write("l", src, "automation/logs/a.log")
        try write("{}", src, "automation/x_status.json")
        try write("{}", src, "automation/.workspace-claim.json")
        try write("h", src, "automation/hosts/h.json")
        try write("1", src, "backups/scheduled-1/manifest.json")
        let p = try plan()
        let paths = steps(p, .runHistory).map(\.source)
        XCTAssertEqual(paths.count, 2)
        let archives = steps(p, .runHistory).compactMap(\.archive)
        XCTAssertTrue(archives.isEmpty)  // both absent from the target: plain copies
        XCTAssertFalse(paths.contains { $0.contains("claim") || $0.contains("hosts") })
        XCTAssertEqual(steps(p, .backups).map(\.action), [.copyFolder])
    }

    func testTailComesLastAndConfigKeys() throws {
        try write("a: 1\nprofiles:\n  x: y\n", src, "config.yaml")
        try write("a: 2\nb: 1\nprofiles:\n  x: z\n", tgt, "config.yaml")
        try write("x", src, "jamf-cli-data/computers/c_2026-01-01_000000.json")
        let p = try plan()
        XCTAssertEqual(p.differingConfigKeys, ["a", "b"])
        let tail = p.steps.suffix(7).map(\.action)
        XCTAssertEqual(tail, WorkspaceMergePlan.Tail.allCases.map { .tail($0) })
        XCTAssertFalse(p.steps.dropLast(7).contains {
            if case .tail = $0.action { true } else { false }
        })
    }

    func testOutsideFolderAndLinkRefused() throws {
        // /var and /tmp are refused as absolute folders, so the outside folder sits in home.
        let elsewhere = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("jrc-merge-outside-\(UUID().uuidString)")
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: elsewhere) }
        try write(
            "output:\n  allow_absolute_paths: true\njamf_cli:\n  data_dir: \"\(elsewhere.path)\"\n",
            src, "config.yaml")
        let outside = try plan().outsideSourceFolder
        XCTAssertEqual(outside.count, 1)
        XCTAssertTrue(outside[0].hasSuffix(elsewhere.lastPathComponent))

        try write("", src, "config.yaml")
        let kinds = root.appendingPathComponent("\(src)/jamf-cli-data")
        try fm.createDirectory(at: kinds, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: kinds.appendingPathComponent("computers"),
                                  withDestinationURL: elsewhere)
        XCTAssertThrowsError(try plan()) {
            guard case WorkspaceMergePlan.PlanError.unreadable = $0 else { return XCTFail("\($0)") }
        }
    }

    func testSameAndMissing() {
        XCTAssertThrowsError(try WorkspaceMergePlan.make(source: src, target: src, root: root)) {
            XCTAssertEqual($0 as? WorkspaceMergePlan.PlanError, .sameWorkspace)
        }
        XCTAssertThrowsError(try WorkspaceMergePlan.make(source: src, target: "Nope", root: root)) {
            XCTAssertEqual($0 as? WorkspaceMergePlan.PlanError, .noWorkspace("Nope"))
        }
    }

    func testRoundTrip() throws {
        try write("a", src, "jamf-cli-data/computers/c_2026-01-01_000000.json")
        try write("{}", src, "snapshots/summaries/summary_2026-01-02.json")
        try write("{}", tgt, "snapshots/summaries/summary_2026-01-02.json")
        let p = try plan()
        let back = try JSONDecoder().decode(WorkspaceMergePlan.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(back, p)
    }

    private func assertUnreadable(_ area: String, line: UInt = #line) {
        XCTAssertThrowsError(try plan(), line: line) {
            guard case WorkspaceMergePlan.PlanError.unreadable(let got, _) = $0 else {
                return XCTFail("\($0)", line: line)
            }
            XCTAssertEqual(got, area, line: line)
        }
    }

    func testRunHistoryArchivesKeepSubfolder() throws {
        try write("a", src, "automation/logs/a.log")
        try write("b", tgt, "automation/logs/a.log")
        try write("a", src, "automation/x_status.json")
        try write("b", tgt, "automation/x_status.json")
        let archives = steps(try plan(), .runHistory).compactMap(\.archive)
        XCTAssertEqual(archives.count, 2)
        XCTAssertTrue(archives.contains { $0.hasSuffix("archive/runHistory/logs/a.log") })
        XCTAssertTrue(archives.contains { $0.hasSuffix("archive/runHistory/status/x_status.json") })
    }

    func testReportsRule7() throws {
        let r = "Generated Reports/"
        try write("1", src, r + "new.xlsx")
        try write("2", src, r + "same.xlsx")
        try write("2", tgt, r + "same.xlsx")
        try write("3", src, r + "diff.xlsx")
        try write("4", tgt, r + "diff.xlsx")
        let counts = try XCTUnwrap(try plan().counts()[.reports])
        XCTAssertEqual(counts["copy"], 1)
        XCTAssertEqual(counts["skipIdentical"], 1)
        XCTAssertEqual(counts["archiveSource"], 1)
    }

    func testRefusedReportsFolderIsUnreadable() throws {
        let elsewhere = root.appendingPathComponent("elsewhere")
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        for ws in [src, tgt] {
            let link = root.appendingPathComponent("\(ws)/Generated Reports")
            try fm.createSymbolicLink(at: link, withDestinationURL: elsewhere)
            assertUnreadable("reports")
            try fm.removeItem(at: link)
        }
    }

    func testNonFileOrLinkedTargetIsRefused() throws {
        let name = "jamf-cli-data/computers/c_2026-01-01_000000.json"
        try write("a", src, name)
        try fm.createDirectory(
            at: root.appendingPathComponent("\(tgt)/\(name)"), withIntermediateDirectories: true)
        assertUnreadable("snapshots")
        try fm.removeItem(at: root.appendingPathComponent("\(tgt)/jamf-cli-data/computers"))

        let elsewhere = root.appendingPathComponent("elsewhere")
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let kind = root.appendingPathComponent("\(tgt)/jamf-cli-data/computers")
        try fm.createSymbolicLink(at: kind, withDestinationURL: elsewhere)
        assertUnreadable("computers")
    }

    func testUnreadableConfigIsRefused() throws {
        try fm.removeItem(at: root.appendingPathComponent("\(src)/config.yaml"))
        assertUnreadable("config")
    }

    func testStateKindOnlyTheTargetHasMakesNoSteps() throws {
        try write("2026-01-01T00:00:00Z", tgt, "jamf-cli-data/state/overview.last")
        try write("1 x", tgt, "jamf-cli-data/state/overview.fail")
        XCTAssertTrue(steps(try plan(), .state).isEmpty)
    }
}
