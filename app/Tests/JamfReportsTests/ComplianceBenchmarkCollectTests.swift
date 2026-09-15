import XCTest
@testable import JamfReports

/// `pro report compliance-rules` and `compliance-devices` need a benchmark title; collect
/// used to call them bare, so both exited 2 on every Platform API profile.
final class ComplianceBenchmarkSelectionTests: XCTestCase {

    private func data(_ text: String) -> Data { Data(text.utf8) }

    func testTitlesComeFromABareArray() throws {
        let selection = try XCTUnwrap(ReportEngine.benchmarkSelection(
            fromListOutput: data(#"[{"id":"1","title":"CIS Level 1"},{"id":"2","title":"STIG"}]"#),
            configured: []))
        XCTAssertEqual(selection.titles, ["CIS Level 1", "STIG"])
        XCTAssertEqual(selection.missing, [])
        XCTAssertEqual(selection.ambiguous, [])
    }

    func testTitlesComeFromTheBenchmarksEnvelope() throws {
        let selection = try XCTUnwrap(ReportEngine.benchmarkSelection(
            fromListOutput: data(#"{"benchmarks":[{"id":"1","title":"CIS Level 1"}]}"#),
            configured: []))
        XCTAssertEqual(selection.titles, ["CIS Level 1"])
    }

    /// jamf-cli matches a title exactly and case-sensitively.
    func testConfiguredTitlesNarrowTheListByExactMatch() throws {
        let selection = try XCTUnwrap(ReportEngine.benchmarkSelection(
            fromListOutput: data(#"[{"id":"1","title":"CIS Level 1"},{"id":"2","title":"STIG"}]"#),
            configured: ["STIG", "cis level 1", "Missing"]))
        XCTAssertEqual(selection.titles, ["STIG"])
        XCTAssertEqual(selection.missing, ["cis level 1", "Missing"])
    }

    /// Two benchmark IDs sharing a title: jamf-cli refuses the name as ambiguous.
    func testATitleHeldByTwoBenchmarksIsSetAside() throws {
        let list = #"[{"id":"1","title":"Dup"},{"id":"2","title":"Dup"},{"id":"3","title":"STIG"}]"#
        let selection = try XCTUnwrap(
            ReportEngine.benchmarkSelection(fromListOutput: data(list), configured: []))
        XCTAssertEqual(selection.titles, ["STIG"])
        XCTAssertEqual(selection.ambiguous, ["Dup"])
    }

    /// A title starting with "-" would be parsed as a jamf-cli flag in the report's
    /// positional slot, so it is excluded and reported separately, not merged into titles.
    func testALeadingDashTitleIsExcludedAndReportedAsUnsafe() throws {
        let list = #"[{"id":"1","title":"CIS Level 1"},{"id":"2","title":"--help"}]"#
        let selection = try XCTUnwrap(
            ReportEngine.benchmarkSelection(fromListOutput: data(list), configured: []))
        XCTAssertEqual(selection.titles, ["CIS Level 1"])
        XCTAssertEqual(selection.unsafe, ["--help"])
    }

    func testBlankOutputIsATenantWithNoBenchmarks() throws {
        let selection = try XCTUnwrap(
            ReportEngine.benchmarkSelection(fromListOutput: data("\n"), configured: []))
        XCTAssertEqual(selection.titles, [])
    }

    func testNonJSONListOutputIsRejected() {
        XCTAssertNil(ReportEngine.benchmarkSelection(
            fromListOutput: data("Usage: jamf-cli pro"), configured: []))
    }

    func testTheTitleGoesAheadOfTheFlags() {
        let base = ["-p", "p", "pro", "report", "compliance-rules", "--output", "json"]
        XCTAssertEqual(
            ReportEngine.benchmarkReportArguments(base, title: "CIS Level 1"),
            ["-p", "p", "pro", "report", "compliance-rules", "CIS Level 1", "--output", "json"])
    }

    func testMergedRowsCarryTheirBenchmark() throws {
        let merged = try XCTUnwrap(ReportEngine.mergedBenchmarkPayload([
            (title: "CIS", data: data(#"[{"rule":"FileVault","ruleId":"r1"}]"#)),
            (title: "STIG", data: data(#"[{"rule":"FileVault","ruleId":"r9"}]"#)),
        ]))
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: merged) as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["benchmark"] as? String }, ["CIS", "STIG"])
        XCTAssertEqual(rows.map { $0["ruleId"] as? String }, ["r1", "r9"])
    }

    /// No rows: jamf-cli prints "No rule stats found." to stderr and exits 0 with empty stdout.
    func testEmptyReportOutputAddsNoRows() throws {
        let merged = try XCTUnwrap(
            ReportEngine.mergedBenchmarkPayload([(title: "CIS", data: Data())]))
        XCTAssertEqual(String(decoding: merged, as: UTF8.self), "[]")
    }

    func testNonJSONReportOutputRejectsTheMerge() {
        XCTAssertNil(ReportEngine.mergedBenchmarkPayload([
            (title: "CIS", data: data(#"[{"rule":"a"}]"#)),
            (title: "STIG", data: data("Error: unknown flag")),
        ]))
    }
}

/// Runs collect's inventory tier against a stub that answers the benchmark list and the
/// per-title reports from files, and logs every argv it received.
final class ComplianceBenchmarkCollectTests: XCTestCase {

    private var root: URL!
    private var answers: URL!
    private let profile = "benchmarkcollect"

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("JRC-Bench-\(UUID().uuidString)", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("Jamf-Reports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspacesRoot.appendingPathComponent(profile, isDirectory: true),
            withIntermediateDirectories: true)
        answers = root.appendingPathComponent("answers", isDirectory: true)
        try FileManager.default.createDirectory(at: answers, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", workspacesRoot.path, 1)
        addTeardownBlock { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
        ProfileAuthMethod.invalidateCache()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    /// NOT named `jamf-cli` (codesign gate). Maps argv to answer files:
    ///   config list                       → answers/config (empty when absent)
    ///   compliance-benchmarks list        → answers/list
    ///   report compliance-rules <title>   → answers/rules-<title>
    ///   report compliance-devices <title> → answers/devices-<title>
    /// `<name>.exit` holds a non-zero exit code. Anything else prints [] and exits 0.
    private func makeStub() throws -> URL {
        let url = root.appendingPathComponent("stub-cli")
        let script = """
        #!/bin/sh
        A="\(answers.path)"
        printf '%s\\n' "$*" >> "$A/calls.log"
        emit() { f="$A/$1"; if [ -f "$f.exit" ]; then code=$(cat "$f.exit"); else code=0; fi; \\
                 [ -f "$f" ] && cat "$f"; exit "$code"; }
        case "$*" in
          "config list"*) emit config ;;
          *" compliance-benchmarks list "*) emit list ;;
          *" report compliance-rules "*)
            t=$(echo "$*" | sed -E 's/.* compliance-rules ([^ ]+) .*/\\1/'); emit "rules-$t" ;;
          *" report compliance-devices "*)
            t=$(echo "$*" | sed -E 's/.* compliance-devices ([^ ]+) .*/\\1/'); emit "devices-$t" ;;
          *) printf '[]'; exit 0 ;;
        esac
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func answer(_ name: String, _ body: String, exit code: Int? = nil) throws {
        try body.write(to: answers.appendingPathComponent(name), atomically: true, encoding: .utf8)
        if let code {
            try "\(code)".write(to: answers.appendingPathComponent("\(name).exit"),
                                atomically: true, encoding: .utf8)
        }
    }

    private func writeConfig(_ extra: String = "") throws {
        let ws = try XCTUnwrap(ProfileService.workspaceURL(for: profile))
        try ("jamf_cli:\n  profile: \"\(profile)\"\n" + extra).write(
            to: ws.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
    }

    private func calls() -> [String] {
        let url = answers.appendingPathComponent("calls.log")
        let log = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return log.split(separator: "\n").map(String.init)
    }

    private func collectInventory(
        onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void = { _ in }
    ) async throws {
        let stub = try makeStub()
        try await ReportEngine.collect(
            profile: profile, workspacePaths: WorkspacePaths.self,
            tiers: [.inventory], force: true, locateJamfCLI: { stub }, onLine: onLine)
    }

    private func rows(_ kind: String) throws -> [[String: Any]] {
        let dir = try WorkspacePaths.dataDir(for: profile).appendingPathComponent(kind)
        let file = try XCTUnwrap(FileManager.newestJSONFile(in: dir), "no \(kind) snapshot")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file))
        return try XCTUnwrap(object as? [[String: Any]])
    }

    func testEachBenchmarkIsCollectedByTitleAndMerged() async throws {
        try writeConfig()
        try answer("list", #"[{"id":"1","title":"CIS-L1"},{"id":"2","title":"STIG-High"}]"#)
        try answer("rules-CIS-L1", #"[{"rule":"FileVault","ruleId":"r1","passed":9,"failed":1}]"#)
        try answer("rules-STIG-High", #"[{"rule":"FileVault","ruleId":"r7","passed":5}]"#)
        try answer("devices-CIS-L1", "")
        try answer("devices-STIG-High", #"[{"device":"MacA","deviceId":"4","rulesFailed":2}]"#)

        try await collectInventory()

        let log = calls()
        XCTAssertEqual(log.filter { $0.contains("compliance-benchmarks list") }.count, 1,
                       "the benchmark list is fetched once per run, not once per kind")
        XCTAssertTrue(log.contains { $0.contains("compliance-rules CIS-L1 --output json") },
                      "\(log)")
        XCTAssertTrue(log.contains { $0.contains("compliance-devices STIG-High --output json") })
        XCTAssertFalse(log.contains { $0.contains("compliance-rules --output") },
                       "a bare report call exits 2 on every Platform API profile")
        XCTAssertEqual(try rows("compliance-rules").map { $0["benchmark"] as? String },
                       ["CIS-L1", "STIG-High"])
        XCTAssertEqual(try rows("compliance-devices").map { $0["benchmark"] as? String },
                       ["STIG-High"])
        let store = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
        XCTAssertNotNil(store.lastRun(report: "compliance-devices"))
        XCTAssertNil(store.failures(report: "compliance-rules"))
    }

    func testConfiguredBenchmarksLimitWhatIsCollected() async throws {
        try writeConfig("platform:\n  compliance_benchmarks:\n    - \"STIG-High\"\n")
        try answer("list", #"[{"id":"1","title":"CIS-L1"},{"id":"2","title":"STIG-High"}]"#)
        try answer("rules-STIG-High", "[]")
        try answer("devices-STIG-High", "[]")

        try await collectInventory()

        let log = calls()
        XCTAssertFalse(log.contains { $0.contains("CIS-L1") }, "\(log)")
        XCTAssertTrue(log.contains { $0.contains("compliance-rules STIG-High") })
    }

    func testAFailedListingFailsBothKindsWithItsExitCode() async throws {
        try writeConfig()
        try answer("list", "", exit: 5)

        try await collectInventory()

        XCTAssertFalse(calls().contains { $0.contains(" report compliance-") })
        let store = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
        for kind in ReportEngine.benchmarkReportKinds {
            XCTAssertEqual(store.lastFailureExitCode(for: kind), 5, kind)
        }
    }

    /// "Collected, the tenant has no benchmarks" must read differently from "never collected".
    func testATenantWithNoBenchmarksLandsEmptySnapshots() async throws {
        try writeConfig()
        try answer("list", "[]")

        try await collectInventory()

        XCTAssertEqual(try rows("compliance-rules").count, 0)
        XCTAssertEqual(try rows("compliance-devices").count, 0)
    }

    /// Exit 7: some sub-operations failed, but stdout carries valid JSON for the rest.
    /// The exit-code contract for 7 is "warn; save the returned partial data".
    func testAPartialTitleWarnsAndSavesWhatLanded() async throws {
        try writeConfig("platform:\n  compliance_benchmarks:\n    - \"STIG-High\"\n")
        try answer("list", #"[{"id":"1","title":"CIS-L1"},{"id":"2","title":"STIG-High"}]"#)
        try answer("rules-STIG-High", #"[{"rule":"FileVault","ruleId":"r7","passed":5}]"#, exit: 7)
        try answer("devices-STIG-High", "[]")
        let log = BenchmarkLogCollector()

        try await collectInventory(onLine: log.append)

        XCTAssertEqual(try rows("compliance-rules").map { $0["ruleId"] as? String }, ["r7"])
        XCTAssertTrue(
            log.texts.contains { $0.contains("compliance-rules: exit 7 (partial failure)") },
            "\(log.texts)")
    }

    /// Jamf Account cannot grant a tenant-level integration Compliance Benchmarks or Blueprints,
    /// so collect does not ask for them, says why, and records nothing.
    func testATenantLevelProfileSkipsBenchmarksAndBlueprints() async throws {
        try writeConfig()
        let row: [String: Any] = ["name": profile, "auth-method": "platform",
                                  "tenant-id": "00000000-0000-0000-0000-000000000000"]
        let config = try JSONSerialization.data(withJSONObject: [row])
        try answer("config", String(decoding: config, as: UTF8.self))
        try answer("list", #"[{"id":"1","title":"CIS-L1"}]"#)
        let log = BenchmarkLogCollector()

        try await collectInventory(onLine: log.append)

        let requested = calls()
        for command in ["compliance-benchmarks", "compliance-rules", "compliance-devices",
                        "blueprint-status"] {
            XCTAssertFalse(requested.contains { $0.contains(command) }, "\(command): \(requested)")
        }
        XCTAssertTrue(requested.contains { $0.contains("ddm-status") },
                      "DDM reporting still answered tenant credentials, so it is still collected")
        XCTAssertTrue(log.texts.contains {
            $0.contains("[skip] compliance-rules: needs a platform environment integration")
        }, "\(log.texts)")
        let store = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
        XCTAssertNil(store.failures(report: "compliance-rules"), "a skipped kind records nothing")
    }
}

/// Thread-safe collector for streamed log-line text — `onLine` is `@Sendable`,
/// so a plainly captured `var` is not.
private final class BenchmarkLogCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    /// Usable directly as an `onLine` handler.
    var append: @Sendable (CLIBridge.LogLine) -> Void {
        { line in
            self.lock.lock(); defer { self.lock.unlock() }
            self.lines.append(line.text)
        }
    }

    var texts: [String] {
        lock.lock(); defer { lock.unlock() }
        return lines
    }
}
