import XCTest

@testable import JamfReports

final class WorkspaceMergeExecutorTests: XCTestCase {
    private var root: URL!
    private let src = "Cloud", tgt = "OnPrem"
    private let fm = FileManager.default
    private let snap = "jamf-cli-data/computers/"
    private let day = "snapshots/summaries/summary_2026-01-02.json"

    override func setUpWithError() throws {
        root = fm.temporaryDirectory
            .appendingPathComponent("jrc-merge-run-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        try write("", src, "config.yaml")
        try write("", tgt, "config.yaml")
        try write("a", src, snap + "c_2026-01-01_000000.json")
        try write("same", src, snap + "c_2026-01-03_000000.json")
        try write("same", tgt, snap + "c_2026-01-03_000000.json")
        try write("source", src, snap + "c_2026-01-04_000000.json")
        try write("target", tgt, snap + "c_2026-01-04_000000.json")
        try write(#"{"date":"2026-01-02","totalDevices":5,"source":"jamf-cli","#
                  + #""fileVaultPct":70,"sipPct":90}"#, src, day)
        try write(#"{"date":"2026-01-02","totalDevices":10,"source":"jamf-cli","fileVaultPct":50}"#,
                  tgt, day)
        try write("2026-02-01T00:00:00Z", src, "jamf-cli-data/state/overview.last")
        try write("2026-01-01T00:00:00Z", tgt, "jamf-cli-data/state/overview.last")
        try write("1 x", tgt, "jamf-cli-data/state/overview.fail")
        try write("l", src, "automation/logs/a.log")
        try write("1", src, "backups/scheduled-1/manifest.json")
    }

    override func tearDownWithError() throws {
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        try? fm.removeItem(at: root)
    }

    // MARK: Helpers

    private func url(_ ws: String, _ rel: String) -> URL {
        root.appendingPathComponent(ws).appendingPathComponent(rel)
    }

    private func write(_ text: String, _ ws: String, _ rel: String) throws {
        let file = url(ws, rel)
        try fm.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    private func read(_ file: URL) -> String? { try? String(contentsOf: file, encoding: .utf8) }

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [String] = []
        var all: [String] { lock.withLock { list } }
        func add(_ call: String) { lock.withLock { list.append(call) } }
    }

    private func deps(
        _ calls: Calls = Calls(),
        hold: @escaping @Sendable (_ body: @Sendable () async throws -> Void) async throws
            -> Void = { try await $0() },
        claim: @escaping @Sendable (String) -> SharedWorkspace.Claim? = { _ in nil }
    ) -> WorkspaceMergeExecutor.Dependencies {
        WorkspaceMergeExecutor.Dependencies(
            hold: hold, blockingClaim: claim,
            writePlatformSlot: { calls.add("slot \($0)->\($1)") },
            copyBenchmarks: { calls.add("bench \($0)->\($1)") },
            retargetSchedules: { calls.add("schedules \($0)->\($1)") },
            rewritePolicy: { calls.add("policy \($0)->\($1)") },
            appSupport: root.appendingPathComponent(".app-support", isDirectory: true))
    }

    private func journal() throws -> WorkspaceMergeJournal {
        WorkspaceMergeJournal(
            plan: try WorkspaceMergePlan.make(source: src, target: tgt, root: root), done: 0)
    }

    private func merged(_ j: WorkspaceMergeJournal) -> URL {
        URL(fileURLWithPath: j.plan.mergedFolder, isDirectory: true)
    }

    /// Relative path to bytes for every regular file below the workspaces root.
    private func tree() throws -> [String: Data] {
        var result: [String: Data] = [:]
        let base = root.resolvingSymlinksInPath().path + "/"
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return result
        }
        for case let file as URL in walker {
            var info = stat()
            guard lstat(file.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }
            let path = file.resolvingSymlinksInPath().path
            let rel = path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
            // The merged folder's name carries the plan's stamp, which differs per plan.
            let stable = rel.replacingOccurrences(
                of: #"_merged/[^/]+/"#, with: "_merged/X/", options: .regularExpression)
            result[stable] = try Data(contentsOf: file)
        }
        return result.filter { !$0.key.contains("merge-journal") }
    }

    // MARK: Tests

    func testFullRun() async throws {
        let calls = Calls()
        let j = try journal()
        let sourceFiles = try tree().keys.filter { $0.hasPrefix("\(src)/") }
        let seen = Calls()
        try await WorkspaceMergeExecutor.run(j, deps: deps(calls)) { done, total in
            seen.add("\(done)/\(total)")
        }
        XCTAssertEqual(seen.all.last, "\(j.plan.steps.count)/\(j.plan.steps.count)")

        XCTAssertEqual(read(url(tgt, snap + "c_2026-01-01_000000.json")), "a")
        XCTAssertEqual(read(url(tgt, snap + "c_2026-01-03_000000.json")), "same")
        XCTAssertEqual(read(url(tgt, snap + "c_2026-01-04_000000.json")), "target")
        let archived = merged(j).appendingPathComponent(
            "archive/snapshots/computers/c_2026-01-04_000000.json")
        XCTAssertEqual(read(archived), "source")

        let filled = try SummaryJSONParser.parse(url(tgt, day))
        XCTAssertEqual(filled.totalDevices, 10)
        XCTAssertEqual(filled.fileVaultPct, 50)
        XCTAssertEqual(filled.sipPct, 90)
        for side in ["target", "source"] {
            XCTAssertNotNil(read(merged(j).appendingPathComponent(
                "archive/summaries/\(side)/summary_2026-01-02.json")), side)
        }

        XCTAssertEqual(read(url(tgt, "jamf-cli-data/state/overview.last")), "2026-02-01T00:00:00Z")
        XCTAssertFalse(fm.fileExists(atPath: url(tgt, "jamf-cli-data/state/overview.fail").path))
        XCTAssertEqual(read(url(tgt, "automation/logs/a.log")), "l")
        XCTAssertEqual(read(url(tgt, "backups/scheduled-1/manifest.json")), "1")
        XCTAssertNotNil(read(merged(j).appendingPathComponent("archive/config/config.yaml")))

        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent(src).path))
        let moved = merged(j).appendingPathComponent("workspace")
        XCTAssertTrue(fm.fileExists(atPath: moved.appendingPathComponent("config.yaml").path))
        // Nothing the source held is deleted.
        for rel in sourceFiles {
            let inside = String(rel.dropFirst(src.count + 1))
            XCTAssertTrue(fm.fileExists(atPath: moved.appendingPathComponent(inside).path), rel)
        }
        XCTAssertNil(WorkspaceMergeJournal.pending(target: tgt))
        XCTAssertTrue(fm.fileExists(
            atPath: merged(j).appendingPathComponent("merge-journal.json").path))
        XCTAssertEqual(calls.all, [
            "slot \(src)->\(tgt)", "bench \(src)->\(tgt)", "schedules \(src)->\(tgt)",
            "policy \(src)->\(tgt)",
        ])
    }

