import XCTest
@testable import JamfReports

/// Editor rows keep their identity across a removal, and the identity stays out of equality
/// and out of config.yaml.
@MainActor
final class ConfigRowIdentityTests: XCTestCase {
    func testRemovingMiddleAgentKeepsOtherRowIDs() {
        let store = WorkspaceStore(demoMode: false)
        (0..<3).forEach { _ in store.addSecurityAgent() }
        let ids = store.configState.securityAgents.map(\.id)
        XCTAssertEqual(Set(ids).count, 3)
        store.removeSecurityAgent(at: 1)
        XCTAssertEqual(store.configState.securityAgents.map(\.id), [ids[0], ids[2]])
    }

    func testRemovingMiddleCustomEAKeepsOtherRowIDs() {
        let store = WorkspaceStore(demoMode: false)
        (0..<3).forEach { _ in store.addCustomEA() }
        let ids = store.configState.customEAs.map(\.id)
        store.removeCustomEA(at: 1)
        XCTAssertEqual(store.configState.customEAs.map(\.id), [ids[0], ids[2]])
    }

    func testRemovingMiddleBenchmarkKeepsOtherRowIDs() {
        let store = WorkspaceStore(demoMode: false)
        store.configState.complianceBenchmarks = ["A", "B", "C"]
        // A loaded list has no ids yet; the first removal assigns them.
        store.removeComplianceBenchmark(at: 1)
        let ids = store.configState.benchmarkRowIDs
        XCTAssertEqual(store.configState.complianceBenchmarks, ["A", "C"])
        store.addComplianceBenchmark()
        XCTAssertEqual(store.configState.benchmarkRowIDs.id(at: 0), ids.id(at: 0))
        XCTAssertEqual(store.configState.benchmarkRowIDs.id(at: 1), ids.id(at: 1))
        XCTAssertNotEqual(store.configState.benchmarkRowIDs.id(at: 2), ids.id(at: 1))
    }

    func testRowIDDoesNotAffectEqualityOrSavedOutput() {
        let a = ConfigSecurityAgent(name: "Falcon", column: "c", connectedValue: "Up")
        let b = ConfigSecurityAgent(name: "Falcon", column: "c", connectedValue: "Up")
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertEqual(a, b)

        var one = ConfigState.defaultState
        var two = ConfigState.defaultState
        one.securityAgents = [a]
        two.securityAgents = [b]
        one.benchmarkRowIDs.append(rowCount: 0)
        XCTAssertEqual(one.benchmarkRowIDs, two.benchmarkRowIDs)

        var docOne = YAMLCodec.emptyDocument()
        var docTwo = docOne
        ConfigService.apply(state: one, to: &docOne)
        ConfigService.apply(state: two, to: &docTwo)
        XCTAssertEqual(docOne.root, docTwo.root)
    }
}
