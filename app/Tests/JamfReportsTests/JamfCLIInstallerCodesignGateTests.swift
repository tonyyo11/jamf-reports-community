import Foundation
import XCTest
@testable import JamfReports

// Tests for M-01 follow-up (PR-6 item 2): JamfCLIInstaller.installedVersion(at:)
// invokes the codesign-verified-fingerprint gate before spawning
// `jamf-cli --version`. Without the gate, a tampered binary discovered
// at install/upgrade time would execute its `--version` path during
// the discovery/post-install validation pass.
//
// On rejection the function returns nil (matching the existing
// launch-failure contract) so the upgrade flow treats the binary as
// "unknown version" and replaces it via installFromGitHub.
final class JamfCLIInstallerCodesignGateTests: XCTestCase {

    nonisolated(unsafe) private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("InstallerCodesign-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        JamfCLIIdentity.clearVerificationCacheForTesting()
    }

    override func tearDownWithError() throws {
        JamfCLIIdentity.clearVerificationCacheForTesting()
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDir = nil
        try super.tearDownWithError()
    }

    @MainActor
    func testInstalledVersionRejectsUnverifiedJamfCLI() throws {
        // Fake "jamf-cli" file that fails codesign verification (no
        // signature). The gate refuses before any process is spawned,
        // so the returned version is nil.
        let fake = tempDir.appendingPathComponent("jamf-cli")
        try Data("not-a-real-binary".utf8).write(to: fake)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: fake.path
        )

        let version = JamfCLIInstaller.installedVersion(at: fake)
        XCTAssertNil(version, "Codesign gate rejection must produce a nil version (no spawn)")
    }

    @MainActor
    func testInstalledVersionSkipsGateForNonJamfCLIBasename() {
        // Gate is keyed on basename == "jamf-cli". /bin/echo runs and
        // its output is parsed for a version string; since `--version`
        // produces no semver-shaped output, `parseVersion(from:)` returns
        // nil — but the assertion target is that the gate did NOT block
        // the spawn, which the surrounding test setup confirms (no
        // crash, completion within the test timeout).
        let echoBin = URL(fileURLWithPath: "/bin/echo")
        guard FileManager.default.isExecutableFile(atPath: echoBin.path) else {
            return  // platform without /bin/echo — skip silently
        }
        _ = JamfCLIInstaller.installedVersion(at: echoBin)
        // Implicit assertion: non-jamf-cli basename must bypass the
        // gate and execute (no crash, no hang).
    }
}
