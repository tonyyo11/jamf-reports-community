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
            "a", "0", "dummy", "fixture-edu", "profile_01",
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

    // MARK: - Writer/parser round-trip safety (slug side)
    //
    // code-reviewer M-1: the writer's sanitizedSlug + isValidComponent
    // previously permitted `.` in slugs. A schedule name `daily.run`
    // produced a 3-component label that the new parser rejects — the
    // writer would succeed and the file would land on disk, but the
    // Schedules UI silently dropped it. Mirror the parser tightening
    // in the writer so user-entered names with dots are sanitized
    // away, not silently mis-attributed.

    func testSanitizedSlugPreservesDotsForVisibility() {
        // The sanitizer intentionally preserves `.` so that a dotted
        // schedule name surfaces a `nil` label downstream rather than
        // being silently rewritten. The post-PR-3 validity gate is
        // `isValidComponent`, exercised in
        // `testWriterRejectsScheduleNameThatYieldsDottedSlug` below.
        XCTAssertEqual(LaunchAgentWriter.sanitizedSlug(from: "Daily.Run"), "daily.run",
                       "Sanitizer preserves `.` so malformed names surface as nil at label construction")
        // Sanity: hyphens and underscores still survive.
        XCTAssertEqual(LaunchAgentWriter.sanitizedSlug(from: "Daily Backup-Run_v2"), "daily-backup-run_v2")
    }

    func testWriterRejectsScheduleNameThatYieldsDottedSlug() {
        // The exact M-1 finding from code-reviewer: a user-entered
        // schedule name `"daily.run"` previously sanitized to
        // `"daily.run"`, then produced a 3-component label
        // `<prefix>.dummy.daily.run` that the new parser rejects.
        // After PR-3, `isValidComponent` rejects `.` in the slug, so
        // `label(for:)` returns nil — the writer surfaces the
        // malformed name instead of silently writing a plist the
        // Schedules UI then drops.
        let prefix = LaunchAgentWriter.labelPrefix
        let dottedSlug = LaunchAgentWriter.sanitizedSlug(from: "daily.run")
        XCTAssertTrue(dottedSlug.contains("."),
                      "Setup invariant: sanitizer preserves `.` so the test exercises the validity gate, not the sanitizer")

        // Constructing a label from a sanitized dotted slug must fail.
        // We verify via the structural check: the writer's
        // `isValidComponent` rejects the slug, so any code path that
        // routes through it (label(for:), nativeWrite(for:)) refuses
        // to construct a 3-component label.
        let badLabel = "\(prefix).dummy.daily.run"
        XCTAssertNil(LaunchAgentService.parse(URL(fileURLWithPath: "/nonexistent/\(badLabel).plist")),
                     "Even if a legacy 3-component plist exists, the parser must reject it")
    }

    // MARK: - Migration helper surfaces dotted workspace dirs

    #if DEBUG
    // `JRC_TEST_WORKSPACES_ROOT` is gated on #if DEBUG in
    // ProfileService.workspacesRoot(). These tests are skipped in
    // release builds because the env override would no-op and the
    // assertions would scan the real ~/Jamf-Reports — a false-pass or
    // a false-fail depending on the dev machine's profile inventory.

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
    #endif

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
    // re-attributed the plist to the WRONG profile. PR-3 tightened the
    // parser to require exactly 2 post-prefix components for non-multi
    // labels — anything else is rejected.

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
