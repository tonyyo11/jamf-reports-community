import XCTest
@testable import JamfReports

/// Track B Wave 2 — B-07 wires `CodeSignVerifier` into the JamfCLIInstaller
/// download path. Until the canonical Jamf Team ID is confirmed against a
/// known-good binary, the verification is gated behind
/// `enforceCodesignVerification`. These tests assert the seam is in place
/// and the verifier is reachable from production code.
@MainActor
final class JamfCLIInstallerCodesignTests: XCTestCase {

    func test_expectedJamfTeamID_constantExists() {
        // Compile-time assertion: the symbol is reachable, regardless of
        // whether the placeholder has been replaced yet.
        XCTAssertNotNil(JamfCLIInstaller.expectedJamfTeamID as String?)
    }

    func test_enforcementEnabled_withKnownTeamID() {
        // Team ID is confirmed — enforcement must be on and the ID must match.
        // Any regression that resets these (merge conflict, accidental nil) fails here.
        XCTAssertEqual(JamfCLIInstaller.expectedJamfTeamID, "483DWKW443")
        XCTAssertTrue(JamfCLIInstaller.enforceCodesignVerification)
    }

    func test_codesignVerifier_rejectsUnsignedTempFile() throws {
        // Create a file at a temporary path; SecStaticCodeCreateWithPath on
        // an unsigned/empty file should fail validity, so verify() returns
        // false and the installer would refuse the binary if enforcement
        // were on.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-not-a-binary-\(UUID().uuidString)")
        try Data("not a mach-o".utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        XCTAssertFalse(CodeSignVerifier.verify(url: url, expectedTeamID: "ABCDE12345"))
    }

    func test_codesignVerifier_rejectsUnsignedBinary_withProductionTeamID() throws {
        // Regression gate: verify that the production Team ID ("483DWKW443") correctly
        // rejects an unsigned binary. If expectedTeamID is ever changed to a value that
        // accepts any binary (e.g., empty string or a pattern match bug), this fails.
        guard let teamID = JamfCLIIdentity.expectedTeamID else {
            XCTFail("JamfCLIIdentity.expectedTeamID must be non-nil when enforcement is active")
            return
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-unsigned-prod-\(UUID().uuidString)")
        try Data("not a mach-o".utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        XCTAssertFalse(
            CodeSignVerifier.verify(url: url, expectedTeamID: teamID),
            "Production team ID '\(teamID)' must reject an unsigned binary"
        )
    }
}
