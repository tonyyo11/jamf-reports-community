import XCTest
@testable import JamfReports

/// Jamf Protect configuration in backups: the call, the skip rules, the manifest, retention
/// and file permissions. Nothing here runs jamf-cli: a shell script stands in for it, under a
/// name that is not `jamf-cli` (`CLIBridge.codesignGate` keys on that filename).
@MainActor
final class ProtectBackupTests: XCTestCase {

    private enum ProtectMode { case ok, partial, failed, hang }

    private let connectedConfig = """
    protect:
      enabled: true
      profile: "protect-login"
    """

    // MARK: - Argument building and the plan

    func test_arguments_carryProfileNoInputAndOutput() {
        XCTAssertEqual(
            ProtectBackup.arguments(profile: "protect-login", outputDirectory: "/stage/protect"),
            ["-p", "protect-login", "--no-input", "protect", "backup",
             "--output", "/stage/protect"])
        // A profile that looks like a flag is still the value of -p.
        XCTAssertEqual(
            ProtectBackup.arguments(profile: "--output", outputDirectory: "/s").prefix(2),
            ["-p", "--output"])
    }

    func test_plan_notConnectedNeverEvaluatesThePinOrStorage() throws {
        var evaluated = 0
        let none = ProtectBackup.plan(
            config: nil, workspaceProfile: "ws",
            pinAllows: { evaluated += 1; return true },
            sharedStorage: { evaluated += 1; return nil })
        XCTAssertEqual(none, .notConnected)
        for yaml in ["protect:\n  enabled: false\n  profile: \"p\"\n",
                     "output:\n  output_dir: x\n",
                     "school_cli:\n  enabled: true\nprotect:\n  enabled: true\n  profile: \"p\"\n"] {
            let config = try loadConfig(yaml)
            XCTAssertEqual(
                ProtectBackup.plan(
                    config: config, workspaceProfile: "ws",
                    pinAllows: { evaluated += 1; return true },
                    sharedStorage: { evaluated += 1; return nil }),
                .notConnected, yaml)
        }
        XCTAssertEqual(evaluated, 0)
    }

    func test_plan_runsWhenConnectedLocalAndPinned() throws {
        let config = try loadConfig(connectedConfig)
        XCTAssertEqual(
            ProtectBackup.plan(config: config, workspaceProfile: "ws",
                               pinAllows: { true }, sharedStorage: { nil }),
            .run(profile: "protect-login"))
    }

    func test_plan_skipsOnDriftEmptyProfileAndSharedStorage() throws {
        let config = try loadConfig(connectedConfig)
        guard case .skip(let drift) = ProtectBackup.plan(
            config: config, workspaceProfile: "ws",
            pinAllows: { false }, sharedStorage: { nil }) else { return XCTFail("drift") }
        XCTAssertTrue(drift.contains("protect.profile changed"), drift)

        guard case .skip(let shared) = ProtectBackup.plan(
            config: config, workspaceProfile: "ws",
            pinAllows: { true }, sharedStorage: { "on OneDrive" }) else { return XCTFail("shared") }
        XCTAssertTrue(shared.contains("on OneDrive"), shared)

        let blank = try loadConfig("protect:\n  enabled: true\n  profile: \"\"\n")
        guard case .skip(let empty) = ProtectBackup.plan(
            config: blank, workspaceProfile: "ws",
            pinAllows: { true }, sharedStorage: { nil }) else { return XCTFail("empty") }
        XCTAssertTrue(empty.contains("protect.profile is empty"), empty)
    }

