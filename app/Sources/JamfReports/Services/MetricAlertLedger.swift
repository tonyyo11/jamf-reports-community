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
/// Stored at `<workspace>/automation/.metric-alerts-ledger.json`, or in this Mac's Application
/// Support when that folder is refused (`AutomationStateFile`), so a symlinked `automation`
/// neither mutes the alerts nor repeats them. Best-effort I/O: a read or write failure returns
/// the input keys unchanged, so alerting fails toward SENDING, never toward silence.
struct MetricAlertLedger: Sendable {
    let workspace: URL

    private var fileURL: URL {
        AutomationStateFile.url(named: ".metric-alerts-ledger.json", in: workspace)
    }

    private struct Record: Codable {
        var day: String
        var keys: [String]
    }

    /// Return the subset of `keys` not yet carded for `day`, WITHOUT persisting.
    /// A stale record from a prior day resets: today's keys are all new. On a
    /// read failure returns `keys` unchanged so a ledger problem never silences
    /// an alert.
    func pendingKeys(day: String, keys: [String]) -> [String] {
        guard !keys.isEmpty else { return [] }
        let existing = load(from: fileURL)
        let already: Set<String> = existing?.day == day ? Set(existing?.keys ?? []) : []
        return keys.filter { !already.contains($0) }
    }

    /// Mark `keys` as carded for `day`, merged with anything already carded
    /// today so a later same-day run dedups against the full set.
    ///
    /// Call this ONLY after a confirmed send. Recording first would let a
    /// transient webhook failure silence that rule for the rest of the day —
    /// the same discipline `DayMarker` uses for the overdue digest.
    func record(day: String, keys: [String]) {
        guard !keys.isEmpty else { return }
        let url = fileURL
        let existing = load(from: url)
        let already: Set<String> = existing?.day == day ? Set(existing?.keys ?? []) : []
        save(Record(day: day, keys: Array(already.union(keys))), to: url)
    }

    private func load(from url: URL) -> Record? {
        guard let data = BoundedFile.stateData(url) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    private func save(_ record: Record, to fileURL: URL) {
        do {
            try AutomationStateFile.write(JSONEncoder().encode(record), to: fileURL)
        } catch {
            AppLogger.webhook.warning(
                "MetricAlertLedger: could not persist ledger — same-day dedup may not hold: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
