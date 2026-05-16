import Foundation
import XCTest
@testable import JamfReports

final class MigrationBannerTests: XCTestCase {
    func testMigrationBannerDetectionWithLegacyWorkspaces() {
        let banner = MigrationBanner(
            legacyWorkspaces: ["old.workspace", "another.legacy"],
            legacySchedules: [],
            onDismiss: {}
        )

        XCTAssertTrue(banner.shouldShow, "Banner should show when legacy workspaces exist")
    }

    func testMigrationBannerDetectionWithLegacySchedules() {
        let banner = MigrationBanner(
            legacyWorkspaces: [],
            legacySchedules: ["com.github.tonyyo11.jamf-reports-community.old.profile.daily-snapshot.plist"],
            onDismiss: {}
        )

        XCTAssertTrue(banner.shouldShow, "Banner should show when legacy schedules exist")
    }

    func testMigrationBannerHidesWhenNoLegacyItems() {
        let banner = MigrationBanner(
            legacyWorkspaces: [],
            legacySchedules: [],
            onDismiss: {}
        )

        XCTAssertFalse(banner.shouldShow, "Banner should not show when no legacy items exist")
    }
}