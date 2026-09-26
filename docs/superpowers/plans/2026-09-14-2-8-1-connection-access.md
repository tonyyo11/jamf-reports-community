# 2.8.1 Connection Access Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Compliance Benchmarks collect on Jamf Platform API profiles, setup catches a wrong
environment or tenant ID, and a data source that fails for a permission or scope reason says so
and stops being retried hourly.

**Architecture:** Collect lists benchmarks once per run, runs both compliance reports per title,
and saves merged rows tagged with their benchmark. A pure `FailureCause` classifier reads
jamf-cli's JSON error envelope; collect stores the cause beside the failure counter, Run History
and the health banner name it, self-remediation skips permanent causes, and a dead run's message
uses it. A pure `ConnectionCheck` verdict plus a thin runner asks the gateway two questions when a
Platform API profile validates. A run counts as dead when nothing landed, whatever the exit codes.

**Tech Stack:** Swift 6 / SwiftUI, macOS 15+, SwiftPM, XCTest; jamf-cli floor 1.18.0, tracked 1.29.0.

**Spec:** `docs/superpowers/specs/2026-09-12-connection-access-and-setup-design.md` — this plan
implements §9.1–9.3, §9.5, §9.6, §10.1 (cause in the detail line), §10.3 (Run History hint), the
§10.4 connection check and setup copy, and §13 defects 1 and 2. Everything else in the spec is the
2.9.0 plan.

## Global Constraints

- Branch `fix/2-8-1-connection-access` from `origin/main` (f5611d0, v2.8.0). Never stack on
  `docs/platform-access-wiki`. Every source file this plan edits is identical between that docs
  branch's base (76a48e5) and `origin/main`, so the line numbers below hold on main.
- jamf-cli floor 1.18.0, tracked 1.29.0. A command spelling that changed in 1.29 gates on
  `JamfCLIInstaller.supportsSpecDerivedNames(_:)` (true only for a confirmed ≥ 1.29.0).