    func testInterruptedRunResumesToTheSameTree() async throws {
        let plain = try journal()
        try await WorkspaceMergeExecutor.run(plain, deps: deps())
        let expected = try tree()

        try fm.removeItem(at: root)
        try setUpWithError()
        let j = try journal()
        do {
            try await WorkspaceMergeExecutor.run(j, deps: deps(), stopAfter: 3)
            XCTFail("stopAfter must stop the run")
        } catch is CancellationError {}
        guard let pending = WorkspaceMergeJournal.pending(target: tgt) else {
            return XCTFail("no pending journal")
        }
        XCTAssertEqual(pending.done, 3)
        try await WorkspaceMergeExecutor.run(pending, deps: deps())
        XCTAssertEqual(try tree(), expected)
    }

    func testStepRunTwiceChangesNothing() async throws {
        let j = try journal()
        let fill = try XCTUnwrap(j.plan.steps.firstIndex {
            if case .fillSummary = $0.action { return true }
            return false
        })
        do {
            try await WorkspaceMergeExecutor.run(j, deps: deps(), stopAfter: fill + 1)
        } catch is CancellationError {}
        let before = try tree()
        var again = j
        again.done = fill
        do {
            try await WorkspaceMergeExecutor.run(again, deps: deps(), stopAfter: 1)
        } catch is CancellationError {}
        XCTAssertEqual(try tree(), before)
    }

    func testRefusedHoldWritesNothing() async throws {
        let before = try tree()
        do {
            try await WorkspaceMergeExecutor.run(
                try journal(), deps: deps(hold: { _ in throw CLIBridgeError.tickLockHeld }))
            XCTFail("the hold must refuse")
        } catch {
            XCTAssertEqual(error as? CLIBridgeError, .tickLockHeld)
        }
        XCTAssertEqual(try tree(), before)
        XCTAssertNil(WorkspaceMergeJournal.pending(target: tgt))
    }

    func testPeerClaimWritesNothing() async throws {
        let before = try tree()
        let peer = SharedWorkspace.Claim(
            host: .init(id: "peer", name: "Peer Mac"), operation: "collect",
            startedAt: Date(), expiresAt: Date().addingTimeInterval(600), pid: 1,
            appVersion: "x")
        let target = tgt
        do {
            try await WorkspaceMergeExecutor.run(
                try journal(), deps: deps(claim: { $0 == target ? peer : nil }))
            XCTFail("a peer claim must refuse")
        } catch {
            XCTAssertEqual(error as? WorkspaceMergeExecutor.RunError,
                           .peerClaim(workspace: tgt, host: "Peer Mac"))
        }
        XCTAssertEqual(try tree(), before)
        XCTAssertNil(WorkspaceMergeJournal.pending(target: tgt))
    }

