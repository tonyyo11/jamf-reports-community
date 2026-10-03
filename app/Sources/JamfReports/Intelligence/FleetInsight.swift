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

/// What a screen hands the generator: a header, the screen's focus and its
/// aggregate facts. Aggregates only — never a device, user or host name.
struct FleetInsightInput: Sendable, Equatable {
    let title: String
    let focus: String
    let facts: [Fact]
    let notes: [String]

    enum Value: Sendable, Equatable {
        case percent(Double)
        case count(Int)
        case number(Double)
        case text(String)
    }

    /// Which way is good: a nonzero change is called "better" or "worse" from it.
    /// A neutral fact prints its value only.
    enum Polarity: Sendable, Equatable {
        case higherIsBetter, lowerIsBetter, neutral
    }

    /// `label` is a state phrase: a share reads "<label> on N% of devices; <complement> on M%".
    /// `complement` is used only for `.percent` with non-neutral polarity; a `prior` of
    /// another `Value` case prints no change.
    struct Fact: Sendable, Equatable {
        let label: String
        let value: Value
        let prior: Value?
        let polarity: Polarity
        /// The other side of a device share ("not enabled"); nil when the
        /// remainder is not a device state, as for an average.
        var complement: String? = nil
    }

    /// The title, the focus, one line per fact, then the notes. Changes are in
    /// percentage points for shares, signed integers for counts and one decimal
    /// for numbers, each followed by "better" or "worse" when nonzero.
    ///
    /// `maxApproxTokens` bounds the size: tokens are approximated at 4 chars per
    /// token (the widely-used rough heuristic; the generator additionally caps
    /// the budget at the live model's `contextSize / 4`). If the rendered
    /// context exceeds the budget it is truncated on a line boundary so a
    /// partial fact is never emitted.
    func promptContext(maxApproxTokens: Int = 1_500) -> String {
        let lines = [clean(title), "Focus: \(clean(focus))"] + facts.map(\.line) + notes.map(clean)
        return Self.budget(lines, maxApproxTokens: maxApproxTokens)
    }

    /// The most characters any one field (title, focus, label, text value, note) sends.
    static let fieldLimit = 200

