import Foundation
import XCTest
@testable import JamfReports

// Tests for M-01 follow-up (PR-6 item 1): Provenance.captureJamfCLIVersion
// invokes the codesign-verified-fingerprint gate before spawning the
// supplied jamf-cli URL. Without the gate, a tampered jamf-cli would
// execute `--version` on every report-generation run and surface its
// output (or side effects) in the provenance block.
final class ProvenanceCodesignGateTests: XCTestCase {

    nonisolated(unsafe) private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ProvenanceCodesign-\(UUID().uuidString)", isDirectory: true)
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

    func testCaptureJamfCLIVersionReturnsNilWhenURLIsNil() async {
        let version = await Provenance.captureJamfCLIVersion(jamfCLIURL: nil)
        XCTAssertNil(version, "nil URL must short-circuit before any process spawn")
    }

    func testCaptureJamfCLIVersionRejectsUnverifiedJamfCLI() async throws {
        // Fake "jamf-cli" file at a path the codesign verifier will reject
        // (it is not a signed binary at all). The gate must refuse before
        // any process is spawned, so the returned version is nil.
        let fake = tempDir.appendingPathComponent("jamf-cli")
        try Data("not-a-real-binary".utf8).write(to: fake)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: fake.path
        )

        let version = await Provenance.captureJamfCLIVersion(jamfCLIURL: fake)
        XCTAssertNil(version, "Codesign gate rejection must produce a nil version (no spawn)")
    }

    func testCaptureJamfCLIVersionSkipsGateForNonJamfCLIBasename() async {
        // The gate is keyed on basename == "jamf-cli". An executable with
        // any other basename (here /bin/echo, used as a sentinel for "this
        // would otherwise run") bypasses the gate and the underlying
        // Process executes. /bin/echo --version writes "--version" to
        // stdout, so the first non-empty line is "--version".
        let echoBin = URL(fileURLWithPath: "/bin/echo")
        guard FileManager.default.isExecutableFile(atPath: echoBin.path) else {
            return  // platform without /bin/echo — skip silently
        }
        let version = await Provenance.captureJamfCLIVersion(jamfCLIURL: echoBin)
        XCTAssertEqual(
            version, "--version",
            "Non-jamf-cli basename must bypass the gate and execute normally"
        )
    }
}
