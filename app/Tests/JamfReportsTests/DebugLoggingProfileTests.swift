import XCTest
@testable import JamfReports

final class DebugLoggingProfileTests: XCTestCase {
    private func profileURL() throws -> URL {
        try XCTUnwrap(DebugLoggingService.bundledProfileURL, "bundled debug-logging .mobileconfig missing")
    }

    func test_profileIsValidPlist_withLoggingPayloadForOurSubsystem() throws {
        let data = try Data(contentsOf: try profileURL())
        let root = try PropertyListSerialization.propertyList(from: data, format: nil)
        let dict = try XCTUnwrap(root as? [String: Any])
        let payloads = try XCTUnwrap(dict["PayloadContent"] as? [[String: Any]])
        let logging = try XCTUnwrap(payloads.first {
            ($0["PayloadType"] as? String) == "com.apple.system.logging"
        })
        let subsystems = try XCTUnwrap(logging["Subsystems"] as? [String: Any])
        XCTAssertNotNil(subsystems["com.github.tonyyo11.jamf-reports-community"],
                        "profile must target our OSLog subsystem")
    }

    func test_profilePersistsVerbose() throws {
        let data = try Data(contentsOf: try profileURL())
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("Persist"), "profile must enable persistence")
        XCTAssertTrue(text.contains("Debug"), "profile must persist at debug level")
    }

    func test_profileDoesNotRevealPrivateData() throws {
        let data = try Data(contentsOf: try profileURL())
        // reveal-private is a local-only, warned opt-in — it must NOT ship in the MDM profile.
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("Enable-Private-Data"))
    }

    func test_profileScopeIsUser_noEscalation() throws {
        let data = try Data(contentsOf: try profileURL())
        let root = try PropertyListSerialization.propertyList(from: data, format: nil)
        let dict = try XCTUnwrap(root as? [String: Any])
        XCTAssertEqual(dict["PayloadScope"] as? String, "User")
    }
}
