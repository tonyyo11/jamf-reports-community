import Foundation
import XCTest
@testable import JamfReports

// Tests for M-01 follow-up (PR-6 item 3): ProfileService.discoverJamfCLIProfiles
// invokes the codesign-verified-fingerprint gate before spawning
// `jamf-cli config list`. Without the gate, a tampered jamf-cli would
// execute on every sidebar profile load.
//
// On rejection the function falls back to `fallbackConfigProfiles` —
// the same recovery path used when the binary is absent or the spawn
// fails — so the user still sees their profiles (read directly from
// `~/.config/jamf-cli/config.yaml`) and nothing untrusted runs.
final class ProfileServiceCodesignGateTests: XCTestCase {

    nonisolated(unsafe) private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ProfileServiceCodesign-\(UUID().uuidString)", isDirectory: true)
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

    func testDiscoverJamfCLIProfilesRejectsUnverifiedJamfCLI() throws {
        // Fake "jamf-cli" file that fails codesign verification (no
        // signature). The gate must reject before `Process()` runs, so
        // the result matches what discoverJamfCLIProfiles produces when
        // the binary is unavailable (fallbackConfigProfiles path).
        let fake = tempDir.appendingPathComponent("jamf-cli")
        try Data("not-a-real-binary".utf8).write(to: fake)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: fake.path
        )

        // Direct ensureVerifiedJamfCLI check on the fake — confirms the
        // gate would refuse it (sanity-checks the test fixture itself).
        let direct = JamfCLIIdentity.ensureVerifiedJamfCLI(executable: fake)
        switch direct {
        case .success:
            XCTFail("Test setup invalid: unsigned fake jamf-cli passed verification")
        case .failure:
            break
        }
        let rejected = ProfileService.discoverJamfCLIProfiles(
            scheduleCounts: [:],
            _testBinaryOverride: fake
        )
        // The gate fell through to fallbackConfigProfiles. That helper
        // is private; the cleanest equivalence we can prove is that
        // passing a nonexistent binary (which short-circuits to the
        // same fallback path BEFORE the gate is even consulted) yields
        // the same result.
        let nonexistent = tempDir.appendingPathComponent("does-not-exist-jamf-cli")
        XCTAssertFalse(FileManager.default.fileExists(atPath: nonexistent.path))
        let absent = ProfileService.discoverJamfCLIProfiles(
            scheduleCounts: [:],
            _testBinaryOverride: nonexistent
        )
        XCTAssertEqual(
            rejected.map(\.name).sorted(), absent.map(\.name).sorted(),
            "Codesign-gate rejection must produce the same fallback list as a missing binary"
        )
    }

    func testDiscoverJamfCLIProfilesSkipsGateForNonJamfCLIBasename() {
        // Gate is keyed on basename == "jamf-cli". An executable with
        // any other basename bypasses the gate. /bin/echo accepts the
        // arguments but produces no parseable JSON, so the function
        // falls back to fallbackConfigProfiles via the JSON-decode
        // guard. Assertion target: no crash, no hang.
        let echoBin = URL(fileURLWithPath: "/bin/echo")
        guard FileManager.default.isExecutableFile(atPath: echoBin.path) else {
            return  // platform without /bin/echo — skip silently
        }
        _ = ProfileService.discoverJamfCLIProfiles(
            scheduleCounts: [:],
            _testBinaryOverride: echoBin
        )
        // Implicit assertion: non-jamf-cli basename must bypass the
        // gate and execute (no crash, no hang).
    }
}
