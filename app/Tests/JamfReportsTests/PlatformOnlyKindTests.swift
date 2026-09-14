import XCTest
@testable import JamfReports

/// The four Platform API kinds against a Jamf Pro instance profile.
///
/// On `auth-method: oauth2` they cannot succeed, so before 2.7.0 they failed
/// on every run — invisibly until the health strip started reporting them,
/// after which the strip was permanently red and self-remediation retried them
/// hourly forever. These pin both halves of the rule and, more importantly,
/// the direction it fails in: unknown is not "not platform".
final class PlatformOnlyKindTests: XCTestCase {

    // MARK: - The kind set

    func testPlatformOnlyKindsAreAllKnownCollectKinds() {
        for kind in ReportEngine.platformOnlyKinds {
            XCTAssertTrue(
                ReportEngine.knownCollectKinds.contains(kind),
                "\(kind) must stay in knownCollectKinds — CI enforces tier coverage from it"
            )
        }
    }

    // MARK: - nonPlatformAuthMethod

    func testOAuth2ProfileRulesOutThePlatformKinds() {
        XCTAssertEqual(ReportEngine.nonPlatformAuthMethod("oauth2"), "oauth2")
    }

    func testPlatformProfileKeepsThem() {
        XCTAssertNil(ReportEngine.nonPlatformAuthMethod("platform"))
        XCTAssertNil(ReportEngine.nonPlatformAuthMethod("PLATFORM"))
    }

    /// The load-bearing case: an unresolvable auth method must never be read
    /// as "not platform" — that would silently stop collecting four kinds on a
    /// platform profile whose probe happened to fail.
    func testUnknownAuthMethodFailsTowardCollecting() {
        XCTAssertNil(ReportEngine.nonPlatformAuthMethod(nil))
        XCTAssertNil(ReportEngine.nonPlatformAuthMethod(""))
        XCTAssertNil(ReportEngine.nonPlatformAuthMethod("   "))
    }

    // MARK: - Freshness exclusion

    func testFreshnessExcludesPlatformKindsOnAnOAuth2Profile() {
        let kinds = Set(WorkspaceStore.expectedKinds(skipExpensive: false, authMethod: "oauth2"))
        for kind in ReportEngine.platformOnlyKinds {
            XCTAssertFalse(kinds.contains(kind), "\(kind) cannot be served by an oauth2 profile")
        }
        XCTAssertTrue(kinds.contains("security"), "ordinary Pro kinds must still be expected")
    }

    func testFreshnessKeepsPlatformKindsOnAPlatformProfile() {
        let kinds = Set(WorkspaceStore.expectedKinds(skipExpensive: false, authMethod: "platform"))
        for kind in ReportEngine.platformOnlyKinds {
            XCTAssertTrue(kinds.contains(kind))
        }
    }

    func testFreshnessKeepsPlatformKindsWhenAuthIsUnknown() {
        let kinds = Set(WorkspaceStore.expectedKinds(skipExpensive: false, authMethod: nil))
        for kind in ReportEngine.platformOnlyKinds {
            XCTAssertTrue(kinds.contains(kind))
        }
    }

    /// The two exclusions are independent — turning on the expensive-skip
    /// toggle must not disturb the platform rule, or vice versa.
    func testBothExclusionsApplyTogether() {
        let kinds = Set(WorkspaceStore.expectedKinds(skipExpensive: true, authMethod: "oauth2"))
        for kind in ReportEngine.expensivePerDeviceKinds {
            XCTAssertFalse(kinds.contains(kind))
        }
        for kind in ReportEngine.platformOnlyKinds {
            XCTAssertFalse(kinds.contains(kind))
        }
    }

    // MARK: - Auth-method parse (tri-state)

    func testAuthMethodParseReturnsTheMethodNotABool() {
        let json = """
        [{"name": "prod", "url": "https://x", "auth-method": "OAuth2", "default": true}]
        """
        XCTAssertEqual(
            PlatformCapabilityService.authMethod(data: Data(json.utf8), profile: "prod"),
            "oauth2"
        )
    }

    func testAuthMethodParseReturnsNilForAnAbsentProfileOrGarbage() {
        let json = """
        [{"name": "other", "url": "https://x", "auth-method": "oauth2", "default": true}]
        """
        XCTAssertNil(
            PlatformCapabilityService.authMethod(data: Data(json.utf8), profile: "missing")
        )
        XCTAssertNil(PlatformCapabilityService.authMethod(data: Data("nope".utf8), profile: "p"))
    }

    // MARK: - Manual collect tiers

    func testManualCollectTargetsOnlyTheTiersBehind() {
        let issue = DataFreshnessIssue(
            snapshotKind: "security", tier: .refresh, kind: .failing,
            lastSuccess: nil, consecutiveFailures: 4, lastFailure: nil
        )
        XCTAssertEqual(WorkspaceStore.manualCollectTiers([issue]), [.refresh])
    }

    /// With nothing flagged the button still has to do something useful — a
    /// person clicking a health strip expects a collect, not a no-op.
    func testManualCollectWithNoIssuesCollectsEverything() {
        XCTAssertEqual(
            WorkspaceStore.manualCollectTiers([]), Set(CollectionTier.allCases)
        )
    }

    // MARK: - 2.8.0 scan-phase kinds

    /// The scan-phase kinds are per-device fan-outs, so the Settings toggle
    /// that hides the four existing per-device kinds hides these two as well.
    func testScanPhaseKindsAreExpensiveAndHiddenByTheToggle() {
        for kind in ["ddm-device-status", "mdm-command-health"] {
            XCTAssertTrue(ReportEngine.expensivePerDeviceKinds.contains(kind), kind)
            XCTAssertTrue(ReportEngine.knownCollectKinds.contains(kind), kind)
            XCTAssertFalse(WorkspaceStore.expectedKinds(skipExpensive: true, authMethod: "oauth2")
                            .contains(kind), "\(kind) must not be expected when skipped")
            XCTAssertTrue(WorkspaceStore.expectedKinds(skipExpensive: false, authMethod: "oauth2")
                            .contains(kind), "\(kind) is expected on an on-prem profile")
        }
    }
}
