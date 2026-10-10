import Foundation
import os

/// Turns pipe reads into whole lines. A read ends wherever the kernel cut it, so a character
/// or a line can straddle two reads; bytes are held until the 0x0A that ends their line, and
/// only a complete line is decoded. Splits on bytes: Swift reads "\r\n" as one `Character`
/// equal to neither "\r" nor "\n".
struct UTF8LineSplitter: Sendable {
    private var pending = Data()

    /// The non-empty lines completed by `chunk`, without line endings. A trailing CR is
    /// dropped, so CRLF output reads as LF output.
    mutating func append(_ chunk: Data) -> [String] {
        pending.append(chunk)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<newline]
            pending.removeSubrange(pending.startIndex...newline)
            if let text = Self.decode(line) { lines.append(text) }
        }
        return lines
    }

    /// The final line when the stream ended without a newline. Call once, at EOF.
    mutating func finish() -> [String] {
        defer { pending.removeAll() }
        return Self.decode(pending).map { [$0] } ?? []
    }

    private static func decode(_ bytes: Data) -> String? {
        let trimmed = bytes.last == 0x0D ? bytes.dropLast() : bytes[...]
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
