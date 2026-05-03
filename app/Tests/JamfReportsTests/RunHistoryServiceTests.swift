import Foundation
import XCTest
@testable import JamfReports

final class RunHistoryServiceTests: XCTestCase {
    func testParseLogTailTreatsNonZeroExitCodesAsFailures() throws {
        let logURL = try writeLog("[info] started\n[info] exit 126 after 9s\n")

        let (exitCode, duration) = RunHistoryService.parseLogTail(from: logURL)

        XCTAssertEqual(exitCode, 126)
        XCTAssertEqual(duration, "9s")
    }

    func testExitCodeParserHandlesSignedValues() {
        XCTAssertEqual(RunHistoryService.exitCode(from: "[info] exit 0 after 1s"), 0)
        XCTAssertEqual(RunHistoryService.exitCode(from: "[info] exit 2 after 1s"), 2)
        XCTAssertEqual(RunHistoryService.exitCode(from: "[info] exit -1 after 1s"), -1)
        XCTAssertNil(RunHistoryService.exitCode(from: "[info] exited normally"))
    }

    private func writeLog(_ text: String) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("run.log")
        try text.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return url
    }
}
