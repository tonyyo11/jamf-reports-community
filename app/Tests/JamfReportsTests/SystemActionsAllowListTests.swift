import Foundation
import XCTest
@testable import JamfReports

/// Behavioral tests for the SystemActions path allow-list gate.
///
/// `canonicalize` is private; the testable decision surface is:
/// - `SystemActions.isURLAllowed(_:)` — pure predicate, no side effects (safe for all paths)
/// - `SystemActions.reveal(_:)` — returns false without opening Finder for rejected paths
///
/// Tests use the real home directory because `allowedParents()` resolves
/// `FileManager.default.homeDirectoryForCurrentUser` with no test override.
/// Paths under ~/Jamf-Reports that do not exist on disk are still correctly
/// accepted/rejected because `resolvingSymlinksInPath()` returns a nonexistent
/// path as-is; the prefix check is purely string-based.
///
/// The symlink traversal test creates real symlinks in a temp directory to
/// exercise the `resolvingSymlinksInPath()` resolution branch.
final class SystemActionsAllowListTests: XCTestCase {

    private let home = FileManager.default.homeDirectoryForCurrentUser
    private let fm = FileManager.default

    // MARK: - Paths inside allowed roots are accepted

    /// A path directly inside ~/Jamf-Reports is accepted.
    func test_pathInsideJamfReports_isAllowed() {
        let url = home.appendingPathComponent("Jamf-Reports/some-profile/report.xlsx")
        XCTAssertTrue(
            SystemActions.isURLAllowed(url),
            "Path inside ~/Jamf-Reports must be allowed; path=\(url.path)"
        )
    }

    /// A path inside ~/Jamf-Reports nested two levels deep is accepted.
    func test_pathDeepInsideJamfReports_isAllowed() {
        let url = home.appendingPathComponent("Jamf-Reports/profile/Generated Reports/report.xlsx")
        XCTAssertTrue(SystemActions.isURLAllowed(url))
    }

    /// The ~/Jamf-Reports root itself is accepted.
    func test_jamfReportsRoot_isAllowed() {
        let url = home.appendingPathComponent("Jamf-Reports")
        XCTAssertTrue(
            SystemActions.isURLAllowed(url),
            "~/Jamf-Reports root itself must be allowed"
        )
    }

    /// A path inside ~/Library/LaunchAgents is accepted.
    func test_pathInsideLaunchAgents_isAllowed() {
        let url = home.appendingPathComponent(
            "Library/LaunchAgents/com.github.tonyyo11.jamf-reports-community.test.plist"
        )
        XCTAssertTrue(
            SystemActions.isURLAllowed(url),
            "Path inside ~/Library/LaunchAgents must be allowed"
        )
    }

    /// A path inside ~/Library/Logs/JamfReports is accepted.
    func test_pathInsideJamfReportsLogs_isAllowed() {
        let url = home.appendingPathComponent("Library/Logs/JamfReports/app.log")
        XCTAssertTrue(
            SystemActions.isURLAllowed(url),
            "Path inside ~/Library/Logs/JamfReports must be allowed"
        )
    }

    // MARK: - Paths outside all allowed roots are rejected

    /// A path in ~/Documents is rejected (removed from allow-list in B-04).
    func test_documentsPath_isRejected() {
        let url = home.appendingPathComponent("Documents/report.xlsx")
        XCTAssertFalse(
            SystemActions.isURLAllowed(url),
            "~/Documents was removed from the allow-list in B-04 and must be rejected"
        )
    }

    /// A path in ~/Downloads is rejected.
    func test_downloadsPath_isRejected() {
        let url = home.appendingPathComponent("Downloads/export.csv")
        XCTAssertFalse(SystemActions.isURLAllowed(url))
    }

    /// A path in ~/Desktop is rejected.
    func test_desktopPath_isRejected() {
        let url = home.appendingPathComponent("Desktop/report.xlsx")
        XCTAssertFalse(SystemActions.isURLAllowed(url))
    }

    /// /etc/passwd (absolute path outside home) is rejected.
    func test_absoluteSystemPath_isRejected() {
        let url = URL(fileURLWithPath: "/etc/passwd")
        XCTAssertFalse(SystemActions.isURLAllowed(url))
    }

    /// A path in /tmp is rejected (/tmp was explicitly removed in B-04).
    func test_tmpPath_isRejected() {
        let url = URL(fileURLWithPath: "/tmp/report.xlsx")
        XCTAssertFalse(SystemActions.isURLAllowed(url))
    }

