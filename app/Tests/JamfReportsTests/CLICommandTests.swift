import Foundation
import XCTest
@testable import JamfReports

/// Argv-shape and `snapshotKind` tests for `CLICommand`.
///
/// These are pure value tests — no `Process`, no fixtures. Adding a new
/// `CLICommand` case should add a corresponding test here.
final class CLICommandTests: XCTestCase {

    // MARK: - argv

    func testProHelpArgv() {
        XCTAssertEqual(CLICommand.proHelp.argv, ["pro", "--help"])
    }

    func testProHelpProfileIsEmpty() {
        XCTAssertEqual(CLICommand.proHelp.profile, "")
    }

    func testProHelpSnapshotKindIsNil() {
        XCTAssertNil(CLICommand.proHelp.snapshotKind)
    }

    func testProAuthTokenArgv() {
        let command = CLICommand.proAuthToken(profile: "harbor")
        XCTAssertEqual(
            command.argv,
            ["-p", "harbor", "pro", "auth", "token", "--output", "json", "--no-input"]
        )
    }

    func testSchoolDepDevicesListArgv() {
        let command = CLICommand.schoolDepDevicesList(profile: "school-prod")
        XCTAssertEqual(
            command.argv,
            ["-p", "school-prod", "school", "dep-devices", "list", "--output", "json"]
        )
    }

    func testSchoolIBeaconsListArgv() {
        let command = CLICommand.schoolIBeaconsList(profile: "dummy")
        XCTAssertEqual(
            command.argv,
            ["-p", "dummy", "school", "ibeacons", "list", "--output", "json"]
        )
    }

    // MARK: - Smart-group templates (jamf-cli PR #205, target release TBD)

    func testProSmartGroupTemplatesArgv() {
        let command = CLICommand.proSmartGroupTemplates(profile: "harbor")
        XCTAssertEqual(
            command.argv,
            ["-p", "harbor", "pro", "sg", "templates", "--output", "json"]
        )
    }

    func testProSmartGroupPreviewArgvNoParams() {
        let command = CLICommand.proSmartGroupPreview(
            profile: "harbor",
            templateSlug: "stale-checkin",
            params: [:]
        )
        XCTAssertEqual(
            command.argv,
            ["-p", "harbor", "pro", "sg", "preview", "--template", "stale-checkin", "--output", "json"]
        )
    }

    func testProSmartGroupPreviewArgvSortsParamsDeterministically() {
        // Insertion-order-independent: same dict in any iteration order produces the same argv.
        let command = CLICommand.proSmartGroupPreview(
            profile: "harbor",
            templateSlug: "os-version-below",
            params: ["version": "15.0", "platform": "macOS"]
        )
        // Sorted alphabetically: --platform=… before --version=…
        XCTAssertEqual(
            command.argv,
            ["-p", "harbor", "pro", "sg", "preview", "--template", "os-version-below",
             "--platform=macOS", "--version=15.0",
             "--output", "json"]
        )
    }

    func testProSmartGroupApplyArgvIncludesYesAndOptionalFlags() {
        let command = CLICommand.proSmartGroupApply(
            profile: "harbor",
            templateSlug: "not-encrypted",
            smartGroupName: "Unencrypted Macs (outreach)",
            params: [:],
            recalculate: true,
            dryRun: false
        )
        XCTAssertEqual(
            command.argv,
            ["-p", "harbor", "pro", "sg", "apply",
             "--template", "not-encrypted",
             "--name", "Unencrypted Macs (outreach)",
             "--recalculate",
             "--yes",
             "--output", "json"]
        )
    }

    func testProSmartGroupApplyArgvDryRunOmitsRecalculate() {
        let command = CLICommand.proSmartGroupApply(
            profile: "harbor",
            templateSlug: "stale-checkin",
            smartGroupName: "Stale 90d",
            params: [:],
            recalculate: false,
            dryRun: true
        )
        XCTAssertEqual(
            command.argv,
            ["-p", "harbor", "pro", "sg", "apply",
             "--template", "stale-checkin",
             "--name", "Stale 90d",
             "--dry-run",
             "--yes",
             "--output", "json"]
        )
    }

    func testProSmartGroupApplyArgvAlwaysIncludesYes() {
        // GUI context has no TTY; --yes must be present regardless of dry-run.
        let live = CLICommand.proSmartGroupApply(
            profile: "p", templateSlug: "t", smartGroupName: "n",
            params: [:], recalculate: false, dryRun: false
        )
        let dry = CLICommand.proSmartGroupApply(
            profile: "p", templateSlug: "t", smartGroupName: "n",
            params: [:], recalculate: false, dryRun: true
        )
        XCTAssertTrue(live.argv.contains("--yes"))
        XCTAssertTrue(dry.argv.contains("--yes"))
    }

    func testProSmartGroupVerifyTemplatesArgv() {
        let command = CLICommand.proSmartGroupVerifyTemplates(profile: "harbor")
        XCTAssertEqual(
            command.argv,
            ["-p", "harbor", "pro", "sg", "verify-templates", "--output", "json"]
        )
    }

