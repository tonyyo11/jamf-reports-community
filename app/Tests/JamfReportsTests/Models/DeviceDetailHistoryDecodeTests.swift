import Foundation
import Testing
@testable import JamfReports

/// Pins `DeviceDetail.decode` against the exact row shape jamf-cli's
/// `overviewToRows` emits for `pro device <id> --output json`
/// (lowercase `section`/`resource`/`value`, jamf-cli >= v1.23.0 / PR #276).
/// MDM Command History rows carry `commandState` + `dateCompleted` combined
/// into a single `value` string by jamf-cli itself before the JSON reaches
/// this app — the generic key-value decoder needs no dedicated fields for
/// them. This guards that passthrough against future changes to the
/// priority-key lists in `DeviceDetail.buildSections`.
struct DeviceDetailHistoryDecodeTests {

    @Test("MDM command history rows surface the combined state + completion date")
    func mdmCommandHistoryRowDecodes() throws {
        let json = """
        [
          {"section": "MDM Command History (Last 10)", "resource": "ProfileList",
           "value": "ACKNOWLEDGED  2026-03-30 10:01"},
          {"section": "MDM Command History (Last 10)", "resource": "EraseDevice",
           "value": "PENDING"}
        ]
        """
        let detail = try DeviceDetail.decode(from: Data(json.utf8), lookupID: "42")

        let section = try #require(detail.sections.first { $0.title == "MDM Command History (Last 10)" })
        #expect(section.items.count == 2)

        let profileList = try #require(section.items.first { $0.label == "ProfileList" })
        #expect(profileList.value == "ACKNOWLEDGED  2026-03-30 10:01")

        let erase = try #require(section.items.first { $0.label == "EraseDevice" })
        #expect(erase.value == "PENDING")
    }

    @Test("Policy history rows surface the combined status + completion date")
    func policyHistoryRowDecodes() throws {
        let json = """
        [
          {"section": "Policy History (Last 10)", "resource": "Install Chrome",
           "value": "Completed  2026-03-30 12:00"},
          {"section": "Policy History (Last 10)", "resource": "Update Flash",
           "value": "Failed  2026-03-30 09:13", "status": "red"}
        ]
        """
        let detail = try DeviceDetail.decode(from: Data(json.utf8), lookupID: "42")

        let section = try #require(detail.sections.first { $0.title == "Policy History (Last 10)" })
        let install = try #require(section.items.first { $0.label == "Install Chrome" })
        #expect(install.value == "Completed  2026-03-30 12:00")

        // "status" carries jamf-cli's ColorHint (e.g. "red") and must never
        // shadow the real "value" field.
        let update = try #require(section.items.first { $0.label == "Update Flash" })
        #expect(update.value == "Failed  2026-03-30 09:13")
    }
}
