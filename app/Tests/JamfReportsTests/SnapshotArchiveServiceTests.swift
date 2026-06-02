import XCTest
@testable import JamfReports

/// SnapshotArchiveService surfaces the workspace's snapshot families on the
/// Data Sources screen. Production showed the "summaries" family as
/// "0 snapshots / Zero KB" forever — the service only counted `.csv` files,
/// but Trends summaries are `summary_*.json`.
///
/// These tests exercise the internal file-discovery logic through the glob /
/// counting behavior using a fake workspace under the real workspaces root is
/// not possible in CI (paths are pinned to ~/Jamf-Reports), so they target the
/// pure helpers via a real temp directory + the service's family construction
/// through `families(profile:)` only when the profile root resolves.
final class SnapshotArchiveServiceTests: XCTestCase {

    func testJSONSummariesAreCountedAsSnapshots() throws {
        // The discovery logic counts files by extension; verify the rules via
        // the service's fixture-friendly seam: a temp dir structured like
        // <root>/snapshots/summaries/. WorkspacePathGuard pins roots to
        // ~/Jamf-Reports/<profile>, so this test builds a real (temporary)
        // profile workspace there and cleans it up.
        let profile = "snaptest\(Int.random(in: 10_000...99_999))"
        guard let root = WorkspacePathGuard.root(for: profile) else {
            throw XCTSkip("workspace root unavailable for test profile")
        }
        let summariesDir = root
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent("summaries", isDirectory: true)
        try FileManager.default.createDirectory(at: summariesDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        // Two JSON summaries + one CSV archive in the same family dir.
        try #"{"date":"2026-06-01","totalDevices":5,"staleCount":0,"source":"jamf-cli"}"#
            .write(to: summariesDir.appendingPathComponent("summary_2026-06-01.json"),
                   atomically: true, encoding: .utf8)
        try #"{"date":"2026-05-31","totalDevices":5,"staleCount":0,"source":"jamf-cli"}"#
            .write(to: summariesDir.appendingPathComponent("summary_2026-05-31.json"),
                   atomically: true, encoding: .utf8)
        try "a,b\n1,2"
            .write(to: summariesDir.appendingPathComponent("export_2026-06-01.csv"),
                   atomically: true, encoding: .utf8)

        let families = SnapshotArchiveService().families(profile: profile)
        let summaries = families.first { $0.name == "summaries" }

        XCTAssertEqual(summaries?.snapshotCount, 3, "JSON + CSV files must both count")
        XCTAssertGreaterThan(summaries?.totalBytes ?? 0, 0)
        XCTAssertNotNil(summaries?.latestDate)
        // Glob reflects the dominant extension (2 json vs 1 csv).
        XCTAssertEqual(summaries?.glob.hasSuffix(".json"), true)
        XCTAssertEqual(summaries?.usedBy, "Trends · Overview score cards")
    }
}
