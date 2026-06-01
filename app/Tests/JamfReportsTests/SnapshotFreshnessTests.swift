import Foundation
import XCTest
@testable import JamfReports

final class SnapshotFreshnessTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnapshotFreshnessTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    // MARK: - Missing / empty directory

    func testMissingDirectoryReturnsNoSnapshots() {
        let missing = tempDir.appendingPathComponent("does-not-exist", isDirectory: true)
        let result = SnapshotFreshness.evaluate(dataDir: missing)
        XCTAssertEqual(result, .noSnapshots)
    }

    func testEmptyDirectoryReturnsNoSnapshots() {
        let result = SnapshotFreshness.evaluate(dataDir: tempDir)
        XCTAssertEqual(result, .noSnapshots)
    }

    // MARK: - Boundary: 59 minutes → fresh, 61 minutes → stale

    func testFiftyNineMinutesIsFresh() throws {
        let fileAge: TimeInterval = 59 * 60
        let now = Date()
        let fileDate = now.addingTimeInterval(-fileAge)
        try writeFile(name: "snapshot.json", at: fileDate)

        let result = SnapshotFreshness.evaluate(dataDir: tempDir, threshold: 3600, now: now)
        guard case .fresh(let minutes) = result else {
            XCTFail("Expected .fresh, got \(result)")
            return
        }
        XCTAssertEqual(minutes, 59)
    }

    func testSixtyOneMinutesIsStale() throws {
        let fileAge: TimeInterval = 61 * 60
        let now = Date()
        let fileDate = now.addingTimeInterval(-fileAge)
        try writeFile(name: "snapshot.json", at: fileDate)

        let result = SnapshotFreshness.evaluate(dataDir: tempDir, threshold: 3600, now: now)
        guard case .stale(let minutes) = result else {
            XCTFail("Expected .stale, got \(result)")
            return
        }
        XCTAssertEqual(minutes, 61)
    }

    // MARK: - Newest mtime wins across nested directories

    func testNewestFileAcrossNestedDirectoriesIsUsed() throws {
        let now = Date()
        let subDir = tempDir.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)

        // Older file at root
        try writeFile(name: "old.json", at: now.addingTimeInterval(-120 * 60))
        // Newer file in subdirectory
        try writeFile(name: "new.json", at: now.addingTimeInterval(-10 * 60), in: subDir)

        let result = SnapshotFreshness.evaluate(dataDir: tempDir, threshold: 3600, now: now)
        guard case .fresh(let minutes) = result else {
            XCTFail("Expected .fresh, got \(result)")
            return
        }
        XCTAssertEqual(minutes, 10)
    }

    // MARK: - Hidden files are ignored

    func testHiddenFilesAreIgnored() throws {
        let now = Date()
        // Only file is hidden — should not count
        try writeFile(name: ".hidden-snapshot.json", at: now.addingTimeInterval(-10 * 60))

        let result = SnapshotFreshness.evaluate(dataDir: tempDir, threshold: 3600, now: now)
        XCTAssertEqual(result, .noSnapshots)
    }

    // MARK: - Directories themselves are ignored (only regular files count)

    func testDirectoriesAreNotCountedAsFiles() throws {
        let now = Date()
        // Create a subdirectory with a recent mtime but no files
        let subDir = tempDir.appendingPathComponent("recent-subdir", isDirectory: true)
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        try setMTime(url: subDir, date: now.addingTimeInterval(-5 * 60))

        let result = SnapshotFreshness.evaluate(dataDir: tempDir, threshold: 3600, now: now)
        XCTAssertEqual(result, .noSnapshots)
    }

    // MARK: - Custom threshold respected

    func testCustomThresholdRespected() throws {
        let now = Date()
        // File is 10 minutes old
        try writeFile(name: "snapshot.json", at: now.addingTimeInterval(-10 * 60))

        // With a 5-minute threshold, should be stale
        let staleResult = SnapshotFreshness.evaluate(dataDir: tempDir, threshold: 5 * 60, now: now)
        guard case .stale = staleResult else {
            XCTFail("Expected .stale with 5-minute threshold, got \(staleResult)")
            return
        }

        // With a 20-minute threshold, should be fresh
        let freshResult = SnapshotFreshness.evaluate(dataDir: tempDir, threshold: 20 * 60, now: now)
        guard case .fresh = freshResult else {
            XCTFail("Expected .fresh with 20-minute threshold, got \(freshResult)")
            return
        }
    }

    // MARK: - Helpers

    @discardableResult
    private func writeFile(name: String, at date: Date, in directory: URL? = nil) throws -> URL {
        let dir = directory ?? tempDir!
        let url = dir.appendingPathComponent(name)
        try "{}".write(to: url, atomically: true, encoding: .utf8)
        try setMTime(url: url, date: date)
        return url
    }

    private func setMTime(url: URL, date: Date) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: date],
            ofItemAtPath: url.path
        )
    }
}

// MARK: - Equatable conformance for test assertions

extension SnapshotFreshness.Decision: Equatable {
    public static func == (lhs: SnapshotFreshness.Decision, rhs: SnapshotFreshness.Decision) -> Bool {
        switch (lhs, rhs) {
        case (.noSnapshots, .noSnapshots): return true
        case (.fresh(let a), .fresh(let b)): return a == b
        case (.stale(let a), .stale(let b)): return a == b
        default: return false
        }
    }
}
