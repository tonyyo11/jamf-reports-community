import Foundation

/// A metric key an alert rule can target, mapped to a `DailySummary` value.
///
/// Raw values are the snake_case, config-facing keys documented in
/// `config.example.yaml`. Percentage metrics are on a 0–100 scale (the same
/// scale `DailySummary` stores); count/total metrics are whole numbers bridged
/// to `Double` so a single comparison path serves both.
enum AlertMetric: String, CaseIterable, Sendable {
    case fileVaultPct = "filevault_pct"
    case compliancePct = "compliance_pct"
    case osCurrentPct = "os_current_pct"
    case patchPct = "patch_pct"
    case sipPct = "sip_pct"
    case firewallPct = "firewall_pct"
    case gatekeeperPct = "gatekeeper_pct"
    case secureBootPct = "secure_boot_pct"
    case bootstrapPct = "bootstrap_pct"
    case xprotectPct = "xprotect_pct"
    case cvePct = "cve_pct"
    case mscpScorePct = "mscp_score_pct"
    case securityScore = "security_score"
    case staleCount = "stale_count"
    case actionItemsP0 = "action_items_p0"
    case totalDevices = "total_devices"
    // Mobile devices (`DailySummary.mobile`); each pct is `met / of`.
    case mobileOSCurrentPct = "mobile_os_current_pct"
    case mobilePasscodePct = "mobile_passcode_pct"
    case mobileSupervisedPct = "mobile_supervised_pct"
    case mobileDataProtectionPct = "mobile_data_protection_pct"
    case mobileStaleCount = "mobile_stale_count"
    case mobileJailbrokenCount = "mobile_jailbroken_count"
    // Jamf Protect (`DailySummary.protect*`); absent without a Protect collect.
    case protectComputerCount = "protect_computer_count"
    case protectMatchedPct = "protect_matched_pct"
    case protectOpenAlertCount = "protect_open_alert_count"
    case protectHighAlertCount = "protect_high_alert_count"

    /// Short human label for the alert card (never a percentage sign — the
    /// message string carries units).
    var label: String {
        switch self {
        case .fileVaultPct: return "FileVault"
        case .compliancePct: return "Compliance"
        case .osCurrentPct: return "OS currency"
        case .patchPct: return "Patch"
        case .sipPct: return "SIP"
        case .firewallPct: return "Firewall"
        case .gatekeeperPct: return "Gatekeeper"
        case .secureBootPct: return "Secure Boot"
        case .bootstrapPct: return "Bootstrap Token"
        case .xprotectPct: return "XProtect"
        case .cvePct: return "CVE remediation"
        case .mscpScorePct: return "mSCP score"
        case .securityScore: return "Security score"
        case .staleCount: return "Stale devices"
        case .actionItemsP0: return "P0 action items"
        case .totalDevices: return "Total Macs"
        case .mobileOSCurrentPct: return "Mobile OS currency"
        case .mobilePasscodePct: return "Mobile passcode compliance"
        case .mobileSupervisedPct: return "Supervised mobile devices"
        case .mobileDataProtectionPct: return "Mobile data protection"
        case .mobileStaleCount: return "Stale mobile devices"
        case .mobileJailbrokenCount: return "Jailbroken mobile devices"
        case .protectComputerCount: return "Jamf Protect computers"
        case .protectMatchedPct: return "Jamf Protect match with inventory"
        case .protectOpenAlertCount: return "Jamf Protect open alerts"
        case .protectHighAlertCount: return "Jamf Protect high alerts"
        }
    }

    /// True for percentage metrics (0–100). Used only for message formatting.
    var isPercentage: Bool {
        switch self {
        case .staleCount, .actionItemsP0, .totalDevices, .mobileStaleCount,
             .mobileJailbrokenCount, .protectComputerCount, .protectOpenAlertCount,
             .protectHighAlertCount: return false
        default: return true
        }
    }

