import Foundation
import XCTest
@testable import JamfReports

// MARK: - CLISubcommandTests
// Tests for the check and school-check subcommands.
// These test the logic functions directly rather than the full process launch.

final class CLISubcommandTests: XCTestCase {

    // MARK: - check: invalid profile exits 1

    func testCheckInvalidProfileExits1() {
        let result = checkConfigForProfile("INVALID PROFILE!!!")
        XCTAssertEqual(result, 1)
    }

    func testCheckMissingWorkspaceExits1() {
        // A valid slug (lowercase — the UUID hex must be lowercased or it is
        // an invalid slug) that has no workspace on disk.
        let slug = "no-such-workspace-\(UUID().uuidString.prefix(8).lowercased())"
        // Defensive: a stale workspace dir from a prior run (or a UUID-prefix
        // collision) would let checkConfigForProfile see a config.yaml and
        // return 0, flaking this test. Remove any pre-existing dir for the slug.
        if let workspace = ProfileService.workspaceURL(for: slug) {
            try? FileManager.default.removeItem(at: workspace)
        }
        let result = checkConfigForProfile(slug)
        XCTAssertEqual(result, 1)
    }

    // MARK: - school-check: invalid profile exits 1

    func testSchoolCheckInvalidProfileExits1() {
        let result = schoolCheckForProfile("INVALID!!!")
        XCTAssertEqual(result, 1)
    }

    func testSchoolCheckMissingWorkspaceExits1() {
        // Lowercase the UUID hex so the slug is valid — otherwise this
        // exercises the invalid-slug path instead of the missing-workspace one.
        let slug = "no-such-workspace-\(UUID().uuidString.prefix(8).lowercased())"
        // Defensive: remove any stale workspace dir for this slug (see
        // testCheckMissingWorkspaceExits1).
        if let workspace = ProfileService.workspaceURL(for: slug) {
            try? FileManager.default.removeItem(at: workspace)
        }
        let result = schoolCheckForProfile(slug)
        XCTAssertEqual(result, 1)
    }
}

// MARK: - Test harness wrappers
// These replicate the private functions from main.swift so they can be unit-tested.
// main.swift functions are file-private, so we re-implement the testable core logic here.

/// Testable version of `runCheck`'s validation gates: profile slug, workspace
/// URL, and `config.yaml` presence. Stops short of the full config decode.
///
/// `ProfileService.workspaceURL(for:)` is pure path construction — it never
/// touches the disk, so it is non-nil for every valid slug. The `config.yaml`
/// existence check is what actually distinguishes a real workspace from a
/// missing one, exactly as `main.swift`'s `runCheck` does.
func checkConfigForProfile(_ profile: String) -> Int32 {
    guard ProfileService.isValid(profile) else { return 1 }
    guard let workspace = ProfileService.workspaceURL(for: profile) else { return 1 }
    let configURL = workspace.appendingPathComponent("config.yaml")
    guard FileManager.default.fileExists(atPath: configURL.path) else { return 1 }
    return 0
}

/// Testable version of runSchoolCheck (validates profile and workspace only).
func schoolCheckForProfile(_ profile: String) -> Int32 {
    guard ProfileService.isValid(profile) else { return 1 }
    guard let url = ProfileService.workspaceURL(for: profile),
          FileManager.default.fileExists(atPath: url.path) else { return 1 }
    return 0
}
