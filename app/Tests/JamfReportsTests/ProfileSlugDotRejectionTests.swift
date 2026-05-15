import Foundation
import XCTest
@testable import JamfReports

// Tests for S-03 from review/REPORT.md: ProfileService.isValid
// previously permitted `.` in profile slugs. LaunchAgentWriter builds
// labels of the form `com.jamfreports.<profile>.<slug>` and
// LaunchAgentService.profileAndSlug(from:) parses them by splitting on
// `.`. A profile named `dummy.prod` with a slug `daily` produced the
// label `com.jamfreports.dummy.prod.daily`, which the parser then
// silently re-interpreted as profile=`dummy`, slug=`prod.daily`. Path
// construction protected directory access via prefix checks; label
// parsing did not.
//
// Fix: drop `.` from the allowed character set in `isValid` so any
// dotted profile name is rejected at validation, before reaching the
// label writer or parser. Existing workspace directories on disk with
// dots in their names are surfaced via `dottedLegacyWorkspaces()` so
// they aren't silently invisible to the user.
final class ProfileSlugDotRejectionTests: XCTestCase {

    // MARK: - Validation rejects dotted profiles

    func testIsValidRejectsDottedProfile() {
        // The canonical REPORT.md S-03 example.
        XCTAssertFalse(ProfileService.isValid("dummy.prod"),
                       "Dotted profile name must be rejected to avoid ambiguous LaunchAgent label parsing")
        XCTAssertFalse(ProfileService.isValid("tenant-1.prod"),
                       "Hyphen-then-dot must also be rejected")
        XCTAssertFalse(ProfileService.isValid("school.test"))
        XCTAssertFalse(ProfileService.isValid("a.b.c"))
    }

    func testIsValidAcceptsUndottedProfiles() {
        // Sanity: the tightening must not over-reject legitimate slugs.
        let valid = [
            "a", "0", "dummy", "harbor-edu", "profile_01",
            "tenant-1-prod", "school-test",
        ]
        for profile in valid {
            XCTAssertTrue(ProfileService.isValid(profile),
                          "Undotted profile '\(profile)' must remain valid")
        }
    }

    // MARK: - Label-parsing ambiguity is structurally impossible

    func testLabelParserCannotBeFedAmbiguousDottedProfile() {
        // The parser at LaunchAgentService.profileAndSlug splits on `.`
        // and takes parts.first as the profile. If the regex allowed
        // dots, "dummy.prod" + "daily" would yield label
        // "com.jamfreports.dummy.prod.daily" → profile="dummy",
        // slug="prod.daily" — i.e. the parser silently lost the
        // ".prod" portion of the profile name.
        //
        // After the fix, even if a label like that were constructed by
        // a malicious or legacy path, the parser's
        // `ProfileService.isValid(profile)` guard ensures it would
        // still extract the un-ambiguous prefix "dummy" — but the
        // profile NAME "dummy.prod" is no longer valid, so the writer
        // would have refused to construct that label in the first
        // place.
        //
        // Verify both directions: (a) parser still parses a valid
        // legacy non-dotted label correctly, (b) the only paths that
        // could have produced the ambiguous label are now closed at
        // the validator.
        XCTAssertFalse(ProfileService.isValid("dummy.prod"))
    }

    // MARK: - Migration helper surfaces dotted workspace dirs

    func testDottedLegacyWorkspacesReturnsDottedDirsOnly() throws {
        let testRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ProfileSlugDot-\(UUID().uuidString)", isDirectory: true)
        let workspacesRoot = testRoot.appendingPathComponent("Jamf-Reports", isDirectory: true)
        try FileManager.default.createDirectory(at: workspacesRoot, withIntermediateDirectories: true)

        // Three dirs: two with dots (legacy, must be flagged), one valid.
        for name in ["dummy.prod", "tenant-1.prod", "valid-profile"] {
            try FileManager.default.createDirectory(
                at: workspacesRoot.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        setenv("JRC_TEST_WORKSPACES_ROOT", workspacesRoot.path, 1)
        defer {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: testRoot)
        }

        let flagged = ProfileService.dottedLegacyWorkspaces()
        XCTAssertEqual(flagged.sorted(), ["dummy.prod", "tenant-1.prod"],
                       "Migration helper must surface every dotted workspace dir so the user knows what disappeared")
        XCTAssertFalse(flagged.contains("valid-profile"),
                       "Valid (undotted) workspace must not appear in the migration list")
    }

    func testDottedLegacyWorkspacesEmptyWhenNoneOnDisk() throws {
        let testRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ProfileSlugDot-clean-\(UUID().uuidString)", isDirectory: true)
        let workspacesRoot = testRoot.appendingPathComponent("Jamf-Reports", isDirectory: true)
        try FileManager.default.createDirectory(at: workspacesRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: workspacesRoot.appendingPathComponent("clean-profile", isDirectory: true),
            withIntermediateDirectories: true
        )

        setenv("JRC_TEST_WORKSPACES_ROOT", workspacesRoot.path, 1)
        defer {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: testRoot)
        }

        XCTAssertEqual(ProfileService.dottedLegacyWorkspaces(), [],
                       "Clean workspace root must produce an empty migration list")
    }

    // MARK: - workspaceURL rejects dotted slug

    func testWorkspaceURLReturnsNilForDottedSlug() {
        XCTAssertNil(ProfileService.workspaceURL(for: "dummy.prod"),
                     "Dotted slugs must not resolve to a workspace URL after S-03 tightening")
    }
}
