import Foundation

/// PR-22: how often a report should be fetched.
///
/// - `.seconds(N)`: fetch when the last successful run is at least
///   N seconds old. Cadence math is inclusive: a report fetched
///   exactly N seconds ago is due.
/// - `.never`: never fetch. The "kill switch" for reports that
///   crash the server (e.g., `update-status` on memory-fragile
///   on-prem Jamf Pro) or that the operator never wants. Wins over
///   "never fetched" — a `.never` report is never due even if it
///   has no state file.
///
/// `.never` is the type-safe alternative to overloading nil. Callers
/// can distinguish "report has no per_report config (use preset
/// default)" from "operator explicitly disabled this report" by
/// keeping nil and `.never` semantically separate.
enum Cadence: Sendable, Hashable {
    case seconds(Int)
    case never

    /// Short human-readable label used in run-log "[skip] not due" lines.
    /// `seconds(N)` renders as `"<N>s"` rather than a translated duration
    /// because operators copying log lines into bug reports want byte-
    /// stable strings, not "1 day" / "1d" / "24h" inconsistency across
    /// locales.
    var label: String {
        switch self {
        case .seconds(let n): return "\(n)s"
        case .never:          return "never"
        }
    }
}

/// PR-22 T-3: YAML-friendly Codable for `Cadence`.
///
/// On disk:
/// - `cadence: 43200` → `.seconds(43200)` (non-negative integer)
/// - `cadence: never` (or `"Never"`, case-insensitive) → `.never`
///
/// Stored as a single value (scalar) — never a one-key object — so the
/// surrounding `per_report` schema can also be a scalar in the bare-cadence
/// shorthand (`overview: 43200`). Negative seconds and unknown strings throw
/// `DecodingError.dataCorrupted` so a typo surfaces with the YAML line range
/// `JSONDecoder` carries through from `ConfigLoader`'s conversion.
extension Cadence: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let int = try? container.decode(Int.self) {
            guard int >= 0 else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Cadence seconds must be non-negative, got \(int)"
                )
            }
            self = .seconds(int)
            return
        }
        if let raw = try? container.decode(String.self) {
            let normalized = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if normalized == "never" {
                self = .never
                return
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Cadence string must be 'never', got '\(raw)'"
            )
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Cadence must be a non-negative integer or the string 'never'"
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .seconds(let n): try container.encode(n)
        case .never:          try container.encode("never")
        }
    }
}

/// PR-22 T-4 + T-7: pure scheduling decisions.
///
/// `isDue(lastRun:cadence:now:)` is the core gate that
/// `ReportEngine.collect` consults per report before launching a
/// jamf-cli subprocess. It has no I/O — callers (T-8) read the state
/// file via `StateFileStore` and pass the timestamp in.
///
/// `resolve(report:config:)` (T-7) sits on top of this and picks the
/// cadence from a `CollectCadenceConfig` + preset; both functions
/// live here so the resolver + decision API form a tight, testable
/// pair.
enum CadenceResolver {

    /// Decide whether `report` should be fetched at `now` given its
    /// last successful fetch and target cadence.
    ///
    /// - `lastRun: nil` (never fetched) is due unless cadence is `.never`.
    /// - `lastRun` ≥ cadence ago is due.
    /// - `lastRun` < cadence ago is not due.
    /// - `cadence: .never` is never due regardless of `lastRun`.
    ///
    /// `now` defaults to `Date()` for production callers; tests inject
    /// a fixed clock so the suite is deterministic.
    static func isDue(
        lastRun: Date?,
        cadence: Cadence,
        now: Date = Date()
    ) -> Bool {
        switch cadence {
        case .never:
            return false
        case .seconds(let interval):
            guard let lastRun else { return true }
            let elapsed = now.timeIntervalSince(lastRun)
            return elapsed >= TimeInterval(interval)
        }
    }

    /// Resolve the target `Cadence` for `report` from `config`.
    ///
    /// Precedence (highest → lowest):
    ///
    /// 1. On-prem hard exclusions (`update-status`,
    ///    `update-device-failures`) → `.never`. Operators escape by
    ///    switching to `preset: custom` + explicit `per_report` entry.
    /// 2. `per_report[<kind>].cadence` if present → use it.
    /// 3. `preset.defaultCadence(for: tier)` where tier comes from
    ///    `per_report[<kind>].tier` if set, else
    ///    `CollectionTier.tier(forReport:)`.
    /// 4. Under `preset: custom` with no `per_report` entry → `.never`.
    /// 5. Unknown report kind on `on-prem`/`cloud` → `.never`.
    ///
    /// `config: nil` (no `collect_cadence:` block at all) is treated as
    /// on-prem defaults so a fresh workspace works without a GUI write.
    /// PR-23's GUI writes a real preset on first save so this fallback
    /// is only the first-run experience.
    ///
    /// PR-22 T-7.
    static func resolve(
        report: String,
        config: CollectCadenceConfig?
    ) -> Cadence {
        let preset = config?.preset ?? .onPrem

        // Rule 1: on-prem hard exclusions win over everything.
        if preset.hardExcludedKinds.contains(report) {
            return .never
        }

        let entry = config?.perReport?[report]

        // Rule 2: per_report cadence wins over preset defaults.
        if let cadence = entry?.cadence {
            return cadence
        }

        // Rule 4: custom with no entry = .never.
        if preset == .custom {
            return .never
        }

        // Rule 3 + 5: tier lookup → preset default; nil tier (unknown
        // kind) on a non-custom preset = .never.
        let tier = entry?.tier ?? CollectionTier.tier(forReport: report)
        guard let tier else {
            return .never
        }
        if let defaultSeconds = preset.defaultCadence(for: tier) {
            return .seconds(defaultSeconds)
        }
        return .never
    }
}
