import Foundation
import XCTest
@testable import JamfReports

/// Argv-shape and `snapshotKind` tests for `CLICommand`.
///
/// These are pure value tests — no `Process`, no fixtures. Adding a new
/// `CLICommand` case should add a corresponding test here.
final class CLICommandTests: XCTestCase {

    // MARK: - argv

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

    func testArgvAlwaysStartsWithProfileFlag() {
        let cases: [CLICommand] = [
            .proAuthToken(profile: "p1"),
            .schoolDepDevicesList(profile: "p2"),
            .schoolIBeaconsList(profile: "p3"),
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
