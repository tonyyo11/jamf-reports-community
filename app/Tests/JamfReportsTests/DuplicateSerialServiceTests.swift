import Foundation
import XCTest
@testable import JamfReports

/// Tests for `DuplicateSerialService`: decode of the real jamf-cli v1.23.0+
/// `pro report duplicate-serials` shape, grouping by serial, and the
/// three-state (never-collected / clean / duplicates-found) contract
/// `AuditView` renders from.
///
/// `DuplicateSerialService` is a `Sendable` struct with `nonisolated static`
/// load methods — matches the `GroupInventoryService` pattern, no `@MainActor`
/// needed.
final class DuplicateSerialServiceTests: XCTestCase {

    // MARK: - Helpers

    private func writeTmp(_ content: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dup-serial-test-\(UUID().uuidString).json")
        try Data(content.utf8).write(to: url)
        return url
    }

    private func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Decode: real fixture shape

    /// Fixture content mirrors upstream `internal/commands/pro_report_serials.go`
    /// (`runReportDuplicateSerials`) exactly: a bare array of flat
    /// `{serial, id, name, last_contact}` objects, already grouped by serial and
    /// ordered by ascending numeric id (stale record first).
    func testDecodesRealFixtureAndGroupsBySerial() throws {
        let url = TestFixtures.dir(
            "jamf-cli-data/duplicate-serials/duplicate-serials_20260710T090000.json"
        )
        let snapshot = DuplicateSerialService.load(url: url)

        XCTAssertTrue(snapshot.isDetected)
        XCTAssertEqual(snapshot.groups.count, 2)
        XCTAssertEqual(snapshot.affectedRecordCount, 4)

        let first = try XCTUnwrap(snapshot.groups.first)
        XCTAssertEqual(first.serial, "C02X1234")
        XCTAssertEqual(first.records.map(\.recordId), ["2", "10"])
        XCTAssertEqual(first.records.map(\.name), ["Mac-old", "Mac-new"])
        XCTAssertEqual(first.records[0].lastContact, "2025-01-01T00:00:00Z")

        let second = try XCTUnwrap(snapshot.groups.last)
        XCTAssertEqual(second.serial, "C02Z9999")
        XCTAssertEqual(second.records.count, 2)
    }

    /// Exercises the same newest-file-selection layer `load(profile:)` uses
    /// internally (`FileManager.newestJSONFile(in:)`), via a `TestFixtures`
    /// directory copy rather than touching the real `~/Jamf-Reports` tree.
    func testCopiedFixtureDirResolvesViaNewestJSONFile() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("dup-serial-dir-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try TestFixtures.copyDir("jamf-cli-data/duplicate-serials", to: tmp)

        let newest = FileManager.newestJSONFile(in: tmp)
        XCTAssertNotNil(newest)
        let snapshot = DuplicateSerialService.load(url: newest)

        XCTAssertTrue(snapshot.isDetected)
        XCTAssertEqual(snapshot.groups.count, 2)
    }

    // MARK: - .empty on missing dir / nil url — "never collected"

    func testNilURLReturnsUndecodedEmpty() {
        let snapshot = DuplicateSerialService.load(url: nil)
        XCTAssertFalse(snapshot.isDetected)
        XCTAssertTrue(snapshot.groups.isEmpty)
        XCTAssertEqual(snapshot.affectedRecordCount, 0)
    }

