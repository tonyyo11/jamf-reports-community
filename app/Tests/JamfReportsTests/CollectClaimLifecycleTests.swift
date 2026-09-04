import XCTest
@testable import JamfReports

/// The part of `ReportEngine.collect` that no test could reach before: what
/// happens to the workspace claim once the collect body actually runs.
///
/// Reachable now because `collect` takes a `locateJamfCLI` seam. The stub is
/// deliberately NOT named `jamf-cli` — `CLIBridge.codesignGate` keys on exactly
/// that filename and refuses to launch an unsigned one, which is why stubbing
/// on PATH was never an option here.
final class CollectClaimLifecycleTests: XCTestCase {

    private var root: URL!
    private var binDir: URL!
    private let profile = "claimtest"

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("JRC-Claim-\(UUID().uuidString)", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("Jamf-Reports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspacesRoot.appendingPathComponent(profile, isDirectory: true),
            withIntermediateDirectories: true
        )
        binDir = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", workspacesRoot.path, 1)
        addTeardownBlock { unsetenv("JRC_TEST_WORKSPACES_ROOT") }

        try "shared_workspace:\n  enabled: true\n".write(
            to: workspacesRoot.appendingPathComponent(profile)
                .appendingPathComponent("config.yaml"),
            atomically: true, encoding: .utf8
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    /// A stub standing in for jamf-cli. `exitCode` drives whether the collect
    /// succeeds or dies, which is how the throwing path gets exercised.
    private func makeStub(exitCode: Int, stdout: String = "[]") throws -> URL {
        let url = binDir.appendingPathComponent("stub-cli")
        let script = """
        #!/bin/sh
        printf '%s' '\(stdout)'
        exit \(exitCode)
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path
        )
        return url
    }

    private func claimFile() -> URL {
        ProfileService.workspaceURL(for: profile)!
            .appendingPathComponent("automation/.workspace-claim.json")
    }

    /// The whole point of the `defer`: a collect that dies partway through must
    /// still release its claim, or one crashed run wedges the shared folder for
    /// every other Mac until the lease expires.
    func testClaimIsReleasedWhenCollectThrows() async throws {
        let stub = try makeStub(exitCode: 1, stdout: "")

        do {
            try await ReportEngine.collect(
                profile: profile,
                workspacePaths: WorkspacePaths.self,
                force: true,
                locateJamfCLI: { stub },
                onLine: { _ in }
            )
            XCTFail("a stub that fails every call should end the collect")
        } catch {
            // Expected — every live call failed.
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: claimFile().path),
            "the claim must be released even when the collect throws"
        )
    }

    /// And on the ordinary path: claim released, activity recorded, so other
    /// Macs can see this one collected.
    func testSuccessfulCollectReleasesClaimAndRecordsActivity() async throws {
        let stub = try makeStub(exitCode: 0, stdout: "[]")

        try await ReportEngine.collect(
            profile: profile,
            workspacePaths: WorkspacePaths.self,
            force: true,
            locateJamfCLI: { stub },
            onLine: { _ in }
        )

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: claimFile().path),
            "a finished collect leaves no claim behind"
        )
        let hostsDir = ProfileService.workspaceURL(for: profile)!
            .appendingPathComponent("automation/hosts")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: hostsDir.path)) ?? []
        XCTAssertEqual(files.count, 1, "this machine's collect must be recorded for peers")
    }

    /// A missing binary must still be a clean failure, and must not leave a
    /// claim behind — the gate takes one before the binary check now.
    func testMissingBinaryLeavesNoClaim() async {
        do {
            try await ReportEngine.collect(
                profile: profile,
                workspacePaths: WorkspacePaths.self,
                force: true,
                locateJamfCLI: { nil },
                onLine: { _ in }
            )
            XCTFail("expected jamfCLINotFound")
        } catch ReportEngineError.jamfCLINotFound {
            // Expected.
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: claimFile().path),
            "a run that could not start must not hold the folder"
        )
    }
}