- macOS 15+, Swift 6 strict concurrency, and it must compile on Swift 6.1 (CI's Xcode 16.4):
  statics on a `View` that tests call are `nonisolated static`.
- ≤100-character lines, no force unwraps in production code, functions ≤100 lines.
- A jamf-cli test stub must not be named `jamf-cli` (`CLIBridge.codesignGate` keys on that name).
- Fixtures: envelope keys (`error`, `message`, `exitCode`, `exitCodeName`, `hint`) are jamf-cli
  1.29.0's `formatErrorTo`. Message text is the tester's log with trace and environment IDs
  replaced by zeros, or the jamf-cli source strings quoted in spec §6.1 where no capture exists.
  Never invent a key. Replace source-derived strings with scrubbed captures when the tester's
  spec §16 checks come back.
- Tasks 2 and 5 change SwiftUI layout. Their commit bodies carry
  `DRAFT — needs visual verification at PageScaffold.minSupportedWidth`.
- Commit per task. No `Co-Authored-By` trailer. Push and PR only when Tony says.
- Never run two `swift test` processes at once (shared `.build` deadlocks both). Build gate:
  `cd app && swift build --build-tests 2>&1 | grep "error:" || echo OK`. Read the test log's
  `Executed N tests, with M failures` line; a pipe's exit status is not the result.
- The version bump (`MARKETING_VERSION` in `app/build-app.sh` and
  `AppVersionState.fallbackVersion`) and the CHANGELOG roll happen at the release cut, not here.
- Decided in this plan, differing from the spec:
  1. §9.6 rejected-ID wording fires when **any** failure in a dead run is cause 1 or 2 (spec:
     every). Jamf Pro commands on a gateway profile drop the 404 body (spec §14.1), so on a
     profile that reports on Jamf Pro "every" can never hold.
  2. §9.6 "points to Data Sources > Access" points to the Permissions & Access wiki page instead;
     the Access card is 2.9.0.
  3. §9.2 rule 5 "else from the table": names stay empty until the requirements table (2.9.0).
  4. §9.4 source states (Not granted, Access lost, first-failure threshold for causes 1–2) are
     2.9.0. 2.8.1 records causes, names them, and excludes permanent ones from remediation.
  5. §10.4: 2.8.1 adds the connection check and rewrites the instruction copy. The region picker,
     scope-level changes, permission checklist and existing-CLI setup adoption are 2.9.0.
  6. `ConnectionCheck` runs jamf-cli through a `CLIBridge.runAndCapture` closure, not
     `CLIExecutor`: the executor throws away stdout on a non-zero exit, and stdout is where the
     error envelope is.
  7. `pro compliance-benchmarks list --output json` is a generated command whose exact output was
     not captured (no Platform tenant). The parser accepts a bare array or `{"benchmarks": [...]}`.
     Add "benchmark list output" to spec §16 for the tester.
- Out of scope, noted for 2.9.0: `pro report blueprint-status` and `ddm-status` also print nothing
  to stdout when a tenant has no data ("No blueprints found." / "No DDM declaration data found." on
  stderr, exit 0), so both read as failing on such a tenant — the same shape Task 1 fixes for the
  compliance reports.

## File Structure

| File | Change | Responsibility |
|---|---|---|
| `app/Sources/JamfReports/Engine/ReportEngine+ComplianceBenchmarks.swift` | Create | Benchmark discovery, per-title reports, merge |
| `app/Sources/JamfReports/Services/FailureCause.swift` | Create | `JamfCLIErrorEnvelope`, `FailureCause`, `ForbiddenStderrWatcher` |
| `app/Sources/JamfReports/Services/ConnectionCheck.swift` | Create | Scope-ID verdict and runner |
| `app/Sources/JamfReports/Views/ConnectionCheckBanner.swift` | Create | Verdict banner shared by two screens |
| `app/Sources/JamfReports/Engine/ReportEngine.swift` | Modify | Loop dispatch, unlanded-attempt helper, cause capture, dead-run cause, verdict |
| `app/Sources/JamfReports/Services/StateFileStore.swift` | Modify | `<kind>.cause.json` |
| `app/Sources/JamfReports/Services/DataFreshnessHealth.swift` | Modify | Cause on state and issue |
| `app/Sources/JamfReports/Services/WorkspaceStore+Automation.swift` | Modify | Remediation exclusion |
| `app/Sources/JamfReports/Theme/GlobalHealthBanner.swift` | Modify | Cause in the detail line |
| `app/Sources/JamfReports/Services/CLIBridge.swift` | Modify | Exit 3/5 wording, dead-run routing |
| `app/Sources/JamfReports/Services/OnboardingFlow.swift` | Modify | Run and apply the check |
| `app/Sources/JamfReports/Views/OnboardingView.swift` | Modify | Banner, bypass rule, setup copy |
| `app/Sources/JamfReports/Views/ReauthenticateSheet.swift` | Modify | Banner |
| `app/Sources/JamfReports/Views/ProductConnectSheetView.swift` | Modify | Protect copy |
| `app/Sources/JamfReports/Services/ComplianceBenchmarksService.swift` | Modify | Benchmark field, filter |
| `app/Sources/JamfReports/Views/ComplianceBenchmarksView.swift` | Modify | Picker, empty-state commands |
| `app/Sources/JamfReports/Engine/CoreDashboard.swift` | Modify | Benchmark column |

Task order: 1 benchmark collection · 2 benchmark screen and workbook · 3 `FailureCause` ·
4 `ConnectionCheck` · 5 check in onboarding and Update credentials · 6 cause file and remediation ·
7 cause capture in collect · 8 banner names the cause · 9 dead-run cause and exit wording ·
10 nothing landed is dead · 11 docs and full gate.

---

### Task 1: Collect Compliance Benchmarks per benchmark title

`pro report compliance-rules` and `compliance-devices` take a required `<benchmark-title>`
(cobra `ExactArgs(1)`). The collect matrix calls them bare, so both exit 2 on every Platform API
profile. jamf-cli resolves the title against `pro compliance-benchmarks list` by exact,
case-sensitive match on `title`, and refuses a title held by two benchmark IDs as ambiguous. With
no rows, both reports print a note to stderr and exit 0 with empty stdout.

**Files:**
- Create: `app/Sources/JamfReports/Engine/ReportEngine+ComplianceBenchmarks.swift`
- Modify: `app/Sources/JamfReports/Engine/ReportEngine.swift` — loop at 1781 and 1819–1829;
  `KindCollectResult` 2168; `collectOneKind` body 2214–2255; `invokeWithRetry` 2262;
  `saveCollectedPayload` 2314
- Create: `app/Tests/JamfReportsTests/ComplianceBenchmarkCollectTests.swift`

**Interfaces:**
- Consumes: `ReportEngine.jsonPayload(from:)`, `invokeWithRetry`, `saveCollectedPayload`,
  `launchFailureExitCode`, `ReportConfig.platform?.benchmarkTitles`.
- Produces:
  - `ReportEngine.benchmarkReportKinds: Set<String>`
  - `ReportEngine.BenchmarkSelection { titles, missing, ambiguous: [String] }`
  - `ReportEngine.BenchmarkDiscovery` (`.selected`, `.failed(exitCode:data:)`, `.launchFailed`)
  - `ReportEngine.benchmarkSelection(fromListOutput: Data, configured: [String]) -> BenchmarkSelection?`
  - `ReportEngine.benchmarkReportArguments(_ base: [String], title: String) -> [String]`
  - `ReportEngine.mergedBenchmarkPayload(_ pieces: [BenchmarkPiece]) -> Data?`
  - `static func recordUnlandedAttempt(kind:exitCode:data:useCachedData:dataDir:stateStore:collectStart:onLine:) throws -> KindCollectResult`
    (Task 7 adds `sawForbidden:` and the cause)
  - `KindCollectResult`, `invokeWithRetry`, `saveCollectedPayload` become internal.

- [ ] **Step 1: Write the failing pure tests**

Create `app/Tests/JamfReportsTests/ComplianceBenchmarkCollectTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the tests to confirm they fail**

Run: `cd app && swift test --filter ComplianceBenchmarkSelectionTests 2>&1 | tail -20`
Expected: compile error, `type 'ReportEngine' has no member 'benchmarkSelection'`.

- [ ] **Step 3: Add the pure helpers**

Create `app/Sources/JamfReports/Engine/ReportEngine+ComplianceBenchmarks.swift`:

```swift
import Foundation

/// `pro report compliance-rules` and `compliance-devices` need a benchmark title (cobra
/// `ExactArgs(1)`); called bare they exit 2 on every Platform API profile. Collect lists the
/// tenant's benchmarks once per run, runs both reports per title, and saves one snapshot per
/// kind whose rows carry a `benchmark` field.
extension ReportEngine {

    static let benchmarkReportKinds: Set<String> = ["compliance-rules", "compliance-devices"]

    typealias BenchmarkPiece = (title: String, data: Data)

    struct BenchmarkSelection: Equatable, Sendable {
        let titles: [String]
        /// Listed in `platform.compliance_benchmarks` but not on the tenant.
        let missing: [String]
        /// Held by more than one benchmark ID; jamf-cli refuses these by name.
        let ambiguous: [String]
    }

    /// The once-per-run benchmark listing, shared by both compliance kinds.
    enum BenchmarkDiscovery: Sendable {
        case selected(BenchmarkSelection)
        case failed(exitCode: Int32, data: Data)
        case launchFailed
    }

    static func benchmarkListArguments(profile: String) -> [String] {
        ["-p", profile, "pro", "compliance-benchmarks", "list", "--output", "json"]
    }

    /// Titles from `compliance-benchmarks list`, narrowed to `configured` when it is set.
    /// nil when the output is neither a JSON array nor `{"benchmarks": [...]}`.
    static func benchmarkSelection(
        fromListOutput data: Data, configured: [String]
    ) -> BenchmarkSelection? {
        guard let items = benchmarkListItems(data) else { return nil }
        var idsByTitle: [String: Set<String>] = [:]
        var listed: [String] = []
        for (index, item) in items.enumerated() {
            guard let title = item["title"] as? String, !title.isEmpty else { continue }
            if idsByTitle[title] == nil { listed.append(title) }
            idsByTitle[title, default: []].insert(item["id"] as? String ?? "row-\(index)")
        }
        let ambiguous = listed.filter { (idsByTitle[$0]?.count ?? 0) > 1 }
        let usable = listed.filter { !ambiguous.contains($0) }
        guard !configured.isEmpty else {
            return BenchmarkSelection(titles: usable, missing: [], ambiguous: ambiguous)
        }
        return BenchmarkSelection(
            titles: configured.filter { usable.contains($0) },
            missing: configured.filter { idsByTitle[$0] == nil },
            ambiguous: ambiguous.filter { configured.contains($0) }
        )
    }

    /// Inserts `title` as the report's positional argument, ahead of its flags.
    static func benchmarkReportArguments(_ base: [String], title: String) -> [String] {
        var arguments = base
        let flags = base.firstIndex { $0.hasPrefix("--") } ?? base.endIndex
        arguments.insert(title, at: flags)
        return arguments
    }

    /// Per-title report outputs as one JSON array, each row tagged with its benchmark.
    /// Blank output is an empty report. nil when any output is not a JSON array.
    static func mergedBenchmarkPayload(_ pieces: [BenchmarkPiece]) -> Data? {
        var rows: [[String: Any]] = []
        for piece in pieces where !isBlank(piece.data) {
            guard let payload = jsonPayload(from: piece.data),
                  let items = try? JSONSerialization.jsonObject(with: payload) as? [[String: Any]]
            else { return nil }
            for var row in items {
                row["benchmark"] = piece.title
                rows.append(row)
            }
        }
        return try? JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
    }

    private static func benchmarkListItems(_ data: Data) -> [[String: Any]]? {
        guard !isBlank(data) else { return [] }
        guard let payload = jsonPayload(from: data),
              let object = try? JSONSerialization.jsonObject(with: payload) else { return nil }
        if let array = object as? [[String: Any]] { return array }
        return (object as? [String: Any])?["benchmarks"] as? [[String: Any]]
    }

    /// Whitespace only — what jamf-cli leaves on stdout for an empty report.
    private static func isBlank(_ data: Data) -> Bool {
        data.allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }
    }
}
```

- [ ] **Step 4: Run the pure tests**

Run: `cd app && swift test --filter ComplianceBenchmarkSelectionTests 2>&1 | tail -20`
Expected: `Executed 10 tests, with 0 failures`.

- [ ] **Step 5: Write the failing collect tests**

Append to `ComplianceBenchmarkCollectTests.swift`:

```swift
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

    private func collectInventory() async throws {
        let stub = try makeStub()
        try await ReportEngine.collect(
            profile: profile, workspacePaths: WorkspacePaths.self,
            tiers: [.inventory], force: true, locateJamfCLI: { stub }, onLine: { _ in })
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
}
```

- [ ] **Step 6: Run the collect tests to confirm they fail**

Run: `cd app && swift test --filter ComplianceBenchmarkCollectTests 2>&1 | tail -30`
Expected: 4 failures — no `compliance-benchmarks list` call, and a bare
`compliance-rules --output json` in the log.

- [ ] **Step 7: Open three declarations to the extension file**

In `app/Sources/JamfReports/Engine/ReportEngine.swift` delete the word `private` from exactly these
three lines, nothing else:

```swift
    private struct KindCollectResult: Sendable {          // line 2168
    private static func invokeWithRetry(                  // line 2262
    private static func saveCollectedPayload(             // line 2314
```

- [ ] **Step 8: Extract the unlanded-attempt branches**

In `collectOneKind`, replace everything from `let outcome = CollectOutcome(kind: kind, exitCode: exitCode)`
(line 2214) through the function's closing brace (line 2256) with:

```swift
        let outcome = CollectOutcome(kind: kind, exitCode: exitCode)
        let isPartialFailure = exitCode == CLIBridge.exitCodePartialFailure
        guard exitCode == 0 || isPartialFailure, !data.isEmpty else {
            return try Self.recordUnlandedAttempt(
                kind: kind, exitCode: exitCode, data: data, useCachedData: useCachedData,
                dataDir: dataDir, stateStore: stateStore, collectStart: collectStart,
                onLine: onLine
            )
        }
        return try Self.saveCollectedPayload(
            kind: kind, data: data, outcome: outcome,
            isPartialFailure: isPartialFailure, dataDir: dataDir,
            recordManifest: recordManifest, stateStore: stateStore,
            collectStart: collectStart, onLine: onLine
        )
    }

    /// An attempt that produced nothing to save: count it, say why, and keep the cache, or
    /// fail the run under `use_cached_data: false`. Shared with the per-benchmark reports.
    static func recordUnlandedAttempt(
        kind: String,
        exitCode: Int32,
        data: Data,
        useCachedData: Bool,
        dataDir: URL,
        stateStore: StateFileStore?,
        collectStart: Date,
        onLine: @Sendable (CLIBridge.LogLine) -> Void
    ) throws -> KindCollectResult {
        let outcome = CollectOutcome(kind: kind, exitCode: exitCode)
        guard useCachedData else {
            stateStore?.record(.failed(exitCode: exitCode), report: kind, at: collectStart)
            onLine(.init(
                timestamp: Date(), level: .fail,
                text: "[error] \(kind): exit \(exitCode) — failing (use_cached_data=false)"
            ))
            throw ReportEngineError.collectFailed(kind: kind, exitCode: exitCode)
        }
        // Only claim "using cached" when a cached snapshot for this kind exists; otherwise
        // the generate step has nothing to fall back to and the copy would mislead.
        let kindDir = dataDir.appendingPathComponent(kind, isDirectory: true)
        let cacheNote = FileManager.newestJSONFile(in: kindDir) != nil
            ? "skipped (using cached)"
            : "no cached snapshot available"
        // Persisting the failure is what lets DataFreshnessHealth report a kind that has
        // failed nightly for months without anyone opening its screen.
        stateStore?.record(.failed(exitCode: exitCode), report: kind, at: collectStart)
        // jamf-cli's own reason beats a bare exit code in Run History.
        let reason = Self.jamfCLIErrorMessage(in: data).map { " (\($0))" } ?? ""
        onLine(.init(timestamp: Date(), level: .warn,
                     text: "[warn] \(kind): exit \(exitCode)\(reason) — \(cacheNote)"))
        return KindCollectResult(outcome: outcome, saved: false)
    }
```

The log lines and store writes are byte-identical to the branches they replace.

- [ ] **Step 9: Add the collector to the extension file**

Append inside the `extension ReportEngine` in `ReportEngine+ComplianceBenchmarks.swift`:

```swift
    /// One compliance kind's attempt: list benchmarks (once per run, cached in `discovery`),
    /// run the report per title, and save the merged rows.
    static func collectBenchmarkReport(
        kind: String,
        profile: String,
        arguments: [String],
        configuredTitles: [String],
        discovery: inout BenchmarkDiscovery?,
        supportsQuietFlags: Bool,
        bin: URL,
        bridge: CLIBridge,
        dataDir: URL,
        recordManifest: Bool,
        useCachedData: Bool,
        stateStore: StateFileStore?,
        collectStart: Date,
        onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void
    ) async throws -> KindCollectResult {
        onLine(.init(timestamp: Date(), level: .info,
                     text: "[info] collecting \(kind) for \(profile)"))
        let resolved: BenchmarkDiscovery
        if let cached = discovery {
            resolved = cached
        } else {
            resolved = await discoverBenchmarks(
                profile: profile, configuredTitles: configuredTitles,
                supportsQuietFlags: supportsQuietFlags, bin: bin, bridge: bridge, onLine: onLine)
            discovery = resolved
        }
        let titles: [String]
        switch resolved {
        case .launchFailed:
            stateStore?.record(.failed(exitCode: nil), report: kind, at: collectStart)
            return KindCollectResult(
                outcome: CollectOutcome(kind: kind, exitCode: launchFailureExitCode), saved: false)
        case .failed(let exitCode, let data):
            return try recordUnlandedAttempt(
                kind: kind, exitCode: exitCode, data: data, useCachedData: useCachedData,
                dataDir: dataDir, stateStore: stateStore, collectStart: collectStart,
                onLine: onLine)
        case .selected(let selection):
            titles = selection.titles
        }

        var pieces: [BenchmarkPiece] = []
        for title in titles {
            let captured = await invokeWithRetry(
                kind: kind, arguments: benchmarkReportArguments(arguments, title: title),
                supportsQuietFlags: supportsQuietFlags, bin: bin, bridge: bridge, onLine: onLine)
            guard let (exitCode, data) = captured else {
                stateStore?.record(.failed(exitCode: nil), report: kind, at: collectStart)
                return KindCollectResult(
                    outcome: CollectOutcome(kind: kind, exitCode: launchFailureExitCode),
                    saved: false)
            }
            guard exitCode == 0 || exitCode == CLIBridge.exitCodePartialFailure else {
                return try recordUnlandedAttempt(
                    kind: kind, exitCode: exitCode, data: data, useCachedData: useCachedData,
                    dataDir: dataDir, stateStore: stateStore, collectStart: collectStart,
                    onLine: onLine)
            }
            pieces.append((title: title, data: data))
        }

        let success = CollectOutcome(kind: kind, exitCode: 0)
        guard let merged = mergedBenchmarkPayload(pieces) else {
            onLine(.init(timestamp: Date(), level: .warn,
                text: "[warn] \(kind): output is not JSON (renamed/unsupported "
                    + "command on this jamf-cli?) — snapshot not saved"))
            stateStore?.record(.failed(exitCode: 0), report: kind, at: collectStart)
            return KindCollectResult(outcome: success, saved: false)
        }
        return try saveCollectedPayload(
            kind: kind, data: merged, outcome: success, isPartialFailure: false,
            dataDir: dataDir, recordManifest: recordManifest, stateStore: stateStore,
            collectStart: collectStart, onLine: onLine)
    }

    static func discoverBenchmarks(
        profile: String,
        configuredTitles: [String],
        supportsQuietFlags: Bool,
        bin: URL,
        bridge: CLIBridge,
        onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void
    ) async -> BenchmarkDiscovery {
        let captured = await invokeWithRetry(
            kind: "compliance-benchmarks", arguments: benchmarkListArguments(profile: profile),
            supportsQuietFlags: supportsQuietFlags, bin: bin, bridge: bridge, onLine: onLine)
        guard let (exitCode, data) = captured else { return .launchFailed }
        guard exitCode == 0,
              let selection = benchmarkSelection(fromListOutput: data, configured: configuredTitles)
        else { return .failed(exitCode: exitCode, data: data) }
        // `[info]`, not `[warn]`/`[skip]`: the setup screen tallies those prefixes per kind.
        func info(_ text: String) { onLine(.init(timestamp: Date(), level: .info, text: text)) }
        info("[info] compliance benchmarks to collect: \(selection.titles.count)")
        if !selection.missing.isEmpty {
            info("[info] compliance benchmarks not on this tenant, skipped: "
                + selection.missing.joined(separator: ", "))
        }
        if !selection.ambiguous.isEmpty {
            info("[info] compliance benchmarks sharing a title, skipped (jamf-cli selects by "
                + "title): " + selection.ambiguous.joined(separator: ", "))
        }
        return .selected(selection)
    }
```

- [ ] **Step 10: Dispatch the two kinds from the loop**

In `ReportEngine.collect`, add after `var skippedNotDueCount = 0` (line 1781):

```swift
        // Listed at most once per run, by whichever compliance kind runs first.
        var benchmarkDiscovery: BenchmarkDiscovery?
```

Replace lines 1819–1829 (the comment, `let result = try await Self.collectOneKind(...)`, and the two
lines after it) with:

```swift
            // Every kind that got this far produces an outcome, launch failures
            // included — see `launchFailureExitCode` for why that matters.
            let result: KindCollectResult
            if Self.benchmarkReportKinds.contains(kind) {
                result = try await Self.collectBenchmarkReport(
                    kind: kind, profile: profile, arguments: args,
                    configuredTitles: loadedConfig?.platform?.benchmarkTitles ?? [],
                    discovery: &benchmarkDiscovery,
                    supportsQuietFlags: supportsQuietFlags, bin: bin, bridge: bridge,
                    dataDir: dataDir, recordManifest: recordManifest,
                    useCachedData: useCachedData, stateStore: stateStore,
                    collectStart: collectStart, onLine: onLine
                )
            } else {
                result = try await Self.collectOneKind(
                    kind: kind, profile: profile, arguments: args,
                    supportsQuietFlags: supportsQuietFlags, bin: bin, bridge: bridge,
                    dataDir: dataDir, recordManifest: recordManifest,
                    useCachedData: useCachedData, stateStore: stateStore,
                    collectStart: collectStart, onLine: onLine
                )
            }
            outcomes.append(result.outcome)
            if result.saved { savedKinds.insert(kind) }
```

The matrix entries for both kinds stay as they are: they still pass through the platform-only,
tier and cadence filters, and their argv is the base the title is inserted into.

- [ ] **Step 11: Run the new tests and the collect suites they share code with**

Run, one at a time:
`cd app && swift test --filter ComplianceBenchmarkCollectTests 2>&1 | tail -30`
`cd app && swift test --filter 'CollectHonestyTests|DeviceScanCollectTests|CollectClaimLifecycleTests' 2>&1 | tail -30`
Expected: 4 of 4 new tests pass; the existing suites report 0 failures
(`testUnknownAuthMethodSkipsNothing` still sees one failure per platform-only kind, because the
stub's exit 4 now fails the listing and both compliance kinds record it).

- [ ] **Step 12: Commit**

```bash
git add app/Sources/JamfReports/Engine/ReportEngine.swift \
  app/Sources/JamfReports/Engine/ReportEngine+ComplianceBenchmarks.swift \
  app/Tests/JamfReportsTests/ComplianceBenchmarkCollectTests.swift
git commit -m "fix(collect): run Compliance Benchmarks reports per benchmark title" \
  -m "compliance-rules and compliance-devices take a benchmark title and exited 2 on every
Platform API profile. Collect now lists benchmarks once per run, narrows them to
platform.compliance_benchmarks when set, runs both reports per title and saves merged rows
tagged with their benchmark. A tenant with no benchmarks lands empty snapshots."
```

---
### Task 2: Show one benchmark at a time, and a Benchmark column in the workbook

Rows now arrive tagged per benchmark. A rule or device appears once per benchmark, so the view's
row identity must include the benchmark (duplicate `ForEach` IDs are the #185 crash class), and
aggregates over several benchmarks would double-count devices.

**Files:**
- Modify: `app/Sources/JamfReports/Services/ComplianceBenchmarksService.swift` (Snapshot 62–116,
  decoders 137–175, raw types 177–192)
- Modify: `app/Sources/JamfReports/Views/ComplianceBenchmarksView.swift` (content 83–92, empty
  state 124–139, cards 144–210)
- Modify: `app/Sources/JamfReports/Engine/CoreDashboard.swift` (`writeComplianceDevices` 1697,
  `writeComplianceRules` 1727)
- Test: `app/Tests/JamfReportsTests/ComplianceBenchmarksServiceTests.swift`,
  `app/Tests/JamfReportsTests/ComplianceBenchmarksViewTests.swift`

**Interfaces:**
- Consumes: the `benchmark` and `ruleId` row fields written by Task 1.
- Produces: `Snapshot.Rule.ruleId`, `Snapshot.Rule.benchmark`, `Snapshot.Device.benchmark`
  (both default `""`), `Snapshot.benchmarks: [String]`, `Snapshot.filtered(to:) -> Snapshot`,
  `ComplianceBenchmarksView.activeBenchmark(in:selected:) -> String?`,
  `ComplianceBenchmarksView.displayed(_:selected:) -> Snapshot`.

- [ ] **Step 1: Write the failing tests**

Append inside `ComplianceBenchmarksServiceTests`:

```swift
    // MARK: - Per-benchmark rows (2.8.1)

    func testRowsKeepTheirBenchmarkAndStayUniqueAcrossBenchmarks() throws {
        let rulesURL = tempDir.appendingPathComponent("rules.json")
        let json = """
        [
          {"benchmark": "CIS", "rule": "FileVault", "ruleId": "r1", "passed": 9, "failed": 1,
           "unknown": 0, "devices": 10, "passRate": "90.0%"},
          {"benchmark": "STIG", "rule": "FileVault", "ruleId": "r1", "passed": 5, "failed": 5,
           "unknown": 0, "devices": 10, "passRate": "50.0%"}
        ]
        """
        try Data(json.utf8).write(to: rulesURL)
        let snapshot = ComplianceBenchmarksService.load(rulesURL: rulesURL, devicesURL: nil)
        XCTAssertEqual(snapshot.rules.map(\.benchmark), ["CIS", "STIG"])
        XCTAssertEqual(Set(snapshot.rules.map(\.id)).count, 2,
                       "duplicate ForEach IDs crash SwiftUI (#185)")
        XCTAssertEqual(snapshot.benchmarks, ["CIS", "STIG"])
    }

    func testFilteredKeepsOneBenchmarksRows() throws {
        let devicesURL = tempDir.appendingPathComponent("devices.json")
        let json = """
        [
          {"benchmark": "CIS", "device": "MacA", "deviceId": "1", "rulesPassed": 9,
           "rulesFailed": 1, "compliance": "90%"},
          {"benchmark": "STIG", "device": "MacA", "deviceId": "1", "rulesPassed": 5,
           "rulesFailed": 5, "compliance": "50%"}
        ]
        """
        try Data(json.utf8).write(to: devicesURL)
        let snapshot = ComplianceBenchmarksService.load(rulesURL: nil, devicesURL: devicesURL)
        let stig = snapshot.filtered(to: "STIG")
        XCTAssertEqual(stig.devices.map(\.benchmark), ["STIG"])
        XCTAssertEqual(stig.totalDevices, 1)
    }

    func testSnapshotsWithoutABenchmarkFieldHaveNoBenchmarks() throws {
        let rulesURL = tempDir.appendingPathComponent("rules.json")
        try Data(#"[{"rule": "FileVault", "passed": 1}]"#.utf8).write(to: rulesURL)
        let snapshot = ComplianceBenchmarksService.load(rulesURL: rulesURL, devicesURL: nil)
        XCTAssertEqual(snapshot.benchmarks, [])
    }
```

Append inside `ComplianceBenchmarksViewTests`:

```swift
    func testSeveralBenchmarksShowOneAtATime() {
        func rule(_ benchmark: String) -> ComplianceBenchmarksService.Snapshot.Rule {
            .init(rule: "FileVault", passed: 1, failed: 0, unknown: 0, devices: 1,
                  passRate: "100%", ruleId: "r1", benchmark: benchmark)
        }
        let snapshot = ComplianceBenchmarksService.Snapshot(
            rules: [rule("CIS"), rule("STIG")], devices: [],
            rulesSourceFile: nil, devicesSourceFile: nil, snapshotDate: nil)
        func shown(_ selected: String) -> [String] {
            ComplianceBenchmarksView.displayed(snapshot, selected: selected).rules.map(\.benchmark)
        }
        XCTAssertEqual(shown(""), ["CIS"], "defaults to the first benchmark")
        XCTAssertEqual(shown("STIG"), ["STIG"])
        XCTAssertEqual(shown("Removed since"), ["CIS"], "a vanished selection falls back")
    }

    func testOneBenchmarkShowsEverything() {
        let snapshot = ComplianceBenchmarksService.Snapshot(
            rules: [.init(rule: "FileVault", passed: 1, failed: 0, unknown: 0, devices: 1,
                          passRate: "100%", benchmark: "CIS")],
            devices: [], rulesSourceFile: nil, devicesSourceFile: nil, snapshotDate: nil)
        XCTAssertNil(ComplianceBenchmarksView.activeBenchmark(in: snapshot, selected: ""))
        XCTAssertEqual(ComplianceBenchmarksView.displayed(snapshot, selected: "").rules.count, 1)
    }
```

- [ ] **Step 2: Run the tests to confirm they fail**

Run: `cd app && swift test --filter 'ComplianceBenchmarksServiceTests|ComplianceBenchmarksViewTests' 2>&1 | tail -20`
Expected: compile errors, `value of type 'Snapshot.Rule' has no member 'benchmark'`.

- [ ] **Step 3: Carry the benchmark through the service**

In `ComplianceBenchmarksService.swift`, replace the `Rule` and `Device` structs inside `Snapshot`:

```swift
        struct Rule: Sendable, Equatable, Identifiable {
            let rule: String
            let passed: Int
            let failed: Int?
            let unknown: Int
            let devices: Int
            let passRate: String
            var ruleId: String = ""
            /// Benchmark title the row was collected under; empty before 2.8.1.
            var benchmark: String = ""
            /// A rule appears once per benchmark that contains it.
            var id: String { "\(benchmark)|\(ruleId.isEmpty ? rule : ruleId)" }
        }

        struct Device: Sendable, Equatable, Identifiable {
            let device: String
            let deviceId: String
            let rulesPassed: Int
            let rulesFailed: Int?
            let compliance: String
            var benchmark: String = ""
            /// A device appears once per benchmark it was evaluated against.
            var id: String { "\(benchmark)|\(deviceId.isEmpty ? device : deviceId)" }
        }
```

Add after `var totalDevices: Int { devices.count }`:

```swift
        /// Benchmark titles in first-seen order; empty for snapshots from before 2.8.1.
        var benchmarks: [String] {
            var seen: Set<String> = []
            return (rules.map(\.benchmark) + devices.map(\.benchmark))
                .filter { !$0.isEmpty && seen.insert($0).inserted }
        }

        /// This snapshot limited to one benchmark's rows.
        func filtered(to benchmark: String) -> Snapshot {
            Snapshot(
                rules: rules.filter { $0.benchmark == benchmark },
                devices: devices.filter { $0.benchmark == benchmark },
                rulesSourceFile: rulesSourceFile,
                devicesSourceFile: devicesSourceFile,
                snapshotDate: snapshotDate
            )
        }
```

In `decodeRules`, change the `Snapshot.Rule(...)` call's last argument line
`passRate: raw.passRate ?? ""` to:

```swift
                passRate: raw.passRate ?? "",
                ruleId: raw.ruleId ?? "",
                benchmark: raw.benchmark ?? ""
```

In `decodeDevices`, change `compliance: raw.compliance ?? ""` to:

```swift
                compliance: raw.compliance ?? "",
                benchmark: raw.benchmark ?? ""
```

Add `let ruleId: String?` and `let benchmark: String?` as the last two properties of `RawRule`,
and `let benchmark: String?` as the last property of `RawDevice`.

- [ ] **Step 4: Add the picker and draw one benchmark's rows**

In `ComplianceBenchmarksView.swift`, add under `@State private var bridge = CLIBridge()`:

```swift
    @State private var selectedBenchmark = ""
```

Add under `// MARK: - Unlocked sections`:

```swift
    /// What the unlocked cards draw; see `displayed`.
    private var shown: ComplianceBenchmarksService.Snapshot {
        Self.displayed(snapshot, selected: selectedBenchmark)
    }

    /// The benchmark on screen when the snapshot holds several, else nil.
    nonisolated static func activeBenchmark(
        in snapshot: ComplianceBenchmarksService.Snapshot, selected: String
    ) -> String? {
        let benchmarks = snapshot.benchmarks
        guard benchmarks.count > 1 else { return nil }
        return benchmarks.contains(selected) ? selected : benchmarks[0]
    }

    /// One benchmark's rows when there are several (aggregates across benchmarks would
    /// double-count devices), all rows when there is one or none.
    nonisolated static func displayed(
        _ snapshot: ComplianceBenchmarksService.Snapshot, selected: String
    ) -> ComplianceBenchmarksService.Snapshot {
        activeBenchmark(in: snapshot, selected: selected).map(snapshot.filtered(to:)) ?? snapshot
    }

    private var benchmarkPicker: some View {
        let active = Self.activeBenchmark(in: snapshot, selected: selectedBenchmark) ?? ""
        return Menu {
            ForEach(snapshot.benchmarks, id: \.self) { name in
                Button {
                    selectedBenchmark = name
                } label: {
                    if name == active {
                        Label(name, systemImage: "checkmark")
                    } else {
                        Text(name)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "checklist").font(.system(size: 10, weight: .semibold))
                Text(active).font(.callout.weight(.medium))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 22)
            .foregroundStyle(Theme.Colors.fg2)
            .background(Color.white.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Theme.Colors.hairline, lineWidth: 0.5)
            )
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("Compliance benchmark")
        .accessibilityValue(active)
        .help("Switch which compliance benchmark this screen shows")
    }
```

In `content`, change the `.unlockedWithData` case to:

```swift
        case .unlockedWithData:
            if snapshot.benchmarks.count > 1 { benchmarkPicker }
            ruleAggregateCard
            ruleDistributionCard
            deviceTableCard
```

In `ruleAggregateCard`, `ruleDistributionCard` and `deviceTableCard` only, replace `snapshot.` with
`shown.` — eight places, lines 145, 149, 172, 175, 185, 188, 200 and 203. Lines 29 and 52 keep
`snapshot.`: the freshness banner and the lock decision describe the whole snapshot.

Replace the `unlockedEmptyCard`'s `message:` and `commands:` arguments with:

```swift
                    message: "Collect this workspace to list its compliance benchmarks and "
                        + "fetch each one's rule and device results.",
                    commands: [
                        "jamf-cli pro compliance-benchmarks list --output json",
                        "jamf-cli pro report compliance-rules \"<title>\" --output json",
                        "jamf-cli pro report compliance-devices \"<title>\" --output json",
                    ]
```

- [ ] **Step 5: Add the Benchmark column to both sheets**

In `CoreDashboard.swift`, replace `writeComplianceDevices()` and `writeComplianceRules()`:

```swift
    func writeComplianceDevices() throws {
        let raw = try loadLatestJSON(names: ["compliance-devices"])
        let items = (raw as? [[String: Any]]) ?? []
        guard !items.isEmpty else { return }
        let ws = workbook.addSheet("Compliance Devices")
        let ts = ISO8601DateFormatter().string(from: Date())
        var row = ws.writeSheetHeader(title: t("Compliance Devices"),
                                      subtitle: "Generated: \(ts)", ncols: 6)
        ws.setColumnWidth(0, 0, 24)
        ws.setColumnWidth(1, 1, 28)
        ws.setColumnWidth(2, 5, 14)
        let hdrs = ["Benchmark", "Device", "Device ID", "Rules Passed", "Rules Failed",
                    "Compliance %"]
        for (col, h) in hdrs.enumerated() { ws.write(h, row: row, col: col, format: .header) }
        row += 1
        for item in items {
            let compliance = item["compliance"] as? String ?? ""
            let fmt: CellFormat = compliance.isEmpty ? .yellow : .cell
            ws.write(item["benchmark"] as? String ?? "", row: row, col: 0, format: .cell)
            ws.write(item["device"] as? String ?? "", row: row, col: 1, format: .cell)
            ws.write(item["deviceId"] as? String ?? "", row: row, col: 2, format: .cell)
            ws.write(asInt(item["rulesPassed"]) ?? 0, row: row, col: 3, format: .cell)
            ws.write(asInt(item["rulesFailed"]) ?? 0, row: row, col: 4, format: .cell)
            ws.write(compliance, row: row, col: 5, format: fmt)
            row += 1
        }
    }

    // MARK: - Compliance Rules
    // Source: `jamf-cli pro report compliance-rules <title> --output json`, one run per benchmark.

    func writeComplianceRules() throws {
        let raw = try loadLatestJSON(names: ["compliance-rules"])
        let items = (raw as? [[String: Any]]) ?? []
        guard !items.isEmpty else { return }
        let ws = workbook.addSheet("Compliance Rules")
        let ts = ISO8601DateFormatter().string(from: Date())
        var row = ws.writeSheetHeader(title: t("Compliance Rules"),
                                      subtitle: "Generated: \(ts)", ncols: 7)
        ws.setColumnWidth(0, 0, 24)
        ws.setColumnWidth(1, 1, 40)
        ws.setColumnWidth(2, 6, 12)
        let hdrs = ["Benchmark", "Rule", "Passed", "Failed", "Unknown", "Devices", "Pass Rate"]
        for (col, h) in hdrs.enumerated() { ws.write(h, row: row, col: col, format: .header) }
        row += 1
        for item in items {
            let pctStr = item["passRate"] as? String ?? ""
            ws.write(item["benchmark"] as? String ?? "", row: row, col: 0, format: .cell)
            ws.write(item["rule"] as? String ?? "", row: row, col: 1, format: .cell)
            ws.write(asInt(item["passed"]) ?? 0, row: row, col: 2, format: .cell)
            ws.write(asInt(item["failed"]) ?? 0, row: row, col: 3, format: .cell)
            ws.write(asInt(item["unknown"]) ?? 0, row: row, col: 4, format: .cell)
            ws.write(asInt(item["devices"]) ?? 0, row: row, col: 5, format: .cell)
            ws.write(pctStr, row: row, col: 6, format: colorForPctString(pctStr))
            row += 1
        }
    }
```

Keep the existing `// MARK: - Compliance Devices` comment above `writeComplianceDevices`, and
delete the old `// MARK: - Compliance Rules` comment pair so it is not duplicated.

- [ ] **Step 6: Run the tests**

Run: `cd app && swift test --filter 'ComplianceBenchmarksServiceTests|ComplianceBenchmarksViewTests|CoreDashboardTests' 2>&1 | tail -30`
Expected: 0 failures, including the existing `writeComplianceDevices`/`writeComplianceRules`
no-throw tests.

- [ ] **Step 7: Commit**

```bash
git add app/Sources/JamfReports/Services/ComplianceBenchmarksService.swift \
  app/Sources/JamfReports/Views/ComplianceBenchmarksView.swift \
  app/Sources/JamfReports/Engine/CoreDashboard.swift \
  app/Tests/JamfReportsTests/ComplianceBenchmarksServiceTests.swift \
  app/Tests/JamfReportsTests/ComplianceBenchmarksViewTests.swift
git commit -m "feat(compliance): pick a benchmark when a tenant has several" \
  -m "Rows carry their benchmark, so row identity includes it and the screen shows one
benchmark at a time; the workbook sheets gain a Benchmark column.

DRAFT — needs visual verification at PageScaffold.minSupportedWidth (benchmark picker)."
```

---

### Task 3: Classify why a jamf-cli call failed

With `--output json`, a failing jamf-cli command writes `{error, message, exitCode, exitCodeName,
hint}` to stdout; `--no-hints` does not remove `hint`. The rules come from spec §9.2 and the
strings from spec §6.1.

**Files:**
- Create: `app/Sources/JamfReports/Services/FailureCause.swift`
- Create: `app/Tests/JamfReportsTests/FailureCauseTests.swift`

**Interfaces:**
- Consumes: `ReportEngine.jsonPayload(from:)`, `CLIBridge.exitCodePermissionDenied`,
  `CLIBridge.exitCodeRefusedByPolicy`.
- Produces:
  - `JamfCLIErrorEnvelope.parse(_ data: Data) -> JamfCLIErrorEnvelope?` (`error`, `message`, `hint`)
  - `FailureCause` (`Codable, Equatable, Sendable`): `kind: Kind`, `names: [String]`,
    `hint: String?`, `exitCode: Int32`, `var recordedAt: Date? = nil`, `isPermanent`, `label`
  - `FailureCause.Kind`: `.scopeRejected`, `.unknownEnvironment`, `.edgeBlocked`, `.notServed`,
    `.missingPermission`, `.other`
  - `FailureCause.classify(exitCode: Int32, stdout: Data, sawForbiddenOnStderr: Bool = false)`
  - `FailureCause.forbiddenStderrMarker`, `FailureCause.hintByteLimit`

- [ ] **Step 1: Write the failing tests**

Create `app/Tests/JamfReportsTests/FailureCauseTests.swift`:

```swift
import XCTest
@testable import JamfReports

/// Spec 2026-09-12 §9.2, first matching rule wins. Message strings marked "tester log" are
/// captures with IDs zeroed; the rest are jamf-cli 1.29.0 source strings (spec §6.1) until
/// the tester's captures replace them.
final class FailureCauseTests: XCTestCase {

    private func envelope(_ message: String, hint: String? = nil, exit: Int32) -> Data {
        var object: [String: Any] = [
            "error": "request failed", "message": message,
            "exitCode": Int(exit), "exitCodeName": "error",
        ]
        if let hint { object["hint"] = hint }
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    private func classify(_ message: String, hint: String? = nil, exit: Int32) -> FailureCause {
        FailureCause.classify(exitCode: exit, stdout: envelope(message, hint: hint, exit: exit))
    }

    private let gatewayHint = "grant the Jamf Platform API integration these permissions in "
        + "Jamf Account: Compliance > Compliance Benchmarks: Read (compliance-benchmarks:read); "
        + "Inventory > Devices: Read (devices:read). Names are as the permission picker shows "
        + "them: <map URL>"

    // Rule 1

    func testOwnershipForbiddenIsAScopeRejectionEvenWithAPermissionHint() {
        let cause = classify("permission denied (HTTP 403): {\"code\":\"OWNERSHIP_FORBIDDEN\"}",
                             hint: gatewayHint, exit: 5)
        XCTAssertEqual(cause.kind, .scopeRejected, "rule 1 must win over rule 5")
    }

    func testScopeMismatchHintIsAScopeRejection() {
        let hint = "The credential's scope level does not match the scope header sent."
        XCTAssertEqual(classify("forbidden", hint: hint, exit: 5).kind, .scopeRejected)
    }

    // Rule 2 (tester log)

    func testEnvironmentNotFoundIsAnUnknownEnvironment() {
        let message = "API request failed with status 404 Not Found, traceId 0000000000000000 "
            + "(method=GET, url=https://us.api.jamfcloud.com/compliance-benchmarks/v1/benchmarks)"
            + ": [ENVIRONMENT_NOT_FOUND] Environment '00000000-0000-0000-0000-000000000000' "
            + "not found."
        XCTAssertEqual(classify(message, exit: 4).kind, .unknownEnvironment)
    }

    // Rule 3

    func testGatewayEdgeBlockIsRetryable() {
        let cause = classify("request blocked at the Jamf gateway edge (HTTP 403)", exit: 5)
        XCTAssertEqual(cause.kind, .edgeBlocked)
        XCTAssertFalse(cause.isPermanent)
    }

    // Rule 4

    func testUnservedEndpointNoteBeatsThePermissionHint() {
        let hint = gatewayHint + " The Jamf Platform gateway does not serve this endpoint"
        XCTAssertEqual(classify("permission denied (HTTP 403)", hint: hint, exit: 5).kind,
                       .notServed)
    }

    func testExitEightIsNotServed() {
        XCTAssertEqual(classify("refused by policy", exit: 8).kind, .notServed)
    }

    // Rules 5–7

    func testGatewayHintNamesThePermissions() {
        let cause = classify("permission denied (HTTP 403)", hint: gatewayHint, exit: 5)
        XCTAssertEqual(cause.kind, .missingPermission)
        XCTAssertEqual(cause.names, [
            "Compliance > Compliance Benchmarks: Read (compliance-benchmarks:read)",
            "Inventory > Devices: Read (devices:read)",
        ])
    }

    func testGatewayFallbackHintNamesNothing() {
        let hint = "the Jamf Platform API integration lacks a permission this endpoint requires; "
            + "check the integration's permissions in Jamf Account — <map URL>"
        let cause = classify("permission denied (HTTP 403)", hint: hint, exit: 5)
        XCTAssertEqual(cause.kind, .missingPermission)
        XCTAssertEqual(cause.names, [])
    }

    func testJamfProHintNamesThePrivileges() {
        let hint = "Required privilege(s): Read Computers, Read Smart Computer Groups"
        let cause = classify("permission denied (HTTP 403)", hint: hint, exit: 5)
        XCTAssertEqual(cause.names, ["Read Computers", "Read Smart Computer Groups"])
    }

    func testExitFiveWithoutARecognisedHintIsStillAMissingPermission() {
        let hint = "the authenticated account lacks the required API privileges; check its API role"
        XCTAssertEqual(classify("permission denied (HTTP 403)", hint: hint, exit: 5).kind,
                       .missingPermission)
        XCTAssertEqual(FailureCause.classify(exitCode: 5, stdout: Data("oops".utf8)).kind,
                       .missingPermission)
    }

    /// `pro report update-status` exits 0 after both its fetches fail; the 403 is on stderr.
    func testASwallowed403IsAMissingPermission() {
        let cause = FailureCause.classify(exitCode: 0, stdout: Data(), sawForbiddenOnStderr: true)
        XCTAssertEqual(cause.kind, .missingPermission)
    }

    // Rule 8 (tester log)

    func testABare404OnAJamfProCommandIsOther() {
        let cause = classify(
            "resource not found (HTTP 404): GET /pro/v1/buildings?page=0&page-size=100", exit: 4)
        XCTAssertEqual(cause.kind, .other)
        XCTAssertFalse(cause.isPermanent)
    }

    // Storage shape

    func testTheHintIsCappedAtFourKilobytes() throws {
        let cause = classify("x", hint: String(repeating: "a", count: 5_000), exit: 5)
        XCTAssertEqual(try XCTUnwrap(cause.hint).utf8.count, FailureCause.hintByteLimit)
    }

    func testPermanenceFollowsSpecSection95() {
        let permanent: [FailureCause.Kind] =
            [.scopeRejected, .unknownEnvironment, .notServed, .missingPermission]
        for kind in [FailureCause.Kind.scopeRejected, .unknownEnvironment, .edgeBlocked,
                     .notServed, .missingPermission, .other] {
            let cause = FailureCause(kind: kind, names: [], hint: nil, exitCode: 5)
            XCTAssertEqual(cause.isPermanent, permanent.contains(kind), kind.rawValue)
        }
    }

    func testRoundTripsThroughJSON() throws {
        let cause = FailureCause(kind: .missingPermission, names: ["Read Computers"],
                                 hint: "Required privilege(s): Read Computers", exitCode: 5,
                                 recordedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let data = try JSONEncoder().encode(cause)
        XCTAssertEqual(try JSONDecoder().decode(FailureCause.self, from: data), cause)
    }
}
```

- [ ] **Step 2: Run the tests to confirm they fail**

Run: `cd app && swift test --filter FailureCauseTests 2>&1 | tail -20`
Expected: compile error, `cannot find 'FailureCause' in scope`.

- [ ] **Step 3: Write the classifier**

Create `app/Sources/JamfReports/Services/FailureCause.swift`:

```swift
import Foundation

/// jamf-cli's JSON error envelope. With `--output json` a failing command writes it to stdout
/// (`formatErrorTo`); `--no-hints` does not remove `hint`.
struct JamfCLIErrorEnvelope: Decodable, Equatable, Sendable {
    let error: String?
    let message: String?
    let hint: String?

    static func parse(_ data: Data) -> JamfCLIErrorEnvelope? {
        guard let payload = ReportEngine.jsonPayload(from: data) else { return nil }
        return try? JSONDecoder().decode(JamfCLIErrorEnvelope.self, from: payload)
    }
}

/// Why one jamf-cli call failed (spec 2026-09-12 §9.2; first matching rule wins).
struct FailureCause: Codable, Equatable, Sendable {

    enum Kind: String, Codable, Sendable {
        /// Rule 1: the integration's scope level or ID does not match what was sent.
        case scopeRejected
        /// Rule 2: the gateway does not know the environment ID.
        case unknownEnvironment
        /// Rule 3: blocked at the Jamf gateway edge; jamf-cli advises one cold retry.
        case edgeBlocked
        /// Rule 4: the command is outside what this connection's API serves.
        case notServed
        /// Rules 5–7: a missing permission or privilege.
        case missingPermission
        /// Rule 8: anything else; the exit-code handling that existed before applies.
        case other
    }

    let kind: Kind
    /// Permission or privilege names parsed from the hint; empty when it names none.
    let names: [String]
    /// jamf-cli's hint, capped at `hintByteLimit`.
    let hint: String?
    let exitCode: Int32
    /// When the failure was recorded; set by `StateFileStore`.
    var recordedAt: Date? = nil

    static let hintByteLimit = 4_096
    /// What jamf-cli prints on stderr when a command swallows a 403 and exits 0.
    static let forbiddenStderrMarker = "permission denied (HTTP 403)"

    /// Retrying cannot help until someone changes the credential, its scope ID or its
    /// permissions (spec §9.5). Edge blocks stay retryable.
    var isPermanent: Bool {
        switch kind {
        case .scopeRejected, .unknownEnvironment, .notServed, .missingPermission: true
        case .edgeBlocked, .other: false
        }
    }

    /// Plain-language cause for log lines and the health banner.
    var label: String {
        switch kind {
        case .scopeRejected: "the gateway rejected the integration's scope level or ID"
        case .unknownEnvironment: "the gateway does not recognise the environment ID"
        case .edgeBlocked: "blocked at the Jamf gateway edge"
        case .notServed: "not served through this connection"
        case .missingPermission:
            names.isEmpty
                ? "missing permission"
                : "missing permission: " + names.joined(separator: "; ")
        case .other: "exit \(exitCode)"
        }
    }

    static func classify(
        exitCode: Int32, stdout: Data, sawForbiddenOnStderr: Bool = false
    ) -> FailureCause {
        let envelope = JamfCLIErrorEnvelope.parse(stdout)
        let message = envelope?.message ?? ""
        let hint = envelope?.hint ?? ""
        let cappedHint = hint.isEmpty
            ? nil
            : String(decoding: hint.utf8.prefix(hintByteLimit), as: UTF8.self)
        func cause(_ kind: Kind, _ names: [String] = []) -> FailureCause {
            FailureCause(kind: kind, names: names, hint: cappedHint, exitCode: exitCode)
        }
        if message.contains("OWNERSHIP_FORBIDDEN")
            || hint.hasPrefix("The credential's scope level does not match") {
            return cause(.scopeRejected)
        }
        if message.contains("ENVIRONMENT_NOT_FOUND") { return cause(.unknownEnvironment) }
        if message.hasPrefix("request blocked at the Jamf gateway edge") {
            return cause(.edgeBlocked)
        }
        if hint.contains("does not serve this endpoint")
            || hint.contains("not part of the Jamf Platform gateway's published API")
            || exitCode == CLIBridge.exitCodeRefusedByPolicy {
            return cause(.notServed)
        }
        if exitCode == CLIBridge.exitCodePermissionDenied {
            if hint.contains("Jamf Platform API integration") {
                return cause(.missingPermission, gatewayPermissionNames(in: hint))
            }
            if hint.contains("Required privilege(s):") {
                return cause(.missingPermission, privilegeNames(in: hint))
            }
            return cause(.missingPermission)
        }
        return cause(sawForbiddenOnStderr ? .missingPermission : .other)
    }

    /// Gateway hints name permissions between `in Jamf Account: ` and `. Names are`,
    /// separated by `; ` (jamf-cli `privileges.Hint`).
    static func gatewayPermissionNames(in hint: String) -> [String] {
        guard let start = hint.range(of: "in Jamf Account: "),
              let end = hint.range(of: ". Names are", range: start.upperBound..<hint.endIndex)
        else { return [] }
        return hint[start.upperBound..<end.lowerBound]
            .components(separatedBy: "; ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Jamf Pro hints name privileges after `Required privilege(s): `, separated by `, `,
    /// to the end of that line (jamf-cli `EnrichPrivilegeError`).
    static func privilegeNames(in hint: String) -> [String] {
        guard let start = hint.range(of: "Required privilege(s): ") else { return [] }
        return hint[start.upperBound...]
            .prefix { $0 != "\n" }
            .components(separatedBy: ", ")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " .")) }
            .filter { !$0.isEmpty }
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `cd app && swift test --filter FailureCauseTests 2>&1 | tail -20`
Expected: `Executed 15 tests, with 0 failures`.

- [ ] **Step 5: Mutation-check the rule order**

Copy the file aside, move the rule-5 `if exitCode == CLIBridge.exitCodePermissionDenied` block
above the rule-1 `if`, and rerun Step 4. Expected: at least
`testOwnershipForbiddenIsAScopeRejectionEvenWithAPermissionHint` and
`testUnservedEndpointNoteBeatsThePermissionHint` fail. Restore the file from the copy (not
`git checkout` — the file is uncommitted) and rerun Step 4 to see 0 failures.

- [ ] **Step 6: Commit**

```bash
git add app/Sources/JamfReports/Services/FailureCause.swift \
  app/Tests/JamfReportsTests/FailureCauseTests.swift
git commit -m "feat(collect): classify jamf-cli failures from the JSON error envelope" \
  -m "Scope rejected, unknown environment, gateway edge block, not served, and missing
permission (with the names jamf-cli's hint gives), per the connection-access spec 9.2."
```

---
### Task 4: Decide whether the gateway accepts a Platform API profile's scope ID

The gateway issues a token before it reads the scope header, so `config validate` passes with a
wrong environment or tenant ID. jamf-cli's own `platform setup` checks the ID with
`GET /pro/v1/jamf-pro-version`, which needs no permission: 200 means the ID is right, 404
`ENVIRONMENT_NOT_FOUND` means an unknown environment, 403 `OWNERSHIP_FORBIDDEN` means the wrong kind
of ID. Through a Jamf Pro command the 404 body is dropped (spec §14.1), so a bare 404 needs a second
question: a Platform call that matches nothing. The gateway checks scope before permissions, so
even a permission error there proves the ID. `jamf-pro-version` is 1.29's name; 1.28 (the first
release with environment scope) calls it `jamf-pro-versions`.

**Files:**
- Create: `app/Sources/JamfReports/Services/ConnectionCheck.swift`
- Create: `app/Tests/JamfReportsTests/ConnectionCheckTests.swift`

**Interfaces:**
- Consumes: `FailureCause.classify(exitCode:stdout:sawForbiddenOnStderr:)` (Task 3),
  `ReportEngine.jsonPayload(from:)`, `CLIBridge.runAndCapture`, `CLIBridge.environmentForJamfCLI()`,
  `ExecutableLocator.locate(_:)`.
- Produces:
  - `ConnectionCheck.Attempt = (exitCode: Int32, stdout: Data)`
  - `ConnectionCheck.Runner = @Sendable ([String]) async -> Attempt?`
  - `ConnectionCheck.Verdict`: `.accepted(jamfProVersion: String?)`,
    `.rejectedID(FailureCause.Kind)`, `.noJamfPro`, `.undecided(exitCode: Int32?)`;
    `blocksContinue: Bool`; `message: String`
  - `ConnectionCheck.versionArguments(profile:specNames:)`, `probeArguments(profile:)`,
    `needsProbe(_:)`, `verdict(version:probe:)`, `jamfProVersion(in:)`,
    `run(profile:specNames:runner:) async -> Verdict`, `liveRunner() -> Runner?`

- [ ] **Step 1: Write the failing tests**

Create `app/Tests/JamfReportsTests/ConnectionCheckTests.swift`:

```swift
import XCTest
@testable import JamfReports

/// One test per row of spec 2026-09-12 §10.4's result table, plus when step 2 runs. The bare
/// 404 and ENVIRONMENT_NOT_FOUND strings follow the tester's log; the 403 strings are jamf-cli
/// 1.29.0 source strings (spec §6.1).
final class ConnectionCheckTests: XCTestCase {

    private func failure(
        _ exit: Int32, _ message: String, hint: String? = nil
    ) -> ConnectionCheck.Attempt {
        var object: [String: Any] = [
            "error": "request failed", "message": message,
            "exitCode": Int(exit), "exitCodeName": "error",
        ]
        if let hint { object["hint"] = hint }
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return (exitCode: exit, stdout: data)
    }

    private func success(_ stdout: String) -> ConnectionCheck.Attempt {
        (exitCode: 0, stdout: Data(stdout.utf8))
    }

    private var bare404: ConnectionCheck.Attempt {
        failure(4, "resource not found (HTTP 404): GET /pro/v1/jamf-pro-version")
    }

    private var unknownEnvironment: ConnectionCheck.Attempt {
        failure(4, "API request failed with status 404 Not Found, traceId 0000000000000000 "
            + "(method=GET, url=https://us.api.jamfcloud.com/devices/v1/devices): "
            + "[ENVIRONMENT_NOT_FOUND] Environment '00000000-0000-0000-0000-000000000000' "
            + "not found.")
    }

    func testAJamfProVersionAcceptsTheID() {
        let verdict = ConnectionCheck.verdict(version: success(#"{"version":"11.25.0"}"#),
                                              probe: nil)
        XCTAssertEqual(verdict, .accepted(jamfProVersion: "11.25.0"))
        XCTAssertFalse(verdict.blocksContinue)
    }

    func testOwnershipForbiddenOnStepOneBlocks() {
        let version = failure(5, "permission denied (HTTP 403): {\"code\":\"OWNERSHIP_FORBIDDEN\"}")
        let verdict = ConnectionCheck.verdict(version: version, probe: nil)
        XCTAssertEqual(verdict, .rejectedID(.scopeRejected))
        XCTAssertTrue(verdict.blocksContinue)
    }

    func testUnknownEnvironmentOnStepTwoBlocks() {
        XCTAssertEqual(ConnectionCheck.verdict(version: bare404, probe: unknownEnvironment),
                       .rejectedID(.unknownEnvironment))
    }

    func testAnEmptyPageOnStepTwoMeansNoJamfProInThisEnvironment() {
        XCTAssertEqual(ConnectionCheck.verdict(version: bare404, probe: success("[]")),
                       .noJamfPro)
    }

    /// The gateway resolves scope before capability, so a permission error proves the ID.
    func testAPermissionErrorOnStepTwoStillProvesTheID() {
        let hint = "the Jamf Platform API integration lacks a permission this endpoint "
            + "requires; check the integration's permissions in Jamf Account — <map URL>"
        let probe = failure(5, "permission denied (HTTP 403)", hint: hint)
        XCTAssertEqual(ConnectionCheck.verdict(version: bare404, probe: probe), .noJamfPro)
    }

    func testAnythingElseIsUndecided() {
        XCTAssertEqual(ConnectionCheck.verdict(version: nil, probe: nil),
                       .undecided(exitCode: nil))
        XCTAssertEqual(ConnectionCheck.verdict(version: failure(1, "timeout"), probe: nil),
                       .undecided(exitCode: 1))
        XCTAssertEqual(ConnectionCheck.verdict(version: bare404, probe: failure(1, "timeout")),
                       .undecided(exitCode: 1))
        XCTAssertFalse(ConnectionCheck.Verdict.undecided(exitCode: 1).blocksContinue)
    }

    func testOnlyABare404RunsStepTwo() {
        XCTAssertTrue(ConnectionCheck.needsProbe(bare404))
        XCTAssertFalse(ConnectionCheck.needsProbe(unknownEnvironment))
        XCTAssertFalse(ConnectionCheck.needsProbe(success("{}")))
        XCTAssertFalse(ConnectionCheck.needsProbe(failure(1, "timeout")))
        XCTAssertFalse(ConnectionCheck.needsProbe(nil))
    }

    func testRunAsksTheSecondQuestionOnlyAfterABare404() async {
        let twoStep = RecordingRunner(version: bare404, probe: success("[]"))
        let verdict = await ConnectionCheck.run(profile: "p", specNames: true,
                                                runner: twoStep.runner)
        XCTAssertEqual(verdict, .noJamfPro)
        XCTAssertEqual(twoStep.calls.count, 2)
        XCTAssertTrue(twoStep.calls.last?.contains("platform-devices") ?? false)

        let oneStep = RecordingRunner(version: success(#"{"version":"11.25.0"}"#), probe: nil)
        _ = await ConnectionCheck.run(profile: "p", specNames: true, runner: oneStep.runner)
        XCTAssertEqual(oneStep.calls.count, 1)
    }

    func testArgumentsFollowTheInstalledJamfCLI() {
        XCTAssertEqual(ConnectionCheck.versionArguments(profile: "p", specNames: true),
                       ["-p", "p", "pro", "jamf-pro-version", "list", "--output", "json"])
        XCTAssertEqual(ConnectionCheck.versionArguments(profile: "p", specNames: false)[3],
                       "jamf-pro-versions")
        XCTAssertTrue(ConnectionCheck.probeArguments(profile: "p")
            .contains(#"serialNumber=="jrc-connection-check""#),
            "the filter is one argv element; no shell ever parses it")
    }

    func testTheVersionIsReadFromAnObjectOrAnArray() {
        XCTAssertEqual(ConnectionCheck.jamfProVersion(in: Data(#"{"version":"11.2"}"#.utf8)),
                       "11.2")
        XCTAssertEqual(ConnectionCheck.jamfProVersion(in: Data(#"[{"version":"11.3"}]"#.utf8)),
                       "11.3")
        XCTAssertNil(ConnectionCheck.jamfProVersion(in: Data("not json".utf8)))
    }
}

private final class RecordingRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    private let version: ConnectionCheck.Attempt?
    private let probe: ConnectionCheck.Attempt?

    init(version: ConnectionCheck.Attempt?, probe: ConnectionCheck.Attempt?) {
        self.version = version
        self.probe = probe
    }

    var calls: [[String]] { lock.withLock { recorded } }

    var runner: ConnectionCheck.Runner {
        { arguments in
            self.lock.withLock { self.recorded.append(arguments) }
            return arguments.contains("platform-devices") ? self.probe : self.version
        }
    }
}
```

- [ ] **Step 2: Run the tests to confirm they fail**

Run: `cd app && swift test --filter ConnectionCheckTests 2>&1 | tail -20`
Expected: compile error, `cannot find 'ConnectionCheck' in scope`.

- [ ] **Step 3: Write the verdict and runner**

Create `app/Sources/JamfReports/Services/ConnectionCheck.swift`:

```swift
import Foundation

/// Checks a Jamf Platform API profile's environment or tenant ID when it validates (spec
/// 2026-09-12 §10.4). `config validate` cannot: the gateway issues a token before it reads the
/// scope header. Same probe as jamf-cli's own `platform setup`.
enum ConnectionCheck {

    typealias Attempt = (exitCode: Int32, stdout: Data)
    /// Runs jamf-cli with these arguments; nil when the process never launched.
    typealias Runner = @Sendable ([String]) async -> Attempt?

    enum Verdict: Equatable, Sendable {
        /// Jamf Pro answered through the gateway in this environment.
        case accepted(jamfProVersion: String?)
        /// The gateway refused the ID; setup must not continue with it.
        case rejectedID(FailureCause.Kind)
        /// The gateway accepted the ID, but no Jamf Pro answered in this environment.
        case noJamfPro
        /// The check could not tell.
        case undecided(exitCode: Int32?)
    }

    /// Needs no permission. jamf-cli 1.29 renamed `jamf-pro-versions` to `jamf-pro-version`;
    /// the old name warns until 2027-03-09 and the new one exits 2 before 1.29.
    static func versionArguments(profile: String, specNames: Bool) -> [String] {
        ["-p", profile, "pro", specNames ? "jamf-pro-version" : "jamf-pro-versions", "list",
         "--output", "json"]
    }

    /// A Platform call that matches nothing and returns one empty page.
    static func probeArguments(profile: String) -> [String] {
        ["-p", profile, "pro", "platform-devices", "list",
         "--filter", #"serialNumber=="jrc-connection-check""#, "--output", "json"]
    }

    /// Step 2 runs only after a 404 that names no cause.
    static func needsProbe(_ version: Attempt?) -> Bool {
        guard let version, version.exitCode == CLIBridge.exitCodeNotFound else { return false }
        return FailureCause.classify(exitCode: version.exitCode, stdout: version.stdout).kind
            == .other
    }

    static func verdict(version: Attempt?, probe: Attempt?) -> Verdict {
        guard let version else { return .undecided(exitCode: nil) }
        if version.exitCode == 0 {
            return .accepted(jamfProVersion: jamfProVersion(in: version.stdout))
        }
        let first = FailureCause.classify(exitCode: version.exitCode, stdout: version.stdout)
        if first.kind == .scopeRejected || first.kind == .unknownEnvironment {
            return .rejectedID(first.kind)
        }
        guard needsProbe(version) else { return .undecided(exitCode: version.exitCode) }
        guard let probe else { return .undecided(exitCode: nil) }
        if probe.exitCode == 0 { return .noJamfPro }
        let second = FailureCause.classify(exitCode: probe.exitCode, stdout: probe.stdout)
        switch second.kind {
        case .scopeRejected, .unknownEnvironment: return .rejectedID(second.kind)
        case .missingPermission: return .noJamfPro
        case .edgeBlocked, .notServed, .other: return .undecided(exitCode: probe.exitCode)
        }
    }

    static func run(profile: String, specNames: Bool, runner: Runner) async -> Verdict {
        let version = await runner(versionArguments(profile: profile, specNames: specNames))
        var probe: Attempt?
        if needsProbe(version) {
            probe = await runner(probeArguments(profile: profile))
        }
        return verdict(version: version, probe: probe)
    }

    /// `{"version": "11.25.0"}`, or an array holding that object.
    static func jamfProVersion(in stdout: Data) -> String? {
        guard let payload = ReportEngine.jsonPayload(from: stdout),
              let object = try? JSONSerialization.jsonObject(with: payload) else { return nil }
        let fields = (object as? [[String: Any]])?.first ?? (object as? [String: Any])
        guard let version = fields?["version"] as? String, !version.isEmpty else { return nil }
        return version
    }

    /// jamf-cli on PATH with the app's child environment; nil when it is not installed.
    static func liveRunner() -> Runner? {
        guard let binary = ExecutableLocator.locate("jamf-cli") else { return nil }
        return { arguments in
            guard let (exitCode, stdout) = try? await CLIBridge().runAndCapture(
                executable: binary, arguments: arguments,
                environment: CLIBridge.environmentForJamfCLI(), onLine: CLIBridge.noOpOnLine
            ) else { return nil }
            return (exitCode: exitCode, stdout: stdout)
        }
    }
}

extension ConnectionCheck.Verdict {
    var blocksContinue: Bool {
        if case .rejectedID = self { return true }
        return false
    }

    var message: String {
        switch self {
        case .accepted(let version):
            return "Jamf Pro " + (version.map { "\($0) " } ?? "")
                + "answered through the Jamf Platform API in this environment."
        case .rejectedID(.unknownEnvironment):
            return "The gateway does not recognise this environment ID. Copy the platform "
                + "environment ID from Jamf Account: open the integration and click the "
                + "environment pill in Integration details. A tenant ID or client ID here is "
                + "rejected."
        case .rejectedID:
            return "The integration's scope level does not match this ID. An environment-level "
                + "integration needs its environment ID, and a tenant-level (legacy) integration "
                + "its tenant ID. Correct the scope level or the ID, then save again."
        case .noJamfPro:
            return "The gateway accepted the ID, but no Jamf Pro server answered in this "
                + "environment. Jamf Pro screens stay empty unless this is the environment that "
                + "holds your Jamf Pro tenant."
        case .undecided(let exitCode):
            return "The connection check could not confirm the ID"
                + (exitCode.map { " (exit \($0))" } ?? "")
                + ". You can continue; if screens stay empty after the first collect, check the "
                + "ID with Update credentials in Data Sources."
        }
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `cd app && swift test --filter ConnectionCheckTests 2>&1 | tail -20`
Expected: `Executed 10 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/JamfReports/Services/ConnectionCheck.swift \
  app/Tests/JamfReportsTests/ConnectionCheckTests.swift
git commit -m "feat(onboarding): check a Platform API profile's scope ID with the gateway" \
  -m "Asks for the Jamf Pro version, and after a bare 404 makes a Platform call that matches
nothing. Verdicts: accepted, rejected ID, no Jamf Pro in this environment, undecided."
```

---

### Task 5: Run the check when a Platform API profile validates

**Files:**
- Modify: `app/Sources/JamfReports/Services/OnboardingFlow.swift` — `validationExitCode` 199,
  register resets 470 and 512, `validateRegisteredProfile` 797–834
- Create: `app/Sources/JamfReports/Views/ConnectionCheckBanner.swift`
- Modify: `app/Sources/JamfReports/Views/OnboardingView.swift` — `validateStep` 200–240,
  `showsContinueWithoutValidating` 242–249, Platform instructions 434–438, Protect copy 552
- Modify: `app/Sources/JamfReports/Views/ReauthenticateSheet.swift` — `resultSection` 264–287
- Modify: `app/Sources/JamfReports/Views/ProductConnectSheetView.swift` — Protect copy 97
- Create: `app/Tests/JamfReportsTests/OnboardingConnectionCheckTests.swift`

**Interfaces:**
- Consumes: `ConnectionCheck.run`, `ConnectionCheck.liveRunner`, `Verdict.message`,
  `Verdict.blocksContinue` (Task 4).
- Produces: `OnboardingFlow.connectionCheck: ConnectionCheck.Verdict?`,
  `OnboardingFlow.applyConnectionCheck(_:)`, `OnboardingFlow.offersContinueWithoutValidating`,
  `ConnectionCheckBanner(verdict:)`.

- [ ] **Step 1: Write the failing tests**

Create `app/Tests/JamfReportsTests/OnboardingConnectionCheckTests.swift`:

```swift
import XCTest
@testable import JamfReports

/// Spec 2026-09-12 §10.4: a rejected ID blocks setup; "Continue without validating" is offered
/// for a Platform API profile only when the check could not decide. OAuth2 is unchanged.
@MainActor
final class OnboardingConnectionCheckTests: XCTestCase {

    private func flowAtValidate(
        _ type: OnboardingFlow.ProConnectionType, exit: Int32
    ) -> OnboardingFlow {
        let flow = OnboardingFlow()
        flow.proConnectionType = type
        flow.currentStep = .validate
        flow.profileRegistered = true
        flow.validationExitCode = exit
        return flow
    }

    func testARejectedIDBlocksSetup() {
        let flow = flowAtValidate(.platformGateway, exit: 0)
        flow.applyConnectionCheck(.rejectedID(.unknownEnvironment))
        XCTAssertFalse(flow.connectionValidated)
        XCTAssertFalse(flow.offersContinueWithoutValidating)
    }

    func testAnUndecidedCheckOffersTheBypass() {
        let flow = flowAtValidate(.platformGateway, exit: 0)
        flow.applyConnectionCheck(.undecided(exitCode: 1))
        XCTAssertFalse(flow.connectionValidated)
        XCTAssertTrue(flow.offersContinueWithoutValidating)
    }

    func testNoJamfProValidatesWithAWarning() {
        let flow = flowAtValidate(.platformGateway, exit: 0)
        flow.applyConnectionCheck(.noJamfPro)
        XCTAssertTrue(flow.connectionValidated)
        XCTAssertEqual(flow.connectionCheck, .noJamfPro)
    }

    func testAnAcceptedIDValidates() {
        let flow = flowAtValidate(.platformGateway, exit: 0)
        flow.applyConnectionCheck(.accepted(jamfProVersion: "11.25.0"))
        XCTAssertTrue(flow.connectionValidated)
        XCTAssertFalse(flow.offersContinueWithoutValidating)
    }

    func testAPlatformProfileThatFailsValidateGetsNoBypass() {
        let flow = flowAtValidate(.platformGateway, exit: CLIBridge.exitCodeUnauthorized)
        XCTAssertFalse(flow.offersContinueWithoutValidating)
    }

    func testOAuth2KeepsTheBypassAfterAFailedValidate() {
        XCTAssertTrue(flowAtValidate(.oauth2, exit: 1).offersContinueWithoutValidating)
        XCTAssertFalse(flowAtValidate(.oauth2, exit: 0).offersContinueWithoutValidating)
    }
}
```

- [ ] **Step 2: Run the tests to confirm they fail**

Run: `cd app && swift test --filter OnboardingConnectionCheckTests 2>&1 | tail -20`
Expected: compile error, `value of type 'OnboardingFlow' has no member 'applyConnectionCheck'`.

- [ ] **Step 3: Run and apply the check in `OnboardingFlow`**

Add after `var validationExitCode: Int32?` (line 199):

```swift
    /// The gateway's answer about a Platform API profile's scope ID; nil for OAuth2 profiles
    /// and before validation.
    var connectionCheck: ConnectionCheck.Verdict?
```

In both `registerOAuth2Profile` (line 470) and `registerPlatformGatewayProfile` (line 512), add
`connectionCheck = nil` directly after `validationOutput.removeAll()`.

In `validateRegisteredProfile`, add `connectionCheck = nil` after `lastError = nil` at the top, and
replace the block from `validationExitCode = exit` to the function's closing brace with:

```swift
        validationExitCode = exit
        guard exit == 0 else {
            lastError = "jamf-cli config validate failed for \(profile). Review the URL, "
                + "client ID, secret, and API role privileges, then retry."
            return
        }
        guard proConnectionType == .platformGateway else {
            connectionValidated = true
            return
        }
        applyConnectionCheck(await runConnectionCheck(profile: profile))
    }

    private func runConnectionCheck(profile: String) async -> ConnectionCheck.Verdict {
        guard let binary = ExecutableLocator.locate("jamf-cli"),
              let runner = ConnectionCheck.liveRunner() else {
            return .undecided(exitCode: nil)
        }
        let specNames = JamfCLIInstaller.supportsSpecDerivedNames(
            jamfCLIVersion ?? JamfCLIInstaller.installedVersion(at: binary)
        )
        return await ConnectionCheck.run(profile: profile, specNames: specNames, runner: runner)
    }

    /// A rejected or unconfirmed ID stays unvalidated; an ID the gateway accepted validates even
    /// when no Jamf Pro answered, which the banner reports as a warning.
    func applyConnectionCheck(_ verdict: ConnectionCheck.Verdict) {
        connectionCheck = verdict
        switch verdict {
        case .accepted, .noJamfPro: connectionValidated = true
        case .rejectedID, .undecided: connectionValidated = false
        }
    }

    /// "Continue without validating" after a failed validation. For a Platform API profile,
    /// only when the connection check could not decide (spec §10.4).
    var offersContinueWithoutValidating: Bool {
        guard !connectionValidated, canAdvance, let exit = validationExitCode else { return false }
        guard proConnectionType == .platformGateway else { return exit != 0 }
        if case .undecided = connectionCheck { return true }
        return false
    }
```

The `lastError` text is unchanged; only its line is wrapped.

- [ ] **Step 4: Run the tests**

Run: `cd app && swift test --filter OnboardingConnectionCheckTests 2>&1 | tail -20`
Expected: `Executed 6 tests, with 0 failures`.

- [ ] **Step 5: Add the banner and use it on both screens**

Create `app/Sources/JamfReports/Views/ConnectionCheckBanner.swift`:

```swift
import SwiftUI

/// The connection check's verdict, shown by onboarding's Validate step and the Update
/// credentials sheet.
struct ConnectionCheckBanner: View {
    let verdict: ConnectionCheck.Verdict

    var body: some View {
        InlineBanner(icon: Self.icon(for: verdict), tone: Self.tone(for: verdict)) {
            Text(verbatim: verdict.message)
                .font(.footnote)
                .foregroundStyle(Theme.Colors.fg2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    nonisolated static func tone(for verdict: ConnectionCheck.Verdict) -> InlineBannerTone {
        switch verdict {
        case .accepted: .info
        case .rejectedID: .danger
        case .noJamfPro, .undecided: .warn
        }
    }

    nonisolated static func icon(for verdict: ConnectionCheck.Verdict) -> String {
        switch verdict {
        case .accepted: "checkmark.seal"
        case .rejectedID: "xmark.octagon.fill"
        case .noJamfPro, .undecided: "exclamationmark.triangle.fill"
        }
    }
}
```

In `OnboardingView.validateStep`, insert between the first `Card { ... }` and
`if showsContinueWithoutValidating {`:

```swift
            if let check = flow.connectionCheck {
                ConnectionCheckBanner(verdict: check)
            }
```

Change `if showsContinueWithoutValidating {` to `if flow.offersContinueWithoutValidating {`, and
delete the `showsContinueWithoutValidating` property and its doc comment (lines 242–249).

In `ReauthenticateSheet.resultSection`, insert directly after the `lastError` banner's closing `}`:

```swift
        if let check = flow.connectionCheck {
            ConnectionCheckBanner(verdict: check)
        }
```

- [ ] **Step 6: Replace the setup instructions**

In `OnboardingView.platformGatewayForm`, replace the three `Text("1. Go to account.jamf.com → API
Clients")` … `Text("3. Generate a Client Secret (shown only once)")` lines with:

```swift
                        Text("1. In account.jamf.com, open Integrations → Create integration")
                        Text("2. Scope level: Platform environment, choosing only the "
                            + "environment that holds your Jamf Pro tenant")
                        Text("3. Permissions: Read only, for the report areas you want")
                        Text("4. Copy the client ID and the client secret (shown only once)")
                        Text("5. Copy the environment ID: open the integration and click the "
                            + "environment pill")
                        Text("6. Integrations are valid for six months")
```

In `OnboardingView.swift` line 552 and `ProductConnectSheetView.swift` line 97, change
`under Settings → API Clients.` to `under Administrative → API Clients.` (Jamf's current Protect
documentation).

- [ ] **Step 7: Build and run the onboarding suites**

Run: `cd app && swift build --build-tests 2>&1 | grep "error:" || echo OK`
Run: `cd app && swift test --filter 'Onboarding|Reauthenticate|ModalsViewPolish' 2>&1 | tail -30`
Expected: `OK`, then 0 failures.

- [ ] **Step 8: Ask Tony for the visual check, then commit**

Ask Tony to open onboarding's Platform API path and the Update credentials sheet at
`PageScaffold.minSupportedWidth` and look at the six-line instructions card and each banner tone
(to see one without a tenant, temporarily call `flow.applyConnectionCheck(.noJamfPro)` from a
`#Preview` — do not commit that).

```bash
git add app/Sources/JamfReports/Services/OnboardingFlow.swift \
  app/Sources/JamfReports/Views/ConnectionCheckBanner.swift \
  app/Sources/JamfReports/Views/OnboardingView.swift \
  app/Sources/JamfReports/Views/ReauthenticateSheet.swift \
  app/Sources/JamfReports/Views/ProductConnectSheetView.swift \
  app/Tests/JamfReportsTests/OnboardingConnectionCheckTests.swift
git commit -m "feat(onboarding): stop setup on a scope ID the gateway rejects" \
  -m "Validating a Platform API profile now runs the connection check. A rejected ID blocks
setup with where to find the right one, no Jamf Pro in the environment is a warning, and
Continue without validating appears only when the check could not decide. Setup instructions
name Integrations; Protect names Administrative → API Clients.

DRAFT — needs visual verification at PageScaffold.minSupportedWidth."
```

---
### Task 6: Store each kind's last failure cause, and stop retrying permanent ones

Spec §9.3: the last cause for each kind lives in `state/<kind>.cause.json`, written atomically when
a failure is recorded and deleted when the kind lands; like `.fail`, it stays out of the integrity
manifest (`rewriteManifest` hashes `*.last` only). Spec §9.5: self-remediation's exclusion grows
from exit 2 and 8 to causes 1, 2, 4, 5, 6 and 7.

**Files:**
- Modify: `app/Sources/JamfReports/Services/StateFileStore.swift` — `clearFailures` 170,
  `record` 204–212, private helpers 319–327
- Modify: `app/Sources/JamfReports/Services/WorkspaceStore+Automation.swift` —
  `excludingPermanentUsageFailures` 542–568
- Create: `app/Tests/JamfReportsTests/StateFileCauseTests.swift`
- Modify: `app/Tests/JamfReportsTests/DataFreshnessHealthTests.swift`

**Interfaces:**
- Consumes: `FailureCause` (Task 3).
- Produces: `StateFileStore.record(_:report:at:cause:)` (`cause: FailureCause? = nil`),
  `StateFileStore.cause(for:) -> FailureCause?`.

- [ ] **Step 1: Write the failing tests**

Create `app/Tests/JamfReportsTests/StateFileCauseTests.swift`:

```swift
import XCTest
@testable import JamfReports

/// `state/<kind>.cause.json` (spec 2026-09-12 §9.3): the newest failure's cause, gone once the
/// kind lands, never in the integrity manifest.
final class StateFileCauseTests: XCTestCase {

    private var tempDir: URL!
    private var store: StateFileStore!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sfc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = StateFileStore(directory: tempDir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private let permission = FailureCause(
        kind: .missingPermission, names: ["Inventory > Devices: Read (devices:read)"],
        hint: "grant the Jamf Platform API integration these permissions", exitCode: 5)

    func testAFailureStoresItsCauseAndDate() throws {
        store.record(.failed(exitCode: 5), report: "security", at: t0, cause: permission)
        let stored = try XCTUnwrap(store.cause(for: "security"))
        XCTAssertEqual(stored.kind, .missingPermission)
        XCTAssertEqual(stored.names, permission.names)
        XCTAssertEqual(stored.recordedAt, t0)
        XCTAssertEqual(store.failures(report: "security")?.count, 1)
    }

    func testLandingDeletesTheCause() {
        store.record(.failed(exitCode: 5), report: "security", at: t0, cause: permission)
        store.record(.landed, report: "security", at: t0.addingTimeInterval(60))
        XCTAssertNil(store.cause(for: "security"))
    }

    /// A launch failure has no cause; keeping the earlier one would mislabel it.
    func testAFailureWithoutACauseDropsTheStaleOne() {
        store.record(.failed(exitCode: 5), report: "security", at: t0, cause: permission)
        store.record(.failed(exitCode: nil), report: "security", at: t0.addingTimeInterval(60))
        XCTAssertNil(store.cause(for: "security"))
    }

    func testCauseFilesStayOutOfTheManifest() throws {
        store.record(.landed, report: "overview", at: t0)
        store.record(.failed(exitCode: 5), report: "security", at: t0, cause: permission)
        try store.rewriteManifest()
        let manifestURL = tempDir.appendingPathComponent(SnapshotManifest.fileName)
        let manifest = try String(contentsOf: manifestURL, encoding: .utf8)
        XCTAssertTrue(manifest.contains("overview.last"))
        XCTAssertFalse(manifest.contains("cause"))
    }

    func testACorruptCauseFileReadsAsNone() throws {
        try Data("not json".utf8).write(to: tempDir.appendingPathComponent("security.cause.json"))
        XCTAssertNil(store.cause(for: "security"))
    }
}
```

Append inside `DataFreshnessHealthTests`, after
`testNeverRetryableFailuresAreExcludedFromRemediationTargeting`:

```swift
    /// Spec §9.5: a rejected scope ID, an unserved endpoint and a missing permission cannot be
    /// fixed by retrying; a gateway edge block can.
    func testPermanentFailureCausesAreExcludedFromRemediationTargeting() throws {
        let profile = "causefilter"
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("JRC-Cause-\(UUID().uuidString)", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("Jamf-Reports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspacesRoot.appendingPathComponent(profile, isDirectory: true),
            withIntermediateDirectories: true
        )
        setenv("JRC_TEST_WORKSPACES_ROOT", workspacesRoot.path, 1)
        defer {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: root)
        }
        let store = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
        func record(_ report: String, _ kind: FailureCause.Kind, exit: Int32) {
            store.record(.failed(exitCode: exit), report: report, at: now,
                         cause: FailureCause(kind: kind, names: [], hint: nil, exitCode: exit))
        }
        record("security", .missingPermission, exit: 5)
        record("computers", .unknownEnvironment, exit: 4)
        record("policies", .edgeBlocked, exit: 5)

        let issues = ["security", "computers", "policies"].map {
            DataFreshnessIssue(
                snapshotKind: $0, tier: .inventory, kind: .failing,
                lastSuccess: nil, consecutiveFailures: 2, lastFailure: now
            )
        }
        let remediable = WorkspaceStore.excludingPermanentUsageFailures(issues, profile: profile)
        XCTAssertEqual(remediable.map(\.snapshotKind), ["policies"])
    }
```

- [ ] **Step 2: Run the tests to confirm they fail**

Run: `cd app && swift test --filter 'StateFileCauseTests|DataFreshnessHealthTests' 2>&1 | tail -20`
Expected: compile error, `extra argument 'cause' in call`.

- [ ] **Step 3: Write and read the cause file**

In `StateFileStore.swift`, replace `clearFailures(report:)`:

```swift
    /// Drop the failure record and its cause for `report` — called on every success so the
    /// count means *consecutive* failures rather than lifetime failures.
    func clearFailures(report: String) {
        try? FileManager.default.removeItem(at: failureURL(for: report))
        try? FileManager.default.removeItem(at: causeURL(for: report))
    }
```

Replace `record(_:report:at:)`:

```swift
    func record(
        _ outcome: KindOutcome, report: String, at date: Date, cause: FailureCause? = nil
    ) {
        switch outcome {
        case .landed:
            try? recordRun(report: report, at: date)
            clearFailures(report: report)
        case .failed(let exitCode):
            try? recordFailure(report: report, at: date, exitCode: exitCode)
            if let cause {
                try? writeCause(cause, report: report, at: date)
            } else {
                // A cause left from an earlier failure would mislabel this one.
                try? FileManager.default.removeItem(at: causeURL(for: report))
            }
        }
    }

    /// The classified cause of `report`'s newest failure (spec §9.3), or nil when none is
    /// recorded. Reads never throw, like `failures(report:)`.
    func cause(for report: String) -> FailureCause? {
        guard let data = try? Data(contentsOf: causeURL(for: report)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(FailureCause.self, from: data)
    }

    private func writeCause(_ cause: FailureCause, report: String, at date: Date) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var stamped = cause
        stamped.recordedAt = Date(timeIntervalSince1970: floor(date.timeIntervalSince1970))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try atomicWrite(data: try encoder.encode(stamped), to: causeURL(for: report))
    }
```

Add below `failureURL(for:)`:

```swift
    /// `<report>.cause.json`; outside the manifest, which hashes `.last` files only.
    private func causeURL(for report: String) -> URL {
        directory.appendingPathComponent("\(report).cause.json", isDirectory: false)
    }
```

- [ ] **Step 4: Exclude permanent causes from remediation**

In `WorkspaceStore+Automation.swift`, replace the doc comment and the `permanent` filter and log of
`excludingPermanentUsageFailures` (the function keeps its name):

```swift
    /// Drop issues whose last failure makes retry pointless until someone changes the
    /// credential: `exitCodeUsage` (2, a usage or credentials gate), `exitCodeRefusedByPolicy`
    /// (8, outside the profile's API), or a permanent `FailureCause` — a rejected scope ID, an
    /// endpoint this connection does not serve, or a missing permission (spec §9.5). Only
    /// `tiersToRemediate`'s input narrows; the banner still shows every issue.
    nonisolated static func excludingPermanentUsageFailures(
        _ issues: [DataFreshnessIssue], profile: String
    ) -> [DataFreshnessIssue] {
        guard ProfileService.isValid(profile),
              let stateDir = try? WorkspacePaths.stateDir(for: profile) else { return issues }
        let store = StateFileStore(directory: stateDir)
        let permanent = issues.filter {
            let code = store.lastFailureExitCode(for: $0.snapshotKind)
            return code == CLIBridge.exitCodeUsage
                || code == CLIBridge.exitCodeRefusedByPolicy
                || store.cause(for: $0.snapshotKind)?.isPermanent == true
        }
        guard !permanent.isEmpty else { return issues }
        AppLogger.collect.notice(
            """
            Skipping remediation for \(permanent.count, privacy: .public) kind(s) whose last \
            failure cannot succeed on retry (usage gate, policy refusal, scope or permission): \
            \(permanent.map(\.snapshotKind).sorted().joined(separator: ","), privacy: .public)
            """
        )
        let skip = Set(permanent.map(\.snapshotKind))
        return issues.filter { !skip.contains($0.snapshotKind) }
    }
```

- [ ] **Step 5: Run the tests**

Run: `cd app && swift test --filter 'StateFileCauseTests|StateFileFailureTests|StateFileStoreTests|DataFreshnessHealthTests' 2>&1 | tail -20`
Expected: 0 failures.

- [ ] **Step 6: Commit**

```bash
git add app/Sources/JamfReports/Services/StateFileStore.swift \
  app/Sources/JamfReports/Services/WorkspaceStore+Automation.swift \
  app/Tests/JamfReportsTests/StateFileCauseTests.swift \
  app/Tests/JamfReportsTests/DataFreshnessHealthTests.swift
git commit -m "feat(freshness): keep each kind's failure cause and skip permanent ones" \
  -m "state/<kind>.cause.json holds the newest failure's cause, is removed when the kind
lands, and stays out of the manifest. Self-remediation no longer retries a rejected scope ID,
an unserved endpoint or a missing permission; edge blocks stay retryable."
```

---

### Task 7: Record the cause when a kind fails, and show jamf-cli's hint in Run History

Spec §9.1: besides the envelope, some commands swallow a failed request and exit 0 without data;
a stderr line containing `permission denied (HTTP 403)` classifies that attempt as a missing
permission. Spec §10.3: Run History's warning line carries the full hint, while jamf-cli's message
keeps its 300-character cap.

**Files:**
- Modify: `app/Sources/JamfReports/Services/FailureCause.swift` (add `ForbiddenStderrWatcher`)
- Modify: `app/Sources/JamfReports/Engine/ReportEngine.swift` — `collectOneKind` invoke 2199–2202
  and its `recordUnlandedAttempt` call (Task 1); `recordUnlandedAttempt` (Task 1); add
  `causeSuffix` beside `jamfCLIErrorMessage` (3181)
- Create: `app/Tests/JamfReportsTests/CollectFailureCauseTests.swift`

**Interfaces:**
- Consumes: `FailureCause.classify`, `StateFileStore.record(_:report:at:cause:)`,
  `StateFileStore.cause(for:)`.
- Produces: `ForbiddenStderrWatcher` (`sawForbidden`, `forwarding(to:)`),
  `ReportEngine.causeSuffix(_:) -> String`, `recordUnlandedAttempt(... sawForbidden: Bool = false ...)`.

- [ ] **Step 1: Write the failing tests**

Create `app/Tests/JamfReportsTests/CollectFailureCauseTests.swift`:

```swift
import XCTest
@testable import JamfReports

final class CauseSuffixTests: XCTestCase {

    func testTheSuffixNamesTheCauseAndCarriesTheWholeHintOnOneLine() {
        let cause = FailureCause(
            kind: .missingPermission, names: ["Inventory > Devices: Read (devices:read)"],
            hint: "grant the Jamf Platform API integration\nthese permissions", exitCode: 5)
        XCTAssertEqual(
            ReportEngine.causeSuffix(cause),
            " — cause: missing permission: Inventory > Devices: Read (devices:read)"
                + " — hint: grant the Jamf Platform API integration these permissions")
    }

    func testAnUnclassifiedFailureWithoutAHintAddsNothing() {
        let cause = FailureCause(kind: .other, names: [], hint: nil, exitCode: 1)
        XCTAssertEqual(ReportEngine.causeSuffix(cause), "")
    }
}

/// Collect's scan tier against a stub whose stdout, stderr and exit code come from files.
final class CollectFailureCauseTests: XCTestCase {

    private var root: URL!
    private var answers: URL!
    private let profile = "causecapture"

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("JRC-Cause-\(UUID().uuidString)", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("Jamf-Reports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspacesRoot.appendingPathComponent(profile, isDirectory: true),
            withIntermediateDirectories: true)
        answers = root.appendingPathComponent("answers", isDirectory: true)
        try FileManager.default.createDirectory(at: answers, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", workspacesRoot.path, 1)
        addTeardownBlock { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
        ProfileAuthMethod.invalidateCache()
        let ws = try XCTUnwrap(ProfileService.workspaceURL(for: profile))
        try "jamf_cli:\n  profile: \"\(profile)\"\n".write(
            to: ws.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    /// NOT named `jamf-cli` (codesign gate). Every invocation answers the same way.
    private func runScan(stdout: String, stderr: String, exit: Int) async throws -> [String] {
        try stdout.write(to: answers.appendingPathComponent("stdout"),
                         atomically: true, encoding: .utf8)
        try stderr.write(to: answers.appendingPathComponent("stderr"),
                         atomically: true, encoding: .utf8)
        let stub = root.appendingPathComponent("stub-cli")
        let script = """
        #!/bin/sh
        cat "\(answers.path)/stdout"
        cat "\(answers.path)/stderr" >&2
        exit \(exit)
        """
        try script.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let collector = CauseLogCollector()
        // Every kind fails, so the run is dead and throws; this test reads what was recorded.
        try? await ReportEngine.collect(
            profile: profile, workspacePaths: WorkspacePaths.self, tiers: [.scan],
            force: true, locateJamfCLI: { stub }, onLine: collector.append)
        return collector.texts
    }

    func testAPermissionEnvelopeIsRecordedAndShownWithItsHint() async throws {
        let hint = "grant the Jamf Platform API integration these permissions in Jamf Account: "
            + "Inventory > Devices: Read (devices:read). Names are as the permission picker "
            + "shows them: <map URL>"
        let object: [String: Any] = [
            "error": "request failed", "message": "permission denied (HTTP 403)",
            "exitCode": 5, "exitCodeName": "permission", "hint": hint,
        ]
        let envelope = String(decoding: try JSONSerialization.data(withJSONObject: object),
                              as: UTF8.self)

        let log = try await runScan(stdout: envelope, stderr: "", exit: 5)

        let store = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
        let cause = try XCTUnwrap(store.cause(for: "patch-device-failures"))
        XCTAssertEqual(cause.kind, .missingPermission)
        XCTAssertEqual(cause.names, ["Inventory > Devices: Read (devices:read)"])
        let warn = try XCTUnwrap(log.first { $0.hasPrefix("[warn] patch-device-failures: exit 5") })
        XCTAssertTrue(warn.contains("cause: missing permission: Inventory > Devices"), warn)
        XCTAssertTrue(warn.contains("hint: grant the Jamf Platform API integration"), warn)
    }

    /// `pro report update-status` exits 0 after both its fetches fail (spec §9.1).
    func testASwallowed403IsRecordedAsAMissingPermission() async throws {
        _ = try await runScan(
            stdout: "", stderr: "Error: fetching plans: permission denied (HTTP 403): forbidden\n",
            exit: 0)
        let store = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
        XCTAssertEqual(store.cause(for: "update-device-failures")?.kind, .missingPermission)
    }
}

private final class CauseLogCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    var append: @Sendable (CLIBridge.LogLine) -> Void {
        { line in self.lock.withLock { self.lines.append(line.text) } }
    }

    var texts: [String] { lock.withLock { lines } }
}
```

- [ ] **Step 2: Run the tests to confirm they fail**

Run: `cd app && swift test --filter 'CauseSuffixTests|CollectFailureCauseTests' 2>&1 | tail -20`
Expected: compile error, `type 'ReportEngine' has no member 'causeSuffix'`.

- [ ] **Step 3: Add the stderr watcher**

Append to `FailureCause.swift`:

```swift
/// Watches one kind's streamed stderr for jamf-cli's 403 line, for commands that swallow a
/// failed request and exit 0 without data (spec §9.1).
final class ForbiddenStderrWatcher: @unchecked Sendable {
    private let lock = NSLock()
    private var seen = false

    var sawForbidden: Bool { lock.withLock { seen } }

    func forwarding(
        to onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void
    ) -> @Sendable (CLIBridge.LogLine) -> Void {
        { line in
            if line.text.contains(FailureCause.forbiddenStderrMarker) {
                self.lock.withLock { self.seen = true }
            }
            onLine(line)
        }
    }
}
```

- [ ] **Step 4: Classify, record and print the cause**

In `ReportEngine.swift`, add after `jamfCLIErrorMessage(in:limit:)`:

```swift
    /// The cause and jamf-cli's whole hint for a Run History line (spec §10.3). The 300-character
    /// cap applies to jamf-cli's message, not to this.
    static func causeSuffix(_ cause: FailureCause) -> String {
        var suffix = cause.kind == .other ? "" : " — cause: \(cause.label)"
        if let hint = cause.hint {
            suffix += " — hint: " + hint.components(separatedBy: .newlines).joined(separator: " ")
        }
        return suffix
    }
```

In `collectOneKind`, replace the `invokeWithRetry` call with:

```swift
        let stderrWatcher = ForbiddenStderrWatcher()
        let captureResult = await Self.invokeWithRetry(
            kind: kind, arguments: arguments, supportsQuietFlags: supportsQuietFlags,
            bin: bin, bridge: bridge, onLine: stderrWatcher.forwarding(to: onLine)
        )
```

and in its `recordUnlandedAttempt(...)` call add `sawForbidden: stderrWatcher.sawForbidden,` after
`data: data,`.

Replace `recordUnlandedAttempt` (from Task 1) with:

```swift
    /// An attempt that produced nothing to save: classify it, count it, say why, and keep the
    /// cache, or fail the run under `use_cached_data: false`. Shared with the per-benchmark
    /// reports.
    static func recordUnlandedAttempt(
        kind: String,
        exitCode: Int32,
        data: Data,
        sawForbidden: Bool = false,
        useCachedData: Bool,
        dataDir: URL,
        stateStore: StateFileStore?,
        collectStart: Date,
        onLine: @Sendable (CLIBridge.LogLine) -> Void
    ) throws -> KindCollectResult {
        let cause = FailureCause.classify(
            exitCode: exitCode, stdout: data, sawForbiddenOnStderr: sawForbidden)
        let outcome = CollectOutcome(kind: kind, exitCode: exitCode)
        stateStore?.record(.failed(exitCode: exitCode), report: kind, at: collectStart,
                           cause: cause)
        guard useCachedData else {
            onLine(.init(
                timestamp: Date(), level: .fail,
                text: "[error] \(kind): exit \(exitCode)\(Self.causeSuffix(cause)) "
                    + "— failing (use_cached_data=false)"
            ))
            throw ReportEngineError.collectFailed(kind: kind, exitCode: exitCode)
        }
        // Only claim "using cached" when a cached snapshot for this kind exists; otherwise
        // the generate step has nothing to fall back to and the copy would mislead.
        let kindDir = dataDir.appendingPathComponent(kind, isDirectory: true)
        let cacheNote = FileManager.newestJSONFile(in: kindDir) != nil
            ? "skipped (using cached)"
            : "no cached snapshot available"
        // jamf-cli's own reason beats a bare exit code in Run History.
        let reason = Self.jamfCLIErrorMessage(in: data).map { " (\($0))" } ?? ""
        onLine(.init(timestamp: Date(), level: .warn,
                     text: "[warn] \(kind): exit \(exitCode)\(reason) — \(cacheNote)"
                        + Self.causeSuffix(cause)))
        return KindCollectResult(outcome: outcome, saved: false)
    }
```

The warning line still starts `[warn] <kind>:`, which is all `ExistingCLISetupFlow.ingest` parses.

- [ ] **Step 5: Run the tests**

Run: `cd app && swift test --filter 'CauseSuffixTests|CollectFailureCauseTests|CollectHonestyTests|ExistingCLISetupFlowTests|CollectKindStatusTests' 2>&1 | tail -30`
Expected: 0 failures.

- [ ] **Step 6: Commit**

```bash
git add app/Sources/JamfReports/Services/FailureCause.swift \
  app/Sources/JamfReports/Engine/ReportEngine.swift \
  app/Tests/JamfReportsTests/CollectFailureCauseTests.swift
git commit -m "feat(collect): record why a kind failed and show jamf-cli's hint" \
  -m "Collect classifies each failed attempt from the JSON envelope, or a 403 line on stderr
for commands that exit 0 without data, stores the cause, and appends it with the full hint to
the Run History warning line."
```

---
### Task 8: Name the cause in the health banner

Spec §10.1: the detail line names the cause and, for permission causes, the permission.

**Files:**
- Modify: `app/Sources/JamfReports/Services/DataFreshnessHealth.swift` — `DataFreshnessIssue` 11–47,
  `KindCollectionState` 50–55, the three constructions in `evaluate` 92–117
- Modify: `app/Sources/JamfReports/Services/StateFileStore.swift` — `collectionStates` 217–227
- Modify: `app/Sources/JamfReports/Theme/GlobalHealthBanner.swift` — failing headline 145–153
- Test: `app/Tests/JamfReportsTests/GlobalHealthBannerTests.swift`,
  `app/Tests/JamfReportsTests/DataFreshnessHealthTests.swift`,
  `app/Tests/JamfReportsTests/StateFileCauseTests.swift`

**Interfaces:**
- Consumes: `StateFileStore.cause(for:)` (Task 6), `FailureCause.label`, `GlobalHealthBanner.maxNamedKinds`.
- Produces: `DataFreshnessIssue.cause: FailureCause?` and `KindCollectionState.cause: FailureCause?`
  (both `var … = nil`, so existing memberwise calls still compile),
  `GlobalHealthBanner.failingReason(_:) -> String`.

- [ ] **Step 1: Write the failing tests**

Append inside `GlobalHealthBannerTests`:

```swift
    // MARK: - Cause in the detail line (2.8.1)

    private func failing(_ kind: String, _ cause: FailureCause?) -> DataFreshnessIssue {
        DataFreshnessIssue(
            snapshotKind: kind, tier: .inventory, kind: .failing,
            lastSuccess: nil, consecutiveFailures: 2, lastFailure: nil, cause: cause
        )
    }

    private func permission(_ names: [String]) -> FailureCause {
        FailureCause(kind: .missingPermission, names: names, hint: nil, exitCode: 5)
    }

    func testASharedMissingPermissionIsNamed() throws {
        let grant = "Compliance > Compliance Benchmarks: Read (compliance-benchmarks:read)"
        let headline = try XCTUnwrap(GlobalHealthBanner.headline(
            freshness: [failing("compliance-rules", permission([grant])),
                        failing("compliance-devices", permission([grant]))],
            automation: []))
        XCTAssertEqual(headline.detail,
                       "compliance-rules, compliance-devices — missing permission: " + grant)
    }

    func testASharedRejectedEnvironmentIDIsNamed() throws {
        let unknown = FailureCause(kind: .unknownEnvironment, names: [], hint: nil, exitCode: 4)
        let headline = try XCTUnwrap(GlobalHealthBanner.headline(
            freshness: [failing("security", unknown), failing("computers", unknown)],
            automation: []))
        XCTAssertEqual(headline.detail,
                       "security, computers — the gateway does not recognise the environment ID")
    }

    func testMixedOrMissingCausesKeepTheGeneralWording() throws {
        let headline = try XCTUnwrap(GlobalHealthBanner.headline(
            freshness: [failing("security", permission([])), failing("computers", nil)],
            automation: []))
        XCTAssertEqual(headline.detail,
                       "security, computers — data on screens using them is out of date")
    }

    func testManyPermissionNamesCollapse() {
        let reason = GlobalHealthBanner.failingReason(
            [failing("a", permission(["P1", "P2"])), failing("b", permission(["P2", "P3", "P4"]))])
        XCTAssertEqual(reason, "missing permission: P1; P2; P3 +1 more")
    }
```

Append inside `DataFreshnessHealthTests`:

```swift
    func testAnIssueCarriesItsKindsRecordedCause() {
        let cause = FailureCause(kind: .unknownEnvironment, names: [], hint: nil, exitCode: 4)
        let issues = DataFreshnessHealth.evaluate(
            states: [KindCollectionState(kind: "security", lastSuccess: nil,
                                         consecutiveFailures: 2, lastFailure: now, cause: cause)],
            hasCollectedBefore: true, now: now)
        XCTAssertEqual(issues.first?.cause, cause)
    }
```

Append inside `StateFileCauseTests`:

```swift
    func testCollectionStatesCarryTheCause() {
        store.record(.failed(exitCode: 5), report: "security", at: t0, cause: permission)
        XCTAssertEqual(store.collectionStates(for: ["security"]).first?.cause?.kind,
                       .missingPermission)
    }
```

- [ ] **Step 2: Run the tests to confirm they fail**

Run: `cd app && swift test --filter 'GlobalHealthBannerTests|DataFreshnessHealthTests|StateFileCauseTests' 2>&1 | tail -20`
Expected: compile error, `extra argument 'cause' in call`.

- [ ] **Step 3: Carry the cause from disk to the issue**

In `DataFreshnessHealth.swift`, add as the last stored property of `DataFreshnessIssue` (after
`let lastFailure: Date?`) and of `KindCollectionState` (after `let lastFailure: Date?`):

```swift
    /// The newest failure's classified cause, when one was recorded.
    var cause: FailureCause? = nil
```

In `DataFreshnessHealth.evaluate`, add `, cause: state.cause` after `lastFailure: state.lastFailure`
in all three `DataFreshnessIssue(...)` constructions.

In `StateFileStore.collectionStates(for:)`, change `lastFailure: failure?.last` to:

```swift
                lastFailure: failure?.last,
                cause: cause(for: kind)
```

- [ ] **Step 4: Name the cause in the banner**

In `GlobalHealthBanner.headline`, change the failing `detail:` argument to:

```swift
                detail: kindList(failing) + " — " + failingReason(failing)
```

Add after `countPhrase`:

```swift
    /// The cause when every failing kind recorded the same one (spec §10.1), with the
    /// permission names for a missing permission; otherwise the general wording.
    nonisolated static func failingReason(_ failing: [DataFreshnessIssue]) -> String {
        let causes = failing.compactMap(\.cause)
        guard causes.count == failing.count, let first = causes.first, first.kind != .other,
              causes.allSatisfy({ $0.kind == first.kind }) else {
            return "data on screens using " + (failing.count == 1 ? "it" : "them")
                + " is out of date"
        }
        guard first.kind == .missingPermission else { return first.label }
        var seen: Set<String> = []
        let names = causes.flatMap(\.names).filter { seen.insert($0).inserted }
        guard !names.isEmpty else { return first.label }
        let extra = names.count - min(names.count, maxNamedKinds)
        return "missing permission: " + names.prefix(maxNamedKinds).joined(separator: "; ")
            + (extra > 0 ? " +\(extra) more" : "")
    }
```

- [ ] **Step 5: Run the tests**

Run: `cd app && swift test --filter 'GlobalHealthBanner|DataFreshnessHealthTests|StateFileCauseTests|WorkspaceFreshnessEvaluationTests' 2>&1 | tail -20`
Expected: 0 failures (the `GroupCGlobalHealthBannerWordingTests` suite matches the filter too).

- [ ] **Step 6: Commit**

```bash
git add app/Sources/JamfReports/Services/DataFreshnessHealth.swift \
  app/Sources/JamfReports/Services/StateFileStore.swift \
  app/Sources/JamfReports/Theme/GlobalHealthBanner.swift \
  app/Tests/JamfReportsTests/GlobalHealthBannerTests.swift \
  app/Tests/JamfReportsTests/DataFreshnessHealthTests.swift \
  app/Tests/JamfReportsTests/StateFileCauseTests.swift
git commit -m "feat(health): name the failure cause in the health strip" \
  -m "When every failing source recorded the same cause, the detail line says what it is,
and for a missing permission which ones jamf-cli asked for."
```

---

### Task 9: Say why a dead run failed, and name both places a grant lives

Spec §9.6. Deviation 1 in Global Constraints applies: any rejected-ID failure names the run.

**Files:**
- Modify: `app/Sources/JamfReports/Engine/ReportEngine.swift` — `CollectOutcome` 1474,
  `isCollectDead` 1529 (add `DeadRunCause` after it), `enforceCollectVerdicts` dead block 1920–1927,
  `recordUnlandedAttempt` (Task 7), `ReportEngineError.collectDead` 3812 and its description 3843
- Modify: `app/Sources/JamfReports/Services/CLIBridge.swift` — `explainExit` 781–789,
  `explainOperationError` 820–832
- Test: `app/Tests/JamfReportsTests/Engine/CollectAuthDeadVerdictTests.swift`,
  `app/Tests/JamfReportsTests/OperationErrorRoutingTests.swift`,
  `app/Tests/JamfReportsTests/CLIBridgeExplainExitTests.swift`,
  `app/Tests/JamfReportsTests/CollectHonestyTests.swift` (line 93)

**Interfaces:**
- Consumes: `FailureCause.Kind` (Task 3), the cause computed in `recordUnlandedAttempt` (Task 7).
- Produces: `CollectOutcome.cause: FailureCause.Kind?` (`var … = nil`),
  `ReportEngine.DeadRunCause` (`.outage`, `.noPermission`, `.rejectedID`),
  `ReportEngine.deadRunCause(_ outcomes: [CollectOutcome]) -> DeadRunCause`,
  `ReportEngineError.collectDead(profile:failedCount:cause:)` with `cause` defaulting to `.outage`.

- [ ] **Step 1: Write the failing tests**

Append inside `CollectDeadVerdictTests`:

```swift
    // MARK: - Dead-run cause (spec §9.6)

    private func failed(
        _ kind: String, _ exit: Int32, _ cause: FailureCause.Kind?
    ) -> ReportEngine.CollectOutcome {
        ReportEngine.CollectOutcome(kind: kind, exitCode: exit, cause: cause)
    }

    /// Jamf Pro commands on a gateway profile drop the 404 body, so one named rejection is
    /// enough.
    func testAnyRejectedIDNamesTheDeadRun() {
        let outcomes = [failed("security", 4, .other),
                        failed("compliance-rules", 4, .unknownEnvironment)]
        XCTAssertEqual(ReportEngine.deadRunCause(outcomes), .rejectedID)
    }

    func testEveryFailureAMissingPermissionNamesTheDeadRun() {
        let outcomes = [failed("security", 5, .missingPermission),
                        failed("computers", 5, .missingPermission),
                        failed("duplicate-serials", 2, .other)]
        XCTAssertEqual(ReportEngine.deadRunCause(outcomes), .noPermission,
                       "a usage error says nothing about access and is left out")
    }

    func testAnythingElseIsAnOutage() {
        XCTAssertEqual(ReportEngine.deadRunCause(
            [failed("security", 5, .missingPermission), failed("computers", 1, .other)]), .outage)
        XCTAssertEqual(ReportEngine.deadRunCause(
            [failed("security", ReportEngine.launchFailureExitCode, nil)]), .outage)
        XCTAssertEqual(ReportEngine.deadRunCause([]), .outage)
    }
```

Append inside `OperationErrorRoutingTests`:

```swift
    func test_collectDeadWithNoReadableSource_routesAsPermissionDenied() {
        let msg = CLIBridge.explainOperationError(
            ReportEngineError.collectDead(profile: "p", failedCount: 9, cause: .noPermission),
            operation: "Collect")
        XCTAssertEqual(msg, CLIBridge.explainExit(CLIBridge.exitCodePermissionDenied,
                                                  operation: "Collect"))
    }

    func test_collectDeadWithARejectedID_namesTheID() {
        let error = ReportEngineError.collectDead(profile: "p", failedCount: 9, cause: .rejectedID)
        XCTAssertTrue(CLIBridge.explainOperationError(error, operation: "Collect")
            .contains("environment or tenant ID"))
        XCTAssertTrue(error.errorDescription?.contains("environment or tenant ID") ?? false)
    }
```

Append inside `CLIBridgeExplainExitTests`:

```swift
    func testPermissionDeniedNamesBothPlacesAGrantLives() {
        let msg = CLIBridge.explainExit(CLIBridge.exitCodePermissionDenied, operation: "Collect")
        XCTAssertTrue(msg.contains("API role in Jamf Pro"), msg)
        XCTAssertTrue(msg.contains("integration in Jamf Account"), msg)
    }

    func testUnauthorizedNotesThatIntegrationsExpire() {
        let msg = CLIBridge.explainExit(CLIBridge.exitCodeUnauthorized, operation: "Collect")
        XCTAssertTrue(msg.contains("six months"), msg)
    }
```

In `CollectHonestyTests.swift` line 93, change `catch ReportEngineError.collectDead(_, let failedCount)`
to `catch ReportEngineError.collectDead(_, let failedCount, _)`.

- [ ] **Step 2: Run the tests to confirm they fail**

Run: `cd app && swift test --filter 'CollectDeadVerdictTests|OperationErrorRoutingTests|CLIBridgeExplainExitTests' 2>&1 | tail -20`
Expected: compile error, `extra argument 'cause' in call`.

- [ ] **Step 3: Carry the cause on the outcome and pick the dead-run cause**

In `ReportEngine.swift`, add to `CollectOutcome` after `let exitCode: Int32`:

```swift
        /// The failed attempt's classified cause; nil for successes and launch failures.
        var cause: FailureCause.Kind? = nil
```

In `recordUnlandedAttempt`, change `let outcome = CollectOutcome(kind: kind, exitCode: exitCode)`
to `let outcome = CollectOutcome(kind: kind, exitCode: exitCode, cause: cause.kind)`.

Add after `isCollectDead`:

```swift
    /// What a dead run's failures say, for its message (spec §9.6).
    enum DeadRunCause: Equatable, Sendable {
        case outage
        /// Every failure was a missing permission: Jamf answered, nothing was readable.
        case noPermission
        /// A failure named a rejected scope ID. One is enough: Jamf Pro commands on a gateway
        /// profile drop the 404 body (spec §14.1), so they never name it themselves.
        case rejectedID
    }

    /// Exit-2 outcomes are left out, as in `isCollectDead`: a usage error says nothing about
    /// access.
    static func deadRunCause(_ outcomes: [CollectOutcome]) -> DeadRunCause {
        let causes = outcomes.filter { $0.exitCode != CLIBridge.exitCodeUsage }.map(\.cause)
        if causes.contains(where: { $0 == .scopeRejected || $0 == .unknownEnvironment }) {
            return .rejectedID
        }
        if !causes.isEmpty, causes.allSatisfy({ $0 == .missingPermission }) {
            return .noPermission
        }
        return .outage
    }
```

In `enforceCollectVerdicts`, replace the body of `if Self.isCollectDead(...) { ... }` with:

```swift
            let error = ReportEngineError.collectDead(
                profile: profile, failedCount: outcomes.count, cause: Self.deadRunCause(outcomes)
            )
            let msg = "[error] " + (error.errorDescription ?? "collect failed")
            AppLogger.collect.error("\(msg, privacy: .public)")
            onLine(.init(timestamp: Date(), level: .fail, text: msg))
            throw error
```

Change the enum case (line 3812) to:

```swift
    case collectDead(profile: String, failedCount: Int, cause: ReportEngine.DeadRunCause = .outage)
```

and replace its `errorDescription` case (line 3843) with:

```swift
        case .collectDead(let p, let n, let cause):
            switch cause {
            case .outage:
                return "All \(n) live jamf-cli call(s) failed for profile '\(p)' (server " +
                    "unreachable or jamf-cli broken). No snapshot was written. Check network " +
                    "connectivity and jamf-cli health, then re-run collect."
            case .noPermission:
                return "All \(n) live jamf-cli call(s) failed for profile '\(p)': the connection " +
                    "reached Jamf but cannot read any data source. No snapshot was written. " +
                    "Grant read permissions to the profile's API role or integration; the " +
                    "Permissions & Access wiki page lists them per report area."
            case .rejectedID:
                return "All \(n) live jamf-cli call(s) failed for profile '\(p)': the Jamf " +
                    "Platform gateway rejected the profile's environment or tenant ID. No " +
                    "snapshot was written. Correct the ID with Update credentials in Data Sources."
            }
```

The School collect's `throw ReportEngineError.collectDead(profile:failedCount:)` keeps compiling
through the default.

- [ ] **Step 4: Update the explanations**

In `CLIBridge.explainExit`, replace the `exitCodeUnauthorized` and `exitCodePermissionDenied` cases:

```swift
        case exitCodeUnauthorized:
            detail = "authentication failed (401) — this profile's credentials are invalid or "
                + "expired. Re-authenticate it from Data Sources. A Jamf Platform API "
                + "integration is valid for six months; an expired one needs a replacement in "
                + "Jamf Account."
        case exitCodePermissionDenied:
            detail = "permission denied (403) — this profile lacks a required permission. For a "
                + "Jamf Pro API client, grant the privilege to its API role in Jamf Pro; for a "
                + "Jamf Platform API integration, grant the permission to the integration in "
                + "Jamf Account."
```

In `explainOperationError`, replace the `collectDead` `if`:

```swift
        if case let ReportEngineError.collectDead(_, _, cause) = error {
            switch cause {
            case .outage:
                return explainExit(1, operation: operation)                   // all kinds failed
            case .noPermission:
                return explainExit(exitCodePermissionDenied, operation: operation)
            case .rejectedID:
                return "\(operation) failed: the Jamf Platform gateway rejected this profile's "
                    + "environment or tenant ID. Correct it with Update credentials in Data "
                    + "Sources; the environment ID is in the integration's details in Jamf Account."
            }
        }
```

- [ ] **Step 5: Run the tests**

Run: `cd app && swift test --filter 'CollectAuthDeadVerdictTests|CollectDeadVerdictTests|OperationErrorRoutingTests|CLIBridgeExplainExitTests|CollectHonestyTests' 2>&1 | tail -30`
Expected: 0 failures.

- [ ] **Step 6: Commit**

```bash
git add app/Sources/JamfReports/Engine/ReportEngine.swift \
  app/Sources/JamfReports/Services/CLIBridge.swift \
  app/Tests/JamfReportsTests/Engine/CollectAuthDeadVerdictTests.swift \
  app/Tests/JamfReportsTests/OperationErrorRoutingTests.swift \
  app/Tests/JamfReportsTests/CLIBridgeExplainExitTests.swift \
  app/Tests/JamfReportsTests/CollectHonestyTests.swift
git commit -m "fix(collect): say whether a dead run lacked permissions or had a rejected ID" \
  -m "A run where every source failed no longer blames the network when the gateway rejected
the scope ID or nothing was readable. The 403 explanation names both the Jamf Pro API role and
the Jamf Account integration; the 401 explanation notes integrations last six months."
```

---
### Task 10: Count a run as dead when nothing landed

Spec §13.2: `isCollectDead` counts exit 0 as success, but `pro report update-status` exits 0 after
both its fetches fail and `pro audit` reports every check passed after every check failed. Success
now means a snapshot reached disk. `isCollectAuthDead` keeps counting exit 0: authentication
precedes the response body, so exit 0 still proves the credentials work.

**Files:**
- Modify: `app/Sources/JamfReports/Engine/ReportEngine.swift` — `isCollectDead` doc and body
  1503–1537, `enforceCollectVerdicts` call 1920, School collect 2870, 2898, 2912
- Modify: `app/Tests/JamfReportsTests/Engine/CollectAuthDeadVerdictTests.swift` (`CollectDeadVerdictTests`)
- Modify: `app/Tests/JamfReportsTests/CollectHonestyTests.swift` — lines 139, 143, plus a new test

**Interfaces:**
- Produces: `ReportEngine.isCollectDead(_ outcomes:, savedKinds: Set<String>, skippedNotDueCount: Int = 0) -> Bool`.

- [ ] **Step 1: Write the failing tests**

Append inside `CollectDeadVerdictTests`:

```swift
    /// Exit 0 is not evidence: some jamf-cli reports exit 0 after every fetch failed.
    func testExitZeroThatLandedNothingIsCollectDead() {
        let outcomes = [outcome("update-status", 0), outcome("security", 1)]
        XCTAssertTrue(ReportEngine.isCollectDead(outcomes, savedKinds: []))
    }
```

Append inside `CollectHonestyTests`, after `testLaunchFailureSentinelIsNeitherSuccessNorAuthNorUsage`:

```swift
    /// Every command exited 0 and printed nothing, so nothing was saved: the run fetched no
    /// data and must not read as healthy.
    func testExitZeroWithNothingSavedIsADeadCollect() async throws {
        try writeConfig("jamf_cli:\n  profile: \"\(profile)\"\n")
        let stub = try makeStub(exitCode: 0, stdout: "")

        do {
            try await ReportEngine.collect(
                profile: profile, workspacePaths: WorkspacePaths.self, tiers: [.scan],
                force: true, locateJamfCLI: { stub }, onLine: { _ in })
            XCTFail("a run that saved nothing must not succeed")
        } catch ReportEngineError.collectDead(_, let failedCount, _) {
            XCTAssertEqual(failedCount, 2)
        }
    }
```

- [ ] **Step 2: Run the tests to confirm they fail**

Run: `cd app && swift test --filter 'CollectDeadVerdictTests|CollectHonestyTests' 2>&1 | tail -20`
Expected: compile error, `extra argument 'savedKinds' in call`.

- [ ] **Step 3: Base the verdict on what landed**

In `ReportEngine.swift`, replace the last paragraph of `isCollectDead`'s doc comment (from
`/// Returns false for an empty outcome set` to the end of the comment) and the function with:

```swift
    /// Returns false for an empty outcome set, when any kind landed a snapshot this run, when
    /// at least one kind was skipped as not due, and for a failure set that is exit-2-only.
    /// An exit code is not evidence of success: `pro report update-status` exits 0 after both
    /// its fetches fail (connection-access spec §13.2), so success means data reached disk.
    static func isCollectDead(
        _ outcomes: [CollectOutcome], savedKinds: Set<String>, skippedNotDueCount: Int = 0
    ) -> Bool {
        guard !outcomes.isEmpty, savedKinds.isEmpty else { return false }
        guard skippedNotDueCount == 0 else { return false }
        return outcomes.contains { $0.exitCode != CLIBridge.exitCodeUsage }
    }
```

In `enforceCollectVerdicts`, change the call to:

```swift
        if Self.isCollectDead(
            outcomes, savedKinds: savedKinds, skippedNotDueCount: skippedNotDueCount
        ) {
```

In the School collect: add `var schoolSaved: Set<String> = []` on the line after
`var schoolOutcomes: [CollectOutcome] = []` (2870); add `schoolSaved.insert(kind)` on the line after
its `try saveSnapshot(data: data, kind: kind, dataDir: dataDir)` (2898, the first of the two such
lines in the file — the second, 2981, is Protect); and change `if Self.isCollectDead(schoolOutcomes)`
(2912) to `if Self.isCollectDead(schoolOutcomes, savedKinds: schoolSaved)`.

- [ ] **Step 4: Update the existing verdict tests**

In `CollectDeadVerdictTests`, pass `savedKinds:` to every existing call. Kinds that exited 0 or 7
in a test are the ones that landed:

| Test | New call |
|---|---|
| `testAllFailNoAuth_isCollectDead`, `testAllFailRateLimited_isCollectDead`, `testAllFailWithOne401_collectDeadIsAlsoTrue` | `isCollectDead(outcomes, savedKinds: [])` |
| `testOneSuccessPlusFailures_isNotCollectDead`, `testSingleSuccessAmongManyFailures_isNotCollectDead` | `isCollectDead(outcomes, savedKinds: ["overview"])` |
| `testExit7IsNotCollectDead` | `isCollectDead([outcome("security", 7)], savedKinds: ["security"])` |
| `testAllSuccess_isNotCollectDead` | `isCollectDead(outcomes, savedKinds: ["overview", "security", "computers"])` |
| `testEmpty_isNotCollectDead` | `isCollectDead([], savedKinds: [])` |
| `testFailuresOnlyWithSkipsPresent_isNotCollectDead` | `isCollectDead(outcomes, savedKinds: [], skippedNotDueCount: 4)` |
| `testAllExitTwoNoSkips_isNotCollectDead`, `testNoSkipsWithNonUsageFailure_isCollectDead` | `isCollectDead(outcomes, savedKinds: [], skippedNotDueCount: 0)` |
| `testExit7CountsAsSuccessRegardlessOfSkips_isNotCollectDead` | `isCollectDead(outcomes, savedKinds: ["ea-results"], skippedNotDueCount: 0)` |

Update the two doc comments that say exit 7 "counts as success" to say a saved partial result
does. In `CollectHonestyTests`, line 139 becomes `ReportEngine.isCollectDead(launchFailed, savedKinds: [])`
and line 143 `ReportEngine.isCollectDead(launchFailed, savedKinds: [], skippedNotDueCount: 1)`.

- [ ] **Step 5: Run the tests**

Run: `cd app && swift test --filter 'CollectAuthDeadVerdictTests|CollectDeadVerdictTests|CollectHonestyTests|CollectClaimLifecycleTests|DeviceScanCollectTests' 2>&1 | tail -30`
Expected: 0 failures.

- [ ] **Step 6: Commit**

```bash
git add app/Sources/JamfReports/Engine/ReportEngine.swift \
  app/Tests/JamfReportsTests/Engine/CollectAuthDeadVerdictTests.swift \
  app/Tests/JamfReportsTests/CollectHonestyTests.swift
git commit -m "fix(collect): a run that saved nothing is dead whatever the exit codes" \
  -m "Some jamf-cli reports exit 0 after every fetch failed, which kept a run that fetched
nothing from being reported as failed. The outage verdict now asks whether any snapshot landed."
```

---

### Task 11: Documentation, mutation checks and the full gate

**Files:**
- Modify: `CHANGELOG.md`, `CLAUDE.md`, `AGENTS.md`
- Modify (Step 1 gate): `docs/wiki/02-App-Onboarding.md`, `docs/wiki/09-Diagnostics-and-Troubleshooting.md`,
  `docs/wiki/10-Security-and-Operational-Considerations.md`, `docs/wiki/13-Permissions-and-Access.md`

- [ ] **Step 1: Check where the wiki edits can go**

Run: `git fetch origin && git merge-base --is-ancestor origin/docs/platform-access-wiki HEAD && echo in-branch || echo not-in-branch`

The Known Issues text below was added on `docs/platform-access-wiki`. If the result is
`not-in-branch`, stop and ask Tony whether to merge that branch into this one (a clean merge as of
2026-09-14) or to leave Steps 4–7 until it lands. Steps 2, 3 and 8–10 do not depend on it.

- [ ] **Step 2: CHANGELOG**

In `CHANGELOG.md`, insert under `## [Unreleased]`:

```markdown
Jamf Platform API profiles collect Compliance Benchmarks, setup catches a wrong environment ID,
and a source that fails for want of a permission says which one.

### Fixed

- Compliance Benchmarks fill on Jamf Platform API profiles. Each collect lists the tenant's
  benchmarks and fetches rule and device results for each; with several, the screen has a
  benchmark picker and the workbook sheets a Benchmark column. List titles under
  `platform.compliance_benchmarks` to collect only those.
- Validating a Jamf Platform API profile checks the environment or tenant ID with the gateway,
  in onboarding and in Update credentials. A rejected ID stops setup and says where the right one
  is; an ID with no Jamf Pro behind it is a warning.
- A source that fails because the credential lacks a permission, or because the gateway rejected
  the ID, is named in the health strip and in the Run History warning line with jamf-cli's full
  hint, and is no longer retried every hour.
- When every source fails, the error says whether the gateway rejected the ID or nothing was
  readable instead of blaming the network, and a collect where commands exited 0 but nothing
  was saved is reported as failed.
- Setup instructions name Jamf Account's Integrations page and Jamf Protect's Administrative →
  API Clients. The permission-denied explanation names both the Jamf Pro API role and the Jamf
  Account integration; the expired-credentials explanation notes integrations last six months.
```

- [ ] **Step 3: CLAUDE.md and AGENTS.md**

In `CLAUDE.md`, insert after the **Platform-only kinds (2.7.0)** paragraph (which ends
`read as "not platform".`):

```markdown
**Compliance Benchmarks (2.8.1).** `pro report compliance-rules` and `compliance-devices` take a
benchmark title. `ReportEngine+ComplianceBenchmarks` lists benchmarks once per run
(`pro compliance-benchmarks list`), narrows them to `platform.compliance_benchmarks` when set
(jamf-cli matches titles exactly; a title two benchmarks share is skipped), runs both reports per
title and saves one snapshot per kind whose rows carry `benchmark`. A tenant with no benchmarks
lands empty snapshots. A failed listing fails both kinds with its exit code.

**Failure causes (2.8.1).** `recordUnlandedAttempt` classifies every unlanded attempt with
`FailureCause.classify` (the JSON envelope on stdout, or a `permission denied (HTTP 403)`
stderr line for commands that exit 0 without data), stores it in `state/<kind>.cause.json`
(removed on landing, outside the manifest), and appends ` — cause: … — hint: …` to the Run
History warning line. `isCollectDead` asks whether any kind landed, not whether any exited 0.
```

In the service table, replace this passage of the `DataFreshnessHealth` row:

```text
or `CLIBridge.exitCodeRefusedByPolicy` (8, jamf-cli 1.28+), a command outside the profile's published API; both fail identically on retry
```

with:

```text
`CLIBridge.exitCodeRefusedByPolicy` (8, jamf-cli 1.28+), a command outside the profile's published API, or a permanent recorded `FailureCause` (rejected scope ID, endpoint not served, missing permission); all fail identically on retry
```

and add these two rows directly after the `DataFreshnessHealth` row:

```markdown
| `FailureCause` | (2.8.1) Pure classifier for why a jamf-cli call failed (connection-access spec §9.2): scope rejected, unknown environment, gateway edge block, not served, missing permission (names parsed from jamf-cli's hint), other. `JamfCLIErrorEnvelope` decodes `error`/`message`/`hint` from stdout. `isPermanent` drives the remediation exclusion; `label` feeds Run History, the health banner and `ReportEngine.deadRunCause`. `ForbiddenStderrWatcher` catches a 403 on stderr for commands that exit 0 without data. |
| `ConnectionCheck` | (2.8.1) Checks a Platform API profile's environment or tenant ID when it validates, because the gateway issues a token before reading the scope header: `pro jamf-pro-version list` (`jamf-pro-versions` before 1.29), then after a bare 404 a `platform-devices list` filter that matches nothing. Verdicts accepted / rejected ID / no Jamf Pro / undecided; `OnboardingFlow.applyConnectionCheck` blocks setup on a rejected ID and offers Continue without validating only when undecided. Runs through `CLIBridge.runAndCapture` rather than `CLIExecutor`, which drops stdout on a non-zero exit. |
```

Then run: `cp CLAUDE.md AGENTS.md && cmp CLAUDE.md AGENTS.md && echo identical`

- [ ] **Step 4: Wiki 10 — remove the two Known Issues this release fixes**

In `docs/wiki/10-Security-and-Operational-Considerations.md`, delete the paragraph beginning
`**Compliance Benchmarks never fill.**` (ending `planned.`) and the paragraph beginning
`**The app's Platform API guidance is out of date in three places.**` (ending `app is updated.`),
with the blank line after each. The Security Cloud and HTML paragraphs stay.

- [ ] **Step 5: Wiki 13 — Known gaps**

Replace the paragraph under `## Known gaps` with:

```markdown
The app's HTML reports have a known gap; see
[Known Issues](https://github.com/tonyyo11/jamf-reports-community/wiki/10-Security-and-Operational-Considerations#known-issues).
```

- [ ] **Step 6: Wiki 02 — Authenticate and Validate**

In step 4, replace `has the steps. The form's first instruction says "account.jamf.com → API
Clients"; in` and the following line `Jamf Account the page is **Integrations**.` with `has the steps.`
Replace step 5 (from `5. **Validate**` through `once after setup.`) with:

```markdown
5. **Validate** — the app runs `jamf-cli config validate` against the new profile and
   reports success or a redacted error. For a Platform API profile it then asks the gateway
   whether it accepts the environment or tenant ID: a rejected ID stops setup and says where
   the right one is, an ID with no Jamf Pro behind it passes with a warning, and if the check
   cannot decide, **Continue without validating** lets you carry on.
```

- [ ] **Step 7: Wiki 09 — permission denied**

Replace the paragraph from `**Permission denied (exit 5).**` through `example, for the scripts source:`
with (the code block after it stays):

```markdown
**Permission denied (exit 5).** The credential lacks a privilege the command needs. Grant
it on the API role in Jamf Pro for a direct connection, or on the integration in Jamf
Account for a Platform API profile. The source's Run History warning line ends with
`cause:` and jamf-cli's `hint:`, which names the exact grant when jamf-cli knows it, and
self-remediation stops retrying the source until it lands again. To see the whole output
yourself, keep it short. For example, for the scripts source:
```

- [ ] **Step 8: Mutation checks**

Back up each file to the scratchpad first; restore from the backup, never with `git checkout`.
Run the named suite after each mutant and expect at least one failure:

| Mutant | File | Suite |
|---|---|---|
| `case .edgeBlocked, .other: false` → `case .edgeBlocked, .other: true` in `isPermanent` | `FailureCause.swift` | `FailureCauseTests` |
| `causes.contains(where:` → `causes.allSatisfy(` in `deadRunCause` | `ReportEngine.swift` | `CollectDeadVerdictTests` |
| delete `|| store.cause(for: $0.snapshotKind)?.isPermanent == true` | `WorkspaceStore+Automation.swift` | `DataFreshnessHealthTests` |
| `case .missingPermission: return .noJamfPro` → `return .undecided(exitCode: probe.exitCode)` | `ConnectionCheck.swift` | `ConnectionCheckTests` |
| delete `savedKinds.isEmpty` from `isCollectDead`'s guard | `ReportEngine.swift` | `CollectDeadVerdictTests` |

Restore every file and confirm `git diff --stat` matches the pre-mutation tree.

- [ ] **Step 9: Full gate**

Run, one at a time:
`cd app && swift build --build-tests 2>&1 | grep "error:" || echo OK`
`cd app && swift test > /tmp/jrc-281-full.log 2>&1; echo "EXIT=$?"; grep -E "Executed [0-9]+ tests?" /tmp/jrc-281-full.log | tail -1`
`git diff origin/main -U0 -- app CHANGELOG.md CLAUDE.md | grep '^+' | grep -v '^+++' | awk 'length > 101' | head`
Expected: `OK`; `EXIT=0` with 0 failures; no long added lines except the two service-table rows
(table rows are one line by format). CI's Swift 6.1 leg is the isolation gate and runs on push.

- [ ] **Step 10: Commit and hand over**

```bash
git add CHANGELOG.md CLAUDE.md AGENTS.md docs/wiki
git commit -m "docs: Compliance Benchmarks, connection check and failure causes for 2.8.1"
```

Tell Tony: the branch is ready for his visual pass (Tasks 2 and 5), push and PR are his call, and
the tester's spec §16 captures should replace the source-derived fixture strings in
`FailureCauseTests` and `ConnectionCheckTests` when they arrive.

---

## Self-Review

**Spec coverage**

| Spec | Task |
|---|---|
| §9.1 capture: `message`, `hint`, `error`; swallowed 403 on stderr | 3, 7 |
| §9.2 cause rules, name parsing | 3 |
| §9.3 cause file | 6 |
| §9.5 retry exclusion | 6 |
| §9.6 dead-run cause; exit-3 six-month note | 9 (deviations 1–2) |
| §10.1 cause in the banner detail | 8 |
| §10.3 Run History hint | 7 |
| §10.4 connection check, bypass rule, setup copy | 4, 5 (deviation 5) |
| §13.1 Compliance Benchmarks | 1, 2 |
| §13.2 exit 0 counted as success | 10 |
| §15 tests: rules and ordering, verdict rows, exclusion, dead-run cause, mutation checks | 3, 4, 6, 9, 11 |

Not in this plan (2.9.0): §7 requirements table, §8 reachability record, §9.4 source states,
§10.2 Access card, §10.3 per-screen Not granted banners, §10.4 region picker, scope-level changes and
checklist, §11 CLI and generated wiki block.

**Type consistency:** `recordUnlandedAttempt` is introduced in Task 1 and gains `sawForbidden:`
(Task 7) and the outcome's cause (Task 9); `StateFileStore.record(_:report:at:cause:)` from Task 6 is
used in Task 7; `KindCollectionState.cause` and `DataFreshnessIssue.cause` (Task 8) read
`StateFileStore.cause(for:)` (Task 6); `ReportEngineError.collectDead(profile:failedCount:cause:)`
(Task 9) is matched with three elements in Task 10's new test; `ConnectionCheck.Verdict` (Task 4)
is consumed by `OnboardingFlow` and `ConnectionCheckBanner` (Task 5).
