import Foundation

/// Per-day, per-rule dedup ledger for metric-alert cards (2.6 "trust trio" #1).
///
/// On managed-automation scan days two snapshot-only runs collect the same
/// day's summary (freshness daily + scan weekly, ~10 min apart) and both
/// evaluate the alert rules — without a ledger they post identical cards. A
/// persistent condition also re-cards on every run. The ledger records which
/// rule keys have already been carded today and filters them out, while a rule
/// that trips for the FIRST time later the same day still alerts.
///
/// Stored at `<workspace>/automation/.metric-alerts-ledger.json`. Best-effort
/// I/O: any read/write failure returns the input keys unchanged — alerting must
/// fail toward SENDING, never toward silence.
struct MetricAlertLedger: Sendable {
    let workspace: URL

    private var fileURL: URL {
        workspace
            .appendingPathComponent("automation", isDirectory: true)
            .appendingPathComponent(".metric-alerts-ledger.json")
    }

    private struct Record: Codable {
        var day: String
        var keys: [String]
    }

    /// Return the subset of `keys` not yet recorded for `day` (a new `day`
    /// resets the ledger), recording the surviving set before returning. On any
    /// read/write failure returns `keys` unchanged so a ledger problem never
    /// silences an alert.
    func filterAndRecord(day: String, keys: [String]) -> [String] {
        guard !keys.isEmpty else { return [] }
        let existing = load()
        // A stale record from a prior day resets: today's keys are all new.
        let already: Set<String> = existing?.day == day ? Set(existing?.keys ?? []) : []
        let fresh = keys.filter { !already.contains($0) }
        guard !fresh.isEmpty else { return [] }
        // Persist already-carded + newly-carded so a later same-day run dedups
        // against the full set, not just this run's hits.
        save(Record(day: day, keys: Array(already.union(fresh))))
        return fresh
    }

    private func load() -> Record? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    private func save(_ record: Record) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(record).write(to: fileURL, options: .atomic)
        } catch {
            AppLogger.webhook.warning(
                "MetricAlertLedger: could not persist ledger — same-day dedup may not hold: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
