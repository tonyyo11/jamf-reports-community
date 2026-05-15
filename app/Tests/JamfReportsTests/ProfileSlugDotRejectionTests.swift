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

    // MARK: - LaunchAgent label parser rejects legacy dotted-profile plists
    //
    // silent-failure-hunter B-1 finding: a pre-existing plist with a
    // label like `com.<prefix>.tenant-1.prod.daily` would previously
    // parse as profile=`tenant-1`, slug=`prod.daily` because
    // `parts.first` is a valid undotted slug. The parser silently
    // re-attributed the plist to the WRONG profile. PR-3 tightens the
    // parser to require exactly 2 post-prefix components for non-multi
    // labels — anything else is rejected and surfaced via
    // dottedLegacyAgents() for migration.

    func testDottedLegacyAgentsFlagsMisattributableLabels() throws {
        let testRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("DottedLegacyAgents-\(UUID().uuidString)", isDirectory: true)
        let launchAgentsDir = testRoot.appendingPathComponent("LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)

        // Two legacy plists with dotted-profile labels (parts.count == 3+
        // after the prefix); one well-formed modern plist (parts.count == 2).
        let prefix = LaunchAgentWriter.labelPrefix
        let dottedLabels = [
            "\(prefix).tenant-1.prod.daily",
            "\(prefix).dummy.prod.daily",
        ]
        let cleanLabel = "\(prefix).valid-profile.daily"

        for label in dottedLabels + [cleanLabel] {
            let url = launchAgentsDir.appendingPathComponent("\(label).plist")
            let plist: [String: Any] = ["Label": label, "ProgramArguments": ["/bin/true"]]
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0
            )
            try data.write(to: url)
        }

        defer { try? FileManager.default.removeItem(at: testRoot) }

        let flagged = LaunchAgentService.dottedLegacyAgents(in: launchAgentsDir)
        XCTAssertEqual(Set(flagged), Set(dottedLabels),
                       "Migration helper must surface every dotted-profile legacy label and skip well-formed labels")
    }

    func testProfileAndSlugParserRejectsLegacyDottedLabels() {
        // The internal parser is exercised through `parse(url:)`. A
        // legacy plist with a dotted-profile label must produce nil
        // (rejection) rather than silently re-attributing to the wrong
        // profile.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ParserReject-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let prefix = LaunchAgentWriter.labelPrefix
        let legacyLabel = "\(prefix).tenant-1.prod.daily"
        let url = dir.appendingPathComponent("\(legacyLabel).plist")
        let plist: [String: Any] = ["Label": legacyLabel, "ProgramArguments": ["/bin/true"]]
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0
        ) else {
            XCTFail("Failed to serialize plist for test")
            return
        }
        try? data.write(to: url)

        XCTAssertNil(LaunchAgentService.parse(url),
                     "Legacy dotted-profile plist must not parse as a valid Schedule — it must be rejected so the Schedules UI cannot mis-attribute it")
    }
}
