import Foundation

// MARK: - Portable seam model (ungated — compiles on every OS/toolchain)

/// One prioritized finding in a fleet insight. Plain `Sendable` value type so
/// the card and the stub generator construct/render it on every OS version.
struct InsightBullet: Sendable, Equatable {
    enum Severity: String, Sendable, Equatable, CaseIterable {
        case info, warning, critical
    }

    var text: String
    var severity: Severity
}

/// Portable insight result. NEVER carries `@Generable` — it must compile and be
/// constructible outside the macOS-27 gate (`StubInsightGenerator` builds it
/// directly, `AIInsightCard` renders it). The gated `@Generable` companion in
/// this file maps INTO this type before the value crosses the seam.
struct FleetInsight: Sendable, Equatable {
    var headline: String
    var bullets: [InsightBullet]
}

// MARK: - Pure input builder (ungated)

/// The data the generator turns into an insight: the newest fleet summary plus
/// the prior-period summary for deltas. Pure value type, no FoundationModels
/// dependency — built off `TrendStore.filteredSummaries` (oldest-first; `.last`
/// is current, `previous` via `FleetReportEmitter.priorSummary`).
struct FleetInsightInput: Sendable {
    var current: DailySummary
    var previous: DailySummary?

    /// Plain-language prompt context: current fleet facts plus deltas vs. the
    /// prior period. Absent metrics are omitted (never rendered as a misleading
    /// 0%), matching how the trend surfaces treat nil.
    ///
    /// `maxApproxTokens` bounds the size: tokens are approximated at 4 chars per
    /// token (the widely-used rough heuristic; the generator additionally caps
    /// the budget at the live model's `contextSize / 4`). If the rendered
    /// context exceeds the budget it is truncated on a line boundary so a
    /// partial fact is never emitted.
    func promptContext(maxApproxTokens: Int = 1_500) -> String {
        var lines: [String] = []
        lines.append("Fleet snapshot for \(Self.safeDate(current.date)):")
        lines.append("- Total managed devices: \(current.totalDevices)")

        appendPct(&lines, "FileVault encrypted", current.fileVaultPct, previous?.fileVaultPct)
        appendPct(&lines, "OS current", current.osCurrentPct, previous?.osCurrentPct)
        appendPct(&lines, "Patch compliance", current.patchPct, previous?.patchPct)
        appendPct(&lines, "SIP enabled", current.sipPct, previous?.sipPct)
        appendPct(&lines, "Firewall enabled", current.firewallPct, previous?.firewallPct)
        appendPct(&lines, "Gatekeeper enabled", current.gatekeeperPct, previous?.gatekeeperPct)
        appendPct(&lines, "Compliance", current.compliancePct, previous?.compliancePct,
                  proxyNote: current.complianceIsProxy == true)
        appendScore(&lines, "Security score", current.securityScore, previous?.securityScore)

        appendCount(&lines, "Stale devices", current.staleCount, previous?.staleCount)
        appendCount(&lines, "P0 action items", current.actionItemsP0, previous?.actionItemsP0)
        appendCount(&lines, "P1 action items", current.actionItemsP1, previous?.actionItemsP1)
        appendCount(&lines, "P2 action items", current.actionItemsP2, previous?.actionItemsP2)

        if let previous {
            lines.append("Prior period for deltas: \(Self.safeDate(previous.date)).")
        } else {
            lines.append("No prior period available; deltas omitted.")
        }

        return Self.budget(lines, maxApproxTokens: maxApproxTokens)
    }

    /// T-23: `date` is the ONLY free-text string that reaches the prompt (every
    /// other field is a formatted numeric). A tampered summary on synced storage
    /// could otherwise embed prompt-injection text there. Round-trip through the
    /// strict formatter so only a real `yyyy-MM-dd` value is ever emitted.
    static func safeDate(_ raw: String) -> String {
        guard let parsed = SummaryJSONParser.dateFormatter.date(from: raw) else {
            return "unknown date"
        }
        return SummaryJSONParser.dateFormatter.string(from: parsed)
    }

    // MARK: - Rendering helpers

    private func appendPct(
        _ lines: inout [String], _ label: String,
        _ value: Double?, _ prior: Double?, proxyNote: Bool = false
    ) {
        guard let value else { return }
        var line = "- \(label): \(Self.pct(value))"
        if let prior {
            line += " (\(Self.deltaPct(value - prior)) vs prior)"
        }
        if proxyNote { line += " [proxy metric]" }
        lines.append(line)
    }

    private func appendScore(
        _ lines: inout [String], _ label: String, _ value: Double?, _ prior: Double?
    ) {
        guard let value else { return }
        var line = "- \(label): \(Self.num(value))"
        if let prior {
            line += " (\(Self.deltaNum(value - prior)) vs prior)"
        }
        lines.append(line)
    }

    private func appendCount(
        _ lines: inout [String], _ label: String, _ value: Int?, _ prior: Int?
    ) {
        guard let value else { return }
        var line = "- \(label): \(value)"
        if let prior {
            let delta = value - prior
            let sign = delta >= 0 ? "+" : ""
            line += " (\(sign)\(delta) vs prior)"
        }
        lines.append(line)
    }

    // MARK: - Formatting

    private static func pct(_ value: Double) -> String { String(format: "%.1f%%", value) }
    private static func num(_ value: Double) -> String { String(format: "%.1f", value) }
    private static func deltaPct(_ value: Double) -> String {
        String(format: "%@%.1f%%", value >= 0 ? "+" : "", value)
    }
    private static func deltaNum(_ value: Double) -> String {
        String(format: "%@%.1f", value >= 0 ? "+" : "", value)
    }

    /// Truncate the context to `maxApproxTokens` on a line boundary. ~4 chars
    /// per token; drops whole trailing lines so no partial fact is emitted.
    static func budget(_ lines: [String], maxApproxTokens: Int) -> String {
        let maxChars = max(0, maxApproxTokens) * 4
        var kept: [String] = []
        var used = 0
        for line in lines {
            let cost = line.count + 1  // +1 for the joining newline
            if used + cost > maxChars, !kept.isEmpty { break }
            kept.append(line)
            used += cost
        }
        return kept.joined(separator: "\n")
    }
}

// MARK: - Gated @Generable companion (macOS 27 only)

#if canImport(FoundationModels) && compiler(>=6.4)   // 6.4 ships with Xcode 27 only
import FoundationModels

@available(macOS 27, *)
extension FleetIntelligence {
    /// Structured-output companion for guided generation. Lives INSIDE the gate
    /// because `@Generable`/`@Guide` are macOS-27-only macros. Maps 1:1 to the
    /// portable `FleetInsight`; never referenced outside this gate.
    @Generable
    struct GeneratedFleetInsight {
        @Guide(description: "One sentence, plain-language summary of overall fleet health.")
        var headline: String
        @Guide(description: "3 to 6 prioritized findings, each with a severity.")
        var bullets: [GeneratedBullet]
    }

    @Generable
    struct GeneratedBullet {
        @Guide(description: "A single concrete, actionable finding in plain language.")
        var text: String
        @Guide(description: "One of: info, warning, critical.")
        var severity: String
    }

    /// Map the guided-generation value into the portable seam model.
    static func map(_ generated: GeneratedFleetInsight) -> FleetInsight {
        FleetInsight(
            headline: generated.headline,
            bullets: generated.bullets.map {
                InsightBullet(
                    text: $0.text,
                    severity: InsightBullet.Severity(rawValue: $0.severity.lowercased()) ?? .info
                )
            }
        )
    }
}
#endif
