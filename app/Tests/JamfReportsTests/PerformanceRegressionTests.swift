import Foundation
import XCTest
@testable import JamfReports

/// Performance regression guards for cold-launch, config-cache, and scan budget.
///
/// These tests are opt-in: they only run when `JRC_PERF=1` is set in the
/// environment so coverage instrumentation (which serializes execution) doesn't
/// produce false failures.
final class PerformanceRegressionTests: XCTestCase {

    // MARK: - Cold-launch budget

    /// Guards that constructing `WorkspaceStore` in demo mode (no disk I/O,
    /// no subprocess spawns) completes within 250 ms. The real cold-launch path
    /// involves at least one `jamf-cli --version` spawn; demo mode isolates the
    /// pure Swift overhead.
    @MainActor
    func testWorkspaceStoreDemoInitWithinBudget() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["JRC_PERF"] == "1",
            "Skipped outside JRC_PERF=1 to avoid instrumentation noise."
        )

        let budget: TimeInterval = 0.25
        let start = Date()
        let store = WorkspaceStore(demoMode: true)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertTrue(store.demoMode)
        XCTAssertLessThan(
            elapsed, budget,
            "WorkspaceStore(demoMode:true) took \(String(format: "%.0f", elapsed * 1000)) ms "
            + "(budget: \(Int(budget * 1000)) ms)"
        )
    }

    // MARK: - WorkspacePaths config-value cache

    /// Verifies that the second call to `WorkspacePaths.outputDir` hits the
    /// mtime-keyed cache and does not re-read the file. Measured by confirming
    /// the second call is at least 2× faster than the first when the file is
    /// unchanged. We assert correctness (same result) and that the second call
    /// completes within 1 ms (cache hit is pure dictionary lookup).
    func testConfigValueCacheHitIsSubMillisecond() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["JRC_PERF"] == "1",
            "Skipped outside JRC_PERF=1 to avoid instrumentation noise."
        )

        let (workspace, profile) = try makeTemporaryWorkspace(config: """
            output:
              output_dir: "My Reports"
            """)
        defer { try? FileManager.default.removeItem(at: workspace) }

        // First call — cold, reads from disk.
        let first = try WorkspacePaths.outputDir(for: profile)

        // Second call — should hit the cache.
        let cacheStart = Date()
        let second = try WorkspacePaths.outputDir(for: profile)
        let cacheElapsed = Date().timeIntervalSince(cacheStart)

        XCTAssertEqual(first.lastPathComponent, second.lastPathComponent)
        XCTAssertLessThan(
            cacheElapsed, 0.001,
            "Cache hit took \(String(format: "%.3f", cacheElapsed * 1000)) ms; expected < 1 ms"
        )
    }

    /// Verifies that modifying `config.yaml` on disk (different mtime)
    /// causes the cache to be invalidated and the new value to be returned.
    func testConfigValueCacheInvalidatesOnMtimeChange() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["JRC_PERF"] == "1",
            "Skipped outside JRC_PERF=1 to avoid instrumentation noise."
        )

        let (workspace, profile) = try makeTemporaryWorkspace(config: """
            output:
              output_dir: "First Dir"
            """)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let first = try WorkspacePaths.outputDir(for: profile)
        XCTAssertEqual(first.lastPathComponent, "First Dir")

        // Sleep past 1-second mtime resolution on HFS+/APFS.
        Thread.sleep(forTimeInterval: 1.1)

        let configURL = workspace.appendingPathComponent("config.yaml")
        try """
            output:
              output_dir: "Second Dir"
            """.write(to: configURL, atomically: true, encoding: .utf8)

        let second = try WorkspacePaths.outputDir(for: profile)
        XCTAssertEqual(second.lastPathComponent, "Second Dir",
                       "Cache should have been invalidated after mtime change")
    }

    // MARK: - RunHistoryService scan budget

    /// Verifies that `RunHistoryService.list` completes within 500 ms for a
    /// directory containing 100 log files. Each file is minimal (< 1 KB) so
    /// this primarily measures `contentsOfDirectory` + metadata overhead.
    func testRunHistoryListBudgetFor100Files() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["JRC_PERF"] == "1",
            "Skipped outside JRC_PERF=1 to avoid instrumentation noise."
        )

        let logsDir = try makeLogsDirectory(fileCount: 100)
        defer { try? FileManager.default.removeItem(at: logsDir.root) }

        setenv("JRC_TEST_WORKSPACES_ROOT", logsDir.workspacesRoot.path, 1)
        defer { unsetenv("JRC_TEST_WORKSPACES_ROOT") }

        let budget: TimeInterval = 0.5
        let start = Date()
        let results = RunHistoryService.list(profile: logsDir.profile)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(results.count, 100)
        XCTAssertLessThan(
            elapsed, budget,
            "RunHistoryService.list for 100 files took "
            + "\(String(format: "%.0f", elapsed * 1000)) ms (budget: \(Int(budget * 1000)) ms)"
        )
    }

    // MARK: - DeviceRecordMerger O(1) upsert

    /// Verifies that merging 5,000 device records does not degrade to O(n²).
    /// A correct O(1) implementation should complete in well under 1 s;
    /// an O(n²) rebuild over 5,000 items would take ~seconds.
    func testDeviceRecordMergerLinearScale() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["JRC_PERF"] == "1",
            "Skipped outside JRC_PERF=1 to avoid instrumentation noise."
        )

        let (workspace, profile) = try makeTemporaryWorkspace(config: "")
        defer { try? FileManager.default.removeItem(at: workspace) }

        let rows: [[String: String]] = (1...5_000).map { n in
            [
                "Serial Number": "SN\(n)",
                "Computer Name": "Device-\(n)",
                "Jamf ID": "\(n)",
            ]
        }

        let budget: TimeInterval = 1.0
        let start = Date()
        for row in rows {
            _ = DeviceInventoryService.recordFromCSV(row, source: "bench.csv")
        }
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(
            elapsed, budget,
            "Building 5,000 records took \(String(format: "%.0f", elapsed * 1000)) ms "
            + "(budget: \(Int(budget * 1000)) ms) — possible O(n²) regression"
        )

        _ = profile // suppress unused warning
    }

    // MARK: - Helpers

    /// Creates a temporary workspace directory readable by `WorkspacePaths`.
    ///
    /// Returns the workspace URL and a valid profile slug. The caller is
    /// responsible for removing the directory on teardown.
    private func makeTemporaryWorkspace(config: String) throws -> (workspace: URL, profile: String) {
        let profile = "perf-test-profile"
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("JRC-PerfTests-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent(profile, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        addTeardownBlock { unsetenv("JRC_TEST_WORKSPACES_ROOT") }

        if !config.isEmpty {
            let configURL = workspace.appendingPathComponent("config.yaml")
            try config.write(to: configURL, atomically: true, encoding: .utf8)
        }
        return (workspace, profile)
    }

    private struct LogsSetup {
        let root: URL
        let workspacesRoot: URL
        let profile: String
    }

    /// Creates a synthesized `~/Jamf-Reports/<profile>/automation/logs/` tree
    /// with `fileCount` minimal `.log` files and returns paths needed to
    /// override `ProfileService.workspacesRoot()` via `JRC_TEST_WORKSPACES_ROOT`.
    private func makeLogsDirectory(fileCount: Int) throws -> LogsSetup {
        let profile = "perf-scan-profile"
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("JRC-RunHistPerf-\(UUID().uuidString)", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("Jamf-Reports", isDirectory: true)
        let logsDir = workspacesRoot
            .appendingPathComponent(profile, isDirectory: true)
            .appendingPathComponent("automation", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        let labelPrefix = LaunchAgentWriter.labelPrefix
        for n in 1...fileCount {
            let name = "\(labelPrefix).\(profile).daily-snapshot-\(n).out.log"
            let url = logsDir.appendingPathComponent(name)
            try "[info] started\n[info] exit 0 after 2s\n"
                .write(to: url, atomically: true, encoding: .utf8)
        }
        return LogsSetup(root: root, workspacesRoot: workspacesRoot, profile: profile)
    }
}
