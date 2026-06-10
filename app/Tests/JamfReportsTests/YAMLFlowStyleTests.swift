import XCTest
@testable import JamfReports

/// Flow-style YAML collections (`{k: v}` / `[a, b]`) — added after the #181
/// field report: config.example.yaml ships its compliance bands in flow style,
/// and the block-only parser made every app-seeded workspace config
/// unparseable.
final class YAMLFlowStyleTests: XCTestCase {

    private func decode(_ yaml: String) throws -> YAMLCodec.YAMLDocument {
        try YAMLCodec.decode(yaml)
    }

    func testFlowMappingSequenceItem() throws {
        let yaml = """
        bands:
          - {label: "Pass", min_failures: 0, max_failures: 0, color: "#4472C4"}
          - {label: "High (>50)", min_failures: 51, max_failures: 9999, color: "#C0392B"}
        """
        let doc = try decode(yaml)
        let bands = doc.root.mapping?.value(for: "bands")?.sequence
        XCTAssertEqual(bands?.count, 2)
        let first = bands?.first?.mapping
        XCTAssertEqual(first?.value(for: "label")?.stringValue, "Pass")
        XCTAssertEqual(first?.value(for: "min_failures")?.intValue, 0)
        XCTAssertEqual(first?.value(for: "color")?.stringValue, "#4472C4",
                       "the # inside quotes is a color, not a comment")
        let last = bands?.last?.mapping
        XCTAssertEqual(last?.value(for: "label")?.stringValue, "High (>50)")
        XCTAssertEqual(last?.value(for: "max_failures")?.intValue, 9999)
    }

    func testInlineFlowMappingValue() throws {
        let doc = try decode("point: {x: 1, y: 2}")
        let point = doc.root.mapping?.value(for: "point")?.mapping
        XCTAssertEqual(point?.value(for: "x")?.intValue, 1)
        XCTAssertEqual(point?.value(for: "y")?.intValue, 2)
    }

    func testFlowSequenceValue() throws {
        let doc = try decode("versions: [\"15.4\", \"15.3.2\", 7]")
        let versions = doc.root.mapping?.value(for: "versions")?.sequence
        XCTAssertEqual(versions?.count, 3)
        XCTAssertEqual(versions?[0].stringValue, "15.4")
        XCTAssertEqual(versions?[2].intValue, 7)
    }

    func testNestedFlowCollections() throws {
        let doc = try decode("outer: {inner: {a: 1}, list: [1, 2]}")
        let outer = doc.root.mapping?.value(for: "outer")?.mapping
        XCTAssertEqual(outer?.value(for: "inner")?.mapping?.value(for: "a")?.intValue, 1)
        XCTAssertEqual(outer?.value(for: "list")?.sequence?.count, 2)
    }

    func testCommaInsideQuotesDoesNotSplit() throws {
        let doc = try decode("band: {label: \"Med, Low\", n: 1}")
        let band = doc.root.mapping?.value(for: "band")?.mapping
        XCTAssertEqual(band?.value(for: "label")?.stringValue, "Med, Low")
        XCTAssertEqual(band?.value(for: "n")?.intValue, 1)
    }

    func testTrailingCommentAfterFlowMappingIsStripped() throws {
        let doc = try decode("band: {label: \"Pass\", n: 0}   # inline comment")
        let band = doc.root.mapping?.value(for: "band")?.mapping
        XCTAssertEqual(band?.value(for: "label")?.stringValue, "Pass")
    }

    func testMalformedFlowMappingFallsBackToStringScalar() throws {
        // No key/value structure inside the braces — degrade to a string
        // rather than fabricating entries or dropping the value.
        let doc = try decode("weird: {not yaml at all}")
        XCTAssertEqual(doc.root.mapping?.value(for: "weird")?.stringValue, "{not yaml at all}")
    }

    func testEmptyFlowFormsStillParse() throws {
        let doc = try decode("a: {}\nb: []")
        XCTAssertEqual(doc.root.mapping?.value(for: "a")?.mapping?.entries.count, 0)
        XCTAssertEqual(doc.root.mapping?.value(for: "b")?.sequence?.count, 0)
    }
}
