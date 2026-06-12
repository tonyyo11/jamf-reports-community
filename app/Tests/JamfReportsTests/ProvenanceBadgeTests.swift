import XCTest
@testable import JamfReports

/// ProvenanceBadge is a SwiftUI View struct; the class is @MainActor because
/// SwiftUI View-conforming types are MainActor-isolated on Swift 6.1 and later.
@MainActor
final class ProvenanceBadgeTests: XCTestCase {

    // MARK: - label

    func testLabelWithDateAndNoSources() {
        let badge = ProvenanceBadge(asOf: "2026-06-01")
        XCTAssertEqual(badge.label, "Daily summary digest · 2026-06-01")
    }

    func testLabelWhenAsOfIsNil() {
        let badge = ProvenanceBadge(asOf: nil)
        XCTAssertEqual(badge.label, "Daily summary digest · none yet")
    }

    func testLabelIncludesDegradedNoteWhenPresent() {
        let badge = ProvenanceBadge(
            asOf: "2026-06-01",
            sources: ["computers": "cache", "patch-status": "live"]
        )
        // 1 cached — note must appear in the label
        XCTAssertTrue(badge.label.contains("2026-06-01"))
        XCTAssertTrue(badge.label.contains("cached"))
    }

    // MARK: - degradedNote

    func testDegradedNoteNilWhenSourcesNil() {
        let badge = ProvenanceBadge(asOf: "2026-06-01", sources: nil)
        XCTAssertNil(badge.degradedNote)
    }

    func testDegradedNoteNilWhenSourcesEmpty() {
        let badge = ProvenanceBadge(asOf: "2026-06-01", sources: [:])
        XCTAssertNil(badge.degradedNote)
    }

    func testDegradedNoteNilWhenAllLive() {
        let sources: [String: String] = [
            "computers": "live",
            "patch-status": "live",
            "security": "live",
        ]
        let badge = ProvenanceBadge(asOf: "2026-06-01", sources: sources)
        XCTAssertNil(badge.degradedNote)
    }

    /// 2 cached + 1 absent + 1 live → "sources: 2 cached, 1 missing"
    func testDegradedNoteMixedCacheAbsentAndLive() {
        let sources: [String: String] = [
            "computers": "cache",
            "patch-status": "cache",
            "ea-results": "absent",
            "security": "live",
        ]
        let badge = ProvenanceBadge(asOf: "2026-06-01", sources: sources)
        XCTAssertEqual(badge.degradedNote, "sources: 2 cached, 1 missing")
    }

    /// Single cached source, no absent → only cached part in note.
    func testDegradedNoteOnlyCached() {
        let sources: [String: String] = ["computers": "cache"]
        let badge = ProvenanceBadge(asOf: "2026-06-01", sources: sources)
        XCTAssertEqual(badge.degradedNote, "sources: 1 cached")
    }

    /// Single absent source, no cached → only missing part in note.
    func testDegradedNoteOnlyAbsent() {
        let sources: [String: String] = ["ea-results": "absent"]
        let badge = ProvenanceBadge(asOf: "2026-06-01", sources: sources)
        XCTAssertEqual(badge.degradedNote, "sources: 1 missing")
    }
}
