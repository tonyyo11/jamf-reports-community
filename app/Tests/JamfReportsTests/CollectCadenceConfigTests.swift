import XCTest
@testable import JamfReports

/// PR-22 T-3: the YAML schema lives in `docs/architecture/tiered-collection-adr.md`.
/// These tests pin every shape the operator (well — the GUI writing on their behalf)
/// can produce so the on-disk format is locked before the resolver, fetch loop, or
/// migration code reads it.
final class CollectCadenceConfigTests: XCTestCase {

    // MARK: - Cadence scalar Codable

    func testCadenceDecodesPositiveInteger() throws {
        let json = Data("43200".utf8)
        let cadence = try JSONDecoder().decode(Cadence.self, from: json)
        XCTAssertEqual(cadence, .seconds(43_200))
    }

    func testCadenceDecodesNeverString() throws {
        let json = Data("\"never\"".utf8)
        let cadence = try JSONDecoder().decode(Cadence.self, from: json)
        XCTAssertEqual(cadence, .never)
    }

    func testCadenceDecodesNeverCaseInsensitive() throws {
        // YAML doesn't lower-case for us; operators write "Never" too.
        let json = Data("\"Never\"".utf8)
        let cadence = try JSONDecoder().decode(Cadence.self, from: json)
        XCTAssertEqual(cadence, .never)
    }

    func testCadenceRejectsNegativeSeconds() {
        let json = Data("-1".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(Cadence.self, from: json)) { error in
            guard case DecodingError.dataCorrupted = error else {
                return XCTFail("Expected dataCorrupted, got \(error)")
            }
        }
    }

    func testCadenceRejectsUnknownString() {
        let json = Data("\"sometimes\"".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(Cadence.self, from: json)) { error in
            guard case DecodingError.dataCorrupted = error else {
                return XCTFail("Expected dataCorrupted, got \(error)")
            }
        }
    }

    func testCadenceEncodesSecondsAsInteger() throws {
        let data = try JSONEncoder().encode(Cadence.seconds(86_400))
        XCTAssertEqual(String(data: data, encoding: .utf8), "86400")
    }

    func testCadenceEncodesNeverAsString() throws {
        let data = try JSONEncoder().encode(Cadence.never)
        XCTAssertEqual(String(data: data, encoding: .utf8), "\"never\"")
    }

    func testCadenceRoundTripsBothForms() throws {
        let cases: [Cadence] = [.seconds(0), .seconds(86_400), .never]
        for c in cases {
            let encoded = try JSONEncoder().encode(c)
            let decoded = try JSONDecoder().decode(Cadence.self, from: encoded)
            XCTAssertEqual(decoded, c, "Round-trip failed for \(c)")
        }
    }

    // MARK: - PerReportCadence dual-shape decode

    func testPerReportCadenceScalarSeconds() throws {
        // overview: 43200
        let json = Data("43200".utf8)
        let entry = try JSONDecoder().decode(PerReportCadence.self, from: json)
        XCTAssertNil(entry.tier, "Scalar form has no tier override")
        XCTAssertEqual(entry.cadence, .seconds(43_200))
    }

    func testPerReportCadenceScalarNever() throws {
        // update-status: never  — the kill switch
        let json = Data("\"never\"".utf8)
        let entry = try JSONDecoder().decode(PerReportCadence.self, from: json)
        XCTAssertNil(entry.tier)
        XCTAssertEqual(entry.cadence, .never)
    }

    func testPerReportCadenceObjectFormWithTierAndSeconds() throws {
        // overview: { tier: refresh, cadence: 43200 }
        let json = Data("""
        {"tier": "refresh", "cadence": 43200}
        """.utf8)
        let entry = try JSONDecoder().decode(PerReportCadence.self, from: json)
        XCTAssertEqual(entry.tier, .refresh)
        XCTAssertEqual(entry.cadence, .seconds(43_200))
    }

    func testPerReportCadenceObjectFormWithTierAndNever() throws {
        // update-device-failures: { tier: scan, cadence: never }
        let json = Data("""
        {"tier": "scan", "cadence": "never"}
        """.utf8)
        let entry = try JSONDecoder().decode(PerReportCadence.self, from: json)
        XCTAssertEqual(entry.tier, .scan)
        XCTAssertEqual(entry.cadence, .never)
    }

