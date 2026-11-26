import XCTest
@testable import JamfReports

/// What reaches disk of the Protect sources wave E added: the keep-list only, never a guess.
final class ProtectReduceTests: XCTestCase {

    private func reduce(_ kind: String, _ json: String) -> String? {
        ReportEngine.reducingProtect(kind: kind, data: Data(json.utf8))
            .map { String(decoding: $0, as: UTF8.self) }
    }

    func testSignatureVersionsKeepIDAndCreatedOnly() throws {
        let raw = try Data(contentsOf: TestFixtures.dir(
            "protect-wave-e/protect-signature-versions-raw.json"))
        let reduced = try XCTUnwrap(ReportEngine.reducingProtect(
            kind: ReportEngine.protectSignatureVersionsKind, data: raw))
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: reduced) as? [[String: Any]])
        XCTAssertFalse(rows.isEmpty)
        for row in rows { XCTAssertEqual(row.keys.sorted(), ["created", "id"]) }
    }

    func testTheInstallerKeepsItsVersionAsOneRow() throws {
        let raw = try Data(contentsOf: TestFixtures.dir(
            "protect-wave-e/protect-installer-raw.json"))
        let reduced = try XCTUnwrap(ReportEngine.reducingProtect(
            kind: ReportEngine.protectInstallerKind, data: raw))
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: reduced) as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.keys.sorted(), ["installerVersion"])
    }

    func testANestedOrUnlistedValueIsDropped() {
        XCTAssertEqual(
            reduce(ReportEngine.protectSignatureVersionsKind,
                   #"[{"id":{"n":1},"created":"2026-11-20","extra":"x"}]"#),
            #"[{"created":"2026-11-20"}]"#)
    }

    /// A wrong shape is not saved as an empty list: that would read as measured.
    func testARowThatIsNotAnObjectOrHoldsNoKeptKeyIsNotSaved() {
        XCTAssertNil(reduce(ReportEngine.protectSignatureVersionsKind, #"[1, 2]"#))
        XCTAssertNil(reduce(ReportEngine.protectSignatureVersionsKind, #"[{"id":"1"}, "x"]"#))
        XCTAssertNil(reduce(ReportEngine.protectInstallerKind, #"{"foo":1}"#))
        XCTAssertNil(reduce(ReportEngine.protectSignatureVersionsKind, #"[{"id":["1"]}]"#))
    }

    func testTheProtectMatrixRunsTheTwoNewCommandsLast() {
        let matrix = ReportEngine.protectCommandMatrix(profile: "p")
        XCTAssertEqual(matrix.map(\.kind), ReportEngine.protectReportKinds
            + [ReportEngine.protectSignatureVersionsKind, ReportEngine.protectInstallerKind])
        XCTAssertEqual(Array(matrix[4].args.dropFirst(3)),
                       ["threat-prevention-versions", "list", "--output", "json"])
        XCTAssertEqual(Array(matrix[5].args.dropFirst(3)),
                       ["downloads", "summary", "--output", "json"])
    }

    func testAnEmptyAnswerIsAnEmptyList() {
        for json in ["null", "[]"] {
            XCTAssertEqual(reduce(ReportEngine.protectSignatureVersionsKind, json), "[]", json)
            XCTAssertEqual(reduce(ReportEngine.protectInstallerKind, json), "[]", json)
        }
    }

    func testAnyOtherShapeIsNotSaved() {
        XCTAssertNil(reduce(ReportEngine.protectSignatureVersionsKind, #"{"id":"1"}"#),
                     "only the installer answer is a single object")
        XCTAssertNil(reduce(ReportEngine.protectInstallerKind, #""text""#))
        XCTAssertNil(reduce(ReportEngine.protectInstallerKind, "not json"))
        XCTAssertNil(reduce("protect-computers", "[]"), "a kind with no keep-list")
    }
}