    func testDifferentBytesAtACopyDestinationIsAStepError() async throws {
        let j = try journal()
        try write("planted", tgt, snap + "c_2026-01-01_000000.json")
        do {
            try await WorkspaceMergeExecutor.run(j, deps: deps())
            XCTFail("a copy must never overwrite")
        } catch WorkspaceMergeExecutor.RunError.step {}
        XCTAssertEqual(read(url(tgt, snap + "c_2026-01-01_000000.json")), "planted")
    }

    func testSourcePinRemovedTargetPinKept() async throws {
        let support = root.appendingPathComponent(".app-support", isDirectory: true)
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        let pins = try [src, tgt].map {
            try XCTUnwrap(SharedConfigPin.storeURL(workspace: $0, appSupport: support))
        }
        for pin in pins { try Data("{}".utf8).write(to: pin) }
        try await WorkspaceMergeExecutor.run(try journal(), deps: deps())
        XCTAssertFalse(fm.fileExists(atPath: pins[0].path))
        XCTAssertTrue(fm.fileExists(atPath: pins[1].path))
    }

    func testScheduleRetarget() throws {
        let store = ScheduleStore(url: root.appendingPathComponent("schedules.json"))
        let json = """
            [{"label":"l.one","profile":"\(src)","allProfiles":false,"excludedProfiles":[]},
             {"label":"l.all","profile":"","allProfiles":true,
              "excludedProfiles":["\(src)","\(tgt)","Other"]}]
            """
        try store.save(JSONDecoder().decode([ScheduleRecord].self, from: Data(json.utf8)))
        try store.retarget(from: src, to: tgt)
        let records = store.load()
        let one = try XCTUnwrap(records.first { $0.label == "l.one" })
        XCTAssertEqual(one.workspace, tgt)
        let all = try XCTUnwrap(records.first { $0.label == "l.all" })
        XCTAssertEqual(all.excludedWorkspaces, [tgt, "Other"])
    }

    func testPolicyReplacingWorkspace() {
        var policy = AutomationPolicy()
        policy.excludedWorkspaces = [src, "Other", tgt]
        policy.reportGroups = [ReportGroup(name: "fleet", workspaces: [tgt, src, "Other"]),
                               ReportGroup(name: "two", workspaces: [src])]
        let next = policy.replacingWorkspace(src, with: tgt)
        XCTAssertEqual(next.excludedWorkspaces, [tgt, "Other"])
        XCTAssertEqual(next.reportGroups.map(\.workspaces), [[tgt, "Other"], [tgt]])
    }

    @MainActor
    func testMergeHoldRefusesACollect() async throws {
        XCTAssertTrue(CLIBridgeError.mergeInProgress.isCollectRefusal)
        _ = useTemporaryTickLock()
        let started = Flag(), finish = Flag()
        defer { finish.set() }
        let merge = Task { @MainActor in
            try await CLIBridge.holdingTickLock(purpose: .merge) {
                started.set()
                while !finish.isSet { try await Task.sleep(for: .milliseconds(10)) }
            }
        }
        while !started.isSet { try await Task.sleep(for: .milliseconds(10)) }
        do {
            try await CLIBridge.holdingTickLock { }
            XCTFail("a collect must be refused")
        } catch {
            XCTAssertEqual(error as? CLIBridgeError, .mergeInProgress)
        }
        finish.set()
        try await merge.value
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    var isSet: Bool { lock.withLock { raised } }
    func set() { lock.withLock { raised = true } }
}

extension WorkspaceMergeExecutorTests {
    func testCopyBenchmarksOnlyIntoATargetWithNone() throws {
        try write("platform:\n  compliance_benchmarks:\n    - \"CIS L1\"\n", src, "config.yaml")
        try WorkspaceMergeExecutor.copyBenchmarks(src, tgt)
        let copied = try ConfigLoader.rawMapping(
            fromYAML: ConfigLoader.readText(at: url(tgt, "config.yaml")))
        let platform = try XCTUnwrap(copied["platform"] as? [String: Any])
        XCTAssertEqual(platform["compliance_benchmarks"] as? [String], ["CIS L1"])

        try write("platform:\n  compliance_benchmarks:\n    - \"Mine\"\n", tgt, "config.yaml")
        try WorkspaceMergeExecutor.copyBenchmarks(src, tgt)
        XCTAssertEqual(read(url(tgt, "config.yaml")),
                       "platform:\n  compliance_benchmarks:\n    - \"Mine\"\n")
    }
}