    func testPerReportCadenceObjectFormCadenceOnly() throws {
        // overview: { cadence: 86400 }  — object form, no tier override
        let json = Data("""
        {"cadence": 86400}
        """.utf8)
        let entry = try JSONDecoder().decode(PerReportCadence.self, from: json)
        XCTAssertNil(entry.tier)
        XCTAssertEqual(entry.cadence, .seconds(86_400))
    }

    func testPerReportCadenceObjectFormRejectsMissingCadence() {
        // { tier: refresh }  — must specify cadence
        let json = Data("""
        {"tier": "refresh"}
        """.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(PerReportCadence.self, from: json))
    }

    func testPerReportCadenceObjectFormRejectsUnknownTier() {
        let json = Data("""
        {"tier": "warm", "cadence": 60}
        """.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(PerReportCadence.self, from: json))
    }

    // MARK: - CollectCadenceConfig full decode

    func testEmptyConfigDecodes() throws {
        // {} — all fields optional
        let json = Data("{}".utf8)
        let cfg = try JSONDecoder().decode(CollectCadenceConfig.self, from: json)
        XCTAssertNil(cfg.preset)
        XCTAssertNil(cfg.paceSeconds)
        XCTAssertNil(cfg.perReport)
    }

    func testPresetOnlyDecodes() throws {
        let json = Data("""
        {"preset": "on-prem"}
        """.utf8)
        let cfg = try JSONDecoder().decode(CollectCadenceConfig.self, from: json)
        XCTAssertEqual(cfg.preset, .onPrem)
        XCTAssertNil(cfg.perReport)
    }

    func testCustomPresetWithoutPerReportDoesNotThrow() throws {
        // Acceptance criterion: preset: custom without per_report entries
        // must decode without error. T-7 handles the "no entry under custom"
        // case at fetch time (returns .never), so the decoder stays permissive.
        let json = Data("""
        {"preset": "custom"}
        """.utf8)
        let cfg = try JSONDecoder().decode(CollectCadenceConfig.self, from: json)
        XCTAssertEqual(cfg.preset, .custom)
        XCTAssertNil(cfg.perReport)
    }

    func testFullSchemaFromADR() throws {
        // Mirrors the example in docs/architecture/tiered-collection-adr.md
        let json = Data("""
        {
            "preset": "on-prem",
            "pace_seconds": 15,
            "per_report": {
                "update-status": "never",
                "overview": {"tier": "refresh", "cadence": 43200},
                "security": {"tier": "refresh", "cadence": 86400},
                "patch-device-failures": {"tier": "scan", "cadence": 604800}
            }
        }
        """.utf8)
        let cfg = try JSONDecoder().decode(CollectCadenceConfig.self, from: json)
        XCTAssertEqual(cfg.preset, .onPrem)
        XCTAssertEqual(cfg.paceSeconds, 15)
        XCTAssertEqual(cfg.perReport?.count, 4)
        XCTAssertEqual(cfg.perReport?["update-status"]?.cadence, .never)
        XCTAssertNil(cfg.perReport?["update-status"]?.tier)
        XCTAssertEqual(cfg.perReport?["overview"]?.tier, .refresh)
        XCTAssertEqual(cfg.perReport?["overview"]?.cadence, .seconds(43_200))
        XCTAssertEqual(cfg.perReport?["patch-device-failures"]?.tier, .scan)
        XCTAssertEqual(cfg.perReport?["patch-device-failures"]?.cadence, .seconds(604_800))
    }

    func testPerReportPreservesMixedScalarAndObject() throws {
        // The dual-shape support is the whole point — confirm both forms
        // coexist in one decode pass.
        let json = Data("""
        {
            "per_report": {
                "overview": 86400,
                "update-status": "never",
                "patch-status": {"tier": "refresh", "cadence": 43200}
            }
        }
        """.utf8)
        let cfg = try JSONDecoder().decode(CollectCadenceConfig.self, from: json)
        XCTAssertEqual(cfg.perReport?["overview"]?.cadence, .seconds(86_400))
        XCTAssertNil(cfg.perReport?["overview"]?.tier)
        XCTAssertEqual(cfg.perReport?["update-status"]?.cadence, .never)
        XCTAssertEqual(cfg.perReport?["patch-status"]?.tier, .refresh)
    }