    func test_result_classifiesExitCodesAgainstWhatWasWritten() throws {
        let dir = try makeTempDir()
        // Nothing written: any non-zero exit is a failure, timeout included.
        XCTAssertEqual(ProtectBackup.result(exit: 3, directory: dir).state, .failed)
        XCTAssertEqual(ProtectBackup.result(exit: 7, directory: dir).state, .failed)
        XCTAssertEqual(ProtectBackup.result(exit: 0, directory: dir).state, .ok)
        try write("name: a", to: dir.appendingPathComponent("plans/a.yaml"))
        try write("name: c", to: dir.appendingPathComponent("connections.yaml"))
        XCTAssertEqual(ProtectBackup.result(exit: 0, directory: dir).objectCounts,
                       ["plans": 1, "connections": 1])
        XCTAssertEqual(ProtectBackup.result(exit: 7, directory: dir).state, .partial)
        XCTAssertEqual(ProtectBackup.result(exit: 3, directory: dir).state, .failed)
        XCTAssertEqual(
            ProtectBackup.result(exit: CLIBridge.exitCodeTimedOut, directory: dir).state, .failed)
        try write("plans: boom", to: dir.appendingPathComponent("_failures.yaml"))
        let withFailures = ProtectBackup.result(exit: 1, directory: dir)
        XCTAssertEqual(withFailures.state, .partial)
        XCTAssertTrue(withFailures.hasFailuresFile)
        XCTAssertNil(withFailures.objectCounts["_failures"], "_failures.yaml is not a resource")
        // Exit 0 with a failures file is still not a whole backup.
        XCTAssertEqual(ProtectBackup.result(exit: 0, directory: dir).state, .partial)
    }

    // MARK: - backup(): connected

