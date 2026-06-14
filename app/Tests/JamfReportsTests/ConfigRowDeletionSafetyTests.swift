import Foundation
import SwiftUI
import XCTest
@testable import JamfReports

/// Regression coverage for the add-then-remove crash in the Config editor's
/// Security Agents / Custom EAs / Compliance Benchmarks tables. The crash was a
/// SwiftUI `ForEach(indices, id: \.self)` row re-evaluating a `$array[index]`
/// binding for an index removed mid-diff (`Array index out of range` trap). The
/// fix is `safeElementBinding` (tolerant read/write) plus bounds-guarded store
/// removals. The SwiftUI trap itself isn't unit-reachable, so these cover the
/// two pieces that make the trap impossible.
@MainActor
final class ConfigRowDeletionSafetyTests: XCTestCase {

    // MARK: - safeElementBinding (the binding-layer fix)

    private final class Box { var arr: [String] = ["a", "b", "c"] }

    private func makeBinding(_ box: Box) -> Binding<[String]> {
        Binding(get: { box.arr }, set: { box.arr = $0 })
    }

    func testValidIndexReadsAndWritesThrough() {
        let box = Box()
        let elem = safeElementBinding(makeBinding(box), 1, default: "X")
        XCTAssertEqual(elem.wrappedValue, "b")
        elem.wrappedValue = "B!"
        XCTAssertEqual(box.arr, ["a", "B!", "c"])
    }

    func testOutOfRangeReadReturnsDefaultInsteadOfTrapping() {
        let box = Box()
        // Index 5 doesn't exist — a raw `box.arr[5]` would trap. The fix returns
        // the fallback, which is what the disappearing row reads during removal.
        let elem = safeElementBinding(makeBinding(box), 5, default: "fallback")
        XCTAssertEqual(elem.wrappedValue, "fallback")
    }

    func testOutOfRangeWriteIsIgnored() {
        let box = Box()
        let elem = safeElementBinding(makeBinding(box), 9, default: "")
        elem.wrappedValue = "should not land"
        XCTAssertEqual(box.arr, ["a", "b", "c"], "out-of-range write must be dropped")
    }

    func testNegativeIndexReturnsDefault() {
        let box = Box()
        XCTAssertEqual(safeElementBinding(makeBinding(box), -1, default: "d").wrappedValue, "d")
    }

    // MARK: - Store removal bounds guards

    func testAddThenRemoveSecurityAgentLeavesEmpty() {
        let store = WorkspaceStore(demoMode: false)
        let start = store.configState.securityAgents.count
        store.addSecurityAgent()
        XCTAssertEqual(store.configState.securityAgents.count, start + 1)
        store.removeSecurityAgent(at: start)
        XCTAssertEqual(store.configState.securityAgents.count, start)
    }

    func testRemoveSecurityAgentOutOfRangeIsNoOp() {
        let store = WorkspaceStore(demoMode: false)
        store.addSecurityAgent()
        let before = store.configState.securityAgents.count
        store.removeSecurityAgent(at: 999)   // would trap without the guard
        store.removeSecurityAgent(at: -1)
        XCTAssertEqual(store.configState.securityAgents.count, before)
    }

    func testRemoveCustomEAAndBenchmarkOutOfRangeIsNoOp() {
        let store = WorkspaceStore(demoMode: false)
        store.addCustomEA()
        store.addComplianceBenchmark()
        let eaCount = store.configState.customEAs.count
        let benchCount = store.configState.complianceBenchmarks.count
        store.removeCustomEA(at: 999)
        store.removeComplianceBenchmark(at: 999)
        XCTAssertEqual(store.configState.customEAs.count, eaCount)
        XCTAssertEqual(store.configState.complianceBenchmarks.count, benchCount)
    }
}
