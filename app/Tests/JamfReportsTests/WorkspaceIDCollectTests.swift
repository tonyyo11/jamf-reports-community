import XCTest
@testable import JamfReports

/// P2: a collect writes into the workspace's folders and sends `-p` with the profile it was
/// handed, which `CollectRouter` takes from `EnvironmentProfiles`. Driven through a stub jamf-cli
/// (not named `jamf-cli`: the codesign gate refuses that) that logs its argv.
final class WorkspaceIDCollectTests: XCTestCase {
    private let workspaceName = "folder-ws"
    private let profile = "tenant-p"

    func testFoldersComeFromTheWorkspaceAndDashPFromTheProfile() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("JRC-WSID-\(UUID().uuidString)", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("Jamf-Reports", isDirectory: true)
        let folder = workspacesRoot.appendingPathComponent(workspaceName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "jamf_cli:\n  profile: someone-else\n".write(
            to: folder.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
        setenv("JRC_TEST_WORKSPACES_ROOT", workspacesRoot.path, 1)
        addTeardownBlock {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: root)
        }
        let calls = root.appendingPathComponent("calls.log")
        let stub = root.appendingPathComponent("stub-cli")
        try """
            #!/bin/sh
            [ "$1 $2" = "config list" ] && { printf '%s' '[{"name":"\(profile)"}]'; exit 0; }
            printf '%s\\n' "$*" >> "\(calls.path)"
            printf '[]'
            exit 0

            """.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        let lines = Lines()
        _ = try? await ReportEngine.collect(
            workspace: try XCTUnwrap(WorkspaceID(workspaceName)), profile: profile,
            workspacePaths: WorkspacePaths.self, tiers: [.inventory], force: true,
            authConfirmationProbe: { _, _ in false }, locateJamfCLI: { stub },
            now: .testNoon, onLine: lines.add)

        let argv = try String(contentsOf: calls, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertFalse(argv.isEmpty, "\(lines.all)")
        for line in argv where line.hasPrefix("-p ") {
            XCTAssertTrue(line.hasPrefix("-p \(profile) "), line)
        }
        XCTAssertTrue(argv.contains { $0.hasPrefix("-p \(profile) pro computers list") })
        let computers = folder.appendingPathComponent("jamf-cli-data/computers")
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: computers.path).isEmpty)
        for other in [profile, "someone-else"] {
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: workspacesRoot.appendingPathComponent(other).path), other)
        }
    }
}

extension WorkspaceIDCollectTests {
    /// The product check probes the profile the command runs as (the environment's Jamf Pro
    /// slot), not the workspace's name.
    func testTheProductCheckProbesTheJamfProSlot() async {
        let asked = AskedNames()
        let refusal = await CLIBridge.refusesProCommand(
            profile: "folder-ws", operation: "Collect", onLine: nil,
            environment: EnvironmentProfiles(jamfPro: "tenant-p"),
            resolved: { asked.add($0); return nil })
        XCTAssertNil(refusal)
        XCTAssertEqual(asked.all, ["tenant-p"])
    }
}

private final class AskedNames: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    func add(_ name: String) { lock.lock(); names.append(name); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return names }
}

private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func add(_ line: CLIBridge.LogLine) { lock.lock(); stored.append(line.text); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return stored }
}
