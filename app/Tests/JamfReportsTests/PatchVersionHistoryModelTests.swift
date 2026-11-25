import XCTest
@testable import JamfReports

/// What the Version History card lists for one title, and which notes it shows.
final class PatchVersionHistoryModelTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private func day(_ offset: Int) -> Date { start.addingTimeInterval(Double(offset) * 86_400) }

    private func versions(_ latest: [(Int, String)], id: String = "1") -> [VersionVelocity] {
        let days = latest.map { offset, version in
            PatchVelocityBuilder.DayRows(date: day(offset), rows: [PatchStatusRow(
                title: "T", id: id, onLatest: 50, onOther: 50, total: 100, latest: version,
                compliancePct: "")])
        }
        return PatchVelocityBuilder.versions(
            days: days, lookup: ReleaseDateLookup(versionRows: [], releaseFilesNewestFirst: []))
    }

    private func sidecar(_ rows: [PatchVersionDate]) -> VersionDatesRead {
        .rows(rows, stamp: "20261125T060000", bytes: Data())
    }

    func testUnlistedVersionsAreNewestFirstAndAReturningVersionLeads() {
        let model = PatchVersionHistoryModel(
            titleId: "1", versions: versions([(0, "A"), (1, "B"), (2, "A")]), dates: .absent)
        XCTAssertEqual(model.rows.map(\.version), ["A", "B"])
        XCTAssertEqual(model.rows.first?.windows, 2)
    }

    func testListedVersionsFollowTheDefinitionsAfterUnlistedOnes() {
        let model = PatchVersionHistoryModel(
            titleId: "1", versions: versions([(0, "C")]),
            dates: sidecar([
                PatchVersionDate(titleId: "1", title: "T", version: "B", absoluteOrderId: "0"),
                PatchVersionDate(titleId: "1", title: "T", version: "A", absoluteOrderId: "1"),
            ]))
        XCTAssertEqual(model.rows.map(\.version), ["C", "B", "A"])
        XCTAssertNil(model.rows.last?.outcome, "never the latest in this history")
    }

    func testARepeatedVersionKeepsDistinctRowIdentities() {
        let row = PatchVersionDate(titleId: "1", title: "T", version: "A", absoluteOrderId: "0")
        let model = PatchVersionHistoryModel(titleId: "1", versions: [], dates: sidecar([row, row]))
        XCTAssertEqual(model.rows.count, 2)
        XCTAssertEqual(Set(model.rows.map(\.id)).count, 2)
    }

    func testTheFleetFigureShowsOnlyWithWindows() {
        XCTAssertFalse(PatchVersionHistoryModel(titleId: "1", versions: [], dates: .absent)
            .showsFleetFigure)
        XCTAssertTrue(PatchVersionHistoryModel(
            titleId: "1", versions: versions([(0, "A")]), dates: .absent).showsFleetFigure)
    }

    func testAStaleTitleChoiceIsCleared() {
        let titles = [PatchStatusRow(title: "T", id: "1", onLatest: 1, onOther: 0, total: 1,
                                     latest: "1.0", compliancePct: "")]
        XCTAssertEqual(PatchView.validTitle("1", in: titles), "1")
        XCTAssertNil(PatchView.validTitle("2", in: titles))
        XCTAssertNil(PatchView.validTitle(nil, in: titles))
    }

    func testEachNote() {
        let cases: [(VersionDatesRead, PatchVersionHistoryModel.Note)] = [
            (.absent, .notRead),
            (.unreadable("x"), .couldNotBeRead),
            (sidecar([PatchVersionDate(titleId: "2", version: "A")]), .titleNotRead),
            (sidecar([PatchVersionDate(titleId: "1", noVersions: true)]), .noVersions),
            (sidecar([PatchVersionDate(titleId: "1", version: "A", staleSince: "20261120T060000")]),
             .datesFrom(PatchReleaseDateService.stampDate("20261120T060000") ?? .distantPast)),
            (sidecar((0..<100).map { PatchVersionDate(titleId: "1", version: "v\($0)") }), .newest100),
        ]
        for (dates, note) in cases {
            let model = PatchVersionHistoryModel(titleId: "1", versions: [], dates: dates)
            XCTAssertTrue(model.notes.contains(note), "\(note) missing from \(model.notes)")
        }
    }
}