    /// The home directory root itself is rejected.
    func test_homeRoot_isRejected() {
        XCTAssertFalse(SystemActions.isURLAllowed(home))
    }

    // MARK: - Prefix-cousin attack: ~/Jamf-Reports-evil is rejected

    /// A directory whose name starts with "Jamf-Reports" but is a sibling
    /// (not a child) of the allowed root must be rejected.
    /// This verifies the trailing-slash guard in `canonicalize`:
    ///   `resolvedPath.hasPrefix(parentPath + "/")`
    /// Without the slash, "~/Jamf-Reports-evil" would be a false positive.
    func test_prefixCousin_jamfReportsEvil_isRejected() {
        let url = home.appendingPathComponent("Jamf-Reports-evil/report.xlsx")
        XCTAssertFalse(
            SystemActions.isURLAllowed(url),
            "~/Jamf-Reports-evil must not be accepted due to prefix-cousin confusion; " +
            "the slash guard in canonicalize must prevent this"
        )
    }

    /// A bare sibling with the same prefix as an allowed root is rejected.
    func test_prefixCousin_launchAgentsExtra_isRejected() {
        let url = home.appendingPathComponent("Library/LaunchAgentsExtra/foo.plist")
        XCTAssertFalse(SystemActions.isURLAllowed(url))
    }

    // MARK: - Symlink traversal: symlink inside allowed root pointing outside

    /// A symlink located inside ~/Jamf-Reports that points to a directory outside
    /// the allow-list must be rejected after canonicalization resolves the link.
    ///
    /// This creates real temp directories and a symlink to exercise the
    /// `resolvingSymlinksInPath()` branch in `canonicalize`.
    func test_symlinkInsideAllowedRoot_pointingOutside_isRejected() throws {
        // Create a real directory outside the allowed roots to be the link target.
        let outside = fm.temporaryDirectory.appendingPathComponent(
            "SystemActionsOutside-\(UUID().uuidString)", isDirectory: true
        )
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: outside) }

        // Create the symlink inside a temp area that lives under ~/Jamf-Reports
        // to satisfy the allow-list name prefix — we need the link's parent path to
        // start with the allowed root, so we create a real subdirectory there.
        let allowedRoot = home.appendingPathComponent("Jamf-Reports")
        let testSubdir = allowedRoot.appendingPathComponent(
            "AllowListTest-\(UUID().uuidString)", isDirectory: true
        )
        let linkURL = testSubdir.appendingPathComponent("malicious-link")

        do {
            try fm.createDirectory(at: testSubdir, withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: testSubdir) }
            try fm.createSymbolicLink(at: linkURL, withDestinationURL: outside)
            addTeardownBlock { try? FileManager.default.removeItem(at: linkURL) }
        } catch {
            // If ~/Jamf-Reports doesn't exist yet (fresh CI box), the symlink
            // traversal path can't be created — skip rather than fail the suite.
            throw XCTSkip("Could not create symlink under ~/Jamf-Reports: \(error)")
        }

        // The symlink lives inside the allowed root path-prefix-wise, but its
        // resolved target is outside. The gate must reject it.
        XCTAssertFalse(
            SystemActions.isURLAllowed(linkURL),
            "Symlink inside ~/Jamf-Reports pointing outside must be rejected; " +
            "link=\(linkURL.path), target=\(outside.path)"
        )
    }

    // MARK: - reveal() returns false for rejected paths (no Finder side effect)

    /// `reveal(_:)` must return `false` for a path outside the allow-list
    /// and must not open Finder. Verifies the rejection-return-path only
    /// (Finder is not opened for rejected paths — safe to call in tests).
    func test_reveal_rejectsOutsidePath_returnsFalse() {
        let url = home.appendingPathComponent("Documents/report.xlsx")
        let result = SystemActions.reveal(url)
        XCTAssertFalse(result, "reveal must return false for a path outside the allow-list")
    }

    /// `reveal(_:)` must return `false` for a prefix-cousin path.
    func test_reveal_rejectsPrefixCousin_returnsFalse() {
        let url = home.appendingPathComponent("Jamf-Reports-attacker/steal.xlsx")
        let result = SystemActions.reveal(url)
        XCTAssertFalse(result, "reveal must return false for a prefix-cousin path")
    }
}
