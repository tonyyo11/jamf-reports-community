import Foundation
import XCTest
@testable import JamfReports

/// Verifies the `TrendRange` enum contract used by the three Views that
/// read `@AppStorage("defaultTrendRange")` with a default of
/// `TrendRange.w4.rawValue`:
///   - `OverviewView`
///   - `TrendsView`
///   - `SettingsView`
///
/// We cannot exercise SwiftUI's `@AppStorage` subscription without a host
/// app, so these tests pin the raw-value contract those Views depend on.
final class TrendRangeAppStorageTests: XCTestCase {

    // MARK: - Default raw value

    func testDefaultRawValueIsW4() {
        // The three Views all default to TrendRange.w4.rawValue. If this
        // value ever changes, every existing user preference would be
        // silently reset — pin it.
        XCTAssertEqual(TrendRange.w4.rawValue, "W4")
    }

    // MARK: - Forward parse (rawValue → case)

    func testRawValueW4ParsesToCase() {
        XCTAssertEqual(TrendRange(rawValue: "W4"), .w4)
    }

    func testRawValueW12ParsesToCase() {
        XCTAssertEqual(TrendRange(rawValue: "W12"), .w12)
    }

    func testRawValueW26ParsesToCase() {
        XCTAssertEqual(TrendRange(rawValue: "W26"), .w26)
    }

    func testRawValueW52ParsesToCase() {
        XCTAssertEqual(TrendRange(rawValue: "W52"), .w52)
    }

    func testRawValueAllParsesToCase() {
        XCTAssertEqual(TrendRange(rawValue: "All"), .all)
    }

    // MARK: - Invalid values

    func testInvalidRawValueReturnsNil() {
        XCTAssertNil(TrendRange(rawValue: ""))
        XCTAssertNil(TrendRange(rawValue: "w4"))           // case-sensitive
        XCTAssertNil(TrendRange(rawValue: "all"))          // case-sensitive
        XCTAssertNil(TrendRange(rawValue: "ALL"))
        XCTAssertNil(TrendRange(rawValue: "W4 "))          // trailing space
        XCTAssertNil(TrendRange(rawValue: "W8"))
        XCTAssertNil(TrendRange(rawValue: "Weekly"))
    }

    func testViewsFallbackToW4ForInvalidStoredValue() {
        // Production pattern across the three Views:
        //   TrendRange(rawValue: stored) ?? .w4
        //
        // Simulate a corrupted UserDefaults value and assert the fallback.
        let stored = "garbage"
        let resolved = TrendRange(rawValue: stored) ?? .w4
        XCTAssertEqual(resolved, .w4)
    }

    func testViewsFallbackPreservesStoredW26() {
        // Sanity check the other branch of the `?? .w4` fallback: when
        // the stored value is valid, it must be honored — not silently
        // replaced by the default.
        let stored = "W26"
        let resolved = TrendRange(rawValue: stored) ?? .w4
        XCTAssertEqual(resolved, .w26)
    }

    // MARK: - Round-trip

    func testEveryCaseRoundTripsThroughRawValue() {
        for range in TrendRange.allCases {
            let raw = range.rawValue
            XCTAssertEqual(
                TrendRange(rawValue: raw),
                range,
                "TrendRange.\(range) raw value \(raw) failed to parse back to itself"
            )
        }
    }

    // MARK: - CaseIterable contract

    func testAllCasesHasFiveEntries() {
        // The Settings picker iterates allCases; pin the count so adding
        // a new case is a conscious decision (and reminds you to update
        // any code that special-cases the range list).
        XCTAssertEqual(TrendRange.allCases.count, 5)
    }

    func testAllCasesContainsExpectedRanges() {
        XCTAssertEqual(
            TrendRange.allCases,
            [.w4, .w12, .w26, .w52, .all]
        )
    }

    // MARK: - Identifiable

    func testIdentifierMatchesRawValue() {
        // TrendRange.id is `var id: String { rawValue }`. Views use this
        // for ForEach picker rows — make sure they stay aligned.
        for range in TrendRange.allCases {
            XCTAssertEqual(range.id, range.rawValue)
        }
    }
}
