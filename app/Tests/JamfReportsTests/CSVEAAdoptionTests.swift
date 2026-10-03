import Foundation
import XCTest
@testable import JamfReports

/// Round-trip tests for ConfigEAAdopter — proves adoption is additive and
/// non-destructive: new EAs land, pre-existing EAs survive, and unmanaged
/// top-level keys are preserved.
final class CSVEAAdoptionTests: XCTestCase {

    func test_adopt_isAdditiveAndPreservesUnmanagedKeys() throws {
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

        let added = try ConfigEAAdopter.adopt(
            eaProposals: proposals, agentProposals: [], profile: profile, workspaceRoot: root
        ).eas
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

    /// custom_eas typed as a mapping is left as typed, so nothing is added to it, and the
    /// save's report says so; the security agent still lands.
    func test_adopt_intoABlockThatIsNotAListAddsNothingThereAndSaysWhy() throws {
        let root = try temporaryWorkspaceRoot()
        let profile = "ea-adopt-map-\(UUID().uuidString.lowercased())"
        try writeConfig(
            "columns:\n  # names\n  computer_name: Name\n"
                + "custom_eas:\n  Battery:\n    column: Battery\nsecurity_agents: []\n",
            profile: profile, root: root)
        let proposal = ScaffoldService.ProposedEA(
            name: "Disk", column: "Disk Free", type: "text", sampleValue: "50")
        let agent = ScaffoldService.ProposedEA(
            name: "Agent", column: "Agent Status", type: "text", sampleValue: "Running")

        let result = try ConfigEAAdopter.adopt(
            eaProposals: [proposal], agentProposals: [agent], profile: profile,
            workspaceRoot: root)

        XCTAssertEqual(result.eas, 0, "the block was left as typed")
        XCTAssertEqual(result.agents, 1)
        XCTAssertEqual(result.report.keptBlocks, ["custom_eas"])
        XCTAssertTrue(result.report.droppedComments)
        XCTAssertNotNil(result.report.backupName)
        let text = try String(
            contentsOf: ConfigService.configURL(for: profile, workspaceRoot: root),
            encoding: .utf8)
        XCTAssertTrue(text.contains("custom_eas:\n  Battery:\n    column: Battery\n"), text)
        XCTAssertFalse(text.contains("Disk Free"), text)
    }

    func test_adopt_skipsDuplicateEAColumns() throws {
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

        let added = try ConfigEAAdopter.adopt(
            eaProposals: proposals, agentProposals: [], profile: profile, workspaceRoot: root
        ).eas
        XCTAssertEqual(added, 1, "duplicate column must be skipped")

        let reloaded = try ConfigService.load(profile: profile, workspaceRoot: root)
        XCTAssertEqual(reloaded.state.customEAs.count, 2)
        XCTAssertTrue(reloaded.state.customEAs.map(\.column).contains("New EA"))
    }

    func test_adopt_emptyProposalsLeavesConfigUntouched() throws {
        let root = try temporaryWorkspaceRoot()
        let profile = "ea-adopt-empty-\(UUID().uuidString.lowercased())"
        try writeConfig(
            "columns: {}\ncustom_eas: []\n",
            profile: profile,
            root: root
        )

        let added = try ConfigEAAdopter.adopt(
            eaProposals: [], agentProposals: [], profile: profile, workspaceRoot: root
        ).eas
        XCTAssertEqual(added, 0)

        let reloaded = try ConfigService.load(profile: profile, workspaceRoot: root)
        XCTAssertTrue(reloaded.state.customEAs.isEmpty)
    }

    func test_adopt_routesProposalsToEAsAndSecurityAgents() throws {
        let root = try temporaryWorkspaceRoot()
        let profile = "ea-adopt-split-\(UUID().uuidString.lowercased())"
        try writeConfig("columns: {}\ncustom_eas: []\nsecurity_agents: []\n",
                        profile: profile, root: root)

        let falcon = ScaffoldService.ProposedEA(
            name: "CrowdStrike Falcon", column: "CrowdStrike Falcon - Status",
            type: "boolean", sampleValue: "Installed")
        let fileVault = ScaffoldService.ProposedEA(
            name: "FileVault", column: "FileVault 2 - Status",
            type: "boolean", sampleValue: "Encrypted")

        let result = try ConfigEAAdopter.adopt(
            eaProposals: [fileVault], agentProposals: [falcon],
            profile: profile, workspaceRoot: root)
        XCTAssertEqual(result.eas, 1)
        XCTAssertEqual(result.agents, 1)

        let reloaded = try ConfigService.load(profile: profile, workspaceRoot: root)
        XCTAssertEqual(reloaded.state.customEAs.map(\.column), ["FileVault 2 - Status"])
        let agent = try XCTUnwrap(reloaded.state.securityAgents.first)
        XCTAssertEqual(agent.column, "CrowdStrike Falcon - Status")
        // Connected value defaults to the proposal's sample value.
        XCTAssertEqual(agent.connectedValue, "Installed")
    }

    func test_adopt_usesConnectedValueOverride() throws {
        let root = try temporaryWorkspaceRoot()
        let profile = "ea-adopt-cv-\(UUID().uuidString.lowercased())"
        try writeConfig("columns: {}\nsecurity_agents: []\n", profile: profile, root: root)

        let agent = ScaffoldService.ProposedEA(
            name: "Nessus", column: "Nessus - Status", type: "boolean", sampleValue: "Online")
        let result = try ConfigEAAdopter.adopt(
            eaProposals: [], agentProposals: [agent],
            connectedValues: [agent.id: "Connected"], profile: profile, workspaceRoot: root)

        XCTAssertEqual(result.agents, 1)
        let reloaded = try ConfigService.load(profile: profile, workspaceRoot: root)
        XCTAssertEqual(reloaded.state.securityAgents.first?.connectedValue, "Connected")
    }

    func test_adopt_skipsDuplicateAgentColumn() throws {
        let root = try temporaryWorkspaceRoot()
        let profile = "ea-adopt-dupagent-\(UUID().uuidString.lowercased())"
        try writeConfig(
            """
            columns: {}
            security_agents:
              - name: Falcon
                column: CrowdStrike Falcon - Status
                connected_value: Installed
            """,
            profile: profile, root: root)

        let dup = ScaffoldService.ProposedEA(
            name: "Falcon", column: "crowdstrike falcon - status",
            type: "boolean", sampleValue: "Installed")
        let result = try ConfigEAAdopter.adopt(
            eaProposals: [], agentProposals: [dup], profile: profile, workspaceRoot: root)

        XCTAssertEqual(result.agents, 0, "case-insensitive duplicate column must be skipped")
        let reloaded = try ConfigService.load(profile: profile, workspaceRoot: root)
        XCTAssertEqual(reloaded.state.securityAgents.count, 1)
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
