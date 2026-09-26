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
        _ = try? await ReportEngine.collect(
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

    /// A 403 on the first attempt must not stick to a retry that fails for another reason.
    /// The retry exits 0 with empty stdout so a stale latched flag (watcher not reset per
    /// attempt) would misclassify it as `.missingPermission` instead of `.other`.
    /// Exit 1 is retryable; only `patch-device-failures`'s own invocations touch the counter.
    func testARetryIsClassifiedOnItsOwnStderr() async throws {
        let counter = root.appendingPathComponent("patch-attempts")
        let stub = root.appendingPathComponent("stub-cli")
        let script = """
        #!/bin/sh
        case "$*" in
          *patch-status*--scan-failures*)
            n=$(( $(cat "\(counter.path)" 2>/dev/null || echo 0) + 1 ))
            echo "$n" > "\(counter.path)"
            if [ "$n" -eq 1 ]; then
              echo "permission denied (HTTP 403)" >&2
              exit 1
            fi
            exit 0
            ;;
          *)
            printf '[]'
            exit 0
            ;;
        esac
        """
        try script.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        _ = try? await ReportEngine.collect(
            profile: profile, workspacePaths: WorkspacePaths.self, tiers: [.scan],
            force: true, locateJamfCLI: { stub }, onLine: { _ in })
        let store = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
        XCTAssertEqual(store.cause(for: "patch-device-failures")?.kind, .other)
    }

    // MARK: - Exit 0 without data: what jamf-cli's stderr says

    /// A stub that answers from the given `case` arms and prints `[]` for everything else.
    private func collectInventory(_ arms: String) async throws -> [String] {
        let stub = root.appendingPathComponent("stub-cli")
        let script = """
        #!/bin/sh
        case "$*" in
        \(arms)
          *) printf '[]'; exit 0 ;;
        esac
        """
        try script.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let collector = CauseLogCollector()
        _ = try? await ReportEngine.collect(
            profile: profile, workspacePaths: WorkspacePaths.self, tiers: [.inventory],
            force: true, locateJamfCLI: { stub }, onLine: collector.append)
        return collector.texts
    }

    private func snapshotRows(_ kind: String) throws -> [Any]? {
        let dir = try WorkspacePaths.dataDir(for: profile)
            .appendingPathComponent(kind, isDirectory: true)
        guard let url = FileManager.newestJSONFile(in: dir) else { return nil }
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [Any]
    }

    /// A failed blueprint listing exits non-zero (jamf-cli pro_report_platform.go:96-99), so
    /// exit 0 with this line is an environment with no blueprints.
    func testNoBlueprintsLandsAnEmptySnapshot() async throws {
        let log = try await collectInventory("""
          *"report blueprint-status"*) echo "No blueprints found." >&2; exit 0 ;;
        """)
        XCTAssertEqual(try snapshotRows("blueprint-status")?.count, 0)
        let store = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
        XCTAssertNotNil(store.lastRun(report: "blueprint-status"))
        XCTAssertNil(store.cause(for: "blueprint-status"))
        XCTAssertTrue(
            log.contains { $0.contains("blueprint-status: jamf-cli found no blueprints") },
            "\(log)")
    }

    /// Without jamf-cli's line, blank output may be output that went missing: still a failure.
    func testBlankBlueprintOutputWithoutTheLineIsNotAnEmptyAnswer() async throws {
        _ = try await collectInventory("""
          *"report blueprint-status"*) exit 0 ;;
        """)
        XCTAssertNil(try snapshotRows("blueprint-status"))
        let store = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
        XCTAssertNil(store.lastRun(report: "blueprint-status"))
    }

    /// jamf-cli skips each refused device report silently (pro_report_platform.go:447-451), so
    /// blank DDM output means no declarations or a missing permission.
    func testNoDeclarationDataRecordsACauseNamingBothPossibilities() async throws {
        let log = try await collectInventory("""
          *"report ddm-status"*) echo "No DDM declaration data found." >&2; exit 0 ;;
        """)
        XCTAssertNil(try snapshotRows("ddm-status"))
        let store = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
        let cause = try XCTUnwrap(store.cause(for: "ddm-status"))
        XCTAssertEqual(cause.kind, .noDeclarationData)
        XCTAssertTrue(cause.isPermanent, "an hourly retry repeats one refused request per device")
        let warn = try XCTUnwrap(log.first { $0.hasPrefix("[warn] ddm-status: exit 0") }, "\(log)")
        XCTAssertTrue(warn.contains("Declarations reporting"), warn)
    }

    /// jamf-cli 1.31.1's stderr for `pro report update-status`, with or without
    /// `--scan-failures`, on a Jamf Pro with Managed Software Update Plans turned off.
    private static let plansOffStderr = """
    Fetching managed software update statuses...
    Fetching managed software update plans...
    WARNING: failed to fetch update plans: fetching page 0: request failed (HTTP 503): {
      "httpStatus" : 503,
      "errors" : [ {
        "code" : null,
        "description" : "This endpoint cannot be used if the Managed Software Update \
    Plans toggle is off.",
        "id" : "0",
        "field" : null
      } ]
    }
    No managed software update data found.

    """

    func testSoftwareUpdatePlansTurnedOffIsAPermanentCause() async throws {
        let stderrFile = root.appendingPathComponent("plans-off-stderr")
        try Self.plansOffStderr.write(to: stderrFile, atomically: true, encoding: .utf8)
        let log = try await collectInventory("""
          *"report update-status"*) cat "\(stderrFile.path)" >&2; exit 0 ;;
        """)
        let store = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
        let cause = try XCTUnwrap(store.cause(for: "update-status"))
        XCTAssertEqual(cause.kind, .softwareUpdatePlansOff)
        XCTAssertTrue(cause.isPermanent, "an hourly retry gets the same 503 until it is turned on")
        let warn = try XCTUnwrap(
            log.first { $0.hasPrefix("[warn] update-status: exit 0") }, "\(log)")
        XCTAssertTrue(warn.contains("Managed Software Update Plans is turned off"), warn)
    }

    func testSoftwareUpdatePlansTurnedOffIsRecordedForTheScanToo() async throws {
        _ = try await runScan(stdout: "", stderr: Self.plansOffStderr, exit: 0)
        let store = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
        XCTAssertEqual(store.cause(for: "update-device-failures")?.kind, .softwareUpdatePlansOff)
    }

    /// jamf-cli 1.29 exits 0 with `fetch_error` when it cannot list patch policies
    /// (pro_report_patch.go:67-70): one line with the cause, and no "not JSON" line.
    func testAPatchFetchErrorIsRecordedWithItsCause() async throws {
        let document = """
        [{"section": "title_compliance", "data": []},
         {"section": "policy_failures", "data": [],
          "fetch_error": "fetching page 0: permission denied (HTTP 403)"},
         {"section": "device_failures", "data": [], "fetch_error": ""}]
        """
        let log = try await runScan(stdout: document, stderr: "", exit: 0)
        let store = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
        XCTAssertEqual(store.cause(for: "patch-device-failures")?.kind, .missingPermission)
        let lines = log.filter { $0.contains("patch-device-failures") }
        XCTAssertTrue(lines.contains {
            $0.contains("could not fetch policy_failures")
                && $0.contains("cause: missing permission")
        }, "\(lines)")
        XCTAssertFalse(lines.contains { $0.contains("not JSON") }, "\(lines)")
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
