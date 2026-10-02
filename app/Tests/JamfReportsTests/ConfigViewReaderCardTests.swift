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

    func testParseNotesAreListedOneLineEach() {
        let text = ConfigView.readerCardText(keys: [], notes: [
            "Line 3: no \"key: value\" on this line, so it was not read",
            "Line 9: a tab in the indentation; read as indented 0 spaces",
        ])
        XCTAssertEqual(text.title, "Some lines in config.yaml were not read as written")
        XCTAssertEqual(text.pill, "2 lines")
        XCTAssertEqual(text.summary, "The app did not read the lines below as written. "
            + "Correct them in config.yaml.")
        XCTAssertEqual(text.detail, "Line 3: no \"key: value\" on this line, so it was not read\n"
            + "Line 9: a tab in the indentation; read as indented 0 spaces")
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
}
