import XCTest
@testable import JamfReports

/// v2.2.0 managed automation: the `@AppStorage`-backed global policy.
final class AutomationPolicyTests: XCTestCase {

    func testDefaultsAreSafeAndUnmanaged() {
        let p = AutomationPolicy()
        XCTAssertFalse(p.isManaged, "managed mode is off until the operator opts in")
        XCTAssertTrue(p.freshnessEnabled)
        XCTAssertTrue(p.scanEnabled)
        XCTAssertEqual(p.reportsCadence, .weekly)
        XCTAssertFalse(p.backupsEnabled)
        XCTAssertEqual(p.runTime, "06:00")
        XCTAssertEqual(p.excludedProfiles, [])
    }

    func testSerializeParseRoundTrip() {
        var p = AutomationPolicy()
        p.isManaged = true
        p.reportsCadence = .monthly
        p.reportsDayOfMonth = 15
        p.excludedProfiles = ["dummy", "sandbox"]
        p.runTime = "07:30"
        p.reportGroups = [
            ReportGroup(name: "Production Fleet", profiles: ["prod", "dev"]),
            ReportGroup(name: "Customer A", profiles: ["cust-a"]),
        ]
        XCTAssertEqual(AutomationPolicy.parse(p.serialize()), p)
    }

    func testParseOfGarbageReturnsDefaults() {
        XCTAssertEqual(AutomationPolicy.parse("not json"), AutomationPolicy())
        XCTAssertEqual(AutomationPolicy.parse(""), AutomationPolicy())
    }

    /// Partial JSON (a field added in a later build is absent) keeps the other
    /// fields at their saved values instead of wiping the whole policy.
    func testLenientDecodeKeepsPresentFields() {
        let partial = #"{"isManaged":true,"reportsCadence":"daily"}"#
        let p = AutomationPolicy.parse(partial)
        XCTAssertTrue(p.isManaged)
        XCTAssertEqual(p.reportsCadence, .daily)
        // Absent keys fall back to defaults, not to a wiped policy.
        XCTAssertTrue(p.freshnessEnabled)
        XCTAssertEqual(p.runTime, "06:00")
    }

    func testCurrentReadsFromUserDefaults() {
        let suite = UserDefaults(suiteName: "AutomationPolicyTests-\(UUID().uuidString)")!
        defer { suite.removePersistentDomain(forName: suite.dictionaryRepresentation().isEmpty ? "" : "") }
        var p = AutomationPolicy()
        p.isManaged = true
        suite.set(p.serialize(), forKey: AutomationPolicy.storageKey)
        XCTAssertEqual(AutomationPolicy.current(defaults: suite), p)
        // Missing key → defaults.
        let empty = UserDefaults(suiteName: "AutomationPolicyTests-empty-\(UUID().uuidString)")!
        XCTAssertEqual(AutomationPolicy.current(defaults: empty), AutomationPolicy())
    }
}
