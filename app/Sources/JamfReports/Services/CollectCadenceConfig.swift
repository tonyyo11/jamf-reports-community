import Foundation

/// PR-22 T-3: a single entry in `collect_cadence.per_report`.
///
/// The on-disk shape is dual to keep the common case terse:
///
/// ```yaml
/// per_report:
///   update-status: never              # scalar form — kill switch
///   overview: 86400                   # scalar form — bare cadence
///   patch-status:                     # object form — explicit tier override
///     tier: refresh
///     cadence: 43200
/// ```
///
/// `tier` is optional — `nil` means "use whatever tier
/// `CollectionTier.tier(forReport:)` returns for this report kind."
/// Operators typically only set `tier` when they want to promote/demote a
/// report across the Refresh/Inventory/Scan tier toggles (T-9, T-10).
///
/// Decode is permissive about which form is used per entry: the same
/// `per_report` map can mix scalars and objects freely. The `Codable`
/// implementation tries the scalar form first because it's the more common
/// shape in well-curated configs.
struct PerReportCadence: Sendable, Hashable, Equatable {
    /// Explicit tier override. `nil` ⇒ fall back to the default tier from
    /// `CollectionTier.tier(forReport:)` at fetch time.
    var tier: CollectionTier?
    var cadence: Cadence

    init(tier: CollectionTier? = nil, cadence: Cadence) {
        self.tier = tier
        self.cadence = cadence
    }
}

extension PerReportCadence: Codable {
    private enum ObjectKeys: String, CodingKey {
        case tier, cadence
    }

    init(from decoder: Decoder) throws {
        // Scalar form: a bare `Cadence` (int or "never"). Try this first so
        // the typical YAML stays terse and never enters the keyed branch.
        if let scalar = try? decoder.singleValueContainer(),
           let cad = try? scalar.decode(Cadence.self) {
            self.tier = nil
            self.cadence = cad
            return
        }
        // Object form: { tier?: <CollectionTier>, cadence: <Cadence> }
        let keyed = try decoder.container(keyedBy: ObjectKeys.self)
        self.tier = try keyed.decodeIfPresent(CollectionTier.self, forKey: .tier)
        self.cadence = try keyed.decode(Cadence.self, forKey: .cadence)
    }

    func encode(to encoder: Encoder) throws {
        // Prefer the scalar form when there's no tier override — that's how
        // operators write it; the round-trip should preserve that shape.
        if tier == nil {
            var single = encoder.singleValueContainer()
            try single.encode(cadence)
            return
        }
        var keyed = encoder.container(keyedBy: ObjectKeys.self)
        try keyed.encode(tier, forKey: .tier)
        try keyed.encode(cadence, forKey: .cadence)
    }
}

/// PR-22 T-3: top-level `collect_cadence:` block in `config.yaml`.
///
/// Wired into `ReportConfig.collectCadence`. All fields are optional so a
/// fresh workspace's `config.yaml` (or one written before PR-22) decodes to
/// `nil` and the resolver (T-7) substitutes the on-prem preset defaults.
///
/// The "missing config defaults to on-prem" choice is baked into the
/// resolver, not into this struct — keeping the Codable layer permissive
/// means the GUI can show "not configured" honestly rather than implying the
/// user picked on-prem when they actually never touched the screen.
///
/// `preset: custom` deliberately decodes without throwing even when
/// `per_report` is empty or absent; T-7 returns `.never` at fetch time for
/// kinds that have no entry under `custom`, which is the desired safety
/// behavior (the operator opted out of preset defaults — don't sneak the
/// preset back in via decode-time validation).
struct CollectCadenceConfig: Sendable, Hashable, Equatable, Codable {
    var preset: CadencePreset?
    var paceSeconds: Int?
    var perReport: [String: PerReportCadence]?

    private enum CodingKeys: String, CodingKey {
        case preset
        case paceSeconds = "pace_seconds"
        case perReport = "per_report"
    }

    init(
        preset: CadencePreset? = nil,
        paceSeconds: Int? = nil,
        perReport: [String: PerReportCadence]? = nil
    ) {
        self.preset = preset
        self.paceSeconds = paceSeconds
        self.perReport = perReport
    }

    /// PR-23 T-23: seed a full per-report table from a base preset.
    ///
    /// When an operator switches the Settings preset to `.custom`, the
    /// per-report editor starts from the cadences the *previous* preset
    /// resolved — so "switch to custom" is a non-destructive starting
    /// point they can then tweak, not a blank slate.
    ///
    /// Every kind in `ReportEngine.knownCollectKinds` gets an entry: its
    /// tier from `CollectionTier.tier(forReport:)` and its cadence from
    /// `CadenceResolver.resolve` against `basePreset`. On-prem hard
    /// exclusions therefore seed as `.never`, which is the correct
    /// starting point — the operator can lift them deliberately.
    static func customDefaults(basePreset: CadencePreset) -> [String: PerReportCadence] {
        let base = CollectCadenceConfig(preset: basePreset)
        var table: [String: PerReportCadence] = [:]
        for kind in ReportEngine.knownCollectKinds {
            let cadence = CadenceResolver.resolve(report: kind, config: base)
            table[kind] = PerReportCadence(
                tier: CollectionTier.tier(forReport: kind),
                cadence: cadence
            )
        }
        return table
    }
}
