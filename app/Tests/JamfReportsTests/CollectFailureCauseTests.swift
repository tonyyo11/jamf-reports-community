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
        try? await ReportEngine.collect(
            profile: profile, workspacePaths: WorkspacePaths.self, tiers: [.scan],
            force: true, locateJamfCLI: { stub }, onLine: { _ in })
        let store = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
        XCTAssertEqual(store.cause(for: "patch-device-failures")?.kind, .other)
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
