import Foundation
import XCTest
@testable import JamfReports

/// #289: the picker opens at the workspace root, or the nearest folder above it that exists,
/// since a panel given a missing folder reopens wherever the last panel was.
final class WorkspaceFolderPickerTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jrc-picker-start-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testStartsAtAFolderThatExists() {
        XCTAssertEqual(WorkspaceFolderPicker.existingFolder(atOrAbove: root).path,
                       root.standardizedFileURL.path)
    }

    func testStartsAtTheNearestExistingAncestor() {
        let missing = root.appendingPathComponent("Jamf-Reports/inner", isDirectory: true)
        XCTAssertEqual(WorkspaceFolderPicker.existingFolder(atOrAbove: missing).path,
                       root.standardizedFileURL.path)
    }

    func testSkipsAFileWithTheRootsName() throws {
        let file = root.appendingPathComponent("Jamf-Reports")
        try Data().write(to: file)
        XCTAssertEqual(WorkspaceFolderPicker.existingFolder(atOrAbove: file).path,
                       root.standardizedFileURL.path)
    }
}
