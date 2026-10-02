import XCTest
@testable import JamfReports

/// Config Doctor rows for what the YAML reader did not take as written.
final class ConfigDoctorReaderRowsTests: XCTestCase {

    private let fileManager = FileManager.default

    // MARK: - true/false keys read outside the decoder

    func testANonBooleanValueForAKeyReadOutsideTheDecoderIsStated() throws {
        let root = try ConfigLoader.rawMapping(fromYAML: """
            output:
              allow_absolute_paths: yes
            html:
              track_history: 1
            """)
        let rows = ConfigDoctorService.fileReadBooleanRows(root)
        XCTAssertEqual(rows.map(\.id), ["config.value.output.allow_absolute_paths",
                                        "config.value.html.track_history"])
        XCTAssertEqual(rows.map(\.severity), [.warn, .warn])
        XCTAssertEqual(rows.first?.detail,
                       "\"yes\" is not true or false, so the app reads it as false.")
        XCTAssertEqual(rows.last?.detail,
                       "\"1\" is not true or false, so the app reads it as false.")
    }

    func testTrueFalseAndAbsentKeysGiveNoRow() throws {
        for yaml in [
            "output:\n  allow_absolute_paths: \"true\"\nhtml:\n  track_history: False\n",
            "output:\n  allow_absolute_paths:\n",
            "other: 1\n",
        ] {
            let root = try ConfigLoader.rawMapping(fromYAML: yaml)
            XCTAssertEqual(ConfigDoctorService.fileReadBooleanRows(root), [], yaml)
        }
    }

    func testReaderRowsReadTheWorkspaceConfig() throws {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("jrc-doctor-reader-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("doctor", isDirectory: true)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }
        try "output:\n  allow_absolute_paths: on\n    stray: 1\n".write(
            to: workspace.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
        XCTAssertEqual(
            ConfigDoctorService.readerRows(profile: "doctor", workspaceRoot: root).map(\.id),
            ["config.parse_note.0", "config.value.output.allow_absolute_paths"])
        XCTAssertEqual(ConfigDoctorService.readerRows(profile: "absent", workspaceRoot: root), [])
    }

    // MARK: - Lines the reader skipped

    func testEachParseNoteIsAWarningNamingItsLine() throws {
        let notes = try YAMLCodec.decode("""
            thresholds:
              stale_device_days: 10
              stale_device_days: 45
            output:
                output_dir: Elsewhere
            """).parseNotes
        let rows = ConfigDoctorService.parseNoteRows(notes)
        XCTAssertEqual(rows, [
            DoctorRow(
                id: "config.parse_note.0", severity: .warn, title: "config.yaml line 2",
                detail: "\"stale_device_days\" is set again on line 3, and that value is the "
                    + "one read.",
                hint: "Remove one of the two lines."),
            DoctorRow(
                id: "config.parse_note.1", severity: .warn, title: "config.yaml line 5",
                detail: "Indented 4 spaces where 2 spaces were expected, so it was not read.",
                hint: "Line it up with the other keys of its block: two spaces per level."),
        ])
    }

    func testEveryKindOfNoteHasAHint() {
        let kinds: [YAMLCodec.ParseNote.Kind] = [
            .indentation(found: 1, expected: 0), .noKey, .tab(spaces: 0),
            .duplicateKey("a", readLine: 2), .blockScalar(key: "a", indicator: "|"), .orphanItems,
        ]
        let hints = ConfigDoctorService.parseNoteRows(kinds.map { .init(line: 1, kind: $0) })
            .compactMap(\.hint)
        XCTAssertEqual(hints.count, kinds.count)
        XCTAssertEqual(Set(hints).count, kinds.count)
    }

    func testMoreThanTwentyNotesEndInOneRowSayingHowManyMore() {
        let notes = (1...23).map { YAMLCodec.ParseNote(line: $0, kind: .noKey) }
        let rows = ConfigDoctorService.parseNoteRows(notes)
        XCTAssertEqual(rows.count, 21)
        XCTAssertEqual(rows.last?.id, "config.parse_note.more")
        XCTAssertEqual(rows.last?.severity, .warn)
        XCTAssertEqual(rows.last?.detail, "3 more lines in config.yaml were not read as written.")
        XCTAssertEqual(ConfigDoctorService.parseNoteRows(Array(notes.prefix(21))).last?.detail,
                       "1 more line in config.yaml was not read as written.")
        XCTAssertEqual(ConfigDoctorService.parseNoteRows(Array(notes.prefix(20))).count, 20)
    }
}
