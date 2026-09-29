import Foundation
import XCTest
@testable import JamfReports

// S-03 from review/REPORT.md (2026-05-15): a profile named `dummy.prod` with the slug `daily`
// made the label `<prefix>.dummy.prod.daily`, which LaunchAgentService.profileAndSlug read as
// profile `dummy`, slug `prod.daily`. Up to 2.8.2 the fix was refusing `.` in profile names.
// jamf-cli accepts any name, so from 2.8.3 the label encodes the profile instead
// (`ProfileName.labelComponent`), and a `.` in a label is always a separator.
final class ProfileLabelAmbiguityTests: XCTestCase {

    private let prefix = LaunchAgentWriter.labelPrefix

    private func schedule(profile: String, name: String = "Daily") -> Schedule {
        Schedule(
            name: name,
            profile: profile,
            schedule: "Daily 07:00",
            cadence: "daily",
            mode: .jamfCLIOnly,
            next: "-",
            last: "-",
            lastStatus: .ok,
            artifacts: [],
            enabled: true
        )
    }

    // MARK: - Dotted profiles are valid and their labels stay unambiguous

    func testDottedProfilesAreValid() {
        for profile in ["dummy.prod", "tenant-1.prod", "school.test", "a.b.c"] {
            XCTAssertTrue(ProfileService.isValid(profile), profile)
        }
    }

    func testLabelOfADottedProfileHasOneProfileComponent() throws {
        let label = try XCTUnwrap(LaunchAgentWriter.label(for: schedule(profile: "dummy.prod")))
        XCTAssertEqual(label, "\(prefix).dummy%2Eprod.daily")
        XCTAssertTrue(LaunchAgentWriter.isValidLabel(label))
        let parts = label.dropFirst(prefix.count + 1).split(separator: ".")
        XCTAssertEqual(parts.count, 2, "profile and slug, nothing else")
        XCTAssertEqual(ProfileName.name(fromLabelComponent: String(parts[0])), "dummy.prod")
    }

    func testLabelsOfUnusualProfilesAreValidAndDistinct() throws {
        let profiles = ["dummy.prod", "dummy", "Acme Prod", "Zürich", "a/b", "..", "-lead"]
        let labels = try profiles.map {
            try XCTUnwrap(LaunchAgentWriter.label(for: schedule(profile: $0)))
        }
        XCTAssertEqual(Set(labels).count, profiles.count)
        for label in labels {
            XCTAssertTrue(LaunchAgentWriter.isValidLabel(label), label)
        }
    }

    func testNamesUsableBefore283KeepTheirLabel() throws {
        let label = try XCTUnwrap(LaunchAgentWriter.label(for: schedule(profile: "Acme-Dev_2")))
        XCTAssertEqual(label, "\(prefix).Acme-Dev_2.daily")
    }

    // MARK: - Writer/parser round-trip safety (slug side)
    //
    // code-reviewer M-1: the writer's sanitizedSlug + isValidComponent
    // previously permitted `.` in slugs. A schedule name `daily.run`
    // produced a 3-component label that the parser rejects — the
    // writer would succeed and the file would land on disk, but the
    // Schedules UI silently dropped it.

    func testSanitizedSlugPreservesDotsForVisibility() {
        // The sanitizer intentionally preserves `.` so that a dotted
        // schedule name surfaces a `nil` label downstream rather than
        // being silently rewritten; `isValidComponent` is the gate.
        XCTAssertEqual(LaunchAgentWriter.sanitizedSlug(from: "Daily.Run"), "daily.run",
                       "Sanitizer preserves `.` so malformed names surface as nil at label construction")
        XCTAssertEqual(LaunchAgentWriter.sanitizedSlug(from: "Daily Backup-Run_v2"), "daily-backup-run_v2")
    }

    func testWriterRejectsScheduleNameThatYieldsDottedSlug() {
        XCTAssertNil(LaunchAgentWriter.label(for: schedule(profile: "dummy", name: "daily.run")))
        let badLabel = "\(prefix).dummy.daily.run"
        XCTAssertNil(LaunchAgentService.parse(URL(fileURLWithPath: "/nonexistent/\(badLabel).plist")),
                     "Even if a legacy 3-component plist exists, the parser must reject it")
    }

    // MARK: - Workspace folder of a dotted profile

    func testWorkspaceURLOfADottedProfileIsOneFolderNamedLikeIt() throws {
        let url = try XCTUnwrap(ProfileService.workspaceURL(for: "dummy.prod"))
        XCTAssertEqual(url.lastPathComponent, "dummy.prod")
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL.path,
                       ProfileService.workspacesRoot().standardizedFileURL.path)
    }

    // MARK: - LaunchAgent label parser rejects legacy dotted-profile plists
    //
    // silent-failure-hunter B-1 finding: a pre-existing plist with a
    // label like `com.<prefix>.tenant-1.prod.daily` would previously
    // parse as profile=`tenant-1`, slug=`prod.daily`. The parser requires
    // exactly 2 post-prefix components for non-multi labels; plists were
    // only ever written for names without dots, so legacy import is unchanged.

    func testProfileAndSlugParserRejectsLegacyDottedLabels() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ParserReject-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

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
