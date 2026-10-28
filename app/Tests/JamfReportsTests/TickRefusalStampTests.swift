import XCTest
@testable import JamfReports

/// A refusal stamp that cannot be written or read warns and reads as absent, so the next wake
/// falls back to its own clock instead of guessing the Mac was never off.
final class TickRefusalStampTests: XCTestCase {
    nonisolated(unsafe) private var dir: URL!
    private let now = ISO8601DateFormatter().date(from: "2026-10-28T12:00:00Z")!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tick-stamp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: dir)
    }

    private final class Warnings: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func add(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
    }

    func testAStampThatIsADirectoryWarnsAndReadsAsAbsent() throws {
        let url = dir.appendingPathComponent(".tick.blocked")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        let warnings = Warnings()
        XCTAssertNil(TickLock.takeBlockedSince(url: url, warn: warnings.add))
        XCTAssertEqual(warnings.all.count, 1)
        XCTAssertTrue(warnings.all[0].contains(".tick.blocked"), warnings.all[0])
        XCTAssertTrue(warnings.all[0].contains("could not be read"), warnings.all[0])
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "left as found")
        XCTAssertFalse(TickScheduler.wasOff(lastTick: now.addingTimeInterval(-60), refusals: nil,
                                            now: now), "absent stamp, recent tick: not off")
    }

    func testAStampThatCannotBeWrittenWarnsNamingTheFile() throws {
        let url = dir.appendingPathComponent("missing-parent/.tick.blocked")
        let warnings = Warnings()
        TickLock.noteBlocked(url: url, now: now, warn: warnings.add)
        XCTAssertEqual(warnings.all.count, 1)
        XCTAssertTrue(warnings.all[0].contains(".tick.blocked"), warnings.all[0])
        XCTAssertTrue(warnings.all[0].contains("could not be written"), warnings.all[0])

        let locked = dir.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: locked.path)
        let second = Warnings()
        TickLock.noteBlocked(url: locked.appendingPathComponent(".tick.blocked"),
                             now: now, warn: second.add)
        XCTAssertEqual(second.all.count, 1, "an unwritable folder warns too")
    }

    func testAMissingStampIsAbsentWithoutAWarning() {
        let warnings = Warnings()
        XCTAssertNil(TickLock.takeBlockedSince(
            url: dir.appendingPathComponent(".tick.blocked"), warn: warnings.add))
        XCTAssertTrue(warnings.all.isEmpty)
    }

    func testAReadableStampRoundTripsWithoutWarnings() throws {
        let url = dir.appendingPathComponent(".tick.blocked")
        let warnings = Warnings()
        TickLock.noteBlocked(url: url, now: now, warn: warnings.add)
        let taken = try XCTUnwrap(TickLock.takeBlockedSince(url: url, warn: warnings.add))
        XCTAssertEqual(taken.first, now)
        XCTAssertTrue(warnings.all.isEmpty)
    }
}
