import XCTest
@testable import JamfReports

/// Verifies the L3-B distinction: a corrupt posture snapshot is reported as a
/// failure (`loadError != nil` / throws / nil), not silently collapsed to `.empty`.
final class PostureLoadFailureTests: XCTestCase {
    private func corruptFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jr-posture-\(UUID().uuidString).json")
        try Data("{ not valid json".utf8).write(to: url)
        return url
    }

    func test_security_loadFrom_corruptFile_throwsDecodeFailed() throws {
        let url = try corruptFile(); defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try SecurityPostureService.load(from: url)) { error in
            guard case SecurityPostureService.LoadError.decodeFailed = error else {
                return XCTFail("expected .decodeFailed, got \(error)")
            }
        }
    }

    func test_security_failedSnapshot_isDistinctFromEmpty() {
        let failed = SecurityPostureService.Snapshot.failed("boom")
        XCTAssertEqual(failed.loadError, "boom")
        XCTAssertNil(SecurityPostureService.Snapshot.empty.loadError)
        XCTAssertNotEqual(failed, .empty)
    }

    func test_compliance_loadFrom_corruptFile_returnsNil() throws {
        let url = try corruptFile(); defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(CompliancePostureService.load(from: url))
    }

    func test_compliance_failedSnapshot_isDistinctFromEmpty() {
        // Exercises the custom Equatable that must include loadError.
        let failed = CompliancePostureService.Snapshot.failed("boom")
        XCTAssertEqual(failed.loadError, "boom")
        XCTAssertNil(CompliancePostureService.Snapshot.empty.loadError)
        XCTAssertNotEqual(failed, .empty)
    }
}
