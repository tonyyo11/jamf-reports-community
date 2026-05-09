import Foundation
import XCTest
@testable import JamfReports

// MARK: - CodeSignVerifierTests

final class CodeSignVerifierTests: XCTestCase {

    // MARK: - teamID

    func testTeamIDIsNonNilForXcodeApp() throws {
        // Xcode.app is signed with Team ID 59GAB85EFG and is present on macOS
        // development machines where this test suite is expected to run.
        // System binaries (e.g. /usr/bin/codesign) use Apple's platform signing and
        // report "TeamIdentifier=not set" via codesign(1), returning nil here.
        let xcodeURL = URL(fileURLWithPath: "/Applications/Xcode.app")
        guard FileManager.default.fileExists(atPath: xcodeURL.path) else {
            throw XCTSkip("Xcode.app not found — skipping Team ID test")
        }
        let teamID = CodeSignVerifier.teamID(of: xcodeURL)
        XCTAssertNotNil(teamID, "Xcode.app should have a non-nil Team ID")
        XCTAssertFalse(teamID?.isEmpty ?? true, "Xcode.app Team ID should not be empty")
    }

    func testTeamIDIsNilForNonExistentPath() {
        let url = URL(fileURLWithPath: "/nonexistent/path/to/binary")
        let teamID = CodeSignVerifier.teamID(of: url)
        XCTAssertNil(teamID, "Non-existent path should return nil Team ID")
    }

    func testTeamIDIsNilForUnsignedBinary() throws {
        // Write a minimal ELF/Mach-O-like file that is not signed.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("unsigned-test-binary-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Write arbitrary bytes — definitely not a valid signed binary.
        try Data([0xCA, 0xFE, 0xBA, 0xBE, 0x00, 0x00, 0x00, 0x01]).write(to: tmp)
        let teamID = CodeSignVerifier.teamID(of: tmp)
        XCTAssertNil(teamID, "Unsigned/invalid binary should return nil Team ID")
    }

    // MARK: - verify

    func testVerifyReturnsFalseForNonExistentPath() {
        let url = URL(fileURLWithPath: "/nonexistent/path/to/binary")
        let result = CodeSignVerifier.verify(url: url, expectedTeamID: "SOMETEAMID")
        XCTAssertFalse(result, "Non-existent path should fail verification")
    }

    func testVerifyReturnsFalseForWrongTeamID() throws {
        // Xcode.app is a reliably-present, developer-signed binary on dev machines.
        let xcodeURL = URL(fileURLWithPath: "/Applications/Xcode.app")
        guard FileManager.default.fileExists(atPath: xcodeURL.path) else {
            throw XCTSkip("Xcode.app not found — skipping wrong Team ID test")
        }
        let result = CodeSignVerifier.verify(url: xcodeURL, expectedTeamID: "WRONGTEAMID1")
        XCTAssertFalse(result, "Wrong Team ID should fail verification")
    }

    func testVerifyReturnsTrueForCorrectTeamID() throws {
        let xcodeURL = URL(fileURLWithPath: "/Applications/Xcode.app")
        guard FileManager.default.fileExists(atPath: xcodeURL.path) else {
            throw XCTSkip("Xcode.app not found — skipping correct Team ID test")
        }
        guard let teamID = CodeSignVerifier.teamID(of: xcodeURL) else {
            throw XCTSkip("Xcode.app returned nil Team ID — unexpected on this system")
        }
        let result = CodeSignVerifier.verify(url: xcodeURL, expectedTeamID: teamID)
        XCTAssertTrue(result, "Matching Team ID should pass verification")
    }
}
