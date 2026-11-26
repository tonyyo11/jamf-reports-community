import XCTest
@testable import JamfReports

/// Benchmark rules newly failing between two `compliance-rules` snapshots.
final class BenchmarkRuleDriftTests: XCTestCase {
    typealias Rule = BenchmarkRuleDrift.Rule

    private func rule(
        _ id: String, _ failed: Int?, benchmark: String = "CIS", title: String? = nil
    ) -> Rule {
        Rule(rule: title ?? "Rule \(id)", passed: 0, failed: failed, unknown: 0, devices: 1,
             passRate: "", ruleId: id, benchmark: benchmark)
    }

    func testNewlyFailing() {
        let drift = BenchmarkRuleDrift(
            current: [rule("a", 2), rule("b", 0), rule("c", 4)],
            baseline: [rule("a", 0), rule("b", 0), rule("c", 1)])
        XCTAssertEqual(drift.newlyFailing.map(\.ruleId), ["a"])
        XCTAssertEqual(drift.notCompared, 0)
    }

    func testNotComparedCases() {
        let drift = BenchmarkRuleDrift(
            current: [rule("nilNow", nil), rule("nilBefore", 1), rule("new", 1),
                      rule("dup", 1), rule("dup", 2), rule("x", 1, benchmark: "STIG")],
            baseline: [rule("nilNow", 0), rule("nilBefore", nil)])
        XCTAssertTrue(drift.newlyFailing.isEmpty)
        // nilNow, nilBefore, new, the two dup rows, the STIG-only rule.
        XCTAssertEqual(drift.notCompared, 6)
    }

    func testRepeatedKeyInBaselineIsNotCompared() {
        let drift = BenchmarkRuleDrift(
            current: [rule("a", 1)], baseline: [rule("a", 0), rule("a", 0)])
        XCTAssertTrue(drift.newlyFailing.isEmpty)
        XCTAssertEqual(drift.notCompared, 1)
    }

    func testTitleFallbackKey() {
        let drift = BenchmarkRuleDrift(
            current: [rule("", 3, title: "Password length")],
            baseline: [rule("", 0, title: "Password length")])
        XCTAssertEqual(drift.newlyFailing.map(\.rule), ["Password length"])
    }

    func testPair() throws {
        let root = GoldenFleetWorkspace.freshRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let anchor = GoldenFleetClock.anchorNoon()
        func at(_ day: Int, hour: Int = 12) -> Date {
            GoldenFleetClock.timestamp(dayOffset: day, hour: hour, minute: 0, relativeTo: anchor)
        }
        let dataDir = root.appendingPathComponent("data", isDirectory: true)
        let old = try GoldenFleetWorkspace.writeSnapshot(
            kind: "compliance-rules", dataDir: dataDir, at: at(-1), rows: [])
        _ = try GoldenFleetWorkspace.writeSnapshot(
            kind: "compliance-rules", dataDir: dataDir, at: at(0, hour: 8), rows: [])
        let landed = try GoldenFleetWorkspace.writeSnapshot(
            kind: "compliance-rules", dataDir: dataDir, at: at(0), rows: [])
        let pair = try XCTUnwrap(BenchmarkRuleDrift.pair(dataDir: dataDir, landedStamp: at(0)))
        XCTAssertEqual(pair.current.lastPathComponent, landed.lastPathComponent)
        XCTAssertEqual(pair.baseline.lastPathComponent, old.lastPathComponent)
        XCTAssertNil(BenchmarkRuleDrift.pair(dataDir: dataDir, landedStamp: at(-1)))
        XCTAssertNil(BenchmarkRuleDrift.pair(dataDir: dataDir, landedStamp: at(5)))
    }
}
