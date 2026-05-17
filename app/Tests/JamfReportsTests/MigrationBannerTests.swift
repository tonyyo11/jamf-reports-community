import Foundation
import XCTest
@testable import JamfReports

/// `@MainActor` is required (PR-9.5): `MigrationBanner: View` is
/// MainActor-isolated. Swift 6.0/6.1 (CI macos-latest) enforces the
/// isolation check on synchronous test methods; Swift 6.3 (local) relaxes
/// it. The class-level annotation satisfies both compilers.
@MainActor
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