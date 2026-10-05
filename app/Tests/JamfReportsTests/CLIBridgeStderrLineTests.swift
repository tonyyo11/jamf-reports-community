import Foundation
import XCTest
@testable import JamfReports

/// jamf-cli prints a `page_fetch` progress event as raw JSON on stderr. It reads as an `[info]`
/// line in words; every other stderr line stays a warning with its text untouched, because
/// `StderrSignalWatcher` and the failure-cause hints read that text.
final class CLIBridgeStderrLineTests: XCTestCase {

    func testPageFetchEventReadsAsInfoInWords() {
        let line = CLIBridge.stderrLine(#"{"event":"page_fetch","fetched":147,"total":147}"#)
        XCTAssertEqual(line.level, .info)
        XCTAssertEqual(line.text, "[info] fetched 147 of 147 records")
    }

    func testPageFetchWithoutATotalSaysOnlyWhatWasFetched() {
        let line = CLIBridge.stderrLine(#"{"event":"page_fetch","fetched":0,"total":null}"#)
        XCTAssertEqual(line.level, .info)
        XCTAssertEqual(line.text, "[info] fetched 0 records")
    }

    func testPartialPageFetchKeepsRunningCount() {
        let line = CLIBridge.stderrLine(#"  {"event":"page_fetch","fetched":100,"total":1081}"#)
        XCTAssertEqual(line.text, "[info] fetched 100 of 1081 records")
    }

    func testRewrittenLineClassifiesAsInfoWhereRunHistoryReadsIt() {
        let line = CLIBridge.stderrLine(#"{"event":"page_fetch","fetched":9,"total":9}"#)
        XCTAssertEqual(CLIBridge.LogLevel.from(line: line.text), .info)
    }

    func testOtherStderrLinesStayWarningsWithTheirText() {
        let samples = [
            "permission denied (HTTP 403)",
            "Fetching summaries for 135 patch titles...",
            #"{"event":"page_fetch","fetched":"many","total":5}"#,
            #"{"event":"rate_limited","retry_after":3}"#,
            #"{"error":"unauthorized","message":"token expired"}"#,
            #"{"event":"page_fetch""#,
        ]
        for raw in samples {
            let line = CLIBridge.stderrLine(raw)
            XCTAssertEqual(line.level, .warn, raw)
            XCTAssertEqual(line.text, raw)
        }
    }

    func testSignalWatcherStillSeesMarkersBesideProgress() {
        let watcher = StderrSignalWatcher()
        let forward = watcher.forwarding(to: { _ in })
        forward(CLIBridge.stderrLine(#"{"event":"page_fetch","fetched":1,"total":9}"#))
        XCTAssertFalse(watcher.sawForbidden)
        forward(CLIBridge.stderrLine("error: permission denied (HTTP 403) for GET /v1/x"))
        XCTAssertTrue(watcher.sawForbidden)
    }

    func testRunAndCaptureStreamsProgressAsInfoAndErrorsAsWarnings() async throws {
        let sink = StderrLineSink()
        let (exit, _) = try await CLIBridge().runAndCapture(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                #"printf '{"event":"page_fetch","fetched":3,"total":3}\n' 1>&2; "#
                    + "printf 'deprecated command name\\n' 1>&2",
            ],
            onLine: sink.append
        )
        XCTAssertEqual(exit, 0)
        let lines = sink.lines
        XCTAssertEqual(
            lines.map(\.text), ["[info] fetched 3 of 3 records", "deprecated command name"])
        XCTAssertEqual(lines.map(\.level), [.info, .warn])
    }
}

private final class StderrLineSink: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [CLIBridge.LogLine] = []
    var append: @Sendable (CLIBridge.LogLine) -> Void {
        { line in self.lock.lock(); defer { self.lock.unlock() }; self.stored.append(line) }
    }
    var lines: [CLIBridge.LogLine] { lock.lock(); defer { lock.unlock() }; return stored }
}
