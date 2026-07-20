import Foundation
import XCTest
@testable import JamfReports

// MARK: - CLISubcommandTests
// Tests for check, school-check, school-scaffold subcommands.
// These test the logic functions directly rather than the full process launch.

final class CLISubcommandTests: XCTestCase {

    // MARK: - school-scaffold: fuzzy matching

    func testSchoolScaffoldMapsSerialColumn() {
        let headers = ["Device Name", "Serial Number", "OS Version", "Last Checkin",
                       "Model", "Managed", "Email"]
        let mappings = schoolScaffoldMappingsTestable(from: headers)
        XCTAssertEqual(mappings["serial_number"], "Serial Number")
    }

    func testSchoolScaffoldMapsOSVersion() {
        let headers = ["Device Name", "Serial Number", "iOS Version", "Last Contact", "Model"]
        let mappings = schoolScaffoldMappingsTestable(from: headers)
        XCTAssertNotNil(mappings["operating_system"], "Should map iOS Version to operating_system")
    }

    func testSchoolScaffoldMapsLastCheckin() {
        let headers = ["Name", "Serial", "OS", "Last Check-In", "Model"]
        let mappings = schoolScaffoldMappingsTestable(from: headers)
        XCTAssertEqual(mappings["last_checkin"], "Last Check-In")
    }

    func testSchoolScaffoldEmptyHeadersProducesEmptyMappings() {
        let mappings = schoolScaffoldMappingsTestable(from: [])
        XCTAssertTrue(mappings.isEmpty)
    }

    func testSchoolScaffoldMapsEmail() {
        let headers = ["Username", "Email Address", "Location"]
        let mappings = schoolScaffoldMappingsTestable(from: headers)
        XCTAssertEqual(mappings["email"], "Email Address")
    }

    // MARK: - school-scaffold: file output

    func testSchoolScaffoldWritesOutputFile() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("scaffold-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Write a minimal CSV.
        let csvURL = tmp.appendingPathComponent("devices.csv")
        let csv = "Device Name,Serial Number,iOS Version,Last Check-In,Model,Managed\n"
        try csv.write(to: csvURL, atomically: true, encoding: .utf8)

        let outURL = tmp.appendingPathComponent("config.yaml")
        let result = schoolScaffoldToFile(csvPath: csvURL.path, outPath: outURL.path)
        XCTAssertEqual(result, 0, "school-scaffold should exit 0")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outURL.path),
                      "Output file should be created")
        let content = try String(contentsOf: outURL, encoding: .utf8)
        XCTAssertTrue(content.contains("school_columns:"), "Output should contain school_columns section")
    }

    func testSchoolScaffoldAppendToExistingFile() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("scaffold-append-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let csvURL = tmp.appendingPathComponent("devices.csv")
        try "Device Name,Serial\n".write(to: csvURL, atomically: true, encoding: .utf8)

        let outURL = tmp.appendingPathComponent("config.yaml")
        try "jamf_cli:\n  profile: \"test\"\n".write(to: outURL, atomically: true, encoding: .utf8)

        let result = schoolScaffoldToFile(csvPath: csvURL.path, outPath: outURL.path)
        XCTAssertEqual(result, 0)
        let content = try String(contentsOf: outURL, encoding: .utf8)
        XCTAssertTrue(content.contains("jamf_cli:"), "Existing content should be preserved")
        XCTAssertTrue(content.contains("school_columns:"), "school_columns should be appended")
    }

    func testSchoolScaffoldMissingCSVExitsNonZero() {
        let result = schoolScaffoldToFile(
            csvPath: "/nonexistent/path/devices.csv",
            outPath: "/tmp/config.yaml"
        )
        XCTAssertEqual(result, 1, "Missing CSV should exit 1")
    }

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

    // MARK: - Headless managed-automation self-heal guard

    func testReconcileManagedAutomationHeadlessNoOpWhenUnmanaged() {
        XCTAssertFalse(
            shouldReconcileManagedAutomationHeadlessTestable(policy: AutomationPolicy()),
            "isManaged defaults false — the headless call must bail before any I/O"
        )
    }

    func testReconcileManagedAutomationHeadlessRunsWhenManaged() {
        var managed = AutomationPolicy()
        managed.isManaged = true
        XCTAssertTrue(shouldReconcileManagedAutomationHeadlessTestable(policy: managed))
    }
}

