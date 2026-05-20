import XCTest
@testable import JamfReports

/// PR-22 T-7: `CadenceResolver.resolve(report:config:)` composes preset
/// defaults, per-report overrides, hard exclusions, and missing-config
/// fallbacks into a single `Cadence` answer per (report, config) pair.
///
/// The rules, pinned here so the precedence is unambiguous (highest
/// precedence first):
///
/// 1. On-prem hard exclusions (`update-status`, `update-device-failures`)
///    always resolve to `.never` regardless of `per_report` overrides.
///    Operators who want these on a self-hosted server must switch to
///    `preset: custom` and configure the cadence explicitly.
/// 2. `per_report[<kind>].cadence` wins over preset defaults — this is
///    why operators set it.
/// 3. Otherwise, fall back to `preset.defaultCadence(for: tier)` where
///    tier comes from `per_report[<kind>].tier` if set, else
///    `CollectionTier.tier(forReport:)`.
/// 4. Under `preset: custom`, anything without a `per_report` entry
///    resolves to `.never`. Safer to skip than to invent a default the
///    operator didn't ask for.
/// 5. Missing config (nil) means "no `collect_cadence:` block at all" —
///    treated as on-prem defaults so a fresh `workspace-init` workspace
///    behaves sensibly without a GUI write. PR-23's GUI bakes a real
///    preset into config.yaml on first save.
/// 6. Unknown report kinds (not in `CollectionTier.tierMap`) resolve to
///    `.never` on on-prem/cloud presets — refuse to fetch something we
///    have no policy for. On `custom` the `per_report` override path
///    can still set a cadence (operators add new kinds that way).
final class CadenceResolverTests: XCTestCase {

    // MARK: - Missing config defaults to on-prem

    func testNilConfigUsesOnPremDefaults() {
        XCTAssertEqual(
            CadenceResolver.resolve(report: "overview", config: nil),
            .seconds(86_400),
            "Missing collect_cadence ⇒ on-prem refresh = daily"
        )
        XCTAssertEqual(
            CadenceResolver.resolve(report: "app-status", config: nil),
            .seconds(604_800),
            "Missing collect_cadence ⇒ on-prem inventory = weekly"
        )
        XCTAssertEqual(
            CadenceResolver.resolve(report: "update-status", config: nil),
            .never,
            "Missing collect_cadence ⇒ on-prem hard exclusions apply"
        )
    }

    func testEmptyConfigUsesOnPremDefaults() {
        // `collect_cadence: {}` — preset not specified.
        let cfg = CollectCadenceConfig()
        XCTAssertEqual(
            CadenceResolver.resolve(report: "overview", config: cfg),
            .seconds(86_400)
        )
    }

    // MARK: - On-prem preset defaults

    func testOnPremRefreshTierDefault() {
        let cfg = CollectCadenceConfig(preset: .onPrem)
        XCTAssertEqual(
            CadenceResolver.resolve(report: "overview", config: cfg),
            .seconds(86_400)
        )
    }

    func testOnPremInventoryTierDefault() {
        let cfg = CollectCadenceConfig(preset: .onPrem)
        XCTAssertEqual(
            CadenceResolver.resolve(report: "computers", config: cfg),
            .seconds(604_800)
        )
    }

    func testOnPremScanTierDefault() {
        let cfg = CollectCadenceConfig(preset: .onPrem)
        XCTAssertEqual(
            CadenceResolver.resolve(report: "ea-results", config: cfg),
            .seconds(604_800)
        )
    }

    func testOnPremHardExclusionsAlwaysNever() {
        let cfg = CollectCadenceConfig(preset: .onPrem)
        XCTAssertEqual(
            CadenceResolver.resolve(report: "update-status", config: cfg),
            .never
        )
        XCTAssertEqual(
            CadenceResolver.resolve(report: "update-device-failures", config: cfg),
            .never
        )
    }

    func testOnPremHardExclusionsIgnorePerReportOverride() {
        // Operator tried to override the kill switch — preset still wins.
        let cfg = CollectCadenceConfig(
            preset: .onPrem,
            perReport: ["update-status": PerReportCadence(cadence: .seconds(3_600))]
        )
        XCTAssertEqual(
            CadenceResolver.resolve(report: "update-status", config: cfg),
            .never,
            "Hard exclusions must win over per_report on on-prem — operators switch to .custom to escape"
        )
    }

    // MARK: - Cloud preset defaults