    func testRoundTripPreservesAllFields() throws {
        let original = CollectCadenceConfig(
            preset: .cloud,
            paceSeconds: 0,
            perReport: [
                "overview": PerReportCadence(tier: nil, cadence: .seconds(3_600)),
                "update-status": PerReportCadence(tier: nil, cadence: .never),
                "patch-status": PerReportCadence(tier: .refresh, cadence: .seconds(86_400))
            ]
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CollectCadenceConfig.self, from: encoded)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - Wiring into ReportConfig

    func testReportConfigDecodesCollectCadenceFromYAML() throws {
        let yaml = """
        collect_cadence:
          preset: cloud
          pace_seconds: 5
          per_report:
            update-status: never
            overview:
              tier: refresh
              cadence: 43200
        """
        let cfg = try ConfigLoader.loadFromString(yaml)
        XCTAssertEqual(cfg.collectCadence?.preset, .cloud)
        XCTAssertEqual(cfg.collectCadence?.paceSeconds, 5)
        XCTAssertEqual(cfg.collectCadence?.perReport?["update-status"]?.cadence, .never)
        XCTAssertEqual(cfg.collectCadence?.perReport?["overview"]?.tier, .refresh)
        XCTAssertEqual(cfg.collectCadence?.perReport?["overview"]?.cadence, .seconds(43_200))
    }

    func testReportConfigWithoutCollectCadenceStaysNil() throws {
        let yaml = """
        jamf_cli:
          profile: prod
        """
        let cfg = try ConfigLoader.loadFromString(yaml)
        XCTAssertNil(cfg.collectCadence,
                     "Absent collect_cadence must remain nil — T-7 supplies preset defaults")
    }

    // MARK: - customDefaults (PR-23 T-23)

    func testCustomDefaultsCoversEveryKnownKind() {
        let table = CollectCadenceConfig.customDefaults(basePreset: .onPrem)
        XCTAssertEqual(table.count, ReportEngine.knownCollectKinds.count)
        for kind in ReportEngine.knownCollectKinds {
            XCTAssertNotNil(table[kind], "customDefaults must seed a row for \(kind)")
        }
    }

    func testCustomDefaultsFromOnPremMatchesResolvedCadences() {
        let table = CollectCadenceConfig.customDefaults(basePreset: .onPrem)
        // overview is refresh-tier → daily on on-prem.
        XCTAssertEqual(table["overview"]?.tier, .refresh)
        XCTAssertEqual(table["overview"]?.cadence, .seconds(86_400))
        // computers is inventory-tier → weekly on on-prem.
        XCTAssertEqual(table["computers"]?.cadence, .seconds(604_800))
        // update-status is on-prem hard-excluded → seeds as .never, so the
        // operator must lift the kill switch deliberately in the editor.
        XCTAssertEqual(table["update-status"]?.cadence, .never)
    }

    func testCustomDefaultsFromCloudMatchesResolvedCadences() {
        let table = CollectCadenceConfig.customDefaults(basePreset: .cloud)
        XCTAssertEqual(table["overview"]?.cadence, .seconds(43_200), "cloud refresh = twice daily")
        XCTAssertEqual(table["computers"]?.cadence, .seconds(172_800), "cloud inventory = 2 days")
        // Cloud has no hard exclusions — update-status seeds as a real cadence.
        XCTAssertEqual(table["update-status"]?.cadence, .seconds(604_800))
    }

    func testCustomDefaultsEntriesCarryTheReportsTier() {
        let table = CollectCadenceConfig.customDefaults(basePreset: .cloud)
        for kind in ReportEngine.knownCollectKinds {
            XCTAssertEqual(
                table[kind]?.tier, CollectionTier.tier(forReport: kind),
                "\(kind) row must carry its tier-map tier"
            )
        }
    }
}
