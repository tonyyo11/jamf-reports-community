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

    /// The demo's mapping list carries one warning (Bootstrap Token). A live workspace starts
    /// from that list; after it is rebuilt from the workspace's own columns nothing is flagged,
    /// and a mapping is mapped or unmapped by its value alone.
    func testALiveWorkspaceDoesNotInheritTheDemosWarning() {
        let store = WorkspaceStore(demoMode: false)
        XCTAssertTrue(store.columnMappings.contains { $0.status == .warn }, "the seed has one")
        store.revert()
        XCTAssertFalse(store.columnMappings.contains { $0.status == .warn })
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
