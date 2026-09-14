import XCTest
@testable import JamfReports

/// The bundled agent plist is data, not code: pin its shape so a stray edit
/// cannot ship an agent that never fires or points at the wrong program.
final class TickPlistTests: XCTestCase {

    /// A missing plist means the bundle ships no agent and nothing is ever
    /// scheduled — that is the failure this suite exists to catch, so it fails
    /// rather than skipping (the repo's drift-check convention).
    private struct MissingAgentPlist: Error {}

    private func plistURL() throws -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent(
                "LaunchAgents/\(SMAppServiceRegistrar.plistName)")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        XCTFail("bundled agent plist not found above \(#filePath)")
        throw MissingAgentPlist()
    }

    func testBundledAgentPlistShape() throws {
        let data = try Data(contentsOf: try plistURL())
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["Label"] as? String,
                       "com.github.tonyyo11.jamf-reports-community.tick")
        XCTAssertEqual(plist["BundleProgram"] as? String, "Contents/MacOS/JamfReports")
        XCTAssertEqual(plist["ProgramArguments"] as? [String], ["JamfReports", "--tick"])
        XCTAssertEqual(plist["StartInterval"] as? Int, 300)
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(plist["ProcessType"] as? String, "Background")
        XCTAssertNil(plist["StartCalendarInterval"])
        XCTAssertNil(plist["Program"], "SMAppService agents use BundleProgram, never Program")
    }
}
