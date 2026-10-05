import Foundation
import XCTest
@testable import JamfReports

// MARK: - Developer ID test binary

/// Finds an installed binary whose signature satisfies "Developer ID chain, leaf OU = its team",
/// judged by the `codesign` CLI so the choice does not rely on the code under test. Mac App
/// Store apps (and Xcode) carry a Team ID but are re-signed under Apple's own leaf certificate,
/// so they do not qualify.
enum DeveloperIDTestBinary {
    static func find() -> (url: URL, teamID: String)? {
        let fm = FileManager.default
        guard let apps = try? fm.contentsOfDirectory(
            at: URL(fileURLWithPath: "/Applications"),
            includingPropertiesForKeys: nil
        ) else { return nil }
        for app in apps.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where app.pathExtension == "app" {
            let exeDir = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
            guard let exes = try? fm.contentsOfDirectory(
                at: exeDir, includingPropertiesForKeys: nil
            ) else { continue }
            for exe in exes.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                if let team = CodeSignVerifier.teamID(of: exe), !team.isEmpty,
                   codesignCLIAccepts(exe, teamID: team) {
                    return (exe, team)
                }
            }
        }
        return nil
    }

    private static func codesignCLIAccepts(_ url: URL, teamID: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = [
            "-v",
            "-R=anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\"",
            url.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

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
        guard let (binary, _) = DeveloperIDTestBinary.find() else {
            throw XCTSkip("No Developer ID signed binary under /Applications on this host")
        }
        let result = CodeSignVerifier.verify(url: binary, expectedTeamID: "WRONGTEAM1")
        XCTAssertFalse(result, "Wrong Team ID should fail verification")
    }

    func testVerifyReturnsTrueForCorrectTeamID() throws {
        guard let (binary, teamID) = DeveloperIDTestBinary.find() else {
            throw XCTSkip("No Developer ID signed binary under /Applications on this host")
        }
        let result = CodeSignVerifier.verify(url: binary, expectedTeamID: teamID)
        XCTAssertTrue(result, "Matching Team ID should pass verification: \(binary.path)")
    }

    // MARK: - requirement, not just a team ID string

    /// Copies `/usr/bin/true` into a temp dir and ad-hoc signs it, optionally writing a
    /// team identifier into the code directory (which `codesign` lets anyone do).
    private func adHocSignedCopy(teamIdentifier: String?) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-codesign-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let copy = dir.appendingPathComponent("tool")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: copy)

        var args = ["-f", "-s", "-"]
        if let teamIdentifier { args += ["--team-identifier", teamIdentifier] }
        args.append(copy.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw XCTSkip("codesign could not ad-hoc sign the test binary")
        }
        return copy
    }

    func testVerifyRejectsAdHocBinaryClaimingTheExpectedTeamID() throws {
        let claimed = "ABCDE12345"
        let binary = try adHocSignedCopy(teamIdentifier: claimed)
        XCTAssertEqual(
            CodeSignVerifier.teamID(of: binary), claimed,
            "Setup: the ad-hoc code directory should carry the claimed team ID"
        )
        XCTAssertFalse(
            CodeSignVerifier.verify(url: binary, expectedTeamID: claimed),
            "A team ID written into an ad-hoc code directory is not a Developer ID chain"
        )
    }

    func testVerifyRejectsPlainAdHocBinaryForAnyTeamID() throws {
        let binary = try adHocSignedCopy(teamIdentifier: nil)
        XCTAssertFalse(CodeSignVerifier.verify(url: binary, expectedTeamID: "ABCDE12345"))
        XCTAssertFalse(
            CodeSignVerifier.verify(url: binary, expectedTeamID: CodeSignVerifier.teamID(of: binary) ?? "")
        )
    }

    func testVerifyRejectsTeamIDsThatCouldInjectRequirementSyntax() throws {
        let binary = URL(fileURLWithPath: "/bin/ls")
        for bad in [
            "", "abcde12345", "ABCDE1234", "ABCDE123456",
            "\" or anchor apple or \"", "ABCDE12345\" or \"x",
        ] {
            XCTAssertFalse(
                CodeSignVerifier.verify(url: binary, expectedTeamID: bad),
                "Malformed team ID must be refused before it reaches a requirement: \(bad)"
            )
        }
    }
}
