import Foundation

/// What the server-health snapshots say about the Jamf Pro server's own credentials: one
/// reader, so the Health Audit card, the workbook tab and the HTML report agree. Only the
/// built-in CA and Jamf Pro's notifications so far; the other sources join as their kinds land.
struct ServerHealth: Sendable, Equatable {

    enum Fact: Sendable, Equatable {
        case credential(CredentialExpiry)
        case notifications(Notifications)
        case lapsPending(Int)
        case accounts(Accounts)
        case apiClients(APIClients)
    }

    /// Console accounts as counts, never names (opt-in; the reduction saves nothing else).
    struct Accounts: Sendable, Equatable {
        let total: Int
        let fullAccessLocal: Int
        let fullAccessFederated: Int
        let withFailedLogins: Int
        let passwordOlderThanYear: Int
        let passwordAgeUnknown: Int
        /// Accounts whose `failedLoginAttempts` was missing or not a whole number.
        var failedLoginsUnknown: Int = 0
    }

    /// API clients as counts, never names or client IDs (opt-in).
    struct APIClients: Sendable, Equatable {
        let total: Int
        let disabled: Int
        let enabledWithTokenOverOneDay: Int
        /// Enabled clients with no readable token lifetime.
        var tokenLifetimeUnknown: Int = 0
        /// Clients with no readable `enabled`; they are in neither the disabled nor the
        /// token count.
        var enabledUnknown: Int = 0
    }

    /// One opt-in admin-hygiene source: its kind, what it is called on the card and its state.
    struct HygieneRow: Sendable, Equatable {
        let kind: String
        let label: String
        let fact: FactState
        var asOf: Date? = nil
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
            // Group by the raw type; the translated "Unknown type" is only what is shown, so a
            // type with that very name cannot merge with it.
            let names = rawTypes.map { $0.map(ConfigSchema.displayText) ?? "" }
            types = Dictionary(grouping: names, by: { $0 })
                .map { TypeCount(name: $0.key.isEmpty ? L("Unknown type") : $0.key,
                                 count: $0.value.count) }
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
    /// The sources turned on in `collect_opt_in`, in card order; empty with none on.
    var adminHygiene: [HygieneRow] = []

    /// True once any source has been attempted, so the card has something to say.
    var hasAttempt: Bool {
        credentials.contains { $0.fact != .notCollected } || notifications != .notCollected
            || adminHygiene.contains { $0.fact != .notCollected }
    }

    /// Rotations waiting, when that kind has landed.
    var lapsPendingFigure: Int? {
        for row in adminHygiene {
            if case .value(.lapsPending(let count), _) = row.fact { return count }
        }
        return nil
    }

    /// The notifications figure, when that kind has landed.
    var notificationFigure: (value: Notifications, stale: Date?)? {
        if case .value(.notifications(let figure), let stale) = notifications {
            return (figure, stale)
        }
        return nil
    }

    /// The credentials that are expired or inside the warning window, soonest first; a value no
    /// longer measured is not a current warning.
    var expiringCredentials: [CredentialExpiry] {
        credentials.compactMap { row -> CredentialExpiry? in
            guard case .value(.credential(let credential), nil) = row.fact,
                  credential.state == .expired || credential.state == .expiring else { return nil }
            return credential
        }.sorted { ($0.daysLeft ?? 0) < ($1.daysLeft ?? 0) }
    }

    static let caKind = "certificate-authority"
    static let notificationsKind = "jamf-pro-notifications"
    static let lapsKind = "laps-pending-rotations"
    static let accountsKind = "admin-accounts"
    static let apiClientsKind = "api-integrations"

    /// The Data Sources line under an opt-in source: what it needs and why it is off by default.
    static func optInLabel(_ kind: String) -> String? {
        switch kind {
        case lapsKind:
            L("LAPS rotations pending (needs View Local Admin Password, which can also read LAPS passwords)")
        case accountsKind: L("Admin accounts (needs Read Accounts; counts only)")
        case apiClientsKind: L("API clients (needs Read API Integrations; counts only)")
        default: nil
        }
    }

    /// What a source is called in a sentence about it.
    static func sourceName(_ kind: String) -> String {
        switch kind {
        case caKind: L("the built-in certificate authority")
        case notificationsKind: L("Jamf Pro notifications")
        case lapsKind: L("LAPS rotations pending")
        case accountsKind: L("Admin accounts")
        case apiClientsKind: L("API clients")
        default: kind
        }
    }

    static func load(
        dataDir: URL, warningDays: Int, now: Date = Date(), calendar: Calendar = .current,
        optIn: Set<String> = [], maxAgeHours: Int? = nil
    ) -> ServerHealth {
        func read(
            _ kind: String, _ decode: (Any, Date?) -> FactState?
        ) -> (FactState, asOf: Date?) {
            loadFact(kind: kind, dataDir: dataDir, now: now, maxAgeHours: maxAgeHours, decode: decode)
        }
        let (fact, asOf) = read(caKind) { object, landed in
            guard let row = object as? [String: Any] else { return nil }
            let credential = CredentialExpiry(
                key: "ca", label: "Built-in CA", raw: row["notAfter"], warningDays: warningDays,
                now: now, calendar: calendar)
            return .value(.credential(credential), stale: landed)
        }
        let ca = CredentialRow(key: "ca", label: "Built-in CA", fact: fact, asOf: asOf)
        let (notices, noticesAsOf) = read(notificationsKind) { object, landed in
            guard let rows = ReportEngine.listRows(of: object) else { return nil }
            let types = rows.map { ($0 as? [String: Any])?["type"] as? String }
            return .value(.notifications(Notifications(types: types)), stale: landed)
        }
        var health = ServerHealth(
            credentials: [ca], notifications: notices, notificationsAsOf: noticesAsOf)
        health.adminHygiene = [lapsKind, accountsKind, apiClientsKind]
            .filter(optIn.contains).map { kind in
                let (fact, asOf) = read(kind) { object, landed in
                    hygieneFact(kind: kind, object: object).map { .value($0, stale: landed) }
                }
                return HygieneRow(kind: kind, label: sourceName(kind), fact: fact, asOf: asOf)
            }
        return health
    }

