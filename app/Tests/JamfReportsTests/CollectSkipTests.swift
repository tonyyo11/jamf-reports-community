import XCTest
@testable import JamfReports

/// `jamf_cli.collect_skip`, the on-prem stall guard: which names it accepts and
/// what the health strip expects once a kind is listed. The collect-side skip
/// itself is pinned against a stub jamf-cli in `DeviceScanCollectTests`.
final class CollectSkipTests: XCTestCase {

    // MARK: - Normalization

    func testUnderscoresCaseAndWhitespaceAreForgiven() {
        XCTAssertEqual(
            ReportEngine.collectSkipKinds([" Update_Status ", "PATCH_DEVICE_FAILURES"]),
            ["update-status", "patch-device-failures"]
        )
    }

    func testAllFourHeavyKindsCanBeSkipped() {
        let all = ["patch-device-failures", "profile-status", "update-status",
                   "update-device-failures"]
        XCTAssertEqual(ReportEngine.collectSkipKinds(all), Set(all))
        XCTAssertEqual(ReportEngine.skippableKinds, Set(all))
    }

    /// Core inventory always runs: a typo or an over-eager list cannot remove it.
    func testUnknownAndCoreKindsAreIgnored() {
        let skipped = ReportEngine.collectSkipKinds(
            ["computers", "security", "overview", "ea-results", "not-a-kind", "", "update-status"])
        XCTAssertEqual(skipped, ["update-status"])
    }

    func testAnAbsentOrEmptyListSkipsNothing() {
        XCTAssertTrue(ReportEngine.collectSkipKinds(nil).isEmpty)
        XCTAssertTrue(ReportEngine.collectSkipKinds([]).isEmpty)
    }

    func testEverySkippableKindIsACollectKind() {
        for kind in ReportEngine.skippableKinds {
            XCTAssertTrue(ReportEngine.knownCollectKinds.contains(kind), kind)
        }
    }

    func testTheListIsReadFromConfigYAML() throws {
        let config = try ConfigLoader.loadFromString(
            "jamf_cli:\n  collect_skip: [update_status, Profile-Status]\n")
        XCTAssertEqual(
            ReportEngine.collectSkipKinds(config.jamfCli?.collectSkip),
            ["update-status", "profile-status"]
        )
    }

    // MARK: - Freshness

    /// `collect` never runs a listed kind, so the health strip must not wait for it.
    func testFreshnessDoesNotExpectAListedKind() {
        let kinds = Set(WorkspaceStore.expectedKinds(
            skipExpensive: false, authMethod: "oauth2", collectSkip: ["update-status"]))
        XCTAssertFalse(kinds.contains("update-status"))
        XCTAssertTrue(kinds.contains("update-device-failures"), "only the listed kind drops")
        XCTAssertTrue(kinds.contains("computers"))
    }

    func testFreshnessWithNoListIsUnchanged() {
        XCTAssertEqual(
            WorkspaceStore.expectedKinds(skipExpensive: false, authMethod: "oauth2"),
            WorkspaceStore.expectedKinds(
                skipExpensive: false, authMethod: "oauth2", collectSkip: [])
        )
    }
}
