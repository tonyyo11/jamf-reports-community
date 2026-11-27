import XCTest
@testable import JamfReports

/// School and Protect collects tell the truth about launch failures and a refused state folder,
/// as the Jamf Pro collect does.
final class SchoolProtectCollectHonestyTests: XCTestCase {
    private var root: URL!
    private var bin: URL!
    private let profile = "school-honesty"

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("JRC-SPHonesty-\(UUID().uuidString)", isDirectory: true)
        let workspaces = root.appendingPathComponent("Jamf-Reports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspaces.appendingPathComponent(profile, isDirectory: true),
            withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", workspaces.path, 1)
        addTeardownBlock { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
        // Not named `jamf-cli`: `CLIBridge.codesignGate` keys on that filename.
        bin = root.appendingPathComponent("stub-cli")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func installStub(executable: Bool, exitCode: Int = 1) throws {
        let body = executable ? "#!/bin/sh\nexit \(exitCode)\n" : "not an executable\n"
        try body.write(to: bin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: bin.path)
    }

    func testSchoolRunWhereEveryKindFailsToLaunchIsADeadCollect() async throws {
        try installStub(executable: false)
        let stub: URL = bin
        do {
            try await ReportEngine.schoolCollect(
                workspace: WorkspaceID(validating: profile),
                profile: profile, workspacePaths: WorkspacePaths.self, force: true,
                locateJamfCLI: { stub }, onLine: { _ in })
            XCTFail("a School run that launched nothing must not succeed")
        } catch ReportEngineError.collectDead(_, let failedCount, _) {
            XCTAssertGreaterThan(failedCount, 0)
        }
    }

    /// UNCAPTURED fixture: go-keyring's error shape, printed on stderr only.
    private func installLockedKeychainStub() throws {
        let body = "#!/bin/sh\necho 'Error: reading keychain item jamf-cli/p/client-secret: "
            + "exit status 36' >&2\nexit 1\n"
        try body.write(to: bin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
    }

    func testSchoolRunWithALockedKeychainIsADeadCollectNamingTheKeychain() async throws {
        try installLockedKeychainStub()
        let stub: URL = bin
        let seen = LineBox()
        do {
            try await ReportEngine.schoolCollect(
                workspace: WorkspaceID(validating: profile),
                profile: profile, workspacePaths: WorkspacePaths.self, force: true,
                locateJamfCLI: { stub }, onLine: seen.append)
            XCTFail("a locked keychain must not read as a successful School run")
        } catch ReportEngineError.collectDead(_, _, let cause) {
            XCTAssertEqual(cause, .keychainLocked)
            XCTAssertTrue(seen.texts.contains { $0.contains(FailureCause.keychainLockedHint) },
                          "\(seen.texts)")
        }
    }

    func testProtectCollectRecordsALockedKeychainAsTheCause() async throws {
        let data = try WorkspacePaths.dataDir(for: profile)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try installLockedKeychainStub()
        let stub: URL = bin
        try await ReportEngine.protectCollect(
            profile: profile, dataDir: data, locateJamfCLI: { stub },
            readVersion: { _ in "1.38.0" }, onLine: { _ in })
        let store = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
        let kind = try XCTUnwrap(ReportEngine.protectCommandMatrix(profile: profile).first?.kind)
        XCTAssertEqual(store.cause(for: kind)?.kind, .keychainLocked)
    }

    /// Protect rides after the MDM collect. Unforced, a source that landed inside the refresh
    /// cadence, or that timed out twice in a row, is left alone; a direct or forced call and a
    /// Protect-only environment collect everything.
    func testAnUnforcedProtectCollectKeepsTheCadenceAndTheTimeoutHold() async throws {
        let data = try WorkspacePaths.dataDir(for: profile)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let calls = root.appendingPathComponent("calls")
        try "#!/bin/sh\necho x >> '\(calls.path)'\nprintf '[]'\n"
            .write(to: bin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        let stub: URL = bin
        let kinds = ReportEngine.protectCommandMatrix(profile: profile).map(\.kind)
        func callCount() -> Int {
            ((try? String(contentsOf: calls, encoding: .utf8)) ?? "")
                .split(separator: "\n").count
        }
        func collect(forced: Bool) async throws -> [String] {
            try await ReportEngine.$addOnCollectForced.withValue(forced) {
                try await ReportEngine.protectCollect(
                    profile: profile, dataDir: data, locateJamfCLI: { stub },
                    readVersion: { _ in "1.38.0" }, onLine: { _ in })
            }
        }

        let first = try await collect(forced: false)
        XCTAssertEqual(first, kinds, "never collected: every source is due")
        XCTAssertEqual(callCount(), kinds.count)
        let second = try await collect(forced: false)
        XCTAssertEqual(second, [], "all inside the cadence: nothing runs, nothing landed")
        XCTAssertEqual(callCount(), kinds.count)
        let forced = try await collect(forced: true)
        XCTAssertEqual(forced, kinds)
        XCTAssertEqual(callCount(), kinds.count * 2)

        let store = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
        let held = try XCTUnwrap(kinds.first)
        let old = Date().addingTimeInterval(-90_000)
        for kind in kinds { store.record(.landed, report: kind, at: old) }
        store.record(.failed(exitCode: CLIBridge.exitCodeTimedOut), report: held, at: Date())
        store.record(.failed(exitCode: CLIBridge.exitCodeTimedOut), report: held, at: Date())
        let afterHold = try await collect(forced: false)
        XCTAssertEqual(afterHold, Array(kinds.dropFirst()), "the held source waits")
    }

    /// jamf-cli's swallowed 403: exit 0, nothing on stdout, the refusal on stderr.
    private func installSwallowed403Stub() throws {
        let body = "#!/bin/sh\necho 'permission denied (HTTP 403)' >&2\nexit 0\n"
        try body.write(to: bin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
    }

    /// `failedRun` is for a collect that threw (a dead School run prints no `[partial]` line, so
    /// the verdict comes from the failures it recorded); otherwise the `[partial]` line decides.
    private func assertMissingPermissionEndsRetries(
        kind: String, lines: LineBox, failedRunSince start: Date? = nil
    ) throws {
        let store = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
        XCTAssertEqual(store.cause(for: kind)?.kind, .missingPermission)
        let warn = try XCTUnwrap(
            lines.texts.first { $0.hasPrefix("[warn] \(kind): exit 0 — skipped") },
            "\(lines.texts)")
        XCTAssertTrue(warn.contains("— cause: missing permission"), warn)
        let watcher = CollectHonestyWatcher()
        lines.texts.forEach(watcher.observe)
        if let start {
            XCTAssertFalse(watcher.retryCouldHelp(profile: profile, exitCode: 1, since: start),
                           "a refused permission is not fetched by a retry: \(lines.texts)")
        } else {
            XCTAssertTrue(watcher.incomplete, "Run History still reads the run as Partial")
            XCTAssertFalse(watcher.retryCouldHelp(profile: profile),
                           "a refused permission is not fetched by a retry: \(lines.texts)")
        }
    }

    func testSchoolSwallowed403IsAMissingPermissionAndNotRetried() async throws {
        try installSwallowed403Stub()
        let stub: URL = bin
        let seen = LineBox()
        let start = Date().addingTimeInterval(-1)
        do {
            try await ReportEngine.schoolCollect(
                workspace: WorkspaceID(validating: profile),
                profile: profile, workspacePaths: WorkspacePaths.self, force: true,
                locateJamfCLI: { stub }, onLine: seen.append)
            XCTFail("every source refused: the run is dead")
        } catch ReportEngineError.collectDead(_, _, let cause) {
            XCTAssertEqual(cause, .noPermission)
        }
        let kind = try XCTUnwrap(ReportEngine.schoolCommandMatrix(profile: profile).first?.kind)
        try assertMissingPermissionEndsRetries(kind: kind, lines: seen, failedRunSince: start)
    }

    func testProtectSwallowed403IsAMissingPermissionAndNotRetried() async throws {
        let data = try WorkspacePaths.dataDir(for: profile)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try installSwallowed403Stub()
        let stub: URL = bin
        let seen = LineBox()
        try await ReportEngine.protectCollect(
            profile: profile, dataDir: data, locateJamfCLI: { stub },
            readVersion: { _ in "1.38.0" }, onLine: seen.append)
        let kind = try XCTUnwrap(ReportEngine.protectCommandMatrix(profile: profile).first?.kind)
        try assertMissingPermissionEndsRetries(kind: kind, lines: seen)
    }

    /// A `state` folder that is a link is refused with one `[warn]`, not skipped in silence.
    private func linkStateFolder() throws -> URL {
        let data = try WorkspacePaths.dataDir(for: profile)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: data.appendingPathComponent("state"), withDestinationURL: elsewhere)
        return data
    }

    private func refusals(_ lines: [String]) -> [String] {
        lines.filter { $0.hasPrefix("[warn] state is not used") }
    }

    func testSchoolCollectWarnsOnceWhenTheStateFolderIsRefused() async throws {
        _ = try linkStateFolder()
        try installStub(executable: true)
        let stub: URL = bin
        let seen = LineBox()
        _ = try? await ReportEngine.schoolCollect(
            workspace: WorkspaceID(validating: profile),
            profile: profile, workspacePaths: WorkspacePaths.self, force: true,
            locateJamfCLI: { stub }, onLine: seen.append)
        XCTAssertEqual(refusals(seen.texts).count, 1, "\(seen.texts)")
    }

    func testProtectCollectWarnsOnceWhenTheStateFolderIsRefused() async throws {
        let data = try linkStateFolder()
        try installStub(executable: true)
        let stub: URL = bin
        let seen = LineBox()
        try await ReportEngine.protectCollect(
            profile: profile, dataDir: data, locateJamfCLI: { stub },
            readVersion: { _ in "1.38.0" }, onLine: seen.append)
        XCTAssertEqual(refusals(seen.texts).count, 1, "\(seen.texts)")
    }

    // MARK: - Wave E sources

    /// Writes a stub that answers each new Protect command with its own payload and every
    /// other command with `[]`.
    private func installWaveEStub(signatures: String, installer: String) throws {
        let body = """
            #!/bin/sh
            case "$*" in
              *threat-prevention-versions*) printf '%s' '\(signatures)' ;;
              *"downloads summary"*) printf '%s' '\(installer)' ;;
              *) printf '[]' ;;
            esac
            """
        try body.write(to: bin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
    }

    private func newestSnapshot(_ kind: String, in data: URL) throws -> Data {
        let file = try XCTUnwrap(
            FileManager.newestJSONFile(in: data.appendingPathComponent(kind)))
        return try Data(contentsOf: file)
    }

    /// The two sources save only their keep-lists: no download URL, no unknown key.
    func testTheNewProtectSourcesSaveOnlyTheirKeptFields() async throws {
        let data = try WorkspacePaths.dataDir(for: profile)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try installWaveEStub(
            signatures: #"[{"id":"40213","created":"2026-11-20T10:00:00.123456789Z","x":{"y":1}}]"#,
            installer: #"{"installerVersion":"5.1.0.7","installerURL":"https://x.invalid/p"}"#)
        let stub: URL = bin
        let seen = LineBox()
        let landed = try await ReportEngine.$addOnCollectForced.withValue(true) {
            try await ReportEngine.protectCollect(
                profile: profile, dataDir: data, locateJamfCLI: { stub },
                readVersion: { _ in "1.38.0" }, onLine: seen.append)
        }
        XCTAssertTrue(landed.contains(ReportEngine.protectSignatureVersionsKind), "\(seen.texts)")
        XCTAssertTrue(landed.contains(ReportEngine.protectInstallerKind))
        let signatures = try JSONSerialization.jsonObject(
            with: newestSnapshot(ReportEngine.protectSignatureVersionsKind, in: data))
            as? [[String: Any]]
        XCTAssertEqual(signatures?.first?.keys.sorted(), ["created", "id"])
        let installer = try newestSnapshot(ReportEngine.protectInstallerKind, in: data)
        XCTAssertEqual(String(decoding: installer, as: UTF8.self),
                       #"[{"installerVersion":"5.1.0.7"}]"#)
    }

    /// A payload the reducer cannot read is not saved: a failed attempt, reported as not landed.
    func testAProtectSourceThatCannotBeReducedIsNotSaved() async throws {
        let data = try WorkspacePaths.dataDir(for: profile)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try installWaveEStub(signatures: #"{"unexpected":true}"#, installer: "null")
        let stub: URL = bin
        let seen = LineBox()
        let kind = ReportEngine.protectSignatureVersionsKind
        let landed = try await ReportEngine.$addOnCollectForced.withValue(true) {
            try await ReportEngine.protectCollect(
                profile: profile, dataDir: data, locateJamfCLI: { stub },
                readVersion: { _ in "1.38.0" }, onLine: seen.append)
        }
        XCTAssertFalse(landed.contains(kind))
        XCTAssertTrue(seen.texts.contains("[warn] \(kind) not saved: unexpected shape"))
        XCTAssertTrue(seen.texts.contains { $0.hasPrefix("[partial]") && $0.contains(kind) },
                      "\(seen.texts)")
        XCTAssertNil(FileManager.newestJSONFile(in: data.appendingPathComponent(kind)))
        let store = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
        XCTAssertEqual(store.lastFailureExitCode(for: kind), 0)
        XCTAssertTrue(landed.contains(ReportEngine.protectInstallerKind),
                      "a null installer answer is an empty list, which lands")
    }

    /// With every gated source listed in collect_skip, the version is never asked for.
    func testNoVersionProbeWhenTheGatedSourcesAreTurnedOff() async throws {
        let data = try WorkspacePaths.dataDir(for: profile)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try installWaveEStub(signatures: "[]", installer: "[]")
        let stub: URL = bin
        let asked = LineBox()
        let gated = Set(ReportEngine.minimumJamfCLI.keys)
        _ = try await ReportEngine.$addOnCollectForced.withValue(true) {
            try await ReportEngine.protectCollect(
                profile: profile, dataDir: data, collectSkip: gated, locateJamfCLI: { stub },
                readVersion: { _ in
                    asked.append(.init(timestamp: Date(), level: .info, text: "asked"))
                    return "1.38.0"
                }, onLine: { _ in })
        }
        XCTAssertEqual(asked.texts, [])
    }

    /// On a jamf-cli too old for them the new sources are skipped: no command, nothing
    /// recorded, no `[partial]` line; the other Protect sources still run.
    func testAnOldJamfCLISkipsTheNewProtectSourcesQuietly() async throws {
        let data = try WorkspacePaths.dataDir(for: profile)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try installWaveEStub(signatures: "[]", installer: "[]")
        let stub: URL = bin
        let seen = LineBox()
        let landed = try await ReportEngine.$addOnCollectForced.withValue(true) {
            try await ReportEngine.protectCollect(
                profile: profile, dataDir: data, locateJamfCLI: { stub },
                readVersion: { _ in "1.34.0" }, onLine: seen.append)
        }
        XCTAssertEqual(landed, ReportEngine.protectReportKinds)
        XCTAssertTrue(seen.texts.contains("[skip] protect-signature-versions: "
            + "needs jamf-cli 1.38.0 or later (installed: 1.34.0)"))
        XCTAssertFalse(seen.texts.contains { $0.hasPrefix("[partial]") }, "\(seen.texts)")
        let store = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
        for kind in [ReportEngine.protectSignatureVersionsKind, ReportEngine.protectInstallerKind] {
            XCTAssertNil(store.lastRun(report: kind))
            XCTAssertNil(store.lastFailureExitCode(for: kind))
        }
    }
}

private final class LineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

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