    private static func hygieneFact(kind: String, object: Any) -> Fact? {
        guard let counts = object as? [String: Any] else { return nil }
        func count(_ key: String) -> Int? { wholeCount(counts[key]) }
        switch kind {
        case lapsKind: return count("totalCount").map(Fact.lapsPending)
        case accountsKind:
            guard let total = count("total"), let local = count("fullAccessLocal"),
                  let federated = count("fullAccessFederated"),
                  let failed = count("withFailedLogins"),
                  let older = count("passwordOlderThanYear"),
                  let unknown = count("passwordAgeUnknown") else { return nil }
            // The unknown tallies are new; a snapshot saved before them had none to report.
            return .accounts(Accounts(
                total: total, fullAccessLocal: local, fullAccessFederated: federated,
                withFailedLogins: failed, passwordOlderThanYear: older,
                passwordAgeUnknown: unknown, failedLoginsUnknown: count("failedLoginsUnknown") ?? 0))
        default:
            guard let total = count("total"), let disabled = count("disabled"),
                  let long = count("enabledWithTokenOverOneDay") else { return nil }
            return .apiClients(APIClients(
                total: total, disabled: disabled, enabledWithTokenOverOneDay: long,
                tokenLifetimeUnknown: count("tokenLifetimeUnknown") ?? 0,
                enabledUnknown: count("enabledUnknown") ?? 0))
        }
    }

    /// The state of one kind from its newest snapshot and its state files. A server that has
    /// the feature unset wins over an older snapshot; a refusal after a landing keeps the value.
    private static func loadFact(
        kind: String, dataDir: URL, now: Date, maxAgeHours: Int?,
        decode: (Any, Date?) -> FactState?
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
                  let state = decode(object, staleDate(
                      failed: failed, asOf: asOf, store: store, kind: kind, now: now,
                      maxAgeHours: maxAgeHours))
            else { return (.unreadable, asOf) }
            return (state, asOf)
        }
        guard failed else { return (.notCollected, nil) }
        if store.isAdvisory(kind: kind) { return (.notPermitted(privilegeNames(cause?.names ?? [])), nil) }
        return (.failed(cause?.label ?? L("unknown cause")), nil)
    }
}

extension ServerHealth {
    /// The snapshot's date when its value is no longer current: the kind has failed since, or
    /// the snapshot is older than `max_cache_age_hours`. The date is the snapshot's own stamp.
    fileprivate static func staleDate(
        failed: Bool, asOf: Date?, store: StateFileStore, kind: String, now: Date,
        maxAgeHours: Int?
    ) -> Date? {
        if failed { return asOf ?? store.lastRun(report: kind) }
        guard let asOf, let hours = maxAgeHours else { return nil }
        return now.timeIntervalSince(asOf) > Double(hours) * 3_600 ? asOf : nil
    }

    /// Privilege names come from a cause file another Mac can write: filtered and capped.
    static func privilegeNames(_ names: [String]) -> [String] {
        names.prefix(Notifications.maxShownTypes).map(ConfigSchema.displayText)
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
                : L("Not permitted: ") + privilegeNames(names).joined(separator: ", ")
        case .failed(let cause): return L("Could not be collected: ") + cause
        case .unreadable: return L("Could not be read")
        case .value(let fact, let stale):
            let text: String
            switch fact {
            case .credential(let credential): text = credentialText(credential)
            case .notifications(let figure): text = notificationsText(figure)
            case .lapsPending(let count): text = count == 0 ? L("None pending") : "\(count)"
            case .accounts, .apiClients: text = figuresText(fact)
            }
            return stale.map { text + " " + L("(as of \(Self.day($0)), no longer measured)") }
                ?? text
        }
    }

    /// The labelled counts of an admin-hygiene fact; each label is a whole phrase.
    static func figures(of fact: Fact) -> [(label: String, count: Int)] {
        switch fact {
        case .accounts(let figure):
            var rows = [(L("Total"), figure.total),
                        (L("Full access, local"), figure.fullAccessLocal),
                        (L("Full access, federated"), figure.fullAccessFederated),
                        (L("With failed logins"), figure.withFailedLogins),
                        (L("Password over a year old"), figure.passwordOlderThanYear),
                        (L("Password age unknown"), figure.passwordAgeUnknown)]
            if figure.failedLoginsUnknown > 0 {
                rows.append((L("Failed logins not reported"), figure.failedLoginsUnknown))
            }
            return rows
        case .apiClients(let figure):
            var rows = [(L("Total"), figure.total), (L("Disabled"), figure.disabled),
                        (L("Enabled, token over 1 day"), figure.enabledWithTokenOverOneDay)]
            if figure.tokenLifetimeUnknown > 0 {
                rows.append((L("Token lifetime not reported"), figure.tokenLifetimeUnknown))
            }
            if figure.enabledUnknown > 0 {
                rows.append((L("Enabled state not reported"), figure.enabledUnknown))
            }
            return rows
        case .lapsPending(let count): return [(sourceName(lapsKind), count)]
        case .credential, .notifications: return []
        }
    }

    /// "Total: 12 · Full access, local: 3 · ...".
    static func figuresText(_ fact: Fact) -> String {
        figures(of: fact).map { "\($0.label): \($0.count)" }.joined(separator: " · ")
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

    static func day(_ date: Date) -> String { String(ISO8601Time.string(date).prefix(10)) }
}
