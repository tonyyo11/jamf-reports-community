import XCTest
@testable import JamfReports

/// The "Patch Version History" workbook tab, its HTML section and the demo card's data.
final class PatchVersionHistorySheetTests: XCTestCase {

    private var roots: [URL] = []

    override func tearDown() {
        roots.forEach { try? FileManager.default.removeItem(at: $0) }
        roots = []
        super.tearDown()
    }

    private func dataDir(versions: Bool, sidecar: String? = nil) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pvh-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        let dir = root.appendingPathComponent("data", isDirectory: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let folder = dir.appendingPathComponent("patch-status")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if versions {
            for (offset, on) in [(0, 10), (1, 95)] {
                let date = Date().addingTimeInterval(Double(offset - 5) * 86_400)
                let json = #"[{"title":"Firefox","id":"7","on_latest":\#(on),"on_other":0,"#
                    + #""total":100,"latest":"130.0","compliance_pct":""}]"#
                try Data(json.utf8).write(to: folder.appendingPathComponent(
                    "patch-status_\(formatter.string(from: date)).json"))
            }
        }
        if let sidecar {
            let side = dir.appendingPathComponent(PatchReleaseDateService.versionDatesKind)
            try FileManager.default.createDirectory(at: side, withIntermediateDirectories: true)
            try Data(sidecar.utf8).write(
                to: side.appendingPathComponent("patch-version-dates_20261125T060000.json"))
        }
        return dir
    }

    private func texts(_ dash: CoreDashboard) throws -> [String] {
        let cells = try XCTUnwrap(dash.workbook.sheet(named: "Patch Version History")?.dedupedCells)
        return cells.compactMap { if case .string(let s) = $0.value { s } else { nil } }
    }

    private func dashboard(_ dir: URL) throws -> CoreDashboard {
        CoreDashboard(config: try ConfigLoader.loadFromString(""), dataDir: dir, workbook: Workbook())
    }

    func testTheTabHasOneRowPerWindowAndTheFleetFigure() throws {
        let sidecar = #"[{"title_id":"7","title":"Firefox","version":"130.0","#
            + #""release_date":"2026-01-01T00:00:00Z"},{"title_id":"7","version":"129.0"}]"#
        let dash = try dashboard(try dataDir(versions: true, sidecar: sidecar))
        try dash.writePatchVersionHistory()
        let all = try texts(dash)
        for header in ["Title", "Version", "Released", "Window start", "Window end",
                       "Days to 50%", "Days to 90%", "Outcome"] {
            XCTAssertTrue(all.contains(header), header)
        }
        XCTAssertTrue(all.contains("130.0"))
        XCTAssertTrue(all.contains("Reached 90%"))
        XCTAssertTrue(all.contains("1 defined version had no window in the history and is not listed."),
                      "\(all)")
        XCTAssertTrue(all.contains("Last 90 days, counted in version windows:"))
    }

    func testTheFooterSaysWhenTheSidecarIsMissingOrUnreadable() throws {
        let missing = try dashboard(try dataDir(versions: true))
        try missing.writePatchVersionHistory()
        XCTAssertTrue(try texts(missing).contains {
            $0.hasPrefix("Release dates not read") })
        let broken = try dashboard(try dataDir(versions: true, sidecar: "not json"))
        try broken.writePatchVersionHistory()
        XCTAssertTrue(try texts(broken).contains("Release dates could not be read."))
    }

    func testNoHistoryIsTheLiteralSkipLine() throws {
        let dash = try dashboard(try dataDir(versions: false))
        XCTAssertThrowsError(try dash.writePatchVersionHistory()) { error in
            guard let skippable = error as? any SheetSkippable else {
                return XCTFail("not skippable: \(error)")
            }
            XCTAssertEqual(SheetRegistry.skipLine(sheet: "Patch Version History", error: skippable),
                           "[skip] Patch Version History: no patch-status history")
        }
    }

