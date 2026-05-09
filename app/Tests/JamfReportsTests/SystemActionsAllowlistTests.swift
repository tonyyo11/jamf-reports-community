import XCTest
@testable import JamfReports

/// Track B Wave 2 — B-04 SystemActions allow-list narrowing.
///
/// The previous allow-list included `/tmp`, `~/Documents`, and `~/Downloads`,
/// none of which were "bounded to Jamf data". The narrowed list contains
/// only `~/Jamf-Reports`, `~/Library/LaunchAgents`, `~/Library/Logs/JamfReports`.
/// Documents/Downloads/Desktop are now reachable only through
/// `userExportTargetIsAllowed(_:)`, which callers must gate behind explicit
/// per-action user confirmation.
final class SystemActionsAllowlistTests: XCTestCase {

    func test_userExportTargetIsAllowed_acceptsExportTargets() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertTrue(SystemActions.userExportTargetIsAllowed(
            home.appendingPathComponent("Documents/report.xlsx")
        ))
        XCTAssertTrue(SystemActions.userExportTargetIsAllowed(
            home.appendingPathComponent("Downloads/report.xlsx")
        ))
        XCTAssertTrue(SystemActions.userExportTargetIsAllowed(
            home.appendingPathComponent("Desktop/report.xlsx")
        ))
    }

    func test_userExportTargetIsAllowed_rejectsTmpAndSystem() {
        XCTAssertFalse(SystemActions.userExportTargetIsAllowed(
            URL(fileURLWithPath: "/tmp/report.xlsx")
        ))
        XCTAssertFalse(SystemActions.userExportTargetIsAllowed(
            URL(fileURLWithPath: "/private/tmp/report.xlsx")
        ))
        XCTAssertFalse(SystemActions.userExportTargetIsAllowed(
            URL(fileURLWithPath: "/etc/passwd")
        ))
        XCTAssertFalse(SystemActions.userExportTargetIsAllowed(
            URL(fileURLWithPath: "/Volumes/Share/report.xlsx")
        ))
    }

    /// The `/tmp/...` path canonicalizes to `/private/tmp/...`, which has
    /// never matched the `/tmp/` prefix anyway. After narrowing, neither
    /// resolution path is in the allow-list.
    func test_reveal_tmp_doesNotResolveToValidParent() {
        let url = URL(fileURLWithPath: "/tmp/jr-target-\(UUID().uuidString)")
        // SystemActions.reveal swallows errors; we exercise the allow-list
        // indirectly by confirming `/tmp` is no longer accepted by the
        // export-target API.
        XCTAssertFalse(SystemActions.userExportTargetIsAllowed(url))
    }
}
