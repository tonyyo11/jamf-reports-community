import Foundation
import XCTest
@testable import JamfReports

/// Round-trip tests for ConfigEAAdopter — proves adoption is additive and
/// non-destructive: new EAs land, pre-existing EAs survive, and unmanaged
/// top-level keys are preserved.
final class CSVEAAdoptionTests: XCTestCase {

    func test_adoptEAs_isAdditiveAndPreservesUnmanagedKeys() throws {
        let root = try temporaryWorkspaceRoot()
        let profile = "ea-adopt-\(UUID().uuidString.lowercased())"
        try writeConfig(
            """
            columns:
              computer_name: Computer Name
            custom_eas:
              - name: FileVault
                column: FileVault 2 - Status
                type: boolean
                true_value: Encrypted
            notify:
              enabled: true
              provider: teams
              url: https://example.com/webhook
            """,
            profile: profile,
            root: root
        )

        let proposals = [
            ScaffoldService.ProposedEA(
                name: "Systrack Install Status",
                column: "SysTrack Install Status",
                type: "boolean",
                sampleValue: "Installed"
            ),
            ScaffoldService.ProposedEA(
                name: "Mcafee Agent Version",
                column: "McAfee Agent Version",
                type: "version",
                sampleValue: "5.7.6"
            ),
        ]

        let added = try ConfigEAAdopter.adoptEAs(proposals, profile: profile, workspaceRoot: root)
        XCTAssertEqual(added, 2)

        let reloaded = try ConfigService.load(profile: profile, workspaceRoot: root)
        let columns = reloaded.state.customEAs.map(\.column)
        // Pre-existing EA preserved.
        XCTAssertTrue(columns.contains("FileVault 2 - Status"))
        // Newly adopted EAs present.
        XCTAssertTrue(columns.contains("SysTrack Install Status"))
        XCTAssertTrue(columns.contains("McAfee Agent Version"))
        XCTAssertEqual(reloaded.state.customEAs.count, 3)

        // Boolean adoption uses the sample value as the default true_value.
        let systrack = reloaded.state.customEAs.first { $0.column == "SysTrack Install Status" }
        XCTAssertEqual(systrack?.trueValue, "Installed")
        XCTAssertEqual(systrack?.type, "boolean")

        // Unmanaged top-level key (`notify:`) survives the additive save.
        let savedText = try String(
            contentsOf: ConfigService.configURL(for: profile, workspaceRoot: root),
            encoding: .utf8
        )
        XCTAssertTrue(savedText.contains("notify:"),
                      "unmanaged notify block must survive EA adoption")
        XCTAssertTrue(savedText.contains("https://example.com/webhook"),
                      "unmanaged notify.url must survive EA adoption")
    }

    func test_adoptEAs_skipsDuplicateColumns() throws {
        let root = try temporaryWorkspaceRoot()
        let profile = "ea-adopt-dup-\(UUID().uuidString.lowercased())"
        try writeConfig(
            """
            columns: {}
            custom_eas:
              - name: FileVault
                column: FileVault 2 - Status
                type: boolean
                true_value: Encrypted
            """,
            profile: profile,
            root: root
        )

        let proposals = [
            // Duplicate column (case-insensitive) — must be skipped.
            ScaffoldService.ProposedEA(
                name: "FileVault Status",
                column: "filevault 2 - status",
                type: "boolean",
                sampleValue: "Encrypted"
            ),
            ScaffoldService.ProposedEA(
                name: "New EA",
                column: "New EA",
                type: "text",
                sampleValue: "value"
            ),
        ]

        let added = try ConfigEAAdopter.adoptEAs(proposals, profile: profile, workspaceRoot: root)
        XCTAssertEqual(added, 1, "duplicate column must be skipped")

        let reloaded = try ConfigService.load(profile: profile, workspaceRoot: root)
        XCTAssertEqual(reloaded.state.customEAs.count, 2)
        XCTAssertTrue(reloaded.state.customEAs.map(\.column).contains("New EA"))
    }

    func test_adoptEAs_emptyProposalsLeavesConfigUntouched() throws {
        let root = try temporaryWorkspaceRoot()
        let profile = "ea-adopt-empty-\(UUID().uuidString.lowercased())"
        try writeConfig(
            "columns: {}\ncustom_eas: []\n",
            profile: profile,
            root: root
        )

        let added = try ConfigEAAdopter.adoptEAs([], profile: profile, workspaceRoot: root)
        XCTAssertEqual(added, 0)

        let reloaded = try ConfigService.load(profile: profile, workspaceRoot: root)
        XCTAssertTrue(reloaded.state.customEAs.isEmpty)
    }

    // MARK: - Helpers

    private func temporaryWorkspaceRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("JamfReportsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }

    private func writeConfig(_ text: String, profile: String, root: URL) throws {
        let url = try ConfigService.configURL(for: profile, workspaceRoot: root)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