    func testArgvAlwaysStartsWithProfileFlag() {
        let cases: [CLICommand] = [
            .proAuthToken(profile: "p1"),
            .schoolDepDevicesList(profile: "p2"),
            .schoolIBeaconsList(profile: "p3"),
            .proSmartGroupTemplates(profile: "p4"),
            .proSmartGroupPreview(profile: "p5", templateSlug: "t", params: [:]),
            .proSmartGroupApply(
                profile: "p6", templateSlug: "t", smartGroupName: "n",
                params: [:], recalculate: false, dryRun: false
            ),
            .proSmartGroupVerifyTemplates(profile: "p7"),
        ]
        for command in cases {
            XCTAssertEqual(command.argv.first, "-p", "argv must lead with -p for \(command)")
            XCTAssertTrue(command.argv.contains("--output"), "expected JSON output flag for \(command)")
        }
    }

    func testProfileAccessor() {
        XCTAssertEqual(CLICommand.proAuthToken(profile: "alpha").profile, "alpha")
        XCTAssertEqual(CLICommand.schoolDepDevicesList(profile: "beta").profile, "beta")
        XCTAssertEqual(CLICommand.schoolIBeaconsList(profile: "gamma").profile, "gamma")
        XCTAssertEqual(CLICommand.proSmartGroupTemplates(profile: "delta").profile, "delta")
        XCTAssertEqual(
            CLICommand.proSmartGroupPreview(profile: "epsilon", templateSlug: "t", params: [:]).profile,
            "epsilon"
        )
        XCTAssertEqual(
            CLICommand.proSmartGroupApply(
                profile: "zeta", templateSlug: "t", smartGroupName: "n",
                params: [:], recalculate: false, dryRun: false
            ).profile,
            "zeta"
        )
        XCTAssertEqual(CLICommand.proSmartGroupVerifyTemplates(profile: "eta").profile, "eta")
    }

    // MARK: - snapshotKind

    func testProAuthTokenHasNoSnapshot() {
        XCTAssertNil(CLICommand.proAuthToken(profile: "p").snapshotKind)
    }

    func testSchoolDepDevicesSnapshotKind() {
        XCTAssertEqual(
            CLICommand.schoolDepDevicesList(profile: "p").snapshotKind,
            .schoolDepDevices
        )
    }

    func testSchoolIBeaconsSnapshotKind() {
        XCTAssertEqual(
            CLICommand.schoolIBeaconsList(profile: "p").snapshotKind,
            .schoolIBeacons
        )
    }

    func testSnapshotKindRawValuesAreStableFilenameStems() {
        XCTAssertEqual(SnapshotKind.schoolDepDevices.rawValue, "school-dep-devices")
        XCTAssertEqual(SnapshotKind.schoolIBeacons.rawValue, "school-ibeacons")
        XCTAssertEqual(SnapshotKind.smartGroupTemplates.rawValue, "smart-group-templates")
    }

    func testProSmartGroupTemplatesIsCacheable() {
        XCTAssertEqual(
            CLICommand.proSmartGroupTemplates(profile: "p").snapshotKind,
            .smartGroupTemplates
        )
    }

    func testProSmartGroupPreviewIsNotCacheable() {
        // Preview output is parameterized per call; caching would be useless and
        // potentially misleading if params changed between renders.
        XCTAssertNil(
            CLICommand.proSmartGroupPreview(profile: "p", templateSlug: "t", params: [:]).snapshotKind
        )
    }

    func testProSmartGroupApplyIsNotCacheable() {
        // Apply is destructive; its return is a one-shot result, not a snapshot.
        XCTAssertNil(
            CLICommand.proSmartGroupApply(
                profile: "p", templateSlug: "t", smartGroupName: "n",
                params: [:], recalculate: false, dryRun: false
            ).snapshotKind
        )
    }

    func testProSmartGroupVerifyTemplatesIsNotCacheable() {
        // Verify is diagnostic; result varies with tenant state.
        XCTAssertNil(
            CLICommand.proSmartGroupVerifyTemplates(profile: "p").snapshotKind
        )
    }

    // MARK: - Invalid profile guard

    /// Verifies the `[]` release safety-net return for invalid profiles.
    /// Skipped in debug builds where `assertionFailure` would terminate the process.
    func testArgvReturnsEmptyForInvalidProfile() throws {
        #if DEBUG
        throw XCTSkip("assertionFailure fires in debug — invalid-profile argv guard is verified in release builds")
        #else
        let invalidProfiles = ["", "../escape", "foo bar", "--config=/etc/passwd", "UPPER"]
        for profile in invalidProfiles {
            XCTAssertEqual(
                CLICommand.proAuthToken(profile: profile).argv, [],
                "argv must be empty for invalid profile: '\(profile)'"
            )
        }
        #endif
    }
}
