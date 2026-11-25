import Foundation

/// What the server-health snapshots say about the Jamf Pro server's own credentials: one
/// reader, so the Health Audit card, the workbook tab and the HTML report agree. Only the
/// built-in CA and Jamf Pro's notifications so far; the other sources join as their kinds land.
struct ServerHealth: Sendable, Equatable {

    enum Fact: Sendable, Equatable {
        case credential(CredentialExpiry)
        case notifications(Notifications)
    }

    /// The notifications this login sees, counted by the type Jamf names. Jamf filters them by
    /// user and site, so zero means none visible to this login, not none on the server.
    struct Notifications: Sendable, Equatable {
        struct TypeCount: Sendable, Equatable {
            let name: String
            let count: Int
        }
        let total: Int
        /// Every type, most common first, then by name; names pass `ConfigSchema.displayText`
        /// because the snapshot can be written by a peer.
        let types: [TypeCount]

        static let maxShownTypes = 5
        var shown: [TypeCount] { Array(types.prefix(Self.maxShownTypes)) }

        init(types rawTypes: [String?]) {
            total = rawTypes.count
            let names = rawTypes.map { $0.map(ConfigSchema.displayText) ?? L("Unknown type") }
            types = Dictionary(grouping: names, by: { $0 })
                .map { TypeCount(name: $0.key, count: $0.value.count) }
                .sorted { ($1.count, $0.name) < ($0.count, $1.name) }
        }
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
    var notifications: FactState = .notCollected
    var notificationsAsOf: Date? = nil

    /// True once any source has been attempted, so the card has something to say.
    var hasAttempt: Bool {
        credentials.contains { $0.fact != .notCollected } || notifications != .notCollected
    }

    /// The notifications figure, when that kind has landed.
    var notificationFigure: (value: Notifications, stale: Date?)? {
        if case .value(.notifications(let figure), let stale) = notifications {
            return (figure, stale)
        }
        return nil
    }

    /// The credentials that are expired or inside the warning window, soonest first.
    var expiringCredentials: [CredentialExpiry] {
        credentials.compactMap { row -> CredentialExpiry? in
            guard case .value(.credential(let credential), _) = row.fact,
                  credential.state == .expired || credential.state == .expiring else { return nil }
            return credential
        }.sorted { ($0.daysLeft ?? 0) < ($1.daysLeft ?? 0) }
    }

    static let caKind = "certificate-authority"
    static let notificationsKind = "jamf-pro-notifications"

    /// What a source is called in a sentence about it.
    static func sourceName(_ kind: String) -> String {
        switch kind {
        case caKind: L("the built-in certificate authority")
        case notificationsKind: L("Jamf Pro notifications")
        default: kind
        }
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
        let (notices, noticesAsOf) = loadFact(kind: notificationsKind, dataDir: dataDir) {
            object, landed in
            guard let rows = ReportEngine.listRows(of: object) else { return nil }
            let types = rows.map { ($0 as? [String: Any])?["type"] as? String }
            return .value(.notifications(Notifications(types: types)), stale: landed)
        }
        return ServerHealth(
            credentials: [ca], notifications: notices, notificationsAsOf: noticesAsOf)
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
        case .value(let fact, let stale):
            let text: String
            switch fact {
            case .credential(let credential): text = credentialText(credential)
            case .notifications(let figure): text = notificationsText(figure)
            }
            return stale.map { text + " " + L("(as of \(Self.day($0)), no longer measured)") }
                ?? text
        }
    }

    /// "3 (A: 2, B: 1)", the five most common types with "5 of M types" when there are more.
    static func notificationsText(_ figure: Notifications) -> String {
        guard figure.total > 0 else { return L("None visible to this login") }
        let list = figure.shown.map { "\($0.name): \($0.count)" }.joined(separator: ", ")
        let more = figure.types.count > figure.shown.count
            ? " · " + L("\(figure.shown.count) of \(figure.types.count) types") : ""
        return "\(figure.total) (\(list))" + more
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
