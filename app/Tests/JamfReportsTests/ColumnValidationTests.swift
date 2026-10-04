import XCTest
@testable import JamfReports

@MainActor
final class ColumnValidationTests: XCTestCase {

    func testCountsAgreeWithTheirNoun() {
        XCTAssertEqual(ColumnValidationText.mapped(0), "0 columns mapped")
        XCTAssertEqual(ColumnValidationText.mapped(1), "1 column mapped")
        XCTAssertEqual(ColumnValidationText.mapped(12), "12 columns mapped")
        XCTAssertEqual(ColumnValidationText.warnings(1), "1 warning")
        XCTAssertEqual(ColumnValidationText.warnings(2), "2 warnings")
    }

    func testTheWarningNamesTheMappingsItCounts() {
        let mappings: [ColumnMapping] = [
            .init(key: "sip", label: "SIP", value: "SIP Status", required: false, status: .ok),
            .init(key: "bootstrap_token", label: "Bootstrap Token", value: "Token Escrowed",
                  required: false, status: .warn),
            .init(key: "gatekeeper", label: "Gatekeeper", value: "", required: false,
                  status: .warn),
        ]
        XCTAssertEqual(ColumnValidationText.warningDetail(mappings),
                       "Flagged: Bootstrap Token (Token Escrowed), Gatekeeper")
        XCTAssertEqual(ColumnValidationText.warningDetail([]), "Run check for details")
    }

    private func loadedStore(columnsYAML: String) async throws -> WorkspaceStore {
        let manager = FileManager.default
        let profile = "columns-check"
        let root = manager.temporaryDirectory
            .appendingPathComponent("jrc-columns-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent(profile, isDirectory: true)
        try manager.createDirectory(at: workspace, withIntermediateDirectories: true)
        try columnsYAML.write(
            to: workspace.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
        let previousRoot = ProcessInfo.processInfo.environment["JRC_TEST_WORKSPACES_ROOT"]
        let sentinel = UserDefaults.standard.string(forKey: WorkspaceMigration.sentinelKey)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        addTeardownBlock {
            if let previousRoot {
                setenv("JRC_TEST_WORKSPACES_ROOT", previousRoot, 1)
            } else {
                unsetenv("JRC_TEST_WORKSPACES_ROOT")
            }
            UserDefaults.standard.set(sentinel, forKey: WorkspaceMigration.sentinelKey)
            try? manager.removeItem(at: root)
        }
        let store = WorkspaceStore(
            demoMode: false, tickerRegistrar: StubTickerRegistrar(),
            jamfCLIProfileNames: { [] }, discoverProfiles: { [] }, jamfCLIInstallation: { nil })
        store.profile = profile
        try await store.loadConfig()
        return store
    }

    /// The demo's mapping list carries one warning (Bootstrap Token) and a live workspace
    /// starts from that list. Once the workspace's own config is loaded, nothing is flagged
    /// and a mapping is mapped or unmapped by its value alone.
    func testALiveWorkspaceDoesNotInheritTheDemosWarning() async throws {
        let store = try await loadedStore(columnsYAML: """
            columns:
              computer_name: "Computer Name"
              serial_number: "Serial Number"
              bootstrap_token: "Escrow State"
            """)
        XCTAssertFalse(store.columnMappings.contains { $0.status == .warn })
        let statuses = Dictionary(
            uniqueKeysWithValues: store.columnMappings.map { ($0.key, $0.status) })
        XCTAssertEqual(statuses["bootstrap_token"], .ok)
        XCTAssertEqual(statuses["computer_name"], .ok)
        XCTAssertEqual(statuses["manager"], .skip)
        XCTAssertTrue(store.columnMappings.allSatisfy {
            $0.status == ($0.value.isEmpty ? .skip : .ok)
        })
    }

    func testDemoModeKeepsItsOwnBadge() {
        let store = WorkspaceStore(demoMode: true)
        XCTAssertEqual(store.columnMappings.filter { $0.status == .warn }.map(\.key),
                       ["bootstrap_token"])
    }
}
