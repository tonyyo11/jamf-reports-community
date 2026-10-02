import XCTest
@testable import JamfReports

/// Every line the YAML reader does not take as written is recorded with its line number, and
/// recording it never changes what the reader returns.
final class YAMLParseNoteTests: XCTestCase {

    private typealias Note = YAMLCodec.ParseNote

    private func notes(_ yaml: String) throws -> [Note] {
        try YAMLCodec.decode(yaml).parseNotes
    }

    func testAWellFormedFileHasNoNotes() throws {
        let yaml = """
        # comment
        columns:
          computer_name: Computer Name   # trailing comment
          email: "a: b # not a comment"
        security_agents:
        - name: Example Agent
          column: Agent - Status
          connected_value: Running
        custom_eas:
          - name: Example EA
            type: version
            current_versions: ["15.4", "15.3"]
        charts:
          compliance_trend:
            bands:
              - {label: "Pass", min_failures: 0, max_failures: 0, color: "#4472C4"}
        exceptions: []
        """
        XCTAssertEqual(try notes(yaml), [])
    }

    func testALineIndentedDeeperThanItsBlockIsNotedAndStillSkipped() throws {
        let yaml = """
        thresholds:
          stale_device_days: 30
             warning_disk_percent: 80
        output:
            output_dir: Elsewhere
        """
        XCTAssertEqual(try notes(yaml), [
            Note(line: 3, kind: .indentation(found: 5, expected: 2)),
            Note(line: 5, kind: .indentation(found: 4, expected: 2)),
        ])
        let root = try YAMLCodec.decode(yaml).root.mapping
        XCTAssertEqual(root?.value(for: "thresholds")?.mapping?.entries.map(\.key),
                       ["stale_device_days"])
        XCTAssertEqual(root?.value(for: "output")?.mapping?.entries.count, 0)
    }

    func testALineWithNoKeyIsNoted() throws {
        XCTAssertEqual(try notes("output:\n  output_dir: Reports\n  just some words\n"),
                       [Note(line: 3, kind: .noKey)])
    }

    /// A tab is read as if it were not there (unchanged); the note says so.
    func testTabIndentationIsNotedAndReadAsBefore() throws {
        let yaml = "thresholds:\n\tstale_device_days: 45\n"
        XCTAssertEqual(try notes(yaml), [Note(line: 2, kind: .tab(spaces: 0))])
        let root = try YAMLCodec.decode(yaml).root.mapping
        XCTAssertEqual(root?.value(for: "thresholds"), .scalar(.null))
        XCTAssertEqual(root?.value(for: "stale_device_days")?.intValue, 45)
    }

    func testADuplicateKeyIsNotedAtTheLineThatIsNotRead() throws {
        let yaml = """
        thresholds:
          stale_device_days: 10
          warning_disk_percent: 80
          stale_device_days: 45
        thresholds:
          cert_warning_days: 60
        band: {label: A, label: B}
        custom_eas:
          - name: First
            column: Example - Column
            name: Second
        """
        XCTAssertEqual(try notes(yaml), [
            Note(line: 1, kind: .duplicateKey("thresholds", readLine: 5)),
            Note(line: 2, kind: .duplicateKey("stale_device_days", readLine: 4)),
            Note(line: 7, kind: .duplicateKey("label", readLine: 7)),
            Note(line: 9, kind: .duplicateKey("name", readLine: 11)),
        ])
    }

    func testABlockValueIsOneNoteAndReadsAsItsIndicator() throws {
        let yaml = """
        branding:
          org_name: |
            Example Org
            - second line

          logo_path: logo.png
        custom_eas:
          - name: >-
              Folded
            column: Example - Column
        """
        XCTAssertEqual(try notes(yaml), [
            Note(line: 2, kind: .blockScalar(key: "org_name", indicator: "|")),
            Note(line: 8, kind: .blockScalar(key: "name", indicator: ">-")),
        ])
        let root = try YAMLCodec.decode(yaml).root.mapping
        let branding = root?.value(for: "branding")?.mapping
        XCTAssertEqual(branding?.value(for: "org_name")?.stringValue, "|")
        XCTAssertEqual(branding?.value(for: "logo_path")?.stringValue, "logo.png")
        let ea = root?.value(for: "custom_eas")?.sequence?.first?.mapping
        XCTAssertEqual(ea?.value(for: "name")?.stringValue, ">-")
        XCTAssertEqual(ea?.value(for: "column")?.stringValue, "Example - Column")
    }

    func testListItemsWithNoKeyAboveThemAreNoted() throws {
        let yaml = """
        some_key: real value
        - name: orphan
          column: Orphan - Status
        thresholds:
          stale_device_days: 60
        """
        XCTAssertEqual(try notes(yaml), [Note(line: 2, kind: .orphanItems)])
    }

    /// The repair of `key: []` followed by items is reported through `repairedKeys`, not twice.
    func testRepairedItemsAreNotAlsoNoted() throws {
        let document = try YAMLCodec.decode("security_agents: []\n- name: A\n  column: B\n")
        XCTAssertEqual(document.repairedKeys, ["security_agents"])
        XCTAssertEqual(document.parseNotes, [])
    }

    func testLineNumbersCountACRLFAsOneLineBreak() throws {
        XCTAssertEqual(try notes("output:\r\n  output_dir: Reports\r\n     extra: 1\r\n"),
                       [Note(line: 3, kind: .indentation(found: 5, expected: 2))])
    }

    func testTheShippedFilesHaveNoNotes() throws {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var files = ["dummy.yaml", "mobile-insights.yaml"].map { TestFixtures.dir("config/\($0)") }
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("config.example.yaml")
            if FileManager.default.fileExists(atPath: candidate.path) {
                files.append(candidate)
                break
            }
            dir = dir.deletingLastPathComponent()
        }
        XCTAssertEqual(files.count, 3, "config.example.yaml not found")
        for file in files {
            let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
            XCTAssertEqual(try notes(text), [], file.lastPathComponent)
        }
    }

    func testNotesReadAsLinesWithoutTheTypedValues() {
        XCTAssertEqual(
            Note(line: 4, kind: .indentation(found: 1, expected: 2)).display,
            "Line 4: indented 1 space where 2 spaces were expected, so it was not read")
        XCTAssertEqual(
            Note(line: 2, kind: .duplicateKey("stale_device_days", readLine: 9)).display,
            "Line 2: \"stale_device_days\" is set again on line 9, and that value is the one read")
        let long = Note(line: 1, kind: .duplicateKey(String(repeating: "k", count: 90) + "\u{7}",
                                                     readLine: 2)).detail
        XCTAssertFalse(long.contains("\u{7}"))
        XCTAssertTrue(long.contains(String(repeating: "k", count: 59) + "…"))
    }
}
