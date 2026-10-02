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
        \t# a comment indented with a tab
        """
        XCTAssertEqual(try notes(yaml), [])
    }

    /// A block takes its indent from its first line, at any width; a block indented 4 is read.
    func testALineIndentedDeeperThanItsSiblingsIsNotedAndAWiderBlockIsRead() throws {
        let yaml = """
        thresholds:
          stale_device_days: 30
             warning_disk_percent: 80
        output:
            output_dir: Elsewhere
        """
        XCTAssertEqual(try notes(yaml), [Note(line: 3, kind: .indentation(found: 5, expected: 2))])
        let root = try YAMLCodec.decode(yaml).root.mapping
        XCTAssertEqual(root?.value(for: "thresholds")?.mapping?.entries.map(\.key),
                       ["stale_device_days"])
        XCTAssertEqual(root?.value(for: "output")?.mapping?.value(for: "output_dir")?.stringValue,
                       "Elsewhere")
    }

    /// The expected column in a note is where the line's siblings sit, not two past the key.
    func testALineThatDisagreesWithItsSiblingsNamesTheirColumn() throws {
        let yaml = """
        thresholds:
            stale_device_days: 45
              warning_disk_percent: 80
          cert_warning_days: 60
        sheets:
          skip:
            - Example Sheet
             - Second Sheet
        output:
          output_dir: Reports
        """
        XCTAssertEqual(try notes(yaml), [
            Note(line: 3, kind: .indentation(found: 6, expected: 4)),
            Note(line: 4, kind: .indentation(found: 2, expected: 4)),
            Note(line: 8, kind: .indentation(found: 5, expected: 4)),
        ])
        let root = try YAMLCodec.decode(yaml).root.mapping
        XCTAssertEqual(root?.value(for: "thresholds")?.mapping?.entries.map(\.key),
                       ["stale_device_days"])
        XCTAssertEqual(root?.value(for: "sheets")?.mapping?.value(for: "skip")?.sequence,
                       [.scalar(.string("Example Sheet"))])
        XCTAssertEqual(root?.value(for: "output")?.mapping?.value(for: "output_dir")?.stringValue,
                       "Reports")
    }

    /// 2 spaces at the top and 4 inside one block, a list 4 under its key, and a list item's
    /// keys under `-   ` read as the 2-space file does.
    func testMixedWidthsReadAsTheTwoSpaceFile() throws {
        let twoSpace = """
        thresholds:
          stale_device_days: 45
        custom_eas:
          - name: Example EA
            column: Example - Column
            current_versions:
              - "15.4"
        output:
          output_dir: Reports
        """
        let mixed = """
        thresholds:
          stale_device_days: 45
        custom_eas:
            -   name: Example EA
                column: Example - Column
                current_versions:
                        - "15.4"
        output:
                output_dir: Reports
        """
        let expected = try YAMLCodec.decode(twoSpace)
        let actual = try YAMLCodec.decode(mixed)
        XCTAssertEqual(actual.root, expected.root)
        XCTAssertEqual(actual.parseNotes, [])
    }

    /// Before, an empty `current_versions:` took the outer list's next item as its value, and an
    /// empty `name:` took the item's other keys as its value.
    func testAnEmptyKeyIsNullWhenNothingDeeperFollows() throws {
        let stolen = try YAMLCodec.decode(
            "custom_eas:\n  - name: A\n    current_versions:\n  - name: B\n")
        let items = stolen.root.mapping?.value(for: "custom_eas")?.sequence
        XCTAssertEqual(items?.count, 2)
        XCTAssertEqual(items?.first?.mapping?.value(for: "current_versions"), .scalar(.null))
        XCTAssertEqual(items?.last?.mapping?.value(for: "name")?.stringValue, "B")

        let swallowed = try YAMLCodec.decode("custom_eas:\n  - name:\n    column: B\n")
        let item = swallowed.root.mapping?.value(for: "custom_eas")?.sequence?.first?.mapping
        XCTAssertEqual(item?.value(for: "name"), .scalar(.null))
        XCTAssertEqual(item?.value(for: "column")?.stringValue, "B")
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
        // A flow mapping that falls back to text takes its notes with it.
        XCTAssertEqual(try notes("weird: {a: 1, a: 2, not a pair}\n"), [])
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

    /// The encoder writes a list inside a list as a bare `-` with the items under it.
    func testABareDashItemWrittenByTheEncoderReadsBack() throws {
        let value = YAMLCodec.YAMLValue.sequence([
            .sequence([.scalar(.string("a")), .scalar(.int(1))]),
            .sequence([.mapping(.init(entries: [
                .init(key: "name", value: .scalar(.string("Example"))),
                .init(key: "column", value: .scalar(.string("Example - Column"))),
            ]))]),
            .mapping(.init(entries: [])),
            .mapping(.init(entries: [.init(key: "name", value: .scalar(.string("Last")))])),
        ])
        var document = YAMLCodec.emptyDocument()
        document.root = .mapping(.init(entries: [.init(key: "matrix", value: value)]))
        let text = try YAMLCodec.encode(document, replacingTopLevelKeys: ["matrix"])
        XCTAssertTrue(text.contains("\n  -\n"), text)
        let read = try YAMLCodec.decode(text)
        XCTAssertEqual(read.root, document.root)
        XCTAssertEqual(read.parseNotes, [])
    }

    /// A save of a CRLF file used to write an empty line after every line it kept.
    func testEncodingACRLFFileKeepsOneLineBreakPerLine() throws {
        var document = try YAMLCodec.decode(
            "output:\r\n  output_dir: Reports\r\nhtml:\r\n  track_history: false\r\n")
        var root = try XCTUnwrap(document.root.mapping)
        root.set("output", value: .mapping(.init(entries: [
            .init(key: "output_dir", value: .scalar(.string("Edited"))),
        ])))
        document.root = .mapping(root)
        XCTAssertEqual(try YAMLCodec.encode(document, replacingTopLevelKeys: ["output"]),
                       "output:\n  output_dir: Edited\nhtml:\n  track_history: false\n")
    }

    func testABareDashTakesTheMappingUnderIt() throws {
        let read = try YAMLCodec.decode("""
            security_agents:
              -
                name: First Agent
                column: First Agent - Status
              -
              - name: Third Agent
            """)
        XCTAssertEqual(read.root.mapping?.value(for: "security_agents"), .sequence([
            .mapping(.init(entries: [
                .init(key: "name", value: .scalar(.string("First Agent"))),
                .init(key: "column", value: .scalar(.string("First Agent - Status"))),
            ])),
            .scalar(.null),
            .mapping(.init(entries: [.init(key: "name", value: .scalar(.string("Third Agent")))])),
        ]))
        XCTAssertEqual(read.parseNotes, [])
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

        // A list item's first key is not where stray items attach, as before.
        let item = "custom_eas:\n  - current_versions: []\n    - \"15.4\"\n    name: A\n"
        XCTAssertEqual(try notes(item), [Note(line: 3, kind: .orphanItems)])
        let ea = try YAMLCodec.decode(item).root.mapping?.value(for: "custom_eas")?.sequence?
            .first?.mapping
        XCTAssertEqual(ea?.value(for: "current_versions"), .sequence([]))
        XCTAssertEqual(ea?.value(for: "name")?.stringValue, "A")
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

    /// `''` inside single quotes is one `'`, as in YAML: a column header such as `User's Name`.
    func testADoubledSingleQuoteReadsAsOne() throws {
        let root = try YAMLCodec.decode("""
            columns:
              full_name: 'User''s Name'
            band: {'it''s': 'a''b'}
            """).root.mapping
        XCTAssertEqual(root?.value(for: "columns")?.mapping?.value(for: "full_name")?.stringValue,
                       "User's Name")
        XCTAssertEqual(root?.value(for: "band")?.mapping?.value(for: "it's")?.stringValue, "a'b")
    }

    /// A `[` or `{` not closed on its line reads as text; its first line says so.
    func testAFlowListNotClosedOnItsLineIsNotedOnItsFirstLine() throws {
        let yaml = "sheets:\n  skip: [Sheet One,\n    Sheet Two]\ntitle: [Draft] Report\n"
        XCTAssertEqual(try notes(yaml), [
            Note(line: 2, kind: .unclosedFlow),
            Note(line: 3, kind: .indentation(found: 4, expected: 2)),
        ])
        XCTAssertEqual(try YAMLCodec.decode(yaml).root.mapping?.value(for: "title")?.stringValue,
                       "[Draft] Report")
    }

    /// `---` opening the file marks the start of the document; elsewhere it is still noted.
    func testADocumentStartMarkerAtTheTopIsNotNoted() throws {
        for yaml in ["---\nthresholds:\n  stale_device_days: 45\n",
                     "# config\n--- # start\nthresholds:\n  stale_device_days: 45\n"] {
            let document = try YAMLCodec.decode(yaml)
            XCTAssertEqual(document.parseNotes, [], yaml)
            XCTAssertEqual(document.root.mapping?.value(for: "thresholds")?.mapping?
                .value(for: "stale_device_days")?.intValue, 45)
        }
        XCTAssertEqual(try notes("a: 1\n---\nb: 2\n"), [Note(line: 2, kind: .noKey)])
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
