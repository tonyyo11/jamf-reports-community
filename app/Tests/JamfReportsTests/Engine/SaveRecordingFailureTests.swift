import XCTest
@testable import JamfReports

/// The School, Protect and Security Cloud loops record a kind failed before a save throw
/// aborts the collect, as the Jamf Pro loop does.
final class SaveRecordingFailureTests: XCTestCase {
    func testAFailedSaveIsRecordedBeforeItThrows() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("jrc-save-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let dataDir = root.appendingPathComponent("jamf-cli-data")
        let elsewhere = root.appendingPathComponent("elsewhere")
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try fm.createDirectory(at: dataDir, withIntermediateDirectories: true)
        // A linked kind folder is refused, so the save throws.
        try fm.createSymbolicLink(
            at: dataDir.appendingPathComponent("security-risk"), withDestinationURL: elsewhere)
        let store = StateFileStore(directory: dataDir.appendingPathComponent("state"))
        final class Lines: @unchecked Sendable { var all: [String] = [] }
        let lines = Lines()
        XCTAssertThrowsError(try ReportEngine.saveRecordingFailure(
            Data("[]".utf8), kind: "security-risk", dataDir: dataDir, exitCode: 0,
            stateStore: store, at: Date(), onLine: { lines.all.append($0.text) }))
        XCTAssertEqual(store.lastFailureExitCode(for: "security-risk"), 0)
        XCTAssertTrue(lines.all.contains { $0.hasPrefix("[fail] security-risk:") }, "\(lines.all)")
    }
}