    /// The metric's value in a summary, or nil when the source was absent /
    /// failed to decode. Int fields are bridged to `Double`.
    func value(in summary: DailySummary) -> Double? {
        switch self {
        case .fileVaultPct: return summary.fileVaultPct
        case .compliancePct: return summary.compliancePct
        case .osCurrentPct: return summary.osCurrentPct
        case .patchPct: return summary.patchPct
        case .sipPct: return summary.sipPct
        case .firewallPct: return summary.firewallPct
        case .gatekeeperPct: return summary.gatekeeperPct
        case .secureBootPct: return summary.secureBootPct
        case .bootstrapPct: return summary.bootstrapPct
        case .xprotectPct: return summary.xprotectPct
        case .cvePct: return summary.cvePct
        case .mscpScorePct: return summary.mscpScorePct
        case .securityScore: return summary.securityScore
        case .staleCount: return summary.staleCount.map(Double.init)
        case .actionItemsP0: return summary.actionItemsP0.map(Double.init)
        // A day with no Macs (a mobile-only fleet, or a collect that read none) measured no
        // count, so a `below` or `drops_more_than` rule on it never fires.
        case .totalDevices: return summary.totalDevices > 0 ? Double(summary.totalDevices) : nil
        // An absent pair (no device reports the field) is no value, so it never fires.
        case .mobileOSCurrentPct: return summary.mobile?.osCurrent?.pct
        case .mobilePasscodePct: return summary.mobile?.passcode?.pct
        case .mobileSupervisedPct: return summary.mobile?.supervised?.pct
        case .mobileDataProtectionPct: return summary.mobile?.dataProtection?.pct
        case .mobileStaleCount: return summary.mobile?.stale.map(Double.init)
        case .mobileJailbrokenCount: return summary.mobile?.jailbroken.map(Double.init)
        case .protectComputerCount: return summary.protectComputerCount.map(Double.init)
        case .protectMatchedPct: return summary.protectMatched?.pctOneDecimal
        case .protectOpenAlertCount: return summary.protectOpenAlerts.map(Double.init)
        // The alerts snapshot existed but held no open high alert: a real 0.
        case .protectHighAlertCount:
            return (summary.protectAlertCounts?["high"]
                ?? (summary.protectOpenAlerts != nil ? 0 : nil)).map(Double.init)
        }
    }
}

/// A single tripped alert — one `MetricAlertEvaluator.evaluate` result.
struct MetricAlertHit: Sendable, Equatable {
    /// Human label for the metric (e.g. "FileVault").
    let metricLabel: String
    /// The rule that tripped, restated ("below 90", "drops_more_than 5").
    let ruleDescription: String
    /// The fresh value that tripped the rule (0–100 for percentages).
    let current: Double
    /// The prior value used by a `drops_more_than` rule; nil for below/above.
    let prior: Double?
    /// One-line message suitable for a webhook fact value.
    let message: String
}

/// Pure metric-threshold evaluator (2.6 "trust trio" #1). No I/O.
///
/// Percentage metrics are compared on a 0–100 scale (the scale `DailySummary`
/// stores); count/total metrics compare as whole numbers. A rule whose metric
/// is absent from `current` never fires — missing data is not an alert (a
/// separate dead-man feature covers absence). A `drops_more_than` rule with no
/// usable `prior` also never fires.
enum MetricAlertEvaluator {

    /// Evaluate `rules` against the fresh `current` summary, using `prior` for
    /// `drops_more_than`. Returns one hit per tripped rule, in rule order.
    static func evaluate(
        rules: [AlertRule],
        current: DailySummary,
        prior: DailySummary?
    ) -> [MetricAlertHit] {
        rules.compactMap { rule in hit(for: rule, current: current, prior: prior) }
    }