    func testNoFileAtURLReturnsUndecodedEmpty() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-such-file-\(UUID().uuidString).json")
        let snapshot = DuplicateSerialService.load(url: missing)
        XCTAssertFalse(snapshot.isDetected, "A missing file must read as never-collected, not clean")
        XCTAssertFalse(snapshot.readFailed, "A missing file is never-collected, not a read failure")
    }

    func testMissingWorkspaceReturnsUndecodedEmpty() {
        // ProfileService rejects an unslugged profile name outright — the
        // production `load(profile:)` entry point on an unknown/invalid
        // profile must degrade to the same never-collected empty state.
        let snapshot = DuplicateSerialService.load(profile: "Not A Valid Slug!!")
        XCTAssertFalse(snapshot.isDetected)
        XCTAssertTrue(snapshot.groups.isEmpty)
    }

    // MARK: - Zero-duplicates vs never-collected distinction

    /// An empty array is a SUCCESSFUL decode (jamf-cli ran, found nothing) —
    /// must read as "clean fleet," not "never collected."
    func testEmptyArrayDecodesAsCleanNotUndetected() throws {
        let url = try writeTmp("[]")
        defer { remove(url) }

        let snapshot = DuplicateSerialService.load(url: url)
        XCTAssertTrue(snapshot.isDetected, "An empty-but-valid array must still count as detected")
        XCTAssertTrue(snapshot.groups.isEmpty)
        XCTAssertEqual(snapshot.affectedRecordCount, 0)
    }

    // MARK: - Malformed JSON

    /// An existing-but-undecodable file must be distinguishable from
    /// never-collected, so the view doesn't tell a current-jamf-cli operator
    /// to upgrade.
    func testMalformedJSONReadsAsReadFailureNotNeverCollected() throws {
        let url = try writeTmp("{not valid json")
        defer { remove(url) }

        let snapshot = DuplicateSerialService.load(url: url)
        XCTAssertFalse(snapshot.isDetected)
        XCTAssertTrue(snapshot.readFailed)
        XCTAssertTrue(snapshot.groups.isEmpty)
    }

    /// jamf-cli has emitted record ids as both JSON string and number across
    /// versions — a number-typed id must not invalidate the snapshot.
    func testNumberTypedIdDecodes() throws {
        let json = """
        [
          {"serial": "C02X1234", "id": 7, "name": "Mac-a", "last_contact": ""},
          {"serial": "C02X1234", "id": "12", "name": "Mac-b", "last_contact": ""}
        ]
        """
        let url = try writeTmp(json)
        defer { remove(url) }

        let snapshot = DuplicateSerialService.load(url: url)
        XCTAssertTrue(snapshot.isDetected)
        XCTAssertEqual(snapshot.groups.first?.records.map(\.recordId), ["7", "12"])
    }

    // MARK: - Grouping edge cases

    /// The real CLI never emits a blank serial (it excludes them before
    /// grouping), but the grouping layer must not misbehave if a future
    /// shape does — matches the Go source's own whitespace-collision guard.
    func testBlankSerialIsDroppedFromGrouping() throws {
        let json = """
        [
          {"serial": "", "id": "4", "name": "Pending-A", "last_contact": ""},
          {"serial": "  ", "id": "5", "name": "Pending-B", "last_contact": ""},
          {"serial": "C02Z9999", "id": "1", "name": "A", "last_contact": ""},
          {"serial": "C02Z9999", "id": "2", "name": "B", "last_contact": ""}
        ]
        """
        let url = try writeTmp(json)
        defer { remove(url) }

        let snapshot = DuplicateSerialService.load(url: url)
        XCTAssertEqual(snapshot.groups.count, 1)
        XCTAssertEqual(snapshot.affectedRecordCount, 2)
    }

    func testMissingNameFallsBackToRecordID() throws {
        let json = """
        [
          {"serial": "C02X1234", "id": "2", "last_contact": ""},
          {"serial": "C02X1234", "id": "10", "last_contact": ""}
        ]
        """
        let url = try writeTmp(json)
        defer { remove(url) }

        let snapshot = DuplicateSerialService.load(url: url)
        let group = try XCTUnwrap(snapshot.groups.first)
        XCTAssertEqual(group.records.map(\.name), ["2", "10"])
    }

    /// Two groups sharing the same underlying jamf-cli record id must not
    /// merge or cross-assign rows — grouping is by serial alone.
    func testSameRecordIdAcrossGroupsStaysInItsOwnGroup() throws {
        let json = """
        [
          {"serial": "A", "id": "1", "name": "X", "last_contact": ""},
          {"serial": "A", "id": "2", "name": "Y", "last_contact": ""},
          {"serial": "B", "id": "1", "name": "Z", "last_contact": ""}
        ]
        """
        let url = try writeTmp(json)
        defer { remove(url) }

        let snapshot = DuplicateSerialService.load(url: url)
        XCTAssertEqual(snapshot.groups.map(\.serial), ["A", "B"])
        XCTAssertEqual(snapshot.groups[0].records.map(\.recordId), ["1", "2"])
        XCTAssertEqual(snapshot.groups[1].records.map(\.name), ["Z"])
    }
}
