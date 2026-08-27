import Foundation
import CryptoKit

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
        // PR-22 T-14: keep the state manifest in sync after every write so
        // an attacker who tampers a .last file can't quietly defer fetches
        // — the next audit catches the SHA-256 mismatch. The rewrite is
        // try? to avoid undoing the .last write we just succeeded at; a
        // manifest desync is recoverable (audit re-runs catch it), a
        // dropped state write is not.
        try? rewriteManifest()
    }

    // MARK: - Failure tracking (2.8 data-freshness health)

    /// Consecutive-failure record for one report kind.
    struct FailureRecord: Sendable, Equatable {
        let count: Int
        let last: Date
    }

    /// Read the consecutive-failure record for `report`, or nil when the kind
    /// has no recorded failure. Like `lastRun`, reads never throw — a missing
    /// or malformed file means "no known failures".
    func failures(report: String) -> FailureRecord? {
        guard let raw = try? String(contentsOf: failureURL(for: report), encoding: .utf8) else {
            return nil
        }
        let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", maxSplits: 1)
        guard parts.count == 2, let count = Int(parts[0]), count > 0,
              let date = Self.formatter.date(from: String(parts[1])) else { return nil }
        return FailureRecord(count: count, last: date)
    }

    /// Increment the consecutive-failure count for `report`.
    ///
    /// Written on the cache-fallback branch of `ReportEngine.collect`, which is
    /// where a per-kind collect failure used to vanish into a log warning. The
    /// count is what lets `DataFreshnessHealth` distinguish a one-off server
    /// hiccup from a kind that has been quietly failing for months.
    ///
    /// Best-effort by design (`try?` at the call site): losing a failure count
    /// must never undo a collect that otherwise succeeded.
    func recordFailure(report: String, at date: Date) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let next = (failures(report: report)?.count ?? 0) + 1
        let truncated = Date(timeIntervalSince1970: floor(date.timeIntervalSince1970))
        let body = "\(next) \(Self.formatter.string(from: truncated))"
        guard let data = body.data(using: .utf8) else {
            throw StateFileError.encodingFailed(report: report)
        }
        try atomicWrite(data: data, to: failureURL(for: report))
    }

    /// Drop the failure record for `report` — called on every success so the
    /// count means *consecutive* failures rather than lifetime failures.
    func clearFailures(report: String) {
        try? FileManager.default.removeItem(at: failureURL(for: report))
    }

    /// The result of one collect attempt for a single report kind.
    enum KindOutcome: Sendable {
        /// A snapshot was written to disk. Anything short of that — a non-zero
        /// exit, a launch failure, or exit 0 carrying output that isn't JSON —
        /// is `.failed`, because the operator's question is "is the data
        /// there?", not "did the process return?".
        case landed
        case failed
    }

    /// Apply one collect attempt's result to this kind's state.
    ///
    /// The two rules that make the counters mean anything live here rather than
    /// at the five `ReportEngine.collect` branches that used to write the store
    /// directly: a landing advances the cadence boundary AND clears the failure
    /// streak, and everything else increments it.
    ///
    /// Consolidating them is also what makes those rules reachable by tests.
    /// `collect` resolves jamf-cli through `ExecutableLocator`, which has no
    /// injectable seam on purpose — the CWD fallback was removed so a planted
    /// binary can never be handed the API secret — so the collect loop itself
    /// cannot be run in the suite. Adding a test-only executable override to
    /// `collect` would reopen exactly that hole, so the bookkeeping moved to
    /// where it can be tested instead.
    ///
    /// Never throws: a state-write failure must not undo a snapshot already on
    /// disk. The worst case is one redundant fetch next cycle.
    func record(_ outcome: KindOutcome, report: String, at date: Date) {
        switch outcome {
        case .landed:
            try? recordRun(report: report, at: date)
            clearFailures(report: report)
        case .failed:
            try? recordFailure(report: report, at: date)
        }
    }

    /// Per-kind collection state for every kind in `kinds`, for the freshness
    /// evaluator. Kinds with neither a success nor a failure still yield a
    /// state (all-nil) so a never-collected kind is visible rather than absent.
    func collectionStates(for kinds: [String]) -> [KindCollectionState] {
        kinds.map { kind in
            let failure = failures(report: kind)
            return KindCollectionState(
                kind: kind,
                lastSuccess: lastRun(report: kind),
                consecutiveFailures: failure?.count ?? 0,
                lastFailure: failure?.last
            )
        }
    }

    // MARK: - Manifest (T-14)

    /// Rebuild `<state-dir>/manifest.json` from the current `.last`
    /// contents. Called from `recordRun` after every successful state
    /// write so the manifest always reflects the latest state.
    ///
    /// The file format matches `SnapshotManifest`'s decoder — algorithm
    /// "sha256", `files` map of filename → hex digest — plus a
    /// `version: 2` field that distinguishes state-aware manifests from
    /// pre-PR-22 Python-written v1 manifests. Verification uses the same
    /// `SnapshotManifest.verify(snapshot:data:)` API as JSON snapshots.
    func rewriteManifest() throws {
        let fm = FileManager.default
        let manifestURL = directory.appendingPathComponent(
            SnapshotManifest.fileName, isDirectory: false
        )
        guard fm.fileExists(atPath: directory.path) else {
            // Nothing to manifest — clean up any stale file from before
            // the directory was deleted by an operator clearing cache.
            try? fm.removeItem(at: manifestURL)
            return
        }
        let entries = (try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        let lastFiles = entries
            .filter { $0.pathExtension == "last" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var files: [String: String] = [:]
        for url in lastFiles {
            guard let data = try? Data(contentsOf: url) else { continue }
            files[url.lastPathComponent] = Self.sha256Hex(data)
        }

        let payload = StateManifestPayload(
            version: SnapshotManifest.currentSchemaVersion,
            algorithm: "sha256",
            files: files
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(payload)
        try atomicWrite(data: data, to: manifestURL)
    }

    private struct StateManifestPayload: Encodable {
        let version: Int
        let algorithm: String
        let files: [String: String]
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
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

    /// `.fail` rather than `.last` so `rewriteManifest` — which hashes only
    /// `.last` files — is unaffected by failure bookkeeping.
    private func failureURL(for report: String) -> URL {
        directory.appendingPathComponent("\(report).fail", isDirectory: false)
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
