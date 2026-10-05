import Foundation
import XCTest
@testable import JamfReports

final class BackupRecordTests: XCTestCase {

    private func utc(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar.date(from: DateComponents(
            year: y, month: mo, day: d, hour: h, minute: mi, second: s)) ?? .distantPast
    }

    private func record(_ name: String, files: Int, created: Date = Date()) -> BackupRecord {
        BackupRecord(
            name: name, label: "", created: created, sizeBytes: Int64(files) * 10,
            fileCount: files, url: URL(fileURLWithPath: "/tmp/\(name)"))
    }

    func testTheDateInAFolderNameIsReadAsUTC() {
        XCTAssertEqual(BackupRecord.dateInName("20260601T214020"), utc(2026, 6, 1, 21, 40, 20))
        XCTAssertEqual(BackupRecord.dateInName("20260601T214020-2"), utc(2026, 6, 1, 21, 40, 20))
    }

    func testTheOlderToolsNameIsReadAsLocalTime() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let expected = calendar.date(from: DateComponents(
            year: 2026, month: 5, day: 6, hour: 17, minute: 5, second: 14))
        XCTAssertEqual(BackupRecord.dateInName("backup_20260506_170514"), expected)
    }

    func testOtherNamesAndImpossibleDatesHaveNoDate() {
        XCTAssertNil(BackupRecord.dateInName("nightly"))
        XCTAssertNil(BackupRecord.dateInName("20261345T214020"))
        XCTAssertNil(BackupRecord.dateInName("x20260601T214020"))
    }

    func testTheManifestDateWinsThenTheNameThenTheFolderDate() {
        let manifest = utc(2026, 6, 1, 21, 41, 0)
        let modified = utc(2026, 9, 5, 8, 0, 0)
        XCTAssertEqual(
            BackupRecord.created(manifest: manifest, name: "20260601T214020", modified: modified),
            manifest)
        XCTAssertEqual(
            BackupRecord.created(manifest: nil, name: "20260601T214020", modified: modified),
            utc(2026, 6, 1, 21, 40, 20))
        XCTAssertEqual(
            BackupRecord.created(manifest: nil, name: "nightly", modified: modified), modified)
        XCTAssertEqual(
            BackupRecord.created(manifest: nil, name: "nightly", modified: nil), .distantPast)
    }

    func testAnEmptyBackupCannotBeDiffedEitherWay() {
        let full = record("20260918T133550", files: 2810)
        let other = record("20260925T133403", files: 2853)
        let empty = record("20260601T214020", files: 0)
        XCTAssertTrue(BackupRecord.canDiff(full, against: other))
        XCTAssertFalse(BackupRecord.canDiff(empty, against: other))
        XCTAssertFalse(BackupRecord.canDiff(full, against: empty))
        XCTAssertFalse(BackupRecord.canDiff(full, against: full))
        XCTAssertFalse(BackupRecord.canDiff(full, against: nil))
    }

    /// A folder with no files, whose modification date was reset months after the backup was
    /// made, lists under the date in its name.
    func testTheLibraryDatesAnEmptyBackupByItsNameNotItsFolder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-backups-\(UUID().uuidString)", isDirectory: true)
        let saved = ProcessInfo.processInfo.environment["JRC_TEST_WORKSPACES_ROOT"]
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        defer {
            if let saved { setenv("JRC_TEST_WORKSPACES_ROOT", saved, 1) }
            else { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
            try? FileManager.default.removeItem(at: root)
        }
        let profile = "backups-dates"
        let workspace = try XCTUnwrap(ProfileService.workspaceURL(for: profile))
        let backups = workspace.appendingPathComponent("backups", isDirectory: true)
        let empty = backups.appendingPathComponent("20260601T214020", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let reset = utc(2026, 9, 5, 8, 0, 0)
        try FileManager.default.setAttributes([.modificationDate: reset], ofItemAtPath: empty.path)

        let listed = BackupLibrary().list(profile: profile)
        let record = try XCTUnwrap(listed.first)
        XCTAssertEqual(listed.count, 1)
        XCTAssertTrue(record.isEmpty)
        XCTAssertEqual(record.created, utc(2026, 6, 1, 21, 40, 20))
        XCTAssertNotEqual(record.created, reset)
    }
}
