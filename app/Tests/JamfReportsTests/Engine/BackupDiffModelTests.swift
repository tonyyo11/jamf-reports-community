import XCTest
@testable import JamfReports

final class BackupDiffModelTests: XCTestCase {

    private func payload(_ entries: [(String, String, String, String, String)]) -> Data {
        let objects = entries.map { entry in
            [
                "change": entry.0, "field": entry.1, "name": entry.2,
                "old_value": entry.3, "new_value": entry.4,
                "resource": "patch-titles",
            ]
        }
        return try! JSONSerialization.data(withJSONObject: objects)
    }

    // MARK: - Leaf diffing

    func testReportsOnlyTheChangedLeaf() {
        let old = #"{"a":1,"b":2,"c":{"d":"x"}}"#
        let new = #"{"a":1,"b":2,"c":{"d":"y"}}"#
        let result = BackupDiffModel.leafChanges(old: old, new: new)
        XCTAssertFalse(result.opaque)
        XCTAssertEqual(result.changes.count, 1)
        XCTAssertEqual(result.changes.first?.path, "c.d")
        XCTAssertEqual(result.changes.first?.old, "x")
        XCTAssertEqual(result.changes.first?.new, "y")
    }

    func testIdenticalValuesProduceNoChanges() {
        let json = #"{"a":1,"b":[1,2,3]}"#
        XCTAssertTrue(BackupDiffModel.leafChanges(old: json, new: json).changes.isEmpty)
    }

    /// The regression that shaped the design: Jamf version lists are
    /// newest-first, so a new release PREPENDS an element. An index-wise diff
    /// reported one added version as hundreds of modified ones.
    func testPrependedArrayElementIsOneAdditionNotAWholeShift() {
        let old = #"{"versions":[{"software_version":"2.0"},{"software_version":"1.0"}]}"#
        let new = #"""
        {"versions":[{"software_version":"3.0"},{"software_version":"2.0"},{"software_version":"1.0"}]}
        """#
        let result = BackupDiffModel.leafChanges(old: old, new: new)
        XCTAssertEqual(result.changes.count, 1, "a prepend must not renumber the tail")
        XCTAssertEqual(result.changes.first?.path, "versions added")
        XCTAssertEqual(result.changes.first?.new, "1: 3.0")
    }

    func testRemovedArrayElementIsReported() {
        let old = #"{"versions":["a","b"]}"#
        let new = #"{"versions":["a"]}"#
        let result = BackupDiffModel.leafChanges(old: old, new: new)
        XCTAssertEqual(result.changes.first?.path, "versions removed")
        XCTAssertEqual(result.changes.first?.old, "1: b")
    }

    func testReorderingAnArrayIsNotAChange() {
        let old = #"{"v":["a","b","c"]}"#
        let new = #"{"v":["c","a","b"]}"#
        XCTAssertTrue(BackupDiffModel.leafChanges(old: old, new: new).changes.isEmpty)
    }

    func testAddedAndRemovedKeysAreDistinguished() {
        let result = BackupDiffModel.leafChanges(old: #"{"a":1}"#, new: #"{"b":2}"#)
        let paths = Set(result.changes.map(\.path))
        XCTAssertTrue(paths.contains("a removed"))
        XCTAssertTrue(paths.contains("b added"))
    }

    func testNonJSONValuesFallBackToWholeValueReplacement() {
        let result = BackupDiffModel.leafChanges(old: "plain text", new: "other text")
        XCTAssertTrue(result.opaque)
        XCTAssertEqual(result.changes.count, 1)
        XCTAssertEqual(result.changes.first?.new, "other text")
    }

    func testBooleansRenderAsTrueFalseNotOneZero() {
        let result = BackupDiffModel.leafChanges(old: #"{"f":true}"#, new: #"{"f":false}"#)
        XCTAssertEqual(result.changes.first?.old, "true")
        XCTAssertEqual(result.changes.first?.new, "false")
    }

    func testChangesAreCappedAndFlaggedTruncated() {
        var oldDict: [String: Int] = [:]
        var newDict: [String: Int] = [:]
        for index in 0..<(BackupDiffModel.maxChangesPerItem + 10) {
            oldDict["k\(index)"] = 0
            newDict["k\(index)"] = 1
        }
        let old = String(data: try! JSONSerialization.data(withJSONObject: oldDict), encoding: .utf8)!
        let new = String(data: try! JSONSerialization.data(withJSONObject: newDict), encoding: .utf8)!
        let result = BackupDiffModel.leafChanges(old: old, new: new)
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.changes.count, BackupDiffModel.maxChangesPerItem)
    }

    // MARK: - Parsing and grouping

    func testParseReturnsNilForNonArrayPayload() {
        XCTAssertNil(BackupDiffModel.parse(Data(#"{"error":"nope"}"#.utf8)))
        XCTAssertNil(BackupDiffModel.parse(Data("Loading source: ./x".utf8)))
    }

    func testParseAcceptsEmptyArray() {
        XCTAssertEqual(BackupDiffModel.parse(Data("[]".utf8))?.count, 0)
    }

    func testObjectsWithIdenticalChangesCollapseIntoOneGroup() throws {
        let old = #"{"versions":["1.0"]}"#
        let new = #"{"versions":["2.0","1.0"]}"#
        let data = payload([
            ("modified", "versions", "Excel", old, new),
            ("modified", "versions", "Outlook", old, new),
            ("modified", "versions", "OneNote", old, new),
        ])
        let items = try XCTUnwrap(BackupDiffModel.parse(data))
        let groups = BackupDiffModel.group(items)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.names, ["Excel", "OneNote", "Outlook"])
    }

    func testDifferentChangesStayInSeparateGroupsOrderedBySize() throws {
        let shared = (#"{"versions":["1.0"]}"#, #"{"versions":["2.0","1.0"]}"#)
        let unique = (#"{"versions":["9.0"]}"#, #"{"versions":["9.1","9.0"]}"#)
        let data = payload([
            ("modified", "versions", "Solo", unique.0, unique.1),
            ("modified", "versions", "Excel", shared.0, shared.1),
            ("modified", "versions", "Outlook", shared.0, shared.1),
        ])
        let groups = BackupDiffModel.group(try XCTUnwrap(BackupDiffModel.parse(data)))
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.first?.names.count, 2, "largest group must sort first")
        XCTAssertEqual(groups.last?.names, ["Solo"])
    }

    func testHeadlineCountsObjectsAndResources() throws {
        let data = payload([
            ("modified", "versions", "A", #"{"v":1}"#, #"{"v":2}"#),
            ("modified", "versions", "B", #"{"v":1}"#, #"{"v":3}"#),
        ])
        let items = try XCTUnwrap(BackupDiffModel.parse(data))
        XCTAssertEqual(BackupDiffModel.headline(items), "2 objects changed across 1 resource")
        XCTAssertEqual(BackupDiffModel.headline([]), "No differences")
    }

    func testPlainTextRenderingIncludesPathsAndObjectNames() throws {
        let data = payload([
            ("modified", "general", "Excel", #"{"v":"1"}"#, #"{"v":"2"}"#),
        ])
        let groups = BackupDiffModel.group(try XCTUnwrap(BackupDiffModel.parse(data)))
        let text = BackupDiffModel.plainText(groups)
        XCTAssertTrue(text.contains("patch-titles"))
        XCTAssertTrue(text.contains("v: 1 → 2"))
        XCTAssertTrue(text.contains("Excel"))
    }
}
