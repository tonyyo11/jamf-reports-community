import Foundation

/// What the server-health snapshots say about the Jamf Pro server's own credentials: one
/// reader, so the Health Audit card, the workbook tab and the HTML report agree. Only the
/// built-in CA so far; the other sources join as their kinds land.
struct ServerHealth: Sendable, Equatable {

    enum Fact: Sendable, Equatable {
        case credential(CredentialExpiry)
    }

    /// Where one fact stands. A refusal or a missing feature is not a failure.
    enum FactState: Sendable, Equatable {
        /// Never attempted; the row is hidden.
        case notCollected
        /// The server has the feature unset (exit 4).
        case notConfigured
        /// The API role lacks the privilege; `names` are jamf-cli's, or empty.
        case notPermitted([String])
        /// Attempted, never landed, and not a refusal; the text is the cause.
        case failed(String)
        /// The newest snapshot exists and cannot be read.
        case unreadable
        /// Landed; `stale` is the snapshot's date when the kind has failed since.
        case value(Fact, stale: Date?)
    }

    struct CredentialRow: Sendable, Equatable {
        let key: String
        let label: String
        let fact: FactState
        /// The newest snapshot's date, when one exists.
        var asOf: Date? = nil
    }

    let credentials: [CredentialRow]

    /// True once any source has been attempted, so the card has something to say.
    var hasAttempt: Bool { credentials.contains { $0.fact != .notCollected } }

    /// The credentials that are expired or inside the warning window, soonest first.
    var expiringCredentials: [CredentialExpiry] {
        credentials.compactMap { row -> CredentialExpiry? in
            guard case .value(.credential(let credential), _) = row.fact,
                  credential.state == .expired || credential.state == .expiring else { return nil }
            return credential
        }.sorted { ($0.daysLeft ?? 0) < ($1.daysLeft ?? 0) }
    }

    static let caKind = "certificate-authority"

    /// What a source is called in a sentence about it.
    static func sourceName(_ kind: String) -> String {
        kind == caKind ? L("the built-in certificate authority") : kind
    }

    static func load(
        dataDir: URL, warningDays: Int, now: Date = Date(), calendar: Calendar = .current
    ) -> ServerHealth {
        let (fact, asOf) = loadFact(
            kind: caKind, dataDir: dataDir) { object, landed in
            guard let row = object as? [String: Any] else { return nil }
            let credential = CredentialExpiry(
                key: "ca", label: "Built-in CA", raw: row["notAfter"], warningDays: warningDays,
                now: now, calendar: calendar)
            return .value(.credential(credential), stale: landed)
        }
        let ca = CredentialRow(key: "ca", label: "Built-in CA", fact: fact, asOf: asOf)
        return ServerHealth(credentials: [ca])
    }

    /// The state of one kind from its newest snapshot and its state files. A server that has
    /// the feature unset wins over an older snapshot; a refusal after a landing keeps the value.
    private static func loadFact(
        kind: String, dataDir: URL, decode: (Any, Date?) -> FactState?
    ) -> (FactState, asOf: Date?) {
        let store = StateFileStore(directory: dataDir.appendingPathComponent("state"))
        let failed = store.failures(report: kind) != nil
        let cause = failed ? store.cause(for: kind) : nil
        let kindDir = dataDir.appendingPathComponent(kind, isDirectory: true)
        let newest = FileManager.newestJSONFile(in: kindDir)
        let asOf = newest.flatMap { CloudStorage.snapshotTimestamp(of: $0) }
        if cause?.kind == .notConfiguredOnServer { return (.notConfigured, asOf) }
        if let url = newest {
            guard let data = BoundedFile.readSnapshotLogged(url),
                  let object = try? JSONSerialization.jsonObject(
                      with: data, options: [.fragmentsAllowed]),
                  let state = decode(object, failed ? store.lastRun(report: kind) : nil)
            else { return (.unreadable, asOf) }
            return (state, asOf)
        }
        guard failed else { return (.notCollected, nil) }
        if store.isAdvisory(kind: kind) { return (.notPermitted(cause?.names ?? []), nil) }
        return (.failed(cause?.label ?? L("unknown cause")), nil)
    }
}

/// The words for a fact; the card and the tab share them, so they cannot disagree.
extension ServerHealth {
    static func text(for state: FactState) -> String {
        switch state {
        case .notCollected: return ""
        case .notConfigured: return L("Not set up on this server")
        case .notPermitted(let names):
            return names.isEmpty
                ? L("Not permitted for this login")
                : L("Not permitted: ") + names.joined(separator: ", ")
        case .failed(let cause): return L("Could not be collected: ") + cause
        case .unreadable: return L("Could not be read")
        case .value(.credential(let credential), let stale):
            let text = credentialText(credential)
            return stale.map { text + " " + L("(as of \(Self.day($0)), no longer measured)") }
                ?? text
        }
    }

    static func credentialText(_ credential: CredentialExpiry) -> String {
        guard let left = credential.daysLeft, let day = expiryDay(credential) else {
            return L("Expiry not reported")
        }
        switch credential.state {
        case .expired:
            let ago = -left
            return ago <= 0 ? L("Expired (\(day))")
                : ago == 1 ? L("Expired 1 day ago (\(day))") : L("Expired \(ago) days ago (\(day))")
        case .expiring, .ok:
            return left == 1
                ? L("Expires in 1 day (\(day))") : L("Expires in \(left) days (\(day))")
        case .notReported: return L("Expiry not reported")
        }
    }

    /// The expiry as the Mac's own calendar day, to match `daysLeft`.
    static func expiryDay(_ credential: CredentialExpiry) -> String? {
        switch credential.source {
        case .day(let text)?: return text
        case .instant(let date)?:
            let local = Date.ISO8601FormatStyle(timeZone: .current).year().month().day()
            return date.formatted(local)
        case nil: return nil
        }
    }

    private static func day(_ date: Date) -> String { String(ISO8601Time.string(date).prefix(10)) }
}