    /// `count` titles, each with one window that opened 30 days ago at 10% and reached 95% on
    /// day `index + 1`, released when the window opened (dated from today: the builder reads `Date()`).
    private func crossedVersions(_ count: Int, withDates: Bool = true) -> [VersionVelocity] {
        let open = Date().addingTimeInterval(-30 * 86_400)
        return (0..<count).flatMap { index -> [VersionVelocity] in
            let id = "\(index)"
            let rows = [(0, 10), (index + 1, 95)].map { offset, on in
                PatchVelocityBuilder.DayRows(
                    date: open.addingTimeInterval(Double(offset) * 86_400),
                    rows: [PatchStatusRow(title: "Title \(id)", id: id, onLatest: on, onOther: 0,
                                          total: 100, latest: "1.0", compliancePct: "")])
            }
            let dated = withDates ? [PatchVersionDate(
                titleId: id, title: "Title \(id)", version: "1.0",
                releaseDate: ISO8601DateFormatter().string(from: open))] : []
            return PatchVelocityBuilder.versions(
                days: rows, lookup: ReleaseDateLookup(versionRows: dated, releaseFilesNewestFirst: []))
        }
    }

    private func report() throws -> HtmlReport {
        HtmlReport(config: try ConfigLoader.loadFromString(""), dataDir: try dataDir(versions: false))
    }

    func testTheHTMLSectionListsTheSlowestWindowsFirstInTheCappedTable() throws {
        let block = try report().buildPatchVersionHistory(
            crossedVersions(12), dates: .rows([], stamp: "20261125T060000", bytes: Data()))
        XCTAssertTrue(block.isShown)
        XCTAssertTrue(block.html.contains("Slowest to 90% in the last 90 days (12)"), block.html)
        let slowest = try XCTUnwrap(block.html.range(of: "Title 11"))
        let fastest = try XCTUnwrap(block.html.range(of: "Title 0<"))
        XCTAssertLessThan(slowest.lowerBound, fastest.lowerBound, "slowest first")
        XCTAssertTrue(block.html.contains("Show all 12"), block.html)
    }

    func testTheHTMLSectionNamesAMissingOrUnreadableReleaseDatesFile() throws {
        let versions = crossedVersions(2, withDates: false)
        let absent = try report().buildPatchVersionHistory(versions, dates: .absent)
        XCTAssertTrue(absent.html.contains("Release dates not read"), absent.html)
        let unreadable = try report().buildPatchVersionHistory(versions, dates: .unreadable("x"))
        XCTAssertTrue(unreadable.html.contains("Release dates could not be read."), unreadable.html)
    }

    func testTheHTMLSectionIsLeftOutOnlyWhenNoWindowReached90() throws {
        let read = VersionDatesRead.rows([], stamp: "20261125T060000", bytes: Data())
        let open = Date().addingTimeInterval(-10 * 86_400)
        let low = PatchVelocityBuilder.versions(
            days: [PatchVelocityBuilder.DayRows(date: open, rows: [PatchStatusRow(
                title: "T", id: "1", onLatest: 10, onOther: 0, total: 100, latest: "1.0",
                compliancePct: "")])],
            lookup: ReleaseDateLookup(versionRows: [], releaseFilesNewestFirst: []))
        XCTAssertEqual(try report().buildPatchVersionHistory(low, dates: read).omission,
                       "no version window reached 90% in the last 90 days")
        let undated = try report().buildPatchVersionHistory(
            crossedVersions(2, withDates: false), dates: read)
        XCTAssertTrue(undated.isShown, "crossings with no release date still show the figure")
        XCTAssertTrue(undated.html.contains("Reached 90% with no release date: 2"), undated.html)
        XCTAssertFalse(undated.html.contains("Slowest to 90%"))
        XCTAssertEqual(try report().buildPatchVersionHistory([], dates: read).omission,
                       "no patch-status history")
    }

    func testTheDemoHistoryCoversEveryDemoTitleWithAWindow() {
        let demo = DemoData.patchVersionHistory
        let titles = Set(DemoData.patchStatus.titles.map(\.id))
        let windowed = Set(demo.versions.map(\.titleId))
        XCTAssertEqual(windowed, titles)
        for title in DemoData.patchStatus.titles {
            let latest = PatchVelocityBuilder.latestWindowByTitle(demo.versions)[title.id]
            XCTAssertEqual(demo.versions.first { $0.titleId == title.id && $0.windows.contains {
                $0.start == latest?.window.start } }?.version, title.latest,
                "the demo's latest window is the version the Patch table shows")
            XCTAssertLessThanOrEqual(latest?.window.series.last?.date ?? .distantFuture,
                                     DemoData.referenceDate)
        }
    }
}
