import XCTest
@testable import JamfReports

/// The Config screen's healed-keys card also lists the lines the reader did not take as written.
@MainActor
final class ConfigViewReaderCardTests: XCTestCase {

    func testRepairedKeysAloneReadAsBefore() {
        let text = ConfigView.readerCardText(keys: ["custom_eas", "security_agents"], notes: [])
        XCTAssertEqual(text.title, "Config auto-healed on load")
        XCTAssertEqual(text.pill, "2 keys")
        XCTAssertEqual(text.summary, "The following YAML keys had malformed sequence items that "
            + "were auto-reattached. The file reads correctly but is still malformed on disk. "
            + "Save from this screen to persist the cleanup.")
        XCTAssertEqual(text.detail, "custom_eas, security_agents")
    }

    /// The notes come from the reader, as `refreshEngineParseStatus` passes them.
    func testParseNotesAreListedOneLineEach() throws {
        let yaml = "output:\n  output_dir: Reports\n  just some words\n"
            + "thresholds:\n\tstale_device_days: 30\n"
        let notes = try YAMLCodec.decode(yaml).parseNotes.map(\.display)
        let text = ConfigView.readerCardText(keys: [], notes: notes)
        XCTAssertEqual(text.title, "Some lines in config.yaml were not read as written")
        XCTAssertEqual(text.pill, "2 lines")
        XCTAssertEqual(text.summary, "The app did not read the lines below as written. "
            + "Correct them in config.yaml.")
        XCTAssertEqual(text.detail, "Line 3: no \"key: value\" on this line, so it was not read\n"
            + "Line 5: a tab in the indentation, which YAML does not allow; read as indented "
            + "0 spaces")
    }

    func testBothKindsShareTheCardAndLongNoteListsEndInACount() {
        let notes = (1...23).map { "Line \($0): no \"key: value\" on this line" }
        let text = ConfigView.readerCardText(keys: ["custom_eas"], notes: notes)
        XCTAssertEqual(text.title, "Config auto-healed on load")
        XCTAssertEqual(text.pill, "1 key · 23 lines")
        XCTAssertTrue(text.summary.hasSuffix("Correct them in config.yaml."))
        let lines = text.detail.components(separatedBy: "\n")
        XCTAssertEqual(lines.first, "custom_eas")
        XCTAssertEqual(lines.count, 22)
        XCTAssertEqual(lines.last, "…and 3 more")
    }

    func testASaveThatLeftAListBlockAsTypedSaysWhy() throws {
        XCTAssertNil(ConfigView.saveNotice(changedOnDisk: false, report: ConfigSaveReport()))
        let notice = try XCTUnwrap(ConfigView.saveNotice(
            changedOnDisk: false,
            report: ConfigSaveReport(keptBlocks: ["custom_eas", "security_agents"])))
        XCTAssertEqual(notice.title, "Saved with notes")
        XCTAssertEqual(notice.lines, [
            "Save left custom_eas as typed: it is not a list, so this screen reads no entries "
                + "from it and did not write the Custom EAs tab. Write each entry as a "
                + "\"- name:\" list item to edit it here.",
            "Save left security_agents as typed: it is not a list, so this screen reads no "
                + "entries from it and did not write the Security Agents tab. Write each entry "
                + "as a \"- name:\" list item to edit it here.",
        ])
    }

    func testASaveThatDroppedCommentsNamesTheCopy() throws {
        var report = ConfigSaveReport(droppedComments: true)
        XCTAssertNil(ConfigView.saveNotice(changedOnDisk: false, report: report),
                     "no copy, nothing to point at")
        report.backupName = "config.yaml.bak-20261002-101500"
        let notice = try XCTUnwrap(ConfigView.saveNotice(changedOnDisk: false, report: report))
        XCTAssertEqual(notice.lines, [
            "Comments inside the blocks this screen edits are not kept. A copy of the file as "
                + "it was is at config.yaml.bak-20261002-101500.",
        ])
    }

    func testASaveThatDroppedUnreadLinesNamesTheSameCopy() throws {
        let report = ConfigSaveReport(
            droppedComments: true, droppedUnreadLines: true,
            backupName: "config.yaml.bak-20261002-101500")
        let notice = try XCTUnwrap(ConfigView.saveNotice(changedOnDisk: false, report: report))
        XCTAssertEqual(notice.lines, [
            "Comments inside the blocks this screen edits are not kept. A copy of the file as "
                + "it was is at config.yaml.bak-20261002-101500.",
            "Lines this screen could not read inside the blocks it edits are not kept. A copy "
                + "of the file as it was is at config.yaml.bak-20261002-101500.",
        ])
    }

    func testARefusedSaveSaysWhyAndWhatReloadDiscards() throws {
        XCTAssertNil(ConfigView.saveNotice(changedOnDisk: false, report: nil))
        let notice = try XCTUnwrap(ConfigView.saveNotice(changedOnDisk: true, report: nil))
        XCTAssertEqual(notice.title, "Not saved")
        XCTAssertEqual(notice.lines, [
            "config.yaml changed on disk since this screen loaded it. Reload reads the file "
                + "again and discards the changes you have not saved here.",
        ])
    }
}
