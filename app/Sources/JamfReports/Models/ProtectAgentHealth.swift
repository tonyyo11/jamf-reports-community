import Foundation

/// Whether each Jamf Protect agent is current and reachable: signatures behind what Protect
/// published, an agent older than the current installer, and a Mac disconnected for more than a
/// day. The one calculator behind the Protect screen, the workbook, the HTML report and the
/// daily summary; a finding it cannot judge is not evaluated, with the reason, never 0.
struct ProtectAgentHealth: Sendable, Equatable {

    /// How long a published version or installer must have existed before a Mac counts as
    /// behind it, and how long a Mac must have been gone before it counts as disconnected.
    static let grace: TimeInterval = 24 * 3600
    /// The most `protect-installer` snapshots the first-seen scan reads.
    static let maxInstallerFiles = 400

    struct PublishedSignature: Sendable, Equatable {
        let id: Int
        let created: Date
    }

    struct InstallerBaseline: Sendable, Equatable {
        let version: String
        let firstSeen: Date
    }

    /// Why a finding is not evaluated. The screen words it in the app's language; reports use
    /// `englishText`.
    enum Unavailable: Sendable, Equatable {
        case notCollected(kind: String)
        case unreadable(kind: String)
        case noPublishedVersions
        case noVersionOldEnough
        case noInstallerVersion
        case installerNotAVersion(String)
        case installerTooNew(version: String, firstSeen: Date)
        case firstSeenUnknown(String)
        case noCollectionTime

        var englishText: String {
            switch self {
            case .notCollected(let kind): return "\(kind) not collected"
            case .unreadable(let kind): return "\(kind) could not be read"
            case .noPublishedVersions: return "Protect published no signature versions"
            case .noVersionOldEnough: return "no published signature version is 24 hours old yet"
            case .noInstallerVersion: return "Protect gave no installer version"
            case .installerNotAVersion(let v):
                return "installer version \(ConfigSchema.displayText(v)) is not a version number"
            case .installerTooNew(let v, let date):
                return "installer \(ConfigSchema.displayText(v)) first seen "
                    + ISO8601Time.string(date)
            case .firstSeenUnknown(let v):
                return "no dated snapshot holds installer \(ConfigSchema.displayText(v))"
            case .noCollectionTime: return "the protect-computers snapshot has no collection time"
            }
        }
    }

    /// What a Mac is compared with.
    enum BaselineLabel: Sendable, Equatable {
        case published(id: Int, created: Date)
        case installer(version: String, firstSeen: Date)

        var englishText: String {
            switch self {
            case .published(let id, let created):
                return "version \(id), published \(ISO8601Time.string(created))"
            case .installer(let v, let firstSeen):
                return "installer \(ConfigSchema.displayText(v)), first seen "
                    + ISO8601Time.string(firstSeen)
            }
        }
    }

    /// A baseline, or why there is none.
    enum Input<Value: Sendable & Equatable>: Sendable, Equatable {
        case value(Value)
        case unavailable(Unavailable)
    }

    enum MacState: Sendable, Equatable { case yes, no, notEvaluated }

    struct MacStatus: Sendable, Equatable {
        let signaturesBehind: MacState
        let agentBehind: MacState
        let disconnected: MacState
    }

    /// `share` is nil when the finding is not evaluated, and `notEvaluated` then says why.
    struct Finding: Sendable, Equatable {
        let share: MobileSummary.Share?
        let baseline: BaselineLabel?
        let notEvaluated: Unavailable?

        static func unavailable(_ reason: Unavailable) -> Finding {
            Finding(share: nil, baseline: nil, notEvaluated: reason)
        }
    }

    /// `reason` is Protect's text through `ConfigSchema.displayText`; nil when it gave none.
    struct ReasonCount: Sendable, Equatable {
        let reason: String?
        let count: Int
    }

    /// One status per computer row, in row order.
    let macs: [MacStatus]
    let signaturesBehind: Finding
    let agentBehind: Finding
    let disconnected: Finding
    /// Disconnected Macs (the finding's `met`) by Protect's reason, the most common first,
    /// at most `ManagementHealth.maxShownValues`; `distinctReasons` counts them all.
    let disconnectedReasons: [ReasonCount]
    let distinctReasons: Int
    /// Not connected, with no readable time of disconnection: in the finding's `of`, not `met`.
    let disconnectedTimeUnknown: Int

    // MARK: - Evaluate

    static func evaluate(
        computers: [ProtectComputerRow], published: Input<[PublishedSignature]>,
        installer: Input<InstallerBaseline>, now: Date
    ) -> ProtectAgentHealth {
        let cutoff = now.addingTimeInterval(-grace)
        let signatureBaseline = signatureBaseline(published, cutoff: cutoff)
        let agentBaseline = agentBaseline(installer, cutoff: cutoff)
        var macs: [MacStatus] = []
        var signatures = (met: 0, of: 0), agent = (met: 0, of: 0), gone = (met: 0, of: 0)
        var reasons: [String?: Int] = [:]
        var timeUnknown = 0
        for row in computers {
            let sig = signatureState(row, baseline: signatureBaseline.value)
            let ver = agentState(row, baseline: agentBaseline.value)
            let dis = disconnectedState(row, cutoff: cutoff)
            tally(sig, into: &signatures)
            tally(ver, into: &agent)
            tally(dis.state, into: &gone)
            if dis.timeUnknown { timeUnknown += 1 }
            if dis.state == .yes {
                let reason = row.lastDisconnectionReason.map(ConfigSchema.displayText)
                    .flatMap { $0.isEmpty ? nil : $0 }
                reasons[reason, default: 0] += 1
            }
            macs.append(MacStatus(signaturesBehind: sig, agentBehind: ver, disconnected: dis.state))
        }
        let sorted = reasons.map { ReasonCount(reason: $0.key, count: $0.value) }
            .sorted { ($1.count, $0.reason ?? "") < ($0.count, $1.reason ?? "") }
        return ProtectAgentHealth(
            macs: macs,
            signaturesBehind: finding(signatures, baseline: signatureBaseline),
            agentBehind: finding(agent, baseline: agentBaseline),
            disconnected: Finding(
                share: .init(met: gone.met, of: gone.of), baseline: nil, notEvaluated: nil),
            disconnectedReasons: Array(sorted.prefix(ManagementHealth.maxShownValues)),
            distinctReasons: sorted.count, disconnectedTimeUnknown: timeUnknown)
    }

