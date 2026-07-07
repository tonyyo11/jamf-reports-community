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
        case .totalDevices: return "Total devices"
        }
    }

    /// True for percentage metrics (0–100). Used only for message formatting.
    var isPercentage: Bool {
        switch self {
        case .staleCount, .actionItemsP0, .totalDevices: return false
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
        case .totalDevices: return Double(summary.totalDevices)
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

    private static func makeHit(
        metric: AlertMetric, value: Double, prior: Double?,
        ruleDescription: String, message: String
    ) -> MetricAlertHit {
        MetricAlertHit(
            metricLabel: metric.label, ruleDescription: ruleDescription,
            current: value, prior: prior, message: message
        )
    }

    /// Format a value with its unit for the message (percentages get a "%").
    private static func format(_ value: Double, _ metric: AlertMetric) -> String {
        metric.isPercentage ? "\(trim(value))%" : trim(value)
    }

    /// Drop a trailing ".0" so whole numbers read cleanly ("90" not "90.0").
    private static func trim(_ value: Double) -> String {
        if value.rounded() == value { return String(Int(value)) }
        return String(format: "%.1f", value)
    }
}
