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

    /// One credential alert already sent: it is kept across days, since a credential expires
    /// once. `expires` is in the key, so a renewed credential is a new key. A planted entry
    /// silences only its own exact (rule, credential, expiry, state).
    struct CredentialKey: Codable, Hashable {
        let rule: String
        let key: String
        let expires: String
        let state: String

        init?(_ hit: MetricAlertHit) {
            guard let key = hit.credentialKey, let expires = hit.expires,
                  let state = hit.credentialState else { return nil }
            (rule, self.key, self.expires, self.state) = (hit.ruleDescription, key, expires, state)
        }
    }

    /// A 2.12 build rewriting this file drops `credentialKeys`, which re-sends each
    /// credential's current state once.
    private struct Record: Codable {
        var day: String
        var keys: [String]
        var credentialKeys: [CredentialKey]?
    }

    /// An entry stays until its expiry is this many days past, so a credential that stays
    /// expired is not announced again, and the file does not grow without bound.
    static let credentialRetentionDays = 60

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
        save(Record(day: day, keys: Array(already.union(keys)),
                    credentialKeys: existing?.credentialKeys), to: url)
    }

    /// The credential `hits` not yet sent, WITHOUT persisting; every one on a read failure.
    func pendingCredentialHits(_ hits: [MetricAlertHit]) -> [MetricAlertHit] {
        let sent = Set(load(from: fileURL)?.credentialKeys ?? [])
        return hits.filter { CredentialKey($0).map { !sent.contains($0) } ?? false }
    }

    /// Mark credential `hits` as sent, after a confirmed send, and drop entries whose expiry
    /// is more than `credentialRetentionDays` past.
    func recordCredentials(_ hits: [MetricAlertHit], now: Date, calendar: Calendar = .current) {
        let added = hits.compactMap(CredentialKey.init)
        guard !added.isEmpty else { return }
        let url = fileURL
        let existing = load(from: url)
        let kept = Set((existing?.credentialKeys ?? []) + added).filter { entry in
            guard let left = CredentialExpiry(
                key: "", label: "", raw: entry.expires, warningDays: 0, now: now,
                calendar: calendar).daysLeft else { return false }
            return left >= -Self.credentialRetentionDays
        }
        save(Record(day: existing?.day ?? "", keys: existing?.keys ?? [],
                    credentialKeys: kept.sorted { ($0.key, $0.expires, $0.rule, $0.state)
                        < ($1.key, $1.expires, $1.rule, $1.state) }), to: url)
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
                "MetricAlertLedger: could not persist ledger — same-day dedup may not hold: \(error.englishDescription, privacy: .private)"
            )
        }
    }
}
