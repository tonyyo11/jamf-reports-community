import XCTest
@testable import JamfReports

/// `EAResultRow.decodeSnapshot` tolerates the ea-results shapes jamf-cli has
/// emitted across versions, and — crucially — its failure `reason` is PII-safe
/// (keys only, never values) so it can be logged for diagnosis.
final class EAResultDecodeSnapshotTests: XCTestCase {

    func testBareArrayDecodes() {
        let json = #"[{"device":"Mac1","ea_name":"mSCP Failures","value":"3"}]"#.data(using: .utf8)!
        let d = EAResultRow.decodeSnapshot(json)
        XCTAssertEqual(d.rows?.count, 1)
        XCTAssertEqual(d.reason, "array")
        XCTAssertEqual(d.rows?.first?.eaName, "mSCP Failures")
    }

    func testResultsEnvelopeDecodes() {
        let json = #"{"totalCount":1,"results":[{"device":"Mac1","ea_name":"x","value":"0"}]}"#.data(using: .utf8)!
        let d = EAResultRow.decodeSnapshot(json)
        XCTAssertEqual(d.rows?.count, 1)
        XCTAssertEqual(d.reason, "envelope")
    }

    func testNodesEnvelopeDecodes() {
        let json = #"{"nodes":[{"device":"Mac1","ea_name":"x","value":"0"}]}"#.data(using: .utf8)!
        XCTAssertEqual(EAResultRow.decodeSnapshot(json).rows?.count, 1)
    }

    /// An unrecognized shape reports the top-level keys — and NEVER any values,
    /// so the reason is safe to log on a government fleet.
    func testUndecodableReportsKeysNeverValues() {
        let json = #"{"unexpected":[{"serialNumber":"C02SECRET"}],"meta":1}"#.data(using: .utf8)!
        let d = EAResultRow.decodeSnapshot(json)
        XCTAssertNil(d.rows)
        XCTAssertTrue(d.reason.hasPrefix("object keys=["))
        XCTAssertTrue(d.reason.contains("unexpected"))
        XCTAssertTrue(d.reason.contains("meta"))
        XCTAssertFalse(d.reason.contains("C02SECRET"), "structural summary must never leak a value")
    }

    func testEmptyAndTrivialInputs() {
        XCTAssertEqual(EAResultRow.decodeSnapshot(Data()).reason, "not-json-or-empty")
        XCTAssertEqual(EAResultRow.decodeSnapshot("[]".data(using: .utf8)!).rows?.count, 0)
    }

    // MARK: - Truncation salvage (16KB pipe-boundary truncation)

    /// A valid bare array of `count` rows; each object is a full EAResultRow shape.
    private func validArrayJSON(count: Int) -> String {
        let objs = (0 ..< count).map {
            #"{"device":"Mac\#($0)","ea_name":"mSCP Failures","value":"\#($0)"}"#
        }
        return "[" + objs.joined(separator: ",") + "]"
    }

    func testSalvageTruncatedMidStringValue() {
        // 10 complete objects, then truncate partway into the 11th object's value.
        let json = validArrayJSON(count: 10).dropLast()  // drop trailing "]"
            + #",{"device":"Mac10","ea_name":"mSCP Failures","value":"partial-val"#
        let d = EAResultRow.decodeSnapshot(json.data(using: .utf8)!)
        XCTAssertEqual(d.rows?.count, 10)
        XCTAssertTrue(d.reason.contains("salvaged"))
    }

    func testSalvageTruncatedAfterSeparator() {
        // 10 complete objects, then a "}," separator and nothing after it.
        let json = validArrayJSON(count: 10).dropLast()
            + #",{"device":"Mac10","ea_name":"x","value":"1"},"#
        let d = EAResultRow.decodeSnapshot(json.data(using: .utf8)!)
        XCTAssertEqual(d.rows?.count, 11)
        XCTAssertTrue(d.reason.contains("salvaged"))
    }

    func testSalvageTruncatedMidKey() {
        // 10 complete objects, then a partial key in the next object.
        let json = validArrayJSON(count: 10).dropLast()
            + #",{"dev"#
        let d = EAResultRow.decodeSnapshot(json.data(using: .utf8)!)
        XCTAssertEqual(d.rows?.count, 10)
        XCTAssertTrue(d.reason.contains("salvaged"))
    }

    /// The scanner must be string/escape aware: escaped quotes and braces that
    /// live inside string values must not perturb the depth accounting.
    func testSalvageWithEscapedQuotesAndBracesInValues() {
        let obj = #"{"device":"Mac0","ea_name":"path","value":"path\\with \"quote\" and {brace}"}"#
        let json = "[" + obj + "," + obj + "]".dropLast()  // two complete, no closing "]"
        let d = EAResultRow.decodeSnapshot(json.data(using: .utf8)!)
        XCTAssertEqual(d.rows?.count, 2)
        XCTAssertTrue(d.reason.contains("salvaged"))
    }

    /// Brackets and a lone `]` inside a string value must not fool the depth
    /// scan — normal decode and truncated-salvage must both keep them intact.
    func testBracketsInStringValueRoundTrip() {
        let obj = #"{"device":"Mac0","ea_name":"note","value":"array-ish: [1,2,3] and ] alone"}"#
        let full = EAResultRow.decodeSnapshot(("[" + obj + "]").data(using: .utf8)!)
        XCTAssertEqual(full.rows?.count, 1)
        XCTAssertEqual(full.reason, "array")
        XCTAssertEqual(full.rows?.first?.value?.stringValue, "array-ish: [1,2,3] and ] alone")

        // Same value in a completed row, then a truncated trailing row.
        let truncated = "[" + obj + #",{"device":"Mac1","ea_name":"n","value":"part"#
        let salv = EAResultRow.decodeSnapshot(truncated.data(using: .utf8)!)
        XCTAssertEqual(salv.rows?.count, 1)
        XCTAssertEqual(salv.rows?.first?.value?.stringValue, "array-ish: [1,2,3] and ] alone")
        XCTAssertTrue(EAResultRow.isSalvageReason(salv.reason))
    }

    func testIsSalvageReason() {
        let salvaged = EAResultRow.decodeSnapshot(
            (validArrayJSON(count: 5).dropLast() + #",{"dev"#).data(using: .utf8)!
        )
        XCTAssertTrue(EAResultRow.isSalvageReason(salvaged.reason))
        XCTAssertFalse(EAResultRow.isSalvageReason("array"))
        XCTAssertFalse(EAResultRow.isSalvageReason("envelope"))
    }

    /// A truncated OBJECT payload (leading `{`) is not an array — no salvage;
    /// falls through to the PII-safe structural summary.
    func testTruncatedObjectPayloadNotSalvaged() {
        let json = #"{"results":[{"device":"Mac0","value":"1"}"#
        let d = EAResultRow.decodeSnapshot(json.data(using: .utf8)!)
        XCTAssertNil(d.rows)
        XCTAssertFalse(d.reason.contains("salvaged"))
    }
}
