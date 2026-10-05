import Foundation

/// One input of the Security Score, as `security_policy.score_factors` lists it: what is
/// measured and how much it weighs. The score is Σ(weight × share) / Σ(weight) over the
/// factors that have data (`SecurityScoreCalculator`).
struct SecurityScoreFactor: Sendable, Hashable {
    enum Kind: String, CaseIterable, Sendable {
        case fileVault = "filevault", sip, firewall, gatekeeper
        case secureBoot = "secure_boot", bootstrapToken = "bootstrap_token"
        case osCurrent = "os_current", xprotectCurrent = "xprotect_current"
        case patchCompliance = "patch_compliance", checkedIn = "checked_in"
        case mscp, agent

        /// The control the security report counts for this kind.
        var control: SecurityControl? {
            switch self {
            case .fileVault: .fileVault
            case .sip: .sip
            case .firewall: .firewall
            case .gatekeeper: .gatekeeper
            default: nil
            }
        }

        /// Days a new release is allowed before a Mac counts as behind.
        var defaultGraceDays: Int? {
            switch self {
            case .osCurrent: 30
            case .xprotectCurrent: 14
            default: nil
            }
        }

        /// The kinds that name an agent or a baseline, of which a list can hold several.
        var takesTarget: Bool { self == .agent || self == .mscp }
    }

    let kind: Kind
    var weight: Double
    /// `os_current` and `xprotect_current` only; nil uses `Kind.defaultGraceDays`.
    var graceDays: Int?
    /// The agent (`agent`) or baseline (`mscp`) name, trimmed. Nil for the other kinds, and
    /// for an `mscp` factor that scores the first baseline.
    var target: String?

    init(_ kind: Kind, weight: Double, graceDays: Int? = nil, target: String? = nil) {
        self.kind = kind
        self.weight = weight
        self.graceDays = kind.defaultGraceDays == nil ? nil : graceDays
        let name = target?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.target = kind.takesTarget && name?.isEmpty == false ? name : nil
    }

    /// The kind, or `kind:<name>` for an agent or a named baseline.
    var id: String { target.map { "\(kind.rawValue):\($0)" } ?? kind.rawValue }

    /// One factor per key: names match case-insensitively, as `security_agents` names do.
    var key: String { id.lowercased() }

    var resolvedGraceDays: Int { graceDays ?? kind.defaultGraceDays ?? 0 }

    // MARK: Defaults

    static let defaultAgentWeight = 5.0
    static let defaultMSCPWeight = 10.0

    /// The native factors and their default weights, in the order the Scoring tab lists them.
    static let nativeDefaults: [SecurityScoreFactor] = [
        .init(.fileVault, weight: 15), .init(.sip, weight: 10), .init(.firewall, weight: 10),
        .init(.gatekeeper, weight: 5), .init(.secureBoot, weight: 5),
        .init(.bootstrapToken, weight: 5), .init(.osCurrent, weight: 15),
        .init(.xprotectCurrent, weight: 5), .init(.patchCompliance, weight: 10),
        .init(.checkedIn, weight: 5),
    ]

    /// What a workspace scores when `score_factors` is absent: every native factor, the first
    /// mSCP baseline when one is configured, and each named security agent.
    static func defaults(agents: [String], hasBaseline: Bool) -> [SecurityScoreFactor] {
        var factors = nativeDefaults
        if hasBaseline { factors.append(.init(.mscp, weight: defaultMSCPWeight)) }
        for name in agents {
            let factor = SecurityScoreFactor(.agent, weight: defaultAgentWeight, target: name)
            if factor.target != nil, !factors.contains(where: { $0.key == factor.key }) {
                factors.append(factor)
            }
        }
        return factors
    }

    // MARK: Labels

    /// The factor's name on screens and in reports. `staleDays` names the check-in window and
    /// `staleBasis` the dates it counts.
    func label(staleDays: Int? = nil, staleBasis: [StaleBasis] = StaleBasis.default) -> String {
        switch kind {
        case .fileVault: return "FileVault"
        case .sip: return "SIP"
        case .firewall: return "Firewall"
        case .gatekeeper: return "Gatekeeper"
        case .secureBoot: return "Secure Boot at full security"
        case .bootstrapToken: return "Bootstrap token escrowed"
        case .osCurrent: return "macOS current (\(resolvedGraceDays)-day grace)"
        case .xprotectCurrent: return "XProtect current (\(resolvedGraceDays)-day grace)"
        case .patchCompliance: return "Patch compliance"
        case .checkedIn:
            return staleDays.map { StaleRule(days: $0, basis: staleBasis).checkedInLabel() }
                ?? "Checked in recently"
        case .mscp: return target.map { "mSCP: \($0)" } ?? "mSCP baseline"
        case .agent: return "\(target ?? "Agent") connected"
        }
    }

    // MARK: Basis

    /// The summary's `securityScoreBasis` for the scored factors: `id=weight` each, in list
    /// order, so a changed weight is a changed definition. `,`, `=` and `%` in a name are
    /// percent-encoded.
    static func basis(_ factors: [SecurityScoreFactor]) -> String {
        factors.map { "\(escaped($0.id))=\(weightText($0.weight))" }.joined(separator: ",")
    }

    /// The factor labels a basis names, in order: this format's ids, or an earlier build's
    /// metric names (`fileVault,sip,firewall,crowdstrike,mscp`), whose `crowdstrike` was the
    /// EDR agent. An unknown word is dropped.
    static func labels(
        inBasis basis: String, staleDays: Int? = nil, staleBasis: [StaleBasis] = StaleBasis.default,
        edrAgentName: String? = nil
    ) -> [String] {
        basis.split(separator: ",").compactMap { entry in
            let id = unescaped(String(entry.split(separator: "=").first ?? ""))
            if id == "crowdstrike", let name = edrAgentName, !name.isEmpty {
                return "\(name) connected"
            }
            if let label = legacyBasisLabels[id] { return label }
            let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
            guard let kind = parts.first.flatMap(Kind.init(rawValue:)) else { return nil }
            return SecurityScoreFactor(kind, weight: 0, target: parts.count > 1 ? parts[1] : nil)
                .label(staleDays: staleDays, staleBasis: staleBasis)
        }
    }

    private static let legacyBasisLabels: [String: String] = [
        "fileVault": "FileVault", "crowdstrike": "EDR agent", "xprotect": "XProtect",
        "cve": "CVE", "secureBoot": "Secure Boot",
    ]

    static func weightText(_ weight: Double) -> String {
        weight == weight.rounded() ? String(Int(weight)) : String(format: "%g", weight)
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "%", with: "%25")
            .replacingOccurrences(of: ",", with: "%2C")
            .replacingOccurrences(of: "=", with: "%3D")
    }

    private static func unescaped(_ text: String) -> String {
        text.replacingOccurrences(of: "%2C", with: ",")
            .replacingOccurrences(of: "%3D", with: "=")
            .replacingOccurrences(of: "%25", with: "%")
    }
}

/// What one factor measured: Macs that pass over Macs it could judge. For patch compliance
/// the units are device-title pairs.
struct SecurityScoreMeasure: Sendable, Equatable {
    let passing: Int
    let evaluated: Int

    /// 0–100; nil when nothing could be judged.
    var share: Double? {
        guard evaluated > 0 else { return nil }
        return min(max(Double(passing) / Double(evaluated) * 100, 0), 100)
    }
}