    /// T-23: a summary's `date` is free text on synced storage and could carry
    /// prompt-injection text. Round-trip through the strict formatter so only a
    /// real `yyyy-MM-dd` value is ever emitted.
    static func safeDate(_ raw: String) -> String {
        guard let parsed = SummaryJSONParser.dateFormatter.date(from: raw) else {
            return "unknown date"
        }
        return SummaryJSONParser.dateFormatter.string(from: parsed)
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

// MARK: - Fleet digest

extension FleetInsightInput {
    /// The Overview's input: the newest daily summary, with changes against
    /// `previous`. Absent metrics are left out, never sent as 0.
    static func fleet(current: DailySummary, previous: DailySummary?) -> FleetInsightInput {
        func share(_ label: String, _ key: KeyPath<DailySummary, Double?>,
                   _ complement: String? = nil, comparable: Bool = true) -> Fact? {
            current[keyPath: key].map {
                Fact(label: label, value: .percent($0),
                     prior: comparable ? previous?[keyPath: key].map(Value.percent) : nil,
                     polarity: .higherIsBetter, complement: complement)
            }
        }
        func count(_ label: String, _ key: KeyPath<DailySummary, Int?>) -> Fact? {
            current[keyPath: key].map {
                Fact(label: label, value: .count($0),
                     prior: previous?[keyPath: key].map(Value.count), polarity: .lowerIsBetter)
            }
        }
        let proxy = current.complianceIsProxy == true ? " [proxy metric]" : ""
        let facts: [Fact?] = [
            Fact(label: "Total managed devices", value: .count(current.totalDevices),
                 prior: nil, polarity: .neutral),
            share("FileVault encrypted", \.fileVaultPct, "not encrypted"),
            // osCurrentPct counts a Mac on a major the feed does not list as not current.
            share("OS current", \.osCurrentPct, "not on the newest release of its "
                  + "macOS version, or version not listed"),
            // A figure on the other basis (`patchPctBasis`) is no prior for this one.
            share("Patch compliance", \.patchPct,
                  comparable: previous?.patchPctBasis == current.patchPctBasis),
            // "SIP" alone reads as the VoIP protocol to the on-device model.
            share("System Integrity Protection (SIP) enabled", \.sipPct, "not enabled"),
            share("Firewall enabled", \.firewallPct, "not enabled"),
            share("Gatekeeper enabled", \.gatekeeperPct, "not enabled"),
            share("Compliance" + proxy, \.compliancePct),
            current.securityScore.map {
                Fact(label: "Security score", value: .number($0),
                     prior: previous?.securityScore.map(Value.number), polarity: .higherIsBetter)
            },
            count("Stale devices", \.staleCount),
            count("P0 action items", \.actionItemsP0),
            count("P1 action items", \.actionItemsP1),
            count("P2 action items", \.actionItemsP2),
        ]
        let note = previous.map { "Prior period for deltas: \(safeDate($0.date))." }
            ?? "No prior period available; deltas omitted."
        return FleetInsightInput(
            title: "Fleet snapshot for \(safeDate(current.date))",
            focus: "overall fleet health, the largest gaps, and what changed since the "
                + "prior period.",
            facts: facts.compactMap { $0 },
            notes: [note]
        )
    }
}

// MARK: - Rendering

extension FleetInsightInput.Value {
    var text: String {
        switch self {
        case .percent(let value): return String(format: "%.1f%%", tenths(value))
        case .count(let value): return "\(value)"
        case .number(let value): return String(format: "%.1f", tenths(value))
        case .text(let value): return value
        }
    }
}

/// Rounded once, so a share and its remainder always add up to 100.0%.
private func tenths(_ value: Double) -> Double { (value * 10).rounded() / 10 }

/// One line of at most `fieldLimit` characters, so a field can neither start a
/// prompt line of its own nor crowd out the facts.
private func clean(_ field: String) -> String {
    let flat = field.replacing(#/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]+/#, with: " ")
    return String(flat.trimmingCharacters(in: .whitespaces).prefix(FleetInsightInput.fieldLimit))
}

/// One decimal with its sign; never "-0.0".
private func signed(_ delta: Double) -> String {
    String(format: "%@%.1f", delta >= 0 ? "+" : "", delta == 0 ? 0 : delta)
}

extension FleetInsightInput.Fact {
    /// A share with a complement states both sides, so the model never has to
    /// invert "SIP enabled: 1.0%" itself. A neutral fact prints its value only.
    var line: String {
        let label = clean(self.label), shown = clean(value.text)
        var line = "- \(label): \(shown)"
        guard polarity != .neutral else { return line }
        if case .percent(let share) = value, let complement = complement.map(clean) {
            let rest = FleetInsightInput.Value.percent(max(0, 100 - tenths(share))).text
            // A complement with its own comma would otherwise run into "on".
            let on = complement.contains(",") ? ", on" : " on"
            line = "- \(label) on \(shown) of devices; \(complement)\(on) \(rest)"
        }
        return change.map { line + " (\($0))" } ?? line
    }

    private var change: String? {
        let delta: Double, shown: String
        switch (value, prior) {
        case (.percent(let now), .percent(let then)?):
            delta = tenths(now - then)
            shown = signed(delta) + " pp"
        case (.number(let now), .number(let then)?):
            delta = tenths(now - then)
            shown = signed(delta)
        case (.count(let now), .count(let then)?):
            delta = Double(now - then)
            shown = "\(now >= then ? "+" : "")\(now - then)"
        default:
            return nil
        }
        guard delta != 0, polarity != .neutral else { return "\(shown) vs prior" }
        let better = (delta > 0) == (polarity == .higherIsBetter)
        return "\(shown) vs prior, \(better ? "better" : "worse")"
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
