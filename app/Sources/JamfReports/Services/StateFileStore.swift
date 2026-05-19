import Foundation

/// PR-22 T-5: persistent record of "when did we last successfully fetch
/// jamf-cli report `<kind>`."
///
/// One file per report under the configured state directory:
/// `<state-dir>/<report>.last`. Format is a single line of ISO-8601
/// RFC 3339 UTC at seconds precision (no fractional seconds, no trailing
/// newline). This format was chosen because:
///
/// - Operators can `cat overview.last` and immediately recognize the
///   value. The state files become part of diagnostic bundles and need to
///   be readable without parsing tools.
/// - Seconds precision is enough — cadences are minutes-to-days. Sub-
///   second precision would force a `floor()` at every comparison site
///   to keep the `isDue` boundary stable. Truncating at write time gets
///   the same property for free.
/// - Byte-stable across reads. T-14 hashes state files into the snapshot
///   manifest; ISO-8601 strings hash deterministically as long as the
///   tz suffix and precision stay fixed.
///
/// Reads NEVER throw — missing, empty, malformed, or IO-failed all return
/// `nil` ("never fetched"). The resolver treats `nil` as "due now," so a
/// corrupt state file degrades gracefully into "fetch this report on next
/// collect" rather than crashing the loop.
///
/// Writes ARE allowed to throw because a silent persist failure would
/// cause the next `collect` to refetch the report immediately and the
/// one after that, and so on — the cadence would never stabilize. Callers
/// in T-8 should log the throw rather than swallow it.
///
/// No report-kind validation here. Trust the caller. The kind is whatever
/// `ReportEngine.knownCollectKinds` knows about; validation belongs in
/// the resolver, not in storage.
struct StateFileStore: Sendable {

    /// Directory holding `<report>.last` files. Typically
    /// `WorkspacePaths.stateDir(for:)` but tests pass arbitrary URLs.
    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    // MARK: - Read

    /// Return the timestamp of the last successful fetch of `report`, or
    /// `nil` if no file exists, the file is empty, or the contents cannot
    /// be parsed as ISO-8601. Reads do not throw — `nil` means "treat as
    /// never fetched" and the cadence resolver does the right thing.
    func lastRun(report: String) -> Date? {
        let url = fileURL(for: report)
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Self.formatter.date(from: trimmed)
    }

    // MARK: - Write

    /// Atomically record that `report` was successfully fetched at `date`.
    /// Creates the state directory on first write — first fetch after
    /// `workspace-init` must not fail because the dir doesn't exist yet.
    ///
    /// `date` is truncated to second precision before writing so a
    /// `recordRun → lastRun → isDue` round-trip is stable. Without
    /// truncation, callers who pass `Date()` would see sub-millisecond
    /// drift back across the `elapsed >= cadence` boundary, which would
    /// flap reports near their cadence boundary in/out of "due."
    func recordRun(report: String, at date: Date) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let truncated = Date(timeIntervalSince1970: floor(date.timeIntervalSince1970))
        let body = Self.formatter.string(from: truncated)
        guard let data = body.data(using: .utf8) else {
            throw StateFileError.encodingFailed(report: report)
        }
        let url = fileURL(for: report)
        try atomicWrite(data: data, to: url)
    }

    // MARK: - Errors

    enum StateFileError: Error, LocalizedError {
        case encodingFailed(report: String)

        var errorDescription: String? {
            switch self {
            case .encodingFailed(let r):
                "Could not encode state for report '\(r)' as UTF-8"
            }
        }
    }

    // MARK: - Internals

    /// ISO-8601 RFC 3339, UTC, seconds precision, no fractional component.
    /// Pinned as a static so every write produces the identical byte
    /// representation — T-14's snapshot manifest hash relies on it.
    ///
    /// `nonisolated(unsafe)` because `ISO8601DateFormatter` isn't marked
    /// `Sendable` upstream, but per Apple's docs the immutable
    /// `formatOptions`/`timeZone` configuration is safe to share across
    /// threads — both `.string(from:)` and `.date(from:)` are
    /// reentrant on macOS once the formatter is fully configured.
    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    private func fileURL(for report: String) -> URL {
        directory.appendingPathComponent("\(report).last", isDirectory: false)
    }

    /// Write `data` to `url` via a temp-file-then-rename so a crash mid-
    /// write leaves the prior contents intact. `replaceItem` is the
    /// CLAUDE.md-blessed primitive but it requires the destination to
    /// already exist; for a first write we fall back to `Data.write`
    /// (which is already atomic via the `.atomic` option on macOS).
    private func atomicWrite(data: Data, to url: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            // Write new content to a sibling temp file, then replaceItem
            // atomically swaps the inodes — readers either see the old or
            // the new content, never a half-written line.
            let tmp = url.deletingLastPathComponent()
                .appendingPathComponent(".tmp-\(UUID().uuidString)-\(url.lastPathComponent)")
            try data.write(to: tmp, options: .atomic)
            do {
                _ = try fm.replaceItemAt(url, withItemAt: tmp)
            } catch {
                // Clean up the temp file if the replace failed.
                try? fm.removeItem(at: tmp)
                throw error
            }
        } else {
            try data.write(to: url, options: .atomic)
        }
    }
}
