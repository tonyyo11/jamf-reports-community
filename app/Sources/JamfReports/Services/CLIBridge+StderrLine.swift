import Foundation

extension CLIBridge {
    /// One jamf-cli stderr line as the run feed, Run History and the Logging viewer show it.
    ///
    /// stderr is where jamf-cli speaks, so a line is a warning until it proves otherwise.
    /// The one thing that proves otherwise is a `page_fetch` progress event: jamf-cli prints
    /// it as raw JSON on every page of a list, which read as a warning in the viewer. It
    /// becomes an `[info]` line in words. Everything else keeps its text and `.warn` level,
    /// so `StderrSignalWatcher`'s markers, error text and deprecation notices read as before.
    nonisolated static func stderrLine(_ raw: String, at date: Date = Date()) -> LogLine {
        if let words = pageFetchWords(raw) {
            return LogLine(timestamp: date, level: .info, text: words)
        }
        return LogLine(timestamp: date, level: .warn, text: raw)
    }

    /// "[info] fetched 147 of 147 records" for `{"event":"page_fetch","fetched":147,"total":147}`;
    /// nil for any other line, including a `page_fetch` whose counts are not numbers.
    nonisolated static func pageFetchWords(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{"), trimmed.contains("page_fetch"),
              let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))
                as? [String: Any],
              object["event"] as? String == "page_fetch",
              let fetched = object["fetched"] as? Int else { return nil }
        // jamf-cli sends `"total": null` when the server does not report a count.
        if let total = object["total"] as? Int {
            return "[info] fetched \(fetched) of \(total) records"
        }
        return "[info] fetched \(fetched) records"
    }
}
