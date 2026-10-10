import Foundation
import XCTest
@testable import JamfReports

/// A pipe read ends wherever the kernel cut it: mid-character, mid-line, or without a final
/// newline. The line feed must not drop or split any of those, because `StderrSignalWatcher`
/// matches markers inside a line.
final class CLIBridgeLineSplittingTests: XCTestCase {

    private func capture(script: String) async throws -> [String] {
        let sink = LineSink()
        let (exit, _) = try await CLIBridge().runAndCapture(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script],
            onLine: sink.append
        )
        XCTAssertEqual(exit, 0)
        return sink.texts
    }

    func testCharacterSplitAcrossReadsDecodesOnce() async throws {
        // U+20AC is E2 82 AC; the first read ends after two of its three bytes.
        let texts = try await capture(
            script: #"printf 'cost \342\202' 1>&2; sleep 0.3; printf '\254 total\n' 1>&2"#
        )
        XCTAssertEqual(texts, ["cost \u{20AC} total"])
    }

    func testLineSplitAcrossReadsIsOneLine() async throws {
        let texts = try await capture(
            script: "printf 'error: permission den' 1>&2; sleep 0.3; "
                + "printf 'ied (HTTP 403)\\n' 1>&2"
        )
        XCTAssertEqual(texts, ["error: permission denied (HTTP 403)"])
        let watcher = StderrSignalWatcher()
        watcher.forwarding(to: { _ in })(CLIBridge.stderrLine(texts[0]))
        XCTAssertTrue(watcher.sawForbidden)
    }

    func testFinalLineWithoutNewlineArrivesAtEOF() async throws {
        let texts = try await capture(script: "printf 'one\\ntail' 1>&2")
        XCTAssertEqual(texts, ["one", "tail"])
    }

    func testCRLFLinesSplitWithoutTheCarriageReturn() async throws {
        let texts = try await capture(script: "printf 'a\\r\\nb\\r\\n' 1>&2")
        XCTAssertEqual(texts, ["a", "b"])
    }

    func testRunStreamsStdoutLinesWholeAcrossReads() async throws {
        let sink = LineSink()
        let exit = try await CLIBridge().run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", #"printf '[ok] \342\202'; sleep 0.3; printf '\254 done\ntail'"#],
            onLine: sink.append
        )
        XCTAssertEqual(exit, 0)
        XCTAssertEqual(sink.texts, ["[ok] \u{20AC} done", "tail"])
    }

    // MARK: - Splitter

    func testSplitterKeepsAnIncompleteCharacterUntilItsLastByte() {
        var splitter = UTF8LineSplitter()
        XCTAssertEqual(splitter.append(Data([0x61, 0xE2, 0x82])), [])
        XCTAssertEqual(splitter.append(Data([0xAC, 0x0A])), ["a\u{20AC}"])
        XCTAssertEqual(splitter.finish(), [])
    }

    func testSplitterSkipsEmptyLinesAndFlushesTheRemainderOnce() {
        var splitter = UTF8LineSplitter()
        XCTAssertEqual(splitter.append(Data("a\n\nb\r\n\r\nc".utf8)), ["a", "b"])
        XCTAssertEqual(splitter.finish(), ["c"])
        XCTAssertEqual(splitter.finish(), [])
    }

    func testSplitterReplacesInvalidBytesInsteadOfDroppingTheLine() {
        var splitter = UTF8LineSplitter()
        XCTAssertEqual(splitter.append(Data([0x61, 0xFF, 0x62, 0x0A])), ["a\u{FFFD}b"])
    }

    func testSplitterEmitsANewlineFreeStreamInChunksWithoutLoss() {
        let limit = UTF8LineSplitter.maxLineBytes
        let total = 3 * limit
        var splitter = UTF8LineSplitter()
        var emitted: [String] = []
        let block = Data(repeating: 0x78, count: 64 * 1024)
        var sent = 0
        while sent < total {
            emitted += splitter.append(block)
            sent += block.count
        }
        emitted += splitter.finish()
        XCTAssertEqual(emitted.map(\.utf8.count).reduce(0, +), sent)
        XCTAssertTrue(emitted.allSatisfy { $0.utf8.count <= limit })
        XCTAssertGreaterThanOrEqual(emitted.count, 3)
    }

    func testSplitterChunkingNeverSplitsACharacterOrLosesBytes() {
        let limit = UTF8LineSplitter.maxLineBytes
        // Three-byte characters, so the limit falls inside one.
        let text = String(repeating: "\u{20AC}", count: limit / 3 * 2 + 5)
        var splitter = UTF8LineSplitter()
        var emitted = splitter.append(Data(text.utf8))
        emitted += splitter.finish()
        XCTAssertGreaterThan(emitted.count, 1)
        XCTAssertFalse(emitted.contains { $0.contains("\u{FFFD}") })
        XCTAssertEqual(emitted.joined(), text)
    }

    func testSplitterFindsNewlinesAcrossManySmallAppendsAfterAScan() {
        var splitter = UTF8LineSplitter()
        XCTAssertEqual(splitter.append(Data("ab".utf8)), [])
        XCTAssertEqual(splitter.append(Data("cd".utf8)), [])
        XCTAssertEqual(splitter.append(Data("ef\ngh\n".utf8)), ["abcdef", "gh"])
    }
}

private final class LineSink: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var append: @Sendable (CLIBridge.LogLine) -> Void {
        { line in self.lock.lock(); defer { self.lock.unlock() }; self.stored.append(line.text) }
    }
    var texts: [String] { lock.lock(); defer { lock.unlock() }; return stored }
}