    func testCloudRefreshTierDefault() {
        let cfg = CollectCadenceConfig(preset: .cloud)
        XCTAssertEqual(
            CadenceResolver.resolve(report: "overview", config: cfg),
            .seconds(43_200)
        )
    }

    func testCloudInventoryTierDefault() {
        let cfg = CollectCadenceConfig(preset: .cloud)
        XCTAssertEqual(
            CadenceResolver.resolve(report: "computers", config: cfg),
            .seconds(172_800)
        )
    }

    func testCloudNoHardExclusions() {
        let cfg = CollectCadenceConfig(preset: .cloud)
        XCTAssertEqual(
            CadenceResolver.resolve(report: "update-status", config: cfg),
            .seconds(604_800),
            "Cloud has no hard exclusions — update-status falls through to scan tier weekly"
        )
    }

    // MARK: - per_report overrides

    func testPerReportCadenceOverridesPresetDefault() {
        let cfg = CollectCadenceConfig(
            preset: .onPrem,
            perReport: ["overview": PerReportCadence(cadence: .seconds(3_600))]
        )
        XCTAssertEqual(
            CadenceResolver.resolve(report: "overview", config: cfg),
            .seconds(3_600),
            "per_report cadence wins over preset default"
        )
    }

    func testPerReportNeverOverridesPresetDefault() {
        let cfg = CollectCadenceConfig(
            preset: .cloud,
            perReport: ["app-status": PerReportCadence(cadence: .never)]
        )
        XCTAssertEqual(
            CadenceResolver.resolve(report: "app-status", config: cfg),
            .never,
            "Operator's per_report 'never' is the kill switch on cloud presets"
        )
    }

    func testPerReportTierOverrideIsExplicitAboutCadence() {
        // The dual-shape per_report entry includes both tier and cadence;
        // the resolver never synthesizes "default cadence for the new tier"
        // — operators state the cadence they actually want. This keeps the
        // YAML self-explanatory at the cost of one extra integer.
        let cfg = CollectCadenceConfig(
            preset: .cloud,
            perReport: [
                "overview": PerReportCadence(tier: .scan, cadence: .seconds(604_800))
            ]
        )
        XCTAssertEqual(
            CadenceResolver.resolve(report: "overview", config: cfg),
            .seconds(604_800)
        )
    }

    // MARK: - Custom preset

    func testCustomPresetWithoutPerReportEntryIsNever() {
        let cfg = CollectCadenceConfig(preset: .custom)
        XCTAssertEqual(
            CadenceResolver.resolve(report: "overview", config: cfg),
            .never,
            "Custom + no per_report entry = .never. Don't invent defaults the operator didn't pick."
        )
    }

    func testCustomPresetWithPerReportEntryUsesIt() {
        let cfg = CollectCadenceConfig(
            preset: .custom,
            perReport: ["overview": PerReportCadence(cadence: .seconds(7_200))]
        )
        XCTAssertEqual(
            CadenceResolver.resolve(report: "overview", config: cfg),
            .seconds(7_200)
        )
    }

    func testCustomPresetCanOverrideOnPremHardExclusions() {
        // The escape valve for operators who genuinely want update-status
        // on a self-hosted server: switch to custom + set the cadence
        // explicitly. The on-prem-only hard exclusion list does not apply.
        let cfg = CollectCadenceConfig(
            preset: .custom,
            perReport: ["update-status": PerReportCadence(cadence: .seconds(86_400))]
        )
        XCTAssertEqual(
            CadenceResolver.resolve(report: "update-status", config: cfg),
            .seconds(86_400)
        )
    }

    // MARK: - Unknown report kinds

    func testUnknownReportOnOnPremIsNever() {
        let cfg = CollectCadenceConfig(preset: .onPrem)
        XCTAssertEqual(
            CadenceResolver.resolve(report: "experimental-thing", config: cfg),
            .never,
            "Unknown kind = no tier mapping = .never (refuse to fetch policy-less)"
        )
    }

    func testUnknownReportWithPerReportCadenceWorksOnAnyPreset() {
        // Operator adds a kind we don't know about — they still drive
        // its cadence via per_report. This is how custom kinds added
        // upstream get scheduled before the tier map ships them.
        let cfg = CollectCadenceConfig(
            preset: .onPrem,
            perReport: ["experimental-thing": PerReportCadence(cadence: .seconds(3_600))]
        )
        XCTAssertEqual(
            CadenceResolver.resolve(report: "experimental-thing", config: cfg),
            .seconds(3_600)
        )
    }
}