    private static func hit(
        for rule: AlertRule,
        current: DailySummary,
        prior: DailySummary?
    ) -> MetricAlertHit? {
        guard let metric = rule.resolvedMetric,
              let comparison = rule.resolvedComparison,
              let threshold = rule.threshold else { return nil }
        // C3: a resolved rule whose metric is absent from today's summary never
        // fires (missing data is not an alert), but log once so a never-populated
        // metric is distinguishable from a metric that's present-and-not-tripped.
        // The metric key is not PII; evaluate stays otherwise deterministic.
        guard let value = metric.value(in: current) else {
            AppLogger.event(.webhook, .notice,
                "alert rule for \(metric.rawValue) skipped — metric not present in today's summary")
            return nil
        }
        switch comparison {
        case .below:
            guard value < threshold else { return nil }
            return makeHit(metric: metric, value: value, prior: nil,
                           ruleDescription: "below \(trim(threshold))",
                           message: "\(format(value, metric)) — below threshold \(trim(threshold))")
        case .above:
            guard value > threshold else { return nil }
            return makeHit(metric: metric, value: value, prior: nil,
                           ruleDescription: "above \(trim(threshold))",
                           message: "\(format(value, metric)) — above threshold \(trim(threshold))")
        case .dropsMoreThan:
            guard let priorSummary = prior,
                  let priorValue = metric.value(in: priorSummary) else { return nil }
            guard sameBasis(metric, current, priorSummary) else { return nil }
            let drop = priorValue - value
            guard drop > threshold else { return nil }
            let unit = metric.isPercentage ? "pp" : ""
            let msg = "\(format(value, metric)) — dropped \(trim(drop))\(unit) vs "
                + "\(priorSummary.date) (\(format(priorValue, metric)))"
            return makeHit(metric: metric, value: value, prior: priorValue,
                           ruleDescription: "drops_more_than \(trim(threshold))",
                           message: msg)
        }
    }

    /// Whether a drop in `metric` compares like with like. A compliance_pct drop isn't
    /// comparable across a measurement-basis change: the 4-control proxy (~96%) and a
    /// real mSCP failure count (~67%) are different scales, so enabling
    /// compliance.baselines would fabricate a huge false drop. Likewise a patch_pct drop
    /// across the per-title mean and the device-weighted figure (`patchPctBasis`, epic
    /// #207 C1), and a security_score drop across a change in the metrics it weighs
    /// (`securityScoreBasis`, epic #207 H1): adding EDR coverage to a score moves it without
    /// the fleet changing. Absent (nil) basis on both sides is treated as unchanged and
    /// still fires.
    private static func sameBasis(
        _ metric: AlertMetric, _ current: DailySummary, _ prior: DailySummary
    ) -> Bool {
        switch metric {
        case .compliancePct: return current.complianceIsProxy == prior.complianceIsProxy
        case .patchPct: return current.patchPctBasis == prior.patchPctBasis
        case .securityScore: return current.securityScoreBasis == prior.securityScoreBasis
        default: return true
        }
    }

    private static func makeHit(
        metric: AlertMetric, value: Double, prior: Double?,
        ruleDescription: String, message: String
    ) -> MetricAlertHit {
        MetricAlertHit(
            metricLabel: metric.label, ruleDescription: ruleDescription,
            current: value, prior: prior, message: message
        )
    }

    /// Stable per-rule dedup identity for a hit. `metricLabel` maps 1:1 to the
    /// metric and `ruleDescription` restates the operator + threshold, so two
    /// runs that trip the same rule produce the same key — the per-day ledger
    /// uses it to card each rule at most once per day. Derived from the hit's own
    /// fields (no separate rule handle needed).
    static func dedupKey(for hit: MetricAlertHit) -> String {
        "\(hit.metricLabel)|\(hit.ruleDescription)"
    }

    /// Format a value with its unit for the message (percentages get a "%").
    private static func format(_ value: Double, _ metric: AlertMetric) -> String {
        metric.isPercentage ? "\(trim(value))%" : trim(value)
    }

    /// Drop a trailing ".0" so whole numbers read cleanly ("90" not "90.0"). `Int(exactly:)` is
    /// nil outside Int's range and for inf/nan, which a shared summary.json can carry, where
    /// `Int(_:)` would trap.
    static func trim(_ value: Double) -> String {
        if let whole = Int(exactly: value) { return String(whole) }
        return String(format: "%.1f", value)
    }
}