// MARK: - Test harness wrappers
// These replicate the private functions from main.swift so they can be unit-tested.
// main.swift functions are file-private, so we re-implement the testable core logic here.

/// Testable version of schoolScaffoldMappings.
func schoolScaffoldMappingsTestable(from headers: [String]) -> [String: String] {
    let hints: [String: [String]] = [
        "device_name":      ["device name", "name"],
        "serial_number":    ["serial"],
        "operating_system": ["operating system", "os version", "ios version", "ipados"],
        "last_checkin":     ["last check", "last inventory", "last contact", "last seen"],
        "model":            ["model"],
        "managed":          ["managed"],
        "supervised":       ["supervised"],
        "username":         ["username", "user name", "assigned user"],
        "email":            ["email"],
        "device_family":    ["device family", "device type", "type"],
        "asset_tag":        ["asset tag", "asset"],
        "location":         ["location"],
    ]
    let excludes: [String: [String]] = [
        "device_name":  ["model", "type", "family"],
        "model":        ["model name"],
        "last_checkin": ["enrollment"],
    ]
    let lower = headers.map { $0.lowercased() }
    var result: [String: String] = [:]
    for (key, hintList) in hints {
        for hint in hintList {
            guard let idx = lower.firstIndex(where: { $0.contains(hint) }) else { continue }
            let candidate = lower[idx]
            let blocked = (excludes[key] ?? []).contains { candidate.contains($0) }
            if !blocked {
                result[key] = headers[idx]
                break
            }
        }
    }
    return result
}

/// Testable version of runSchoolScaffold.
func schoolScaffoldToFile(csvPath: String, outPath: String) -> Int32 {
    let csvURL = URL(fileURLWithPath: csvPath)
    let outURL = URL(fileURLWithPath: outPath)
    guard FileManager.default.fileExists(atPath: csvURL.path) else { return 1 }
    guard let data = try? Data(contentsOf: csvURL),
          let text = String(data: data, encoding: .utf8) else { return 1 }
    let firstLine = text.components(separatedBy: "\n").first ?? ""
    let delimiter: Character = firstLine.contains(";") ? ";" : ","
    let headers = firstLine.components(separatedBy: String(delimiter))
        .map { $0.trimmingCharacters(in: .init(charactersIn: "\r\"\u{feff}")) }
    let mappings = schoolScaffoldMappingsTestable(from: headers)
    var lines = ["# config.yaml — Jamf School columns (appended by school-scaffold)", "school_columns:"]
    let orderedKeys = [
        "device_name", "serial_number", "operating_system", "last_checkin",
        "model", "managed", "supervised", "username", "email",
        "device_family", "asset_tag", "location",
    ]
    for key in orderedKeys {
        let value = mappings[key] ?? ""
        lines.append("  \(key): \"\(value)\"")
    }
    lines.append("")
    do {
        let fm = FileManager.default
        if fm.fileExists(atPath: outURL.path),
           let existing = try? String(contentsOf: outURL, encoding: .utf8) {
            let appended = existing.hasSuffix("\n") ? existing + lines.joined(separator: "\n")
                : existing + "\n" + lines.joined(separator: "\n")
            try appended.write(to: outURL, atomically: true, encoding: .utf8)
        } else {
            try fm.createDirectory(at: outURL.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try lines.joined(separator: "\n").write(to: outURL, atomically: true, encoding: .utf8)
        }
        return 0
    } catch {
        return 1
    }
}

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

/// Testable version of `shouldReconcileManagedAutomationHeadless` (2.6 field-
/// incident fix). Mirrors the same one-line guard so the headless self-heal
/// entry's "unmanaged → no-op" contract is unit-tested without touching
/// `AutomationPolicy.current()`/`UserDefaults` or launchctl.
func shouldReconcileManagedAutomationHeadlessTestable(policy: AutomationPolicy) -> Bool {
    policy.isManaged
}
