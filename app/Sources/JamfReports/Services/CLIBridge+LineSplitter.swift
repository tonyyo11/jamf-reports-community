import Foundation
import os

/// Turns pipe reads into whole lines. A read ends wherever the kernel cut it, so a character
/// or a line can straddle two reads; bytes are held until the 0x0A that ends their line, and
/// only a complete line is decoded. Splits on bytes: Swift reads "\r\n" as one `Character`
/// equal to neither "\r" nor "\n".
struct UTF8LineSplitter: Sendable {
    /// A line longer than this is emitted in chunks, so a stream with no newline cannot grow
    /// the buffer without bound.
    static let maxLineBytes = 1_048_576

    private var pending = Data()
    /// Bytes at the front of `pending` already searched for a newline.
    private var scanned = 0

    /// The non-empty lines completed by `chunk`, without line endings. A trailing CR is
    /// dropped, so CRLF output reads as LF output.
    mutating func append(_ chunk: Data) -> [String] {
        pending.append(chunk)
        var lines: [String] = []
        var lineStart = pending.startIndex
        var scanFrom = pending.startIndex + scanned
        while let newline = pending[scanFrom...].firstIndex(of: 0x0A) {
            if let text = Self.decode(pending[lineStart..<newline], dropCR: true) {
                lines.append(text)
            }
            lineStart = newline + 1
            scanFrom = lineStart
        }
        pending.removeSubrange(pending.startIndex..<lineStart)
        while pending.count > Self.maxLineBytes {
            let cut = Self.utf8Boundary(in: pending, atOrBefore: Self.maxLineBytes)
            if let text = Self.decode(pending[pending.startIndex..<pending.startIndex + cut],
                                      dropCR: false) {
                lines.append(text)
            }
            pending.removeSubrange(pending.startIndex..<pending.startIndex + cut)
        }
        scanned = pending.count
        return lines
    }

    /// The final line when the stream ended without a newline. Call once, at EOF.
    mutating func finish() -> [String] {
        defer { pending.removeAll(); scanned = 0 }
        return Self.decode(pending[...], dropCR: true).map { [$0] } ?? []
    }

    /// Moves a cut back off a UTF-8 continuation byte so a chunk does not split a character.
    private static func utf8Boundary(in bytes: Data, atOrBefore limit: Int) -> Int {
        var cut = limit
        while cut > limit - 3, cut > 0, bytes[bytes.startIndex + cut] & 0xC0 == 0x80 {
            cut -= 1
        }
        return cut
    }

    private static func decode(_ bytes: Data.SubSequence, dropCR: Bool) -> String? {
        let trimmed = dropCR && bytes.last == 0x0D ? bytes.dropLast() : bytes
        guard !trimmed.isEmpty else { return nil }
        // Invalid bytes become U+FFFD; the line still arrives.
        return String(decoding: trimmed, as: UTF8.self)
    }
}

extension CLIBridge {
    /// A `UTF8LineSplitter` that a pipe's `readabilityHandler` can own. The handler is a
    /// `@Sendable` closure, so the splitter's state sits behind an unfair lock, which makes
    /// the class `Sendable` without `@unchecked`.
    final class PipeLineReader: Sendable {
        private let splitter = OSAllocatedUnfairLock(initialState: UTF8LineSplitter())

        func lines(from chunk: Data) -> [String] {
            splitter.withLock { $0.append(chunk) }
        }

        func finish() -> [String] {
            splitter.withLock { $0.finish() }
        }
    }
}
