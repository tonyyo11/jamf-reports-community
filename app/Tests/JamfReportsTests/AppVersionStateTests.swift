import Foundation
import XCTest
@testable import JamfReports

@MainActor
final class AppVersionStateTests: XCTestCase {
    private let testKey = "lastSeenAppVersion"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: testKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: testKey)
        super.tearDown()
    }

    // MARK: Fresh install

    func testFreshInstall_lastSeenVersionIsEmpty() {
        XCTAssertEqual(AppVersionState.lastSeenVersion, "")
    }

    func testFreshInstall_shouldShowWhatsNewIsFalse() {
        // No UserDefaults value yet — not an upgrade, so banner must not appear.
        XCTAssertFalse(AppVersionState.shouldShowWhatsNew)
    }

    // MARK: Upgrade scenario

    func testUpgrade_differentVersion_shouldShowWhatsNew() {
        // Simulate a previously seen version that differs from current.
        // lastSeenVersion is private(set); write via UserDefaults directly.
        UserDefaults.standard.set("1.0.0", forKey: testKey)
        // currentVersion is either the hardcoded fallback or the bundle
        // version; in tests there is no bundle, so the fallback applies.
        // Either way, "1.0.0" != currentVersion.
        if AppVersionState.currentVersion == "1.0.0" {
            // Guard against the unlikely case where currentVersion is also "1.0.0"
            // (e.g. if someone runs tests with a matching bundle version).
            return
        }
        XCTAssertTrue(AppVersionState.shouldShowWhatsNew)
    }

    func testUpgrade_markSeen_clearsFlag() {
        UserDefaults.standard.set("1.0.0", forKey: testKey)
        AppVersionState.markCurrentVersionSeen()
        XCTAssertFalse(AppVersionState.shouldShowWhatsNew)
    }

    // MARK: Same version

    func testSameVersion_shouldShowWhatsNewIsFalse() {
        // Simulate user already having seen this version.
        UserDefaults.standard.set(AppVersionState.currentVersion, forKey: testKey)
        XCTAssertFalse(AppVersionState.shouldShowWhatsNew)
    }

    // MARK: markCurrentVersionSeen

    func testMarkCurrentVersionSeen_persistsVersion() {
        AppVersionState.markCurrentVersionSeen()
        XCTAssertEqual(AppVersionState.lastSeenVersion, AppVersionState.currentVersion)
    }

    func testMarkCurrentVersionSeen_idempotent() {
        AppVersionState.markCurrentVersionSeen()
        AppVersionState.markCurrentVersionSeen()
        XCTAssertEqual(AppVersionState.lastSeenVersion, AppVersionState.currentVersion)
        XCTAssertFalse(AppVersionState.shouldShowWhatsNew)
    }
}
