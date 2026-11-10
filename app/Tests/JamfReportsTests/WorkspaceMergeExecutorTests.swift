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
        claims: Calls = Calls(),
        claim: @escaping @Sendable (String) -> SharedWorkspace.ClaimDecision = { _ in .acquire }
    ) -> WorkspaceMergeExecutor.Dependencies {
        WorkspaceMergeExecutor.Dependencies(
            hold: hold,
            acquireClaim: { ws in
                let decision = claim(ws)
                if decision == .acquire { claims.add("acquire \(ws)") }
                return decision
            },
            releaseClaim: { claims.add("release \($0)") },
            writePlatformSlot: { calls.add("slot \($0)->\($1)") },
            copyBenchmarks: { calls.add("bench \($0)->\($1)") },
            retargetSchedules: { from, to, _ in calls.add("schedules \(from)->\(to)") },
            rewritePolicy: { from, to, _ in calls.add("policy \(from)->\(to)") },
            appSupport: root.appendingPathComponent(".app-support", isDirectory: true))
    }

    private var support: URL { root.appendingPathComponent(".app-support", isDirectory: true) }

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
        // Both journal files carry the plan's stamp.
        return result.filter { !$0.key.contains("merge-journal") && !$0.key.contains("merge-plan") }
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
        XCTAssertNil(WorkspaceMergeJournal.pending(target: tgt, appSupport: support))
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
        guard let pending = WorkspaceMergeJournal.pending(target: tgt, appSupport: support) else {
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
        let after = try tree()
        XCTAssertEqual(after, before)
    }

    /// With both twins excluded the first run keeps the target; a rerun after a crash must too.
    func testExclusionStepRunTwiceKeepsTheTarget() async throws {
        let store = ScheduleStore(url: root.appendingPathComponent("schedules.json"))
        var record = try JSONDecoder().decode(ScheduleRecord.self, from: Data(
            #"{"label":"l.all","profile":"","allProfiles":true}"#.utf8))
        record.excludedWorkspaces = [src, tgt]
        try store.save([record])
        let plan = try WorkspaceMergePlan.make(
            source: src, target: tgt, root: root, schedules: store.load(), policy: AutomationPolicy())
        XCTAssertEqual(plan.keepTargetExcludedInSchedules, ["l.all"])
        var d = deps()
        d.retargetSchedules = { try store.retarget(from: $0, to: $1, keepTargetIn: $2) }
        let index = try XCTUnwrap(plan.steps.firstIndex { $0.action == .tail(.retargetSchedules) })
        let j = WorkspaceMergeJournal(plan: plan, done: 0)
        do { try await WorkspaceMergeExecutor.run(j, deps: d, stopAfter: index + 1) }
        catch is CancellationError {}
        XCTAssertEqual(store.load().first?.excludedWorkspaces, [tgt])
        var again = j
        again.done = index
        do { try await WorkspaceMergeExecutor.run(again, deps: d, stopAfter: 1) }
        catch is CancellationError {}
        XCTAssertEqual(store.load().first?.excludedWorkspaces, [tgt])
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
        XCTAssertNil(WorkspaceMergeJournal.pending(target: tgt, appSupport: support))
    }

    func testPeerClaimWritesNothing() async throws {
        let before = try tree()
        let peer = SharedWorkspace.Claim(
            host: .init(id: "peer", name: "Peer Mac"), operation: "collect",
            startedAt: Date(), expiresAt: Date().addingTimeInterval(600), pid: 1,
            appVersion: "x")
        let target = tgt
        let claims = Calls()
        do {
            try await WorkspaceMergeExecutor.run(try journal(), deps: deps(
                claims: claims, claim: { $0 == target ? .blocked(peer) : .acquire }))
            XCTFail("a peer claim must refuse")
        } catch {
            XCTAssertEqual(error as? WorkspaceMergeExecutor.RunError,
                           .peerClaim(workspace: tgt, host: "Peer Mac"))
        }
        XCTAssertEqual(try tree(), before)
        XCTAssertNil(WorkspaceMergeJournal.pending(target: tgt, appSupport: support))
        // The source's claim, taken before the target refused, is given back.
        XCTAssertEqual(claims.all, ["acquire \(src)", "release \(src)"])
    }

    func testClaimsHeldForTheRunAndReleased() async throws {
        let claims = Calls()
        try write("{}", src, "automation/\(SharedWorkspace.claimFilename)")
        let full = try journal()
        try await WorkspaceMergeExecutor.run(full, deps: deps(claims: claims))
        XCTAssertEqual(claims.all.prefix(2), ["acquire \(src)", "acquire \(tgt)"])
        // Renewed before every step; the moved source is not released at its old name.
        let steps = full.plan.steps.count
        XCTAssertEqual(claims.all.filter { $0 == "acquire \(tgt)" }.count, steps + 1)
        XCTAssertEqual(claims.all.filter { $0.hasPrefix("release") }, ["release \(tgt)"])
        XCTAssertFalse(fm.fileExists(atPath: merged(full).appendingPathComponent(
            "workspace/automation/\(SharedWorkspace.claimFilename)").path))

        try fm.removeItem(at: root)
        try setUpWithError()
        let thrown = Calls()
        let j = try journal()
        // Other bytes at an archive path the plan named: the archive copy refuses.
        let archived = merged(j).appendingPathComponent(
            "archive/snapshots/computers/c_2026-01-04_000000.json")
        try fm.createDirectory(at: archived.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try "planted".write(to: archived, atomically: true, encoding: .utf8)
        do {
            try await WorkspaceMergeExecutor.run(j, deps: deps(claims: thrown))
            XCTFail("the planted file must stop the run")
        } catch WorkspaceMergeExecutor.RunError.step {}
        XCTAssertEqual(Set(thrown.all), ["acquire \(src)", "acquire \(tgt)",
                                         "release \(src)", "release \(tgt)"])
    }

    /// The target gained the file after planning: R7 keeps it and archives the source's.
    func testCopyDestinationTheTargetGainedFallsBackToTheArchive() async throws {
        let j = try journal()
        try write("planted", tgt, snap + "c_2026-01-01_000000.json")
        try await WorkspaceMergeExecutor.run(j, deps: deps())
        XCTAssertEqual(read(url(tgt, snap + "c_2026-01-01_000000.json")), "planted")
        XCTAssertEqual(read(merged(j).appendingPathComponent(
            "archive/snapshots/computers/c_2026-01-01_000000.json")), "a")
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
        try store.retarget(from: src, to: tgt, keepTargetIn: ["l.all"])
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
        let next = policy.replacingWorkspace(src, with: tgt, keepTargetExcluded: true)
        XCTAssertEqual(next.excludedWorkspaces, ["Other", tgt])
        XCTAssertEqual(next.reportGroups.map(\.workspaces), [[tgt, "Other"], [tgt]])
    }

    /// The target stays excluded only when both twins were (earlier hints named either one).
    private var exclusionCases: [(before: [String], after: [String])] {
        [([tgt, "Other"], ["Other"]), ([src, "Other"], ["Other"]),
         ([src, tgt, "Other"], [tgt, "Other"]), (["Other"], ["Other"])]
    }

    func testPolicyExclusionsAfterMerge() {
        for (before, after) in exclusionCases {
            var policy = AutomationPolicy()
            policy.excludedWorkspaces = before
            XCTAssertEqual(policy.replacingWorkspace(
                src, with: tgt, keepTargetExcluded: before.excludesBoth(src, tgt))
                .excludedWorkspaces, after, "\(before)")
        }
    }

    func testScheduleExclusionsAfterMerge() throws {
        let store = ScheduleStore(url: root.appendingPathComponent("schedules.json"))
        for (before, after) in exclusionCases {
            var record = try JSONDecoder().decode(ScheduleRecord.self, from: Data(
                #"{"label":"l.all","profile":"","allProfiles":true}"#.utf8))
            record.excludedWorkspaces = before
            try store.save([record])
            try store.retarget(
                from: src, to: tgt,
                keepTargetIn: before.excludesBoth(src, tgt) ? ["l.all"] : [])
            XCTAssertEqual(store.load().first?.excludedWorkspaces, after, "\(before)")
        }
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

// MARK: - Fix round 1

extension WorkspaceMergeExecutorTests {
    private func stopped(_ j: WorkspaceMergeJournal, after count: Int) async throws {
        do {
            try await WorkspaceMergeExecutor.run(j, deps: deps(), stopAfter: count)
            XCTFail("stopAfter must stop the run")
        } catch is CancellationError {}
    }

    private func index(of match: (WorkspaceMergePlan.Action) -> Bool,
                       in j: WorkspaceMergeJournal) throws -> Int {
        try XCTUnwrap(j.plan.steps.firstIndex { match($0.action) })
    }

    func testResumeRefusesAStateFileChangedAfterTheCrash() async throws {
        let j = try journal()
        let state = try index(of: { $0 == .replaceState }, in: j)
        // Archive copy made, then the crash before the install: simulate by running up to the
        // step, archiving by hand as the step would.
        try await stopped(j, after: state)
        let step = j.plan.steps[state]
        let archive = URL(fileURLWithPath: try XCTUnwrap(step.archive))
        try fm.createDirectory(at: archive.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try fm.copyItem(at: URL(fileURLWithPath: step.target), to: archive)
        try "changed".write(toFile: step.target, atomically: true, encoding: .utf8)
        guard let pending = WorkspaceMergeJournal.pending(target: tgt, appSupport: support) else {
            return XCTFail("no pending journal")
        }
        do {
            try await WorkspaceMergeExecutor.run(pending, deps: deps())
            XCTFail("a changed target must stop the resume")
        } catch WorkspaceMergeExecutor.RunError.step(let at, _) {
            XCTAssertEqual(at, state)
        }
        XCTAssertEqual(read(URL(fileURLWithPath: step.target)), "changed")
    }

    func testResumeRefusesASummaryChangedAfterTheCrash() async throws {
        let j = try journal()
        let fill = try index(of: {
            if case .fillSummary = $0 { return true }
            return false
        }, in: j)
        try await stopped(j, after: fill + 1)
        try write(#"{"date":"2026-01-02","totalDevices":99,"source":"jamf-cli"}"#, tgt, day)
        var again = j
        again.done = fill
        do {
            try await WorkspaceMergeExecutor.run(again, deps: deps())
            XCTFail("a changed summary must stop the resume")
        } catch WorkspaceMergeExecutor.RunError.step(let at, _) {
            XCTAssertEqual(at, fill)
        }
        XCTAssertEqual(try SummaryJSONParser.parse(url(tgt, day)).totalDevices, 99)
    }

    func testExclusiveInstallLeavesAnExistingEntry() throws {
        let staged = root.appendingPathComponent(".x.tmp")
        let final = root.appendingPathComponent("x")
        try "new".write(to: staged, atomically: true, encoding: .utf8)
        try "old".write(to: final, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try AtomicInstall.installExclusive(staged, at: final)) {
            XCTAssertEqual(($0 as? POSIXError)?.code, .EEXIST)
        }
        XCTAssertEqual(read(final), "old")
        XCTAssertEqual(read(staged), "new")
        try fm.removeItem(at: final)
        try AtomicInstall.installExclusive(staged, at: final)
        XCTAssertEqual(read(final), "new")
    }

    func testCrashBeforeTheLastStepResumes() async throws {
        let plain = try journal()
        try await WorkspaceMergeExecutor.run(plain, deps: deps())
        let expected = try tree()

        try fm.removeItem(at: root)
        try setUpWithError()
        let j = try journal()
        try await stopped(j, after: j.plan.steps.count - 1)
        guard let pending = WorkspaceMergeJournal.pending(target: tgt, appSupport: support) else {
            return XCTFail("no pending journal")
        }
        try await WorkspaceMergeExecutor.run(pending, deps: deps())
        XCTAssertNil(WorkspaceMergeJournal.pending(target: tgt, appSupport: support))
        XCTAssertTrue(fm.fileExists(
            atPath: merged(j).appendingPathComponent("merge-journal.json").path))
        XCTAssertEqual(try tree(), expected)
    }

    func testResumeWhoseJournalWasMovedAsideIsRefused() async throws {
        let j = try journal()
        try await stopped(j, after: 2)
        guard let pending = WorkspaceMergeJournal.pending(target: tgt, appSupport: support) else {
            return XCTFail("no pending journal")
        }
        for name in [".merge-journal.json", ".merge-plan.json"] {
            let file = url(tgt, "automation/\(name)")
            if fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
        }
        do {
            try await WorkspaceMergeExecutor.run(pending, deps: deps())
            XCTFail("a resume with no journal on disk must not start")
        } catch WorkspaceMergeExecutor.RunError.notStarted {
        }
        XCTAssertNil(WorkspaceMergeJournal.pending(target: tgt, appSupport: support))
    }

    func testResumeAtMoveSourceAfterTheFolderMoved() async throws {
        let j = try journal()
        try await stopped(j, after: j.plan.steps.count - 1)
        let moved = merged(j).appendingPathComponent("workspace")
        try fm.moveItem(at: root.appendingPathComponent(src), to: moved)
        guard let pending = WorkspaceMergeJournal.pending(target: tgt, appSupport: support) else {
            return XCTFail("no pending journal")
        }
        let claims = Calls()
        try await WorkspaceMergeExecutor.run(pending, deps: deps(claims: claims))
        XCTAssertNil(WorkspaceMergeJournal.pending(target: tgt, appSupport: support))
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent(src).path))
        XCTAssertTrue(fm.fileExists(atPath: moved.appendingPathComponent("config.yaml").path))
        XCTAssertFalse(claims.all.contains("acquire \(src)"), "no claim at the moved name")
    }

    func testBackupCopyRemovesAStaleStagedCopy() async throws {
        let backups = url(tgt, "backups")
        let leftover = backups.appendingPathComponent(".scheduled-1.tmp-\(UUID().uuidString)")
        try fm.createDirectory(at: leftover, withIntermediateDirectories: true)
        try await WorkspaceMergeExecutor.run(try journal(), deps: deps())
        XCTAssertFalse(fm.fileExists(atPath: leftover.path))
        XCTAssertEqual(read(url(tgt, "backups/scheduled-1/manifest.json")), "1")
    }
}

// MARK: - Fix round 2

extension WorkspaceMergeExecutorTests {
    func testRenewalBlockedMidRunStopsBeforeThatStep() async throws {
        let j = try journal()
        let calls = Counter()
        let peer = SharedWorkspace.Claim(
            host: .init(id: "peer", name: "Peer Mac"), operation: "collect",
            startedAt: Date(), expiresAt: Date().addingTimeInterval(600), pid: 1,
            appVersion: "x")
        // 2 initial claims, then 2 renewals per step: the 9th call is step 3's first renewal.
        let blockAt = 9
        do {
            try await WorkspaceMergeExecutor.run(j, deps: deps(claim: { _ in
                calls.next() >= blockAt ? .blocked(peer) : .acquire
            }))
            XCTFail("a peer taking the claim must stop the run")
        } catch {
            XCTAssertEqual(error as? WorkspaceMergeExecutor.RunError,
                           .peerClaim(workspace: src, host: "Peer Mac"))
        }
        let pending = try XCTUnwrap(WorkspaceMergeJournal.pending(target: tgt, appSupport: support))
        XCTAssertEqual(pending.done, 3)
        XCTAssertEqual(calls.value, blockAt)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func next() -> Int { lock.withLock { count += 1; return count } }
}

// MARK: - Final review

extension WorkspaceMergeExecutorTests {
    func testSummaryTheTargetGainedIsFilled() async throws {
        let name = "snapshots/summaries/summary_2026-01-05.json"
        try write(#"{"date":"2026-01-05","totalDevices":5,"source":"jamf-cli","sipPct":90}"#,
                  src, name)
        let j = try journal()
        try write(#"{"date":"2026-01-05","totalDevices":7,"source":"jamf-cli"}"#, tgt, name)
        try await WorkspaceMergeExecutor.run(j, deps: deps())
        let filled = try SummaryJSONParser.parse(url(tgt, name))
        XCTAssertEqual(filled.totalDevices, 7)
        XCTAssertEqual(filled.sipPct, 90)
        for side in ["target", "source"] {
            XCTAssertNotNil(read(merged(j).appendingPathComponent(
                "archive/summaries/\(side)/summary_2026-01-05.json")), side)
        }
    }

    func testReplaceStateArchivesATargetFileThatAppeared() async throws {
        try write("3", src, "jamf-cli-data/state/overview.timeouts")
        let j = try journal()
        try write("9", tgt, "jamf-cli-data/state/overview.timeouts")
        try await WorkspaceMergeExecutor.run(j, deps: deps())
        XCTAssertEqual(read(url(tgt, "jamf-cli-data/state/overview.timeouts")), "3")
        XCTAssertEqual(read(merged(j).appendingPathComponent(
            "archive/state/overview.timeouts")), "9")
    }

    func testSourceFolderSwappedForALinkStopsTheStep() async throws {
        let j = try journal()
        let kind = url(src, "jamf-cli-data/computers")
        let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
        try fm.moveItem(at: kind, to: elsewhere)
        try fm.createSymbolicLink(at: kind, withDestinationURL: elsewhere)
        do {
            try await WorkspaceMergeExecutor.run(j, deps: deps())
            XCTFail("a linked source folder must stop the run")
        } catch WorkspaceMergeExecutor.RunError.step {}
        XCTAssertFalse(fm.fileExists(atPath: url(tgt, snap + "c_2026-01-01_000000.json").path))
        XCTAssertFalse(fm.fileExists(atPath: merged(j).appendingPathComponent("archive").path))
    }

    private func laterJournal() throws -> WorkspaceMergeJournal {
        WorkspaceMergeJournal(plan: try WorkspaceMergePlan.make(
            source: src, target: tgt, now: Date().addingTimeInterval(3600), root: root), done: 0)
    }

    func testAFreshMergeDoesNotOverwriteAPendingJournal() async throws {
        let first = try journal()
        try await stopped(first, after: 1)
        do {
            try await WorkspaceMergeExecutor.run(try laterJournal(), deps: deps())
            XCTFail("a pending journal must refuse a fresh merge")
        } catch {
            XCTAssertEqual(error as? WorkspaceMergeExecutor.RunError,
                           .pendingMerge(source: src))
        }
        XCTAssertEqual(WorkspaceMergeJournal.pending(target: tgt, appSupport: support), WorkspaceMergeJournal(
            plan: first.plan, done: 1))
    }

    func testStartOverKeepsTheRecordAndAllowsANewMerge() async throws {
        let first = try journal()
        try await stopped(first, after: 1)
        try await WorkspaceMergeExecutor.startOver(target: tgt, deps: deps())
        XCTAssertEqual(WorkspaceMergeJournal.state(target: tgt, appSupport: support), .none)
        XCTAssertEqual(try WorkspaceMergeJournal.readProgress(
            merged(first).appendingPathComponent("merge-journal.json")).done, 1)
        XCTAssertTrue(fm.fileExists(
            atPath: merged(first).appendingPathComponent("merge-plan.json").path))
        let next = try laterJournal()
        try await WorkspaceMergeExecutor.run(next, deps: deps())
        XCTAssertNil(WorkspaceMergeJournal.pending(target: tgt, appSupport: support))
    }

    /// Writes both pending files as a run would; `own` records this Mac's start of the plan.
    private func writePending(_ j: WorkspaceMergeJournal, own: Bool = true) throws {
        let hash = try WorkspaceMergeJournal.write(
            planData: WorkspaceMergeJournal.encodedPlan(j.plan),
            to: WorkspaceMergeJournal.planLocation(target: tgt))
        try WorkspaceMergeJournal.write(
            .init(done: j.done, planSHA256: hash, mergedFolder: j.plan.mergedFolder),
            to: WorkspaceMergeJournal.location(target: tgt))
        if own {
            try WorkspaceMergeJournal.markStarted(
                planSHA256: hash, target: tgt, mergedFolder: j.plan.mergedFolder, done: j.done,
                appSupport: support)
        }
    }

    func testAFinishedPendingJournalIsRetired() throws {
        var finished = try journal()
        finished.done = finished.plan.steps.count
        try writePending(finished)
        XCTAssertNil(WorkspaceMergeJournal.pending(target: tgt, appSupport: support))
        XCTAssertFalse(fm.fileExists(atPath: try WorkspaceMergeJournal.location(target: tgt).path))
        XCTAssertFalse(fm.fileExists(
            atPath: try WorkspaceMergeJournal.planLocation(target: tgt).path))
        XCTAssertTrue(fm.fileExists(atPath: finished.recordURL.path))
        XCTAssertTrue(fm.fileExists(atPath: finished.recordPlanURL.path))
    }

    /// A production plan passes the 1 MB document limit; the plan file has its own.
    func testAPlanAboveOneMegabyteIsPendingAndResumes() async throws {
        var j = try journal()
        j.plan.differingConfigKeys.append(String(repeating: "k", count: 1_200_000))
        try await stopped(j, after: 2)
        let planFile = try WorkspaceMergeJournal.planLocation(target: tgt)
        let size = try XCTUnwrap(fm.attributesOfItem(atPath: planFile.path)[.size] as? Int)
        XCTAssertGreaterThan(size, BoundedFile.documentLimit)
        let pending = try XCTUnwrap(WorkspaceMergeJournal.pending(target: tgt, appSupport: support))
        XCTAssertEqual(pending, WorkspaceMergeJournal(plan: j.plan, done: 2))
        try await WorkspaceMergeExecutor.run(pending, deps: deps())
        XCTAssertEqual(WorkspaceMergeJournal.state(target: tgt, appSupport: support), .none)
        XCTAssertEqual(read(url(tgt, snap + "c_2026-01-01_000000.json")), "a")
    }

    func testAnUnreadablePlanBlocksAFreshRunUntilStartOver() async throws {
        let first = try journal()
        try await stopped(first, after: 1)
        let planFile = try WorkspaceMergeJournal.planLocation(target: tgt)
        try "not json".write(to: planFile, atomically: true, encoding: .utf8)
        XCTAssertTrue(WorkspaceMergeJournal.state(target: tgt, appSupport: support).isUnreadable)
        do {
            try await WorkspaceMergeExecutor.run(try laterJournal(), deps: deps())
            XCTFail("an unreadable journal must refuse a fresh merge")
        } catch {
            XCTAssertEqual(error as? WorkspaceMergeExecutor.RunError, .unreadableJournal)
        }
        XCTAssertEqual(read(planFile), "not json")
        // The journal still names its merged folder, so Start over moves both files there.
        try await WorkspaceMergeExecutor.startOver(target: tgt, deps: deps())
        XCTAssertEqual(WorkspaceMergeJournal.state(target: tgt, appSupport: support), .none)
        XCTAssertEqual(read(merged(first).appendingPathComponent("merge-plan.json")), "not json")
        try await WorkspaceMergeExecutor.run(try laterJournal(), deps: deps())
    }

    func testStartOverRefusesWhileAPeerHoldsTheTarget() async throws {
        try await stopped(try journal(), after: 1)
        let peer = SharedWorkspace.Claim(
            host: .init(id: "peer", name: "Peer Mac"), operation: "merge",
            startedAt: Date(), expiresAt: Date().addingTimeInterval(600), pid: 1,
            appVersion: "x")
        do {
            try await WorkspaceMergeExecutor.startOver(
                target: tgt, deps: deps(claim: { _ in .blocked(peer) }))
            XCTFail("a peer's claim must refuse Start over")
        } catch {
            XCTAssertEqual(error as? WorkspaceMergeExecutor.RunError,
                           .peerClaim(workspace: tgt, host: "Peer Mac"))
        }
        XCTAssertNotNil(WorkspaceMergeJournal.pending(target: tgt, appSupport: support))
    }

    func testARefusedJournalFolderIsAPreWriteRefusal() async throws {
        let j = try journal()
        let automation = url(tgt, "automation")
        try fm.createDirectory(at: root.appendingPathComponent("elsewhere"),
                               withIntermediateDirectories: true)
        try? fm.removeItem(at: automation)
        try fm.createSymbolicLink(at: automation,
                                  withDestinationURL: root.appendingPathComponent("elsewhere"))
        do {
            try await WorkspaceMergeExecutor.run(j, deps: deps())
            XCTFail("a linked automation folder must refuse")
        } catch WorkspaceMergeExecutor.RunError.notStarted {}
    }

    // MARK: Peer-written plans

    private func started() -> WorkspaceMergeJournal.Started? {
        WorkspaceMergeJournal.started(target: tgt, appSupport: support)
    }

    func testAPlantedPlanIsForeignAndNeverRuns() async throws {
        var j = try journal()
        let victim = root.appendingPathComponent("victim.txt")
        try "keep".write(to: victim, atomically: true, encoding: .utf8)
        j.plan.steps[0].target = victim.path
        try writePending(j, own: false)
        XCTAssertTrue(WorkspaceMergeJournal.state(target: tgt, appSupport: support).isForeign)
        XCTAssertNil(WorkspaceMergeJournal.pending(target: tgt, appSupport: support))
        do {
            try await WorkspaceMergeExecutor.run(j, deps: deps())
            XCTFail("a foreign journal must refuse")
        } catch {
            XCTAssertEqual(error as? WorkspaceMergeExecutor.RunError, .foreignJournal)
        }
        XCTAssertEqual(read(victim), "keep")
    }

    func testAForgedFinishedJournalIsNotRetired() throws {
        var finished = try journal()
        finished.done = finished.plan.steps.count
        try writePending(finished, own: false)
        XCTAssertTrue(WorkspaceMergeJournal.state(target: tgt, appSupport: support).isForeign)
        XCTAssertTrue(fm.fileExists(atPath: try WorkspaceMergeJournal.location(target: tgt).path))
        XCTAssertFalse(fm.fileExists(atPath: finished.mergedFolder.path))
    }

    func testAnOwnPlanWithAPathOutsideTheRootRefusesBeforeAnyStep() async throws {
        let outside = fm.temporaryDirectory.appendingPathComponent("jrc-out-\(UUID().uuidString)")
        let evilSibling = root.deletingLastPathComponent()
            .appendingPathComponent(root.lastPathComponent + "-evil/x")
        for bad in [outside.path, root.path + "/../escape", evilSibling.path, "relative/x"] {
            var j = try journal()
            let last = try XCTUnwrap(j.plan.steps.firstIndex {
                if case .copy = $0.action { return true }
                return false
            })
            j.plan.steps[last].target = bad
            let before = try tree()
            do {
                try await WorkspaceMergeExecutor.run(j, deps: deps())
                XCTFail("\(bad) must be refused")
            } catch {
                XCTAssertEqual((error as? WorkspaceMergeExecutor.RunError).map {
                    if case .notStarted = $0 { return true } else { return false }
                }, true, bad)
            }
            XCTAssertEqual(try tree(), before, bad)
            XCTAssertNil(started())
        }
        XCTAssertFalse(fm.fileExists(atPath: outside.path))
    }

    func testRetireRefusesAMergedFolderOutsideTheRoot() throws {
        var j = try journal()
        j.done = j.plan.steps.count
        j.plan.mergedFolder = root.deletingLastPathComponent().path + "/jrc-retire-\(UUID().uuidString)"
        let data = try WorkspaceMergeJournal.encodedPlan(j.plan)
        XCTAssertThrowsError(try j.retire(
            progressAt: url(tgt, "p"), planAt: url(tgt, "q"), planData: data, appSupport: support))
        XCTAssertFalse(fm.fileExists(atPath: j.mergedFolder.path))
        j.plan.mergedFolder = root.path + "/../elsewhere"
        XCTAssertThrowsError(try j.retire(
            progressAt: url(tgt, "p"), planAt: url(tgt, "q"), planData: data, appSupport: support))
    }

    func testRetireRefusesALinkedMergedRootAndWritesNothingOutside() throws {
        var j = try journal()
        j.done = j.plan.steps.count
        let outside = fm.temporaryDirectory.appendingPathComponent("jrc-out-\(UUID().uuidString)")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: outside) }
        try fm.createSymbolicLink(at: root.appendingPathComponent("_merged"),
                                  withDestinationURL: outside)
        let data = try WorkspaceMergeJournal.encodedPlan(j.plan)
        XCTAssertThrowsError(try j.retire(
            progressAt: url(tgt, "p"), planAt: url(tgt, "q"), planData: data, appSupport: support))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: outside.path), [])
    }

    func testStartOverOfAForeignPlanMovesOnlyTheJournalFiles() async throws {
        var j = try journal()
        // A folder the old direct-child-of-_merged check would have accepted.
        let other = root.appendingPathComponent("_merged/Other-20250101-000000")
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        j.plan.mergedFolder = other.path
        try writePending(j, own: false)
        let before = try tree()
        try await WorkspaceMergeExecutor.startOver(target: tgt, deps: deps())
        XCTAssertEqual(WorkspaceMergeJournal.state(target: tgt, appSupport: support), .none)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: other.path), [])
        XCTAssertEqual(try tree(), before)
        let kept = try fm.contentsOfDirectory(atPath: root.appendingPathComponent("_merged").path)
        XCTAssertEqual(kept.filter { $0.contains("-unfinished-") }.count, 1)
    }

    func testStartOverUsesTheRecordedFolderNotTheJournals() async throws {
        let j = try journal()
        try await stopped(j, after: 1)
        let progressURL = try WorkspaceMergeJournal.location(target: tgt)
        var progress = try WorkspaceMergeJournal.readProgress(progressURL)
        let other = root.appendingPathComponent("_merged/Other-20250101-000000")
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        progress.mergedFolder = other.path
        try WorkspaceMergeJournal.write(progress, to: progressURL)
        try await WorkspaceMergeExecutor.startOver(target: tgt, deps: deps())
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: other.path), [])
        XCTAssertTrue(fm.fileExists(
            atPath: merged(j).appendingPathComponent("merge-journal.json").path))
    }

    func testAPeerRaisedJournalCountStartsAtTheRecordsCount() async throws {
        let plain = try journal()
        try await WorkspaceMergeExecutor.run(plain, deps: deps())
        let expected = try tree()
        try fm.removeItem(at: root)
        try setUpWithError()
        try await stopped(try journal(), after: 1)
        let progressURL = try WorkspaceMergeJournal.location(target: tgt)
        var progress = try WorkspaceMergeJournal.readProgress(progressURL)
        progress.done = try journal().plan.steps.count - 1
        try WorkspaceMergeJournal.write(progress, to: progressURL)
        let pending = try XCTUnwrap(WorkspaceMergeJournal.pending(target: tgt, appSupport: support))
        XCTAssertEqual(pending.done, 1)
        // Handed in with the peer's count, the run still starts at the record's.
        var raised = pending
        raised.done = progress.done
        try await WorkspaceMergeExecutor.run(raised, deps: deps())
        XCTAssertEqual(try tree(), expected)
    }

    func testAJournalCountingEveryStepWithALowerRecordIsNotRetired() throws {
        let j = try journal()
        try writePending(j)
        let progressURL = try WorkspaceMergeJournal.location(target: tgt)
        var progress = try WorkspaceMergeJournal.readProgress(progressURL)
        progress.done = j.plan.steps.count
        try WorkspaceMergeJournal.write(progress, to: progressURL)
        guard case .pending(let read) = WorkspaceMergeJournal.state(
            target: tgt, appSupport: support) else { return XCTFail("must stay pending") }
        XCTAssertEqual(read.done, 0)
        XCTAssertTrue(fm.fileExists(atPath: progressURL.path))
        XCTAssertFalse(fm.fileExists(atPath: j.recordURL.path))
    }

    func testTheStartNoteIsClearedWhenTheStartFails() async throws {
        let automation = url(tgt, "automation")
        try fm.createDirectory(at: automation, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: automation.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: automation.path) }
        do {
            try await WorkspaceMergeExecutor.run(try journal(), deps: deps())
            XCTFail("an unwritable automation folder must refuse")
        } catch WorkspaceMergeExecutor.RunError.notStarted {}
        XCTAssertNil(started())
    }

    func testTheStartNoteIsRecordedAndRemovedAfterRetire() async throws {
        let j = try journal()
        try await stopped(j, after: 1)
        XCTAssertEqual(started()?.target, tgt)
        XCTAssertEqual(started()?.planSHA256, WorkspaceMergeJournal.sha256Hex(
            try WorkspaceMergeJournal.encodedPlan(j.plan)))
        try await WorkspaceMergeExecutor.run(
            try XCTUnwrap(WorkspaceMergeJournal.pending(target: tgt, appSupport: support)),
            deps: deps())
        XCTAssertNil(started())
    }

    func testStartOverRemovesTheStartNote() async throws {
        try await stopped(try journal(), after: 1)
        try await WorkspaceMergeExecutor.startOver(target: tgt, deps: deps())
        XCTAssertNil(started())
    }
}