    func test_backup_connectedWorkspaceBacksUpProtectIntoTheSameFolder() async throws {
        let ctx = try makeContext(config: connectedConfig, protect: .ok)
        let lines = Lines()
        let exit = try await CLIBridge().backup(
            profile: ctx.profile, label: "scheduled-t", _testExecutable: ctx.stub
        ) { lines.append($0) }

        XCTAssertEqual(exit, 0)
        let calls = try ctx.calls()
        XCTAssertEqual(calls.count, 2, "\(calls)")
        XCTAssertTrue(calls[0].contains("pro backup"), calls[0])
        let protectCall = calls[1]
        XCTAssertTrue(protectCall.hasPrefix("-p protect-login --no-input protect backup --output "),
                      protectCall)
        XCTAssertTrue(protectCall.hasSuffix("/protect"), protectCall)
        XCTAssertTrue(protectCall.contains("/backups/.tmp-"), "staging folder: \(protectCall)")

        let final = try ctx.onlyBackup()
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: final.appendingPathComponent("computers.json").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: final.appendingPathComponent("protect/plans/a.yaml").path))
        let manifest = try ctx.manifest(of: final)
        let products = try XCTUnwrap(manifest["products"] as? [String: Any])
        XCTAssertEqual((products["pro"] as? [String: Any])?["state"] as? String, "ok")
        XCTAssertEqual((products["pro"] as? [String: Any])?["exit_code"] as? Int, 0)
        let protect = try XCTUnwrap(BackupProductResult.protect(inManifest: manifest))
        XCTAssertEqual(protect, BackupProductResult(
            state: .ok, exitCode: 0,
            objectCounts: ["plans": 2, "action-configs": 1]))
        XCTAssertEqual(manifest["file_count"] as? Int, 4, "the count covers both products")
        XCTAssertEqual(try XCTUnwrap(BackupLibrary().list(profile: ctx.profile).first).protect,
                       protect)
        XCTAssertTrue(lines.texts.contains { $0.hasPrefix("[ok] Jamf Protect") }, "\(lines.texts)")
        XCTAssertFalse(lines.texts.contains { $0.hasPrefix("[partial]") })
    }

    func test_backup_workspaceWithoutProtectIsAsBefore() async throws {
        for config in [nil, "output:\n  output_dir: \"Generated Reports\"\n",
                       "protect:\n  enabled: false\n  profile: \"protect-login\"\n"] {
            let ctx = try makeContext(config: config, protect: .ok)
            let lines = Lines()
            let exit = try await CLIBridge().backup(
                profile: ctx.profile, label: nil, _testExecutable: ctx.stub
            ) { lines.append($0) }
            XCTAssertEqual(exit, 0)
            XCTAssertEqual(try ctx.calls().count, 1, "only pro backup runs")
            let final = try ctx.onlyBackup()
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: final.appendingPathComponent("protect").path))
            let manifest = try ctx.manifest(of: final)
            XCTAssertNil(manifest["products"], "a workspace without Protect writes no products")
            XCTAssertEqual(Set(manifest.keys), ["label", "created_at", "file_count", "size_bytes"])
            XCTAssertFalse(lines.texts.contains { $0.contains("Protect") }, "\(lines.texts)")
        }
    }

    // MARK: - backup(): skipped

    func test_backup_skipsProtectWhenTheProfileDriftedOnASharedWorkspace() async throws {
        let shared = "shared_workspace:\n  enabled: true\n"
        let ctx = try makeContext(
            config: shared + "protect:\n  enabled: true\n  profile: \"protect-a\"\n",
            protect: .ok)
        _ = SharedConfigPin.check(profile: ctx.profile)  // this Mac pins protect-a
        try (shared + "protect:\n  enabled: true\n  profile: \"protect-b\"\n")
            .write(to: ctx.workspace.appendingPathComponent("config.yaml"),
                   atomically: true, encoding: .utf8)
        let lines = Lines()
        let exit = try await CLIBridge().backup(
            profile: ctx.profile, label: "scheduled-t", _testExecutable: ctx.stub
        ) { lines.append($0) }

        XCTAssertEqual(exit, 0, "the Jamf Pro backup stands")
        let calls = try ctx.calls()
        XCTAssertEqual(calls.count, 1, "protect backup must not run: \(calls)")
        let warns = lines.texts.filter { $0.hasPrefix("[warn] Jamf Protect not backed up") }
        XCTAssertEqual(warns.count, 1, "\(lines.texts)")
        XCTAssertTrue(warns[0].contains("protect.profile changed"), warns[0])
        let manifest = try ctx.manifest(of: try ctx.onlyBackup())
        let result = try XCTUnwrap(BackupProductResult.protect(inManifest: manifest))
        XCTAssertEqual(result.state, .skipped)
        XCTAssertFalse(result.isIncomplete, "a skip is not a failure")
        XCTAssertFalse(lines.texts.contains { $0.hasPrefix("[partial]") })
    }

    func test_backup_skipsProtectOnSharedStorage() async throws {
        let ctx = try makeContext(
            config: "shared_workspace:\n  enabled: true\n" + connectedConfig + "\n", protect: .ok)
        let lines = Lines()
        let exit = try await CLIBridge().backup(
            profile: ctx.profile, label: nil, _testExecutable: ctx.stub
        ) { lines.append($0) }

        XCTAssertEqual(exit, 0)
        let calls = try ctx.calls()
        XCTAssertEqual(calls.count, 1, "\(calls)")
        let warns = lines.texts.filter { $0.hasPrefix("[warn] Jamf Protect not backed up") }
        XCTAssertEqual(warns.count, 1, "\(lines.texts)")
        XCTAssertTrue(warns[0].contains("in a shared workspace"), warns[0])
        XCTAssertTrue(warns[0].contains("credentials"), warns[0])
        let final = try ctx.onlyBackup()
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: final.appendingPathComponent("protect").path))
        XCTAssertEqual(
            BackupProductResult.protect(inBackup: final)?.state, .skipped)
    }

    // MARK: - backup(): Protect fails, Pro stands

    func test_backup_partialProtectKeepsProMarksManifestAndRunPartialAndBlocksPruning() async throws {
        let ctx = try makeContext(config: connectedConfig, protect: .partial)
        let lines = Lines()
        let exit = try await CLIBridge().backup(
            profile: ctx.profile, label: "scheduled-20260101", _testExecutable: ctx.stub
        ) { lines.append($0) }

        XCTAssertEqual(exit, 0, "Protect never changes the Jamf Pro backup's exit")
        let final = try ctx.onlyBackup()
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: final.appendingPathComponent("computers.json").path))
        let protect = try XCTUnwrap(BackupProductResult.protect(inBackup: final))
        XCTAssertEqual(protect.state, .partial)
        XCTAssertEqual(protect.exitCode, 7)
        XCTAssertTrue(protect.hasFailuresFile)
        XCTAssertTrue(protect.isIncomplete)

        let texts = lines.texts
        let warn = try XCTUnwrap(texts.first { $0.hasPrefix("[warn] Jamf Protect backup is PARTIAL") })
        XCTAssertTrue(warn.contains("protect/_failures.yaml"), warn)
        XCTAssertEqual(texts.filter { $0.hasPrefix("[partial]") }.count, 1, "\(texts)")

        // The scheduled run's watcher reads that line as an incomplete run; backup mode has no
        // same-day retry, so Partial does not repeat the run.
        let watcher = CollectHonestyWatcher()
        texts.forEach(watcher.observe)
        XCTAssertTrue(watcher.incomplete)
        let backupSchedule = Schedule(
            name: "backup", profile: ctx.profile, schedule: "Mon 07:00", cadence: "custom",
            mode: .backup, next: "—", last: "—", lastStatus: .partial, artifacts: [],
            enabled: true, launchAgentLabel: "com.github.tonyyo11.jamf-reports-community.x.backup")
        var state = TickState()
        let fire = Date(timeIntervalSince1970: 1_788_000_000)
        state.lastStarted[backupSchedule.launchAgentLabel!] = fire
        for hours in [1.0, 3.0, 9.0] {
            XCTAssertTrue(TickScheduler.due(
                schedules: [backupSchedule], state: state, runNowLabels: [],
                now: fire.addingTimeInterval(hours * 3600)).isEmpty,
                "no retry \(hours) h after a Partial backup")
        }
    }

    func test_pruneNeverRemovesOrCountsABackupWithAnIncompleteProtectPart() throws {
        let ctx = try makeContext(config: connectedConfig, protect: .ok)
        let backups = ctx.workspace.appendingPathComponent("backups", isDirectory: true)
        func make(_ name: String, protect: BackupProductResult?) throws {
            var manifest: [String: Any] = ["label": "scheduled-x"]
            if let protect { manifest["products"] = ["protect": protect.manifestValue] }
            let dir = backups.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: manifest)
                .write(to: dir.appendingPathComponent("manifest.json"))
        }
        try make("20260501T010101", protect: nil)
        try make("20260502T010101", protect: BackupProductResult(state: .partial, exitCode: 7))
        try make("20260503T010101", protect: BackupProductResult(state: .failed, exitCode: 3))
        try make("20260504T010101", protect: BackupProductResult(state: .skipped, reason: "x"))
        try make("20260505T010101", protect: BackupProductResult(state: .ok, exitCode: 0))

        let lines = Lines()
        BackupMaintenance.pruneScheduledBackups(profile: ctx.profile, keep: 1) { lines.append($0) }

        let left = try FileManager.default.contentsOfDirectory(atPath: backups.path).sorted()
        XCTAssertEqual(left, ["20260502T010101", "20260503T010101", "20260505T010101"],
                       "incomplete Protect parts stay; of the rest only the newest is kept")
        XCTAssertTrue(lines.texts.contains { $0.contains("2 scheduled backup(s) whose Jamf Protect") },
                      "\(lines.texts)")
    }

    func test_backup_failedProtectDiscardsItsFilesAndKeepsPro() async throws {
        let ctx = try makeContext(config: connectedConfig, protect: .failed)
        let lines = Lines()
        let exit = try await CLIBridge().backup(
            profile: ctx.profile, label: nil, _testExecutable: ctx.stub
        ) { lines.append($0) }

        XCTAssertEqual(exit, 0)
        let final = try ctx.onlyBackup()
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: final.appendingPathComponent("protect").path),
            "files of a failed Protect run are not kept")
        let protect = try XCTUnwrap(BackupProductResult.protect(inBackup: final))
        XCTAssertEqual(protect.state, .failed)
        XCTAssertEqual(protect.exitCode, 3)
        XCTAssertTrue(protect.objectCounts.isEmpty)
        XCTAssertTrue(lines.texts.contains { $0.hasPrefix("[partial]") })
        XCTAssertTrue(lines.texts.contains { $0.hasPrefix("[error]") && $0.contains("authentication failed") },
                      "\(lines.texts)")
    }

    func test_backup_protectHasItsOwnTimeout() async throws {
        let ctx = try makeContext(config: connectedConfig, protect: .hang)
        let lines = Lines()
        let exit = try await CLIBridge().backup(
            profile: ctx.profile, label: nil, protectTimeout: 1, _testExecutable: ctx.stub
        ) { lines.append($0) }

        XCTAssertEqual(exit, 0, "pro backup was not under the 1 s protect limit")
        let protect = try XCTUnwrap(BackupProductResult.protect(inBackup: try ctx.onlyBackup()))
        XCTAssertEqual(protect.state, .failed)
        XCTAssertEqual(protect.exitCode, CLIBridge.exitCodeTimedOut)
        XCTAssertTrue(lines.texts.contains {
            $0.hasPrefix("[error] protect backup stopped after the 1 s limit") }, "\(lines.texts)")
    }

    // MARK: - Manifest compatibility

    func test_olderManifestsStillRead() throws {
        let ctx = try makeContext(config: nil, protect: .ok)
        let backups = ctx.workspace.appendingPathComponent("backups", isDirectory: true)
        let dir = backups.appendingPathComponent("20260601T214020", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try write("{}", to: dir.appendingPathComponent("computers.json"))
        let old = """
        {"label": "scheduled-20260601", "created_at": "2026-06-01T21:40:20Z",
         "file_count": 7, "size_bytes": 1234}
        """
        try write(old, to: dir.appendingPathComponent("manifest.json"))

        let record = try XCTUnwrap(BackupLibrary().list(profile: ctx.profile).first)
        XCTAssertEqual(record.label, "scheduled-20260601")
        XCTAssertEqual(record.fileCount, 7)
        XCTAssertNil(record.protect)
        XCTAssertNil(BackupProductResult.protect(inBackup: dir))
        XCTAssertNil(BackupProductResult.protect(inManifest: ["products": ["pro": ["state": "ok"]]]))
        XCTAssertNil(BackupProductResult.protect(
            inManifest: ["products": ["protect": ["state": "from-the-future"]]]),
            "an unknown state reads as no record, never as ok")
    }

    func test_productResultRoundTripsThroughTheManifest() throws {
        let original = BackupProductResult(
            state: .partial, exitCode: 7, reason: nil,
            objectCounts: ["plans": 3], hasFailuresFile: true)
        let data = try JSONSerialization.data(withJSONObject: ["protect": original.manifestValue])
        let decoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(BackupProductResult(manifestValue: decoded["protect"]), original)
        let skipped = BackupProductResult(state: .skipped, reason: "shared")
        XCTAssertEqual(BackupProductResult(manifestValue: skipped.manifestValue), skipped)
    }

    // MARK: - Backups screen text

    func test_summaryNamesWhatTheLatestBackupHolds() {
        let ok = BackupProductResult(
            state: .ok, exitCode: 0, objectCounts: ["plans": 2, "analytics": 1])
        XCTAssertEqual(ok.protectSummary,
                       "The latest backup includes Jamf Protect: 3 objects (analytics 1, plans 2).")
        let partial = BackupProductResult(
            state: .partial, exitCode: 7, objectCounts: ["plans": 1], hasFailuresFile: true)
        XCTAssertTrue(partial.protectSummary.contains("protect/_failures.yaml"))
        XCTAssertTrue(partial.protectSummary.contains("never pruned"))
        let failed = BackupProductResult(state: .failed, exitCode: 3)
        XCTAssertTrue(failed.protectSummary.contains("failed (exit 3)"))
        XCTAssertEqual(
            BackupProductResult(state: .skipped, reason: "shared").protectSummary,
            "Jamf Protect was not backed up: shared.")
    }

    func test_onlyABackupWithProtectObjectsNotesThatDiffSkipsThem() {
        func record(_ protect: BackupProductResult?) -> BackupRecord {
            BackupRecord(name: "n", label: "", created: Date(), sizeBytes: 1, fileCount: 1,
                         url: URL(fileURLWithPath: "/tmp/n"), protect: protect)
        }
        XCTAssertFalse(record(nil).includesProtectFiles)
        XCTAssertFalse(record(BackupProductResult(state: .skipped, reason: "x")).includesProtectFiles)
        XCTAssertFalse(record(BackupProductResult(state: .failed, exitCode: 3)).includesProtectFiles)
        XCTAssertTrue(record(BackupProductResult(
            state: .ok, exitCode: 0, objectCounts: ["plans": 1])).includesProtectFiles)
    }

    // MARK: - Permissions

    func test_backupKeepsCredentialFilesOwnerOnly() async throws {
        let ctx = try makeContext(config: connectedConfig, protect: .ok)
        _ = try await CLIBridge().backup(
            profile: ctx.profile, label: nil, _testExecutable: ctx.stub) { _ in }

        let final = try ctx.onlyBackup()
        let credential = final.appendingPathComponent("protect/action-configs/hook.yaml")
        XCTAssertEqual(try mode(of: credential), 0o600, "jamf-cli's 0600 survives the move")
        let subpaths = try FileManager.default.subpathsOfDirectory(atPath: final.path)
        for sub in subpaths {
            let url = final.appendingPathComponent(sub)
            let bits = try mode(of: url)
            XCTAssertEqual(bits & 0o077, 0, "\(sub) is \(String(bits, radix: 8))")
        }
        XCTAssertGreaterThanOrEqual(subpaths.count, 7)
        XCTAssertEqual(try mode(of: final.appendingPathComponent("protect")), 0o700)
    }

    // MARK: - Helpers

    private struct Context {
        let profile: String
        let workspace: URL
        let stub: URL
        let log: URL

        func calls() throws -> [String] {
            guard let text = try? String(contentsOf: log, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").map(String.init)
        }

        func onlyBackup() throws -> URL {
            let backups = workspace.appendingPathComponent("backups", isDirectory: true)
            let names = try FileManager.default.contentsOfDirectory(atPath: backups.path)
            XCTAssertEqual(names.count, 1, "\(names)")
            return backups.appendingPathComponent(try XCTUnwrap(names.first), isDirectory: true)
        }

        func manifest(of backup: URL) throws -> [String: Any] {
            let data = try Data(contentsOf: backup.appendingPathComponent("manifest.json"))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
    }

    private func makeContext(config: String?, protect: ProtectMode) throws -> Context {
        let root = try makeTempDir()
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        addTeardownBlock { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
        let profile = "pbk-\(UUID().uuidString.prefix(8).lowercased())"
        let workspace = try XCTUnwrap(ProfileService.workspaceURL(for: profile))
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        if let config {
            try config.write(to: workspace.appendingPathComponent("config.yaml"),
                             atomically: true, encoding: .utf8)
        }
        let scripts = try makeTempDir()
        let log = scripts.appendingPathComponent("calls.log")
        let stub = try makeStub(in: scripts, log: log, protect: protect)
        return Context(profile: profile, workspace: workspace, stub: stub, log: log)
    }

    /// Records each call's arguments, then behaves as `pro backup` or `protect backup`.
    private func makeStub(in dir: URL, log: URL, protect: ProtectMode) throws -> URL {
        let protectBody: String
        let writeFiles = """
        mkdir -p "$out/plans" "$out/action-configs"
        echo 'name: a' > "$out/plans/a.yaml"
        echo 'name: b' > "$out/plans/b.yaml"
        echo 'headers: secret' > "$out/action-configs/hook.yaml"
        chmod 644 "$out/plans/a.yaml" "$out/plans/b.yaml"
        chmod 600 "$out/action-configs/hook.yaml"
        """
        switch protect {
        case .ok:
            protectBody = writeFiles + "\nexit 0"
        case .partial:
            protectBody = writeFiles + "\necho 'plans: boom' > \"$out/_failures.yaml\"\nexit 7"
        case .failed:
            protectBody = writeFiles + "\nexit 3"
        case .hang:
            protectBody = writeFiles + "\nexec /bin/sleep 30"
        }
        let script = """
        #!/bin/sh
        printf '%s\\n' "$*" >> '\(log.path)'
        prev=""; out=""
        for a in "$@"; do
          if [ "$prev" = "--output" ]; then out="$a"; fi
          prev="$a"
        done
        case " $* " in
        *" protect backup "*)
        \(protectBody)
        ;;
        *)
        mkdir -p "$out"
        echo '{"a":1}' > "$out/computers.json"
        chmod 644 "$out/computers.json"
        exit 0
        ;;
        esac
        """
        let url = dir.appendingPathComponent("stub-cli-\(UUID().uuidString)")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func loadConfig(_ yaml: String) throws -> ReportConfig {
        let url = try makeTempDir().appendingPathComponent("config.yaml")
        try yaml.write(to: url, atomically: true, encoding: .utf8)
        return try ConfigLoader.load(from: url)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func mode(of url: URL) throws -> Int {
        try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProtectBackupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }
}

private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [CLIBridge.LogLine] = []

    func append(_ line: CLIBridge.LogLine) { lock.withLock { stored.append(line) } }
    var texts: [String] { lock.withLock { stored.map(\.text) } }
}
