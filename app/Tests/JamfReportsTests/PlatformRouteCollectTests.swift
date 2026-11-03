import XCTest
@testable import JamfReports

/// P3 (spec 3.2, D19): under a `profiles:` block the Platform-only kinds run as the `platform`
/// slot's profile, and without the block exactly as before. A stub answers every command and
/// logs its argv; `config list` names both profiles.
final class PlatformRouteCollectTests: XCTestCase {
    private var root: URL!
    private var answers: URL!
    private let ws = "routecollect"

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("JRC-Route-\(UUID().uuidString)", isDirectory: true)
        let workspaces = root.appendingPathComponent("Jamf-Reports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspaces.appendingPathComponent(ws, isDirectory: true),
            withIntermediateDirectories: true)
        answers = root.appendingPathComponent("answers", isDirectory: true)
        try FileManager.default.createDirectory(at: answers, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", workspaces.path, 1)
        addTeardownBlock { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
        ProfileAuthMethod.invalidateCache()
        try answer("config", """
            [{"name":"\(ws)","auth-method":"oauth2"},
             {"name":"\(ws)-API","auth-method":"platform","environment-id":"e1"}]
            """)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    /// NOT named `jamf-cli`. `answers/<name>` and `<name>.exit` answer `config list` (config),
    /// any command run as `-p <ws>-API` (platform) and any other (pro); the default is `[]`.
    private func makeStub() throws -> URL {
        let url = root.appendingPathComponent("stub-cli")
        let script = """
        #!/bin/sh
        A="\(answers.path)"
        printf '%s\\n' "$*" >> "$A/calls.log"
        emit() { f="$A/$1"; if [ -f "$f.exit" ]; then code=$(cat "$f.exit"); else code=0; fi; \\
                 if [ -f "$f" ]; then cat "$f"; else printf '[]'; fi; exit "$code"; }
        case "$*" in
          "config list"*) emit config ;;
          "--version"*) emit version ;;
          "-p \(ws)-API "*) emit platform ;;
          *) emit pro ;;
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

    private func writeConfig(_ yaml: String) throws {
        let dir = try XCTUnwrap(ProfileService.workspaceURL(for: ws))
        try yaml.write(to: dir.appendingPathComponent("config.yaml"),
                       atomically: true, encoding: .utf8)
    }

    private func calls() -> [String] {
        let log = (try? String(contentsOf: answers.appendingPathComponent("calls.log"),
                               encoding: .utf8)) ?? ""
        return log.split(separator: "\n").map(String.init)
    }

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func add(_ line: String) { lock.lock(); stored.append(line); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return stored }
    }

    @discardableResult
    func collect(tiers: Set<CollectionTier> = [.inventory]) async throws -> [String] {
        let stub = try makeStub()
        let lines = Lines()
        try await ReportEngine.collect(
            workspace: WorkspaceID(validating: ws), profile: ws,
            workspacePaths: WorkspacePaths.self, tiers: tiers, force: true,
            locateJamfCLI: { stub }, onLine: { lines.add($0.text) })
        return lines.all
    }

    func testABlockRunsThePlatformKindsAsThePlatformProfile() async throws {
        try writeConfig("profiles:\n  jamf_pro: \(ws)\n  platform: \(ws)-API\n")
        try await collect()
        let log = calls()
        XCTAssertTrue(log.contains { $0.hasPrefix("-p \(ws)-API ") &&
            $0.contains("compliance-benchmarks list") }, "\(log)")
        XCTAssertFalse(log.contains { $0.hasPrefix("-p \(ws) ") &&
            $0.contains("compliance-") }, "\(log)")
    }

    func testAPlatformSlotOnAnotherJamfProSkipsThePlatformKinds() async throws {
        try writeConfig("profiles:\n  jamf_pro: \(ws)\n  platform: \(ws)-API\n")
        let stub = try makeStub()
        let lines = Lines()
        try await ReportEngine.collect(
            workspace: WorkspaceID(validating: ws), profile: ws,
            workspacePaths: WorkspacePaths.self, tiers: [.inventory], force: true,
            locateJamfCLI: { stub },
            platformHosts: { _, _, _ in ("https://a.jamfcloud.com", "https://b.jamfcloud.com") },
            onLine: { lines.add($0.text) })
        XCTAssertFalse(calls().contains { $0.hasPrefix("-p \(ws)-API ") })
        XCTAssertTrue(lines.all.contains {
            $0.hasPrefix("[warn] Platform API not collected: ") && $0.contains("(\(ws)-API)")
                && $0.contains("(\(ws))")
        }, "\(lines.all)")
        XCTAssertFalse(lines.all.contains {
            $0.contains("a.jamfcloud.com") || $0.contains("b.jamfcloud.com")
        })
        XCTAssertFalse(lines.all.contains { $0.hasPrefix("[plan] Platform API kinds run as") })
    }

    /// A platform slot naming a profile that cannot serve Platform kinds is not probed.
    func testNoHostProbeForANonPlatformProfile() async throws {
        try answer("config", """
            [{"name":"\(ws)","auth-method":"oauth2"},{"name":"\(ws)-API","auth-method":"oauth2"}]
            """)
        try writeConfig("profiles:\n  jamf_pro: \(ws)\n  platform: \(ws)-API\n")
        let stub = try makeStub()
        let lines = Lines()
        let probed = ProbeFlag()
        try await ReportEngine.collect(
            workspace: WorkspaceID(validating: ws), profile: ws,
            workspacePaths: WorkspacePaths.self, tiers: [.inventory], force: true,
            locateJamfCLI: { stub },
            platformHosts: { _, _, _ in probed.set(); return (nil, nil) },
            onLine: { lines.add($0.text) })
        XCTAssertFalse(probed.value)
        XCTAssertFalse(lines.all.contains { $0.contains("collecting the Platform API anyway") })
    }

    private final class ProbeFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        func set() { lock.lock(); flag = true; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    }

    /// The log names the profile each Platform kind ran as; an old-shape run names the workspace.
    func testACollectLineNamesTheProfileTheKindRanAs() async throws {
        try writeConfig("profiles:\n  jamf_pro: \(ws)\n  platform: \(ws)-API\n")
        var lines = try await collect()
        XCTAssertTrue(lines.contains("[info] collecting ddm-status for \(ws)-API"), "\(lines)")
        XCTAssertTrue(lines.contains("[info] collecting computers for \(ws)"), "\(lines)")
        try writeConfig("jamf_cli:\n  data_dir: jamf-cli-data\n")
        lines = try await collect()
        XCTAssertTrue(lines.contains("[info] collecting computers for \(ws)"), "\(lines)")
        XCTAssertFalse(lines.contains { $0.hasSuffix("-API") && $0.hasPrefix("[info] collecting") })
    }

    func testThePlanNamesThePlatformProfile() async throws {
        try writeConfig("profiles:\n  jamf_pro: \(ws)\n  platform: \(ws)-API\n")
        let lines = try await collect()
        XCTAssertTrue(lines.contains("[plan] Platform API kinds run as \(ws)-API"), "\(lines)")
    }

    func testABlockWithoutPlatformSkipsThePlatformKinds() async throws {
        try writeConfig("profiles:\n  jamf_pro: \(ws)\n")
        let lines = try await collect()
        XCTAssertFalse(calls().contains { $0.contains("compliance-") })
        XCTAssertTrue(lines.contains {
            $0 == "[skip] compliance-rules: \(EnvironmentProfiles.noPlatformReason)" }, "\(lines)")
    }

    /// Without the block, a workspace whose own profile is OAuth skips the Platform kinds by
    /// its auth method, worded as before.
    func testAnOldShapeSkipsByAuthMethodAsBefore() async throws {
        try writeConfig("jamf_cli:\n  data_dir: jamf-cli-data\n")
        let lines = try await collect()
        XCTAssertTrue(lines.contains {
            $0 == "[skip] compliance-rules: requires a Platform API profile (auth-method is oauth2)"
        }, "\(lines)")
    }

    private let oneMac = #"[{"id":"1","general":{"managementId":"m1"}}]"#

    /// The Jamf Pro credential is dead while the Platform kinds land: the run is auth-dead,
    /// no device scan fans out, and today's summary is not written.
    func testADeadJamfProProfileIsNotHiddenByPlatformKindsThatLanded() async throws {
        try writeConfig("profiles:\n  jamf_pro: \(ws)\n  platform: \(ws)-API\n")
        try answer("pro", #"{"error":"unauthorized"}"#, exit: 3)
        try answer("platform", #"[{"id":"1","title":"CIS"}]"#)
        let stub = try makeStub()
        do {
            try await ReportEngine.collect(
                workspace: WorkspaceID(validating: ws), profile: ws,
                workspacePaths: WorkspacePaths.self, tiers: [.inventory, .scan], force: true,
                authConfirmationProbe: { _, _ in .rejected },
                locateJamfCLI: { stub }, onLine: { _ in })
            XCTFail("expected authExpired")
        } catch ReportEngineError.authExpired(let named, _) {
            XCTAssertEqual(named, ws)
        }
        XCTAssertFalse(calls().contains { $0.contains("classic-computer-history") })
        let summaries = try WorkspacePaths.summariesDir(for: ws)
        XCTAssertNil(FileManager.newestJSONFile(in: summaries))
    }

    /// The Platform credential is dead while Jamf Pro lands: Partial, and the scan runs.
    func testADeadPlatformProfileLeavesTheJamfProRunStanding() async throws {
        try writeConfig("profiles:\n  jamf_pro: \(ws)\n  platform: \(ws)-API\n")
        try answer("pro", oneMac)
        try answer("platform", #"{"error":"unauthorized"}"#, exit: 3)
        let stub = try makeStub()
        let lines = Lines()
        try await ReportEngine.collect(
            workspace: WorkspaceID(validating: ws), profile: ws,
            workspacePaths: WorkspacePaths.self, tiers: [.inventory, .scan], force: true,
            authConfirmationProbe: { _, _ in .rejected },
            locateJamfCLI: { stub }, onLine: { lines.add($0.text) })
        XCTAssertTrue(lines.all.contains { $0.contains(ReportEngine.unlandedSourcesMarker)
            && $0.contains("compliance-") }, "\(lines.all)")
        XCTAssertTrue(calls().contains { $0.contains("classic-computer-history") })
    }

    func testOneProfileInBothSlotsIsOneGroup() {
        let outcomes = [ReportEngine.CollectOutcome(kind: "computers", exitCode: 0),
                        ReportEngine.CollectOutcome(kind: "compliance-rules", exitCode: 3)]
        let group = ReportEngine.jamfProGroup(
            outcomes: outcomes, savedKinds: ["computers"], platformSeparate: false)
        XCTAssertEqual(group.outcomes, outcomes)
        let split = ReportEngine.jamfProGroup(
            outcomes: outcomes, savedKinds: ["computers"], platformSeparate: true)
        XCTAssertEqual(split.outcomes.map(\.kind), ["computers"])
    }

    /// Every non-Platform kind recorded as just collected, so Jamf Pro has nothing due.
    private func seedJamfProNotDue() throws {
        let store = StateFileStore(directory: try WorkspacePaths.stateDir(for: ws))
        let matrix = ReportEngine.collectCommandMatrix(
            profile: ws, platformProfile: "\(ws)-API", staleDays: 30)
        for kind in matrix.map(\.kind) where !ReportEngine.platformOnlyKinds.contains(kind) {
            try store.recordRun(report: kind, at: Date())
        }
    }

    private func collectNotForced() async throws -> [String] {
        let stub = try makeStub()
        let lines = Lines()
        try await ReportEngine.collect(
            workspace: WorkspaceID(validating: ws), profile: ws,
            workspacePaths: WorkspacePaths.self, tiers: [.inventory], force: false,
            locateJamfCLI: { stub }, onLine: { lines.add($0.text) })
        return lines.all
    }

    /// Jamf Pro not due and every Platform kind failing: nothing landed, so no summary.
    func testPlatformFailingWithJamfProNotDueWritesNoSummary() async throws {
        try writeConfig("profiles:\n  jamf_pro: \(ws)\n  platform: \(ws)-API\n")
        try seedJamfProNotDue()
        try answer("platform", #"{"error":"boom"}"#, exit: 1)
        let lines = try await collectNotForced()
        // The reason line is the evidence the rule fired: without it the summary step runs.
        XCTAssertTrue(lines.contains { $0.contains(ReportEngine.noSourceLandedReason) },
                      "\(lines)")
        let summaries = try WorkspacePaths.summariesDir(for: ws)
        XCTAssertNil(FileManager.newestJSONFile(in: summaries))
    }

    /// Jamf Pro not due and the Platform kinds landing is still a run that landed something.
    func testPlatformLandingWithJamfProNotDueIsNotNothingLanded() async throws {
        try writeConfig("profiles:\n  jamf_pro: \(ws)\n  platform: \(ws)-API\n")
        try seedJamfProNotDue()
        try answer("platform", #"[{"id":"1","title":"CIS"}]"#)
        let lines = try await collectNotForced()
        XCTAssertFalse(lines.contains { $0.contains(ReportEngine.noSourceLandedReason) },
                       "\(lines)")
    }
}