    /// Every finding not evaluated, for computers the app cannot place in time.
    static func notEvaluated(computerCount: Int, reason: Unavailable) -> ProtectAgentHealth {
        let none = MacStatus(
            signaturesBehind: .notEvaluated, agentBehind: .notEvaluated,
            disconnected: .notEvaluated)
        return ProtectAgentHealth(
            macs: Array(repeating: none, count: computerCount),
            signaturesBehind: .unavailable(reason), agentBehind: .unavailable(reason),
            disconnected: .unavailable(reason), disconnectedReasons: [], distinctReasons: 0,
            disconnectedTimeUnknown: 0)
    }

    private struct Baseline<Value> {
        let value: Value?
        let label: BaselineLabel?
        let reason: Unavailable?
    }

    private static func signatureBaseline(
        _ input: Input<[PublishedSignature]>, cutoff: Date
    ) -> Baseline<Int> {
        switch input {
        case .unavailable(let reason):
            return Baseline(value: nil, label: nil, reason: reason)
        case .value(let list):
            guard let newest = list.filter({ $0.created <= cutoff }).max(by: { $0.id < $1.id })
            else {
                return Baseline(value: nil, label: nil,
                                reason: list.isEmpty ? .noPublishedVersions : .noVersionOldEnough)
            }
            return Baseline(
                value: newest.id, label: .published(id: newest.id, created: newest.created),
                reason: nil)
        }
    }

    private static func agentBaseline(
        _ input: Input<InstallerBaseline>, cutoff: Date
    ) -> Baseline<[Int]> {
        switch input {
        case .unavailable(let reason):
            return Baseline(value: nil, label: nil, reason: reason)
        case .value(let installer):
            guard let parts = dottedVersion(installer.version) else {
                return Baseline(value: nil, label: nil,
                                reason: .installerNotAVersion(installer.version))
            }
            guard installer.firstSeen <= cutoff else {
                return Baseline(value: nil, label: nil, reason: .installerTooNew(
                    version: installer.version, firstSeen: installer.firstSeen))
            }
            return Baseline(
                value: parts,
                label: .installer(version: installer.version, firstSeen: installer.firstSeen),
                reason: nil)
        }
    }

    private static func signatureState(_ row: ProtectComputerRow, baseline: Int?) -> MacState {
        guard let baseline, let version = row.signaturesVersion, version == version.rounded()
        else { return .notEvaluated }
        return version < Double(baseline) ? .yes : .no
    }

    private static func agentState(_ row: ProtectComputerRow, baseline: [Int]?) -> MacState {
        guard let baseline, let parts = row.version.flatMap(dottedVersion) else {
            return .notEvaluated
        }
        return isLower(parts, than: baseline) ? .yes : .no
    }

    private static func disconnectedState(
        _ row: ProtectComputerRow, cutoff: Date
    ) -> (state: MacState, timeUnknown: Bool) {
        guard let status = row.connectionStatus else { return (.notEvaluated, false) }
        guard !ProtectDashboardService.isConnected(status) else { return (.no, false) }
        guard let gone = row.lastDisconnection.flatMap(ISO8601Time.parse) else {
            return (.no, true)
        }
        return (gone < cutoff ? .yes : .no, false)
    }

    private static func tally(_ state: MacState, into counts: inout (met: Int, of: Int)) {
        guard state != .notEvaluated else { return }
        counts.of += 1
        if state == .yes { counts.met += 1 }
    }

    private static func finding<V>(
        _ counts: (met: Int, of: Int), baseline: Baseline<V>
    ) -> Finding {
        guard baseline.value != nil else {
            return .unavailable(baseline.reason ?? .noCollectionTime)
        }
        return Finding(
            share: .init(met: counts.met, of: counts.of), baseline: baseline.label,
            notEvaluated: nil)
    }

    // MARK: - Versions

    /// "5.1.0.7" as [5, 1, 0, 7]; nil unless every dot-separated part is a run of digits.
    static func dottedVersion(_ text: String) -> [Int]? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(
            separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber),
                  let number = Int(part) else { return nil }
            numbers.append(number)
        }
        return numbers
    }

    /// Compares part by part, a missing part reading as 0 ("4.6" equals "4.6.0").
    static func isLower(_ lhs: [Int], than rhs: [Int]) -> Bool {
        for index in 0..<max(lhs.count, rhs.count) {
            let l = index < lhs.count ? lhs[index] : 0
            let r = index < rhs.count ? rhs[index] : 0
            if l != r { return l < r }
        }
        return false
    }
}
