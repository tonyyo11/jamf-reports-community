import XCTest
@testable import JamfReports

/// 2.6 "trust trio" #1 — metric-threshold webhook alerting. The evaluator is
/// pure; these tests exercise the comparison logic, absent-data guards, and the
/// `AlertsConfig` / `AlertRule` decode.
final class MetricAlertEvaluatorTests: XCTestCase {

    // MARK: - Fixtures

    /// A summary with all optional metrics nil, so each test sets only the
    /// field it exercises. Memberwise init IS in declaration order.
    private func summary(
        date: String = "2026-07-06",
        totalDevices: Int = 600,
        fileVaultPct: Double? = nil,
        compliancePct: Double? = nil,
        staleCount: Int? = nil,
        osCurrentPct: Double? = nil,
        patchPct: Double? = nil,
        securityScore: Double? = nil,
        actionItemsP0: Int? = nil
    ) -> DailySummary {
        DailySummary(
            date: date,
            totalDevices: totalDevices,
            fileVaultPct: fileVaultPct,
            compliancePct: compliancePct,
            staleCount: staleCount,
            osCurrentPct: osCurrentPct,
            crowdstrikePct: nil,
            patchPct: patchPct,
            source: "test",
            securityScore: securityScore,
            actionItemsP0: actionItemsP0
        )
    }

    private func rule(
        _ metric: String, _ when: String, _ threshold: Double, lookback: Int? = nil
    ) -> AlertRule {
        AlertRule(metric: metric, when: when, threshold: threshold, lookbackDays: lookback)
    }

    // MARK: - below / above

    func testBelowFiresWhenUnderThreshold() {
        let hits = MetricAlertEvaluator.evaluate(
            rules: [rule("filevault_pct", "below", 90)],
            current: summary(fileVaultPct: 87.2), prior: nil
        )
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.metricLabel, "FileVault")
        XCTAssertTrue(hits.first?.message.contains("87.2%") ?? false)
        XCTAssertTrue(hits.first?.message.contains("below threshold 90") ?? false)
    }

    func testBelowDoesNotFireAtOrAboveThreshold() {
        let atThreshold = MetricAlertEvaluator.evaluate(
            rules: [rule("filevault_pct", "below", 90)],
            current: summary(fileVaultPct: 90), prior: nil
        )
        XCTAssertTrue(atThreshold.isEmpty, "equal is not below")
        let above = MetricAlertEvaluator.evaluate(
            rules: [rule("filevault_pct", "below", 90)],
            current: summary(fileVaultPct: 95), prior: nil
        )
        XCTAssertTrue(above.isEmpty)
    }

    func testAboveFiresWhenOverThreshold() {
        let hits = MetricAlertEvaluator.evaluate(
            rules: [rule("stale_count", "above", 50)],
            current: summary(staleCount: 73), prior: nil
        )
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.metricLabel, "Stale devices")
        XCTAssertTrue(hits.first?.message.contains("above threshold 50") ?? false)
    }

    func testAboveDoesNotFireAtOrBelowThreshold() {
        let hits = MetricAlertEvaluator.evaluate(
            rules: [rule("stale_count", "above", 50)],
            current: summary(staleCount: 50), prior: nil
        )
        XCTAssertTrue(hits.isEmpty, "equal is not above")
    }

    // MARK: - drops_more_than

    func testDropsMoreThanFiresOnLargeDrop() {
        let current = summary(date: "2026-07-06", patchPct: 31.8)
        let prior = summary(date: "2026-06-29", patchPct: 37.1)
        let hits = MetricAlertEvaluator.evaluate(
            rules: [rule("patch_pct", "drops_more_than", 5, lookback: 7)],
            current: current, prior: prior
        )
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.prior, 37.1)
        let message = hits.first?.message ?? ""
        XCTAssertTrue(message.contains("dropped 5.3pp"), message)
        XCTAssertTrue(message.contains("2026-06-29"), message)
        XCTAssertTrue(message.contains("(37.1%)"), message)
    }

    func testDropsMoreThanDoesNotFireOnRise() {
        let current = summary(patchPct: 40)
        let prior = summary(date: "2026-06-29", patchPct: 30)
        let hits = MetricAlertEvaluator.evaluate(
            rules: [rule("patch_pct", "drops_more_than", 5)],
            current: current, prior: prior
        )
        XCTAssertTrue(hits.isEmpty, "a rise is not a drop")
    }

    func testDropsMoreThanDoesNotFireOnSmallDrop() {
        let current = summary(patchPct: 35)
        let prior = summary(date: "2026-06-29", patchPct: 37)
        let hits = MetricAlertEvaluator.evaluate(
            rules: [rule("patch_pct", "drops_more_than", 5)],
            current: current, prior: prior
        )
        XCTAssertTrue(hits.isEmpty, "2pp drop does not exceed 5pp threshold")
    }

    func testDropsMoreThanNeverFiresWithoutPrior() {
        let hits = MetricAlertEvaluator.evaluate(
            rules: [rule("patch_pct", "drops_more_than", 5)],
            current: summary(patchPct: 10), prior: nil
        )
        XCTAssertTrue(hits.isEmpty, "no prior → absent history is not an alert")
    }

    func testDropsMoreThanNeverFiresWhenPriorMetricIsNil() {
        let current = summary(patchPct: 10)
        let prior = summary(date: "2026-06-29", patchPct: nil)
        let hits = MetricAlertEvaluator.evaluate(
            rules: [rule("patch_pct", "drops_more_than", 5)],
            current: current, prior: prior
        )
        XCTAssertTrue(hits.isEmpty)
    }

    // MARK: - absent-data guard

    func testNilCurrentMetricNeverFires() {
        let below = MetricAlertEvaluator.evaluate(
            rules: [rule("compliance_pct", "below", 90)],
            current: summary(compliancePct: nil), prior: nil
        )
        XCTAssertTrue(below.isEmpty, "absent metric is not an alert")
        let above = MetricAlertEvaluator.evaluate(
            rules: [rule("security_score", "above", 10)],
            current: summary(securityScore: nil), prior: nil
        )
        XCTAssertTrue(above.isEmpty)
    }

    // MARK: - Int-metric bridge

    func testIntMetricEvaluatesViaDoubleBridge() {
        let hits = MetricAlertEvaluator.evaluate(
            rules: [rule("action_items_p0", "above", 20)],
            current: summary(actionItemsP0: 25), prior: nil
        )
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.current, 25)
        XCTAssertTrue(hits.first?.message.contains("25 —") ?? false,
                      "count metric has no percent sign")
    }

    func testTotalDevicesMetricAlwaysHasValue() {
        let hits = MetricAlertEvaluator.evaluate(
            rules: [rule("total_devices", "below", 500)],
            current: summary(totalDevices: 400), prior: nil
        )
        XCTAssertEqual(hits.first?.current, 400)
    }

    // MARK: - Multiple rules

    func testMultipleRulesProduceOneHitEach() {
        let hits = MetricAlertEvaluator.evaluate(
            rules: [
                rule("filevault_pct", "below", 90),
                rule("stale_count", "above", 50),
                rule("sip_pct", "below", 100),  // nil metric → no fire
            ],
            current: summary(fileVaultPct: 80, staleCount: 60), prior: nil
        )
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits.map { $0.metricLabel }, ["FileVault", "Stale devices"])
    }

    // MARK: - AlertsConfig / AlertRule decode + resolvedRules

    func testResolvedRulesDropsMalformedRules() {
        let config = AlertsConfig(
            enabled: true,
            rules: [
                AlertRule(metric: "filevault_pct", when: "below", threshold: 90),
                AlertRule(metric: nil, when: "below", threshold: 90),          // no metric
                AlertRule(metric: "bogus_metric", when: "below", threshold: 90), // unknown metric
                AlertRule(metric: "patch_pct", when: "sideways", threshold: 5),  // unknown op
                AlertRule(metric: "sip_pct", when: "above", threshold: nil),     // no threshold
            ]
        )
        let resolved = config.resolvedRules
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved.first?.metric, "filevault_pct")
    }

    func testAlertsConfigDecodesFromJSON() throws {
        let json = """
        {
          "enabled": true,
          "rules": [
            {"metric": "filevault_pct", "when": "below", "threshold": 90},
            {"metric": "patch_pct", "when": "drops_more_than", "threshold": 5, "lookback_days": 14}
          ]
        }
        """
        let config = try JSONDecoder().decode(AlertsConfig.self, from: Data(json.utf8))
        XCTAssertTrue(config.isEnabled)
        let rules = try XCTUnwrap(config.rules)
        XCTAssertEqual(rules.count, 2)
        XCTAssertEqual(rules[0].metric, "filevault_pct")
        XCTAssertEqual(rules[0].resolvedComparison, .below)
        XCTAssertEqual(rules[0].resolvedLookbackDays, 7, "default lookback when key absent")
        XCTAssertEqual(rules[1].resolvedComparison, .dropsMoreThan)
        XCTAssertEqual(rules[1].resolvedLookbackDays, 14, "lookback_days coding key")
    }

    func testAlertsConfigDisabledByDefault() {
        XCTAssertFalse(AlertsConfig().isEnabled)
        XCTAssertTrue(AlertsConfig().resolvedRules.isEmpty)
    }

    // MARK: - Tolerant threshold decode (YAMLCodec has no float branch)

    /// Decode one `AlertRule` from a JSON payload where `threshold` takes the
    /// given raw shape (a number token or a quoted string). Mirrors how the YAML
    /// path hands JSONDecoder a number for integer scalars and a STRING for
    /// fractional scalars.
    private func decodeRule(thresholdRaw: String) throws -> AlertRule {
        let json = """
        {"metric": "filevault_pct", "when": "below", "threshold": \(thresholdRaw)}
        """
        return try JSONDecoder().decode(AlertRule.self, from: Data(json.utf8))
    }

    func testThresholdDecodesFromIntegerNumber() throws {
        let rule = try decodeRule(thresholdRaw: "90")
        XCTAssertEqual(rule.threshold, 90)
    }

    func testThresholdDecodesFromFractionalNumber() throws {
        let rule = try decodeRule(thresholdRaw: "90.5")
        XCTAssertEqual(rule.threshold, 90.5)
    }

    /// The load-bearing case: a fractional YAML scalar reaches JSONDecoder as the
    /// STRING "90.5" (YAMLCodec has only an Int branch). Must NOT throw.
    func testThresholdDecodesFromFractionalString() throws {
        let rule = try decodeRule(thresholdRaw: "\"90.5\"")
        XCTAssertEqual(rule.threshold, 90.5)
    }

    func testGarbageThresholdStringDegradesToNilAndRuleDrops() throws {
        let rule = try decodeRule(thresholdRaw: "\"garbage\"")
        XCTAssertNil(rule.threshold, "unparseable threshold degrades to nil, never throws")
        let config = AlertsConfig(enabled: true, rules: [rule])
        XCTAssertTrue(config.resolvedRules.isEmpty)
    }

    func testNaNThresholdStringDroppedByResolvedRules() throws {
        // "nan" parses to a Double, but a non-finite threshold is rejected.
        let rule = try decodeRule(thresholdRaw: "\"nan\"")
        XCTAssertEqual(rule.threshold?.isNaN, true)
        let config = AlertsConfig(enabled: true, rules: [rule])
        XCTAssertTrue(config.resolvedRules.isEmpty, "non-finite threshold is dropped")
    }

    func testInfiniteThresholdStringDroppedByResolvedRules() throws {
        let rule = try decodeRule(thresholdRaw: "\"inf\"")
        XCTAssertEqual(rule.threshold?.isInfinite, true)
        let config = AlertsConfig(enabled: true, rules: [rule])
        XCTAssertTrue(config.resolvedRules.isEmpty)
    }

    func testNegativeThresholdDroppedByResolvedRules() {
        let config = AlertsConfig(
            enabled: true,
            rules: [AlertRule(metric: "filevault_pct", when: "below", threshold: -5)]
        )
        XCTAssertTrue(config.resolvedRules.isEmpty, "negative threshold is meaningless")
    }

    func testLookbackDaysDecodesFromQuotedString() throws {
        let json = """
        {"metric": "patch_pct", "when": "drops_more_than",
         "threshold": 5, "lookback_days": "14"}
        """
        let rule = try JSONDecoder().decode(AlertRule.self, from: Data(json.utf8))
        XCTAssertEqual(rule.resolvedLookbackDays, 14, "quoted lookback parses, not throws")
    }

    /// THE key regression: anything malformed inside the alerts block must never
    /// throw out of the WHOLE config decode. A nested object where a threshold
    /// scalar was expected degrades the rule to all-nil; the config still decodes
    /// and the rule is dropped.
    func testMalformedAlertsBlockDoesNotThrowWholeConfig() throws {
        let json = """
        {
          "enabled": true,
          "rules": [
            {"metric": "filevault_pct", "when": "below", "threshold": {"nested": true}},
            {"threshold": "90.5"}
          ]
        }
        """
        let config = try JSONDecoder().decode(AlertsConfig.self, from: Data(json.utf8))
        XCTAssertTrue(config.isEnabled)
        // First rule: threshold was an object → nil; metric/when present but
        // threshold nil → dropped. Second rule: no metric/when → dropped.
        XCTAssertTrue(config.resolvedRules.isEmpty)
    }

    // MARK: - End-to-end through YAMLCodec + ConfigDecoder

    /// A real config.yaml string with a fractional threshold decodes end-to-end
    /// (YAMLCodec → JSON → ConfigDecoder) into one usable resolved rule. This is
    /// the exact path that aborted every collect/generate before the tolerant
    /// decode — YAMLCodec renders `90.5` as the string "90.5".
    func testFractionalThresholdDecodesThroughYAMLPath() throws {
        let yaml = """
        alerts:
          enabled: true
          rules:
            - {metric: "filevault_pct", when: "below", threshold: 90.5}
        """
        let config = try ConfigLoader.loadFromString(yaml)
        let alerts = try XCTUnwrap(config.alerts)
        XCTAssertTrue(alerts.isEnabled)
        let resolved = alerts.resolvedRules
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved.first?.threshold, 90.5)
        XCTAssertEqual(resolved.first?.resolvedComparison, .below)
    }

    // MARK: - C3 skip logging (never fires, stays deterministic)

    func testAbsentResolvedMetricStillReturnsNoHitsDeterministically() {
        // Metric is a valid key but nil in the summary → no hit, logged once.
        // (The log side effect is fire-and-forget; we assert determinism here.)
        let rules = [rule("compliance_pct", "below", 90)]
        let current = summary(compliancePct: nil)
        let first = MetricAlertEvaluator.evaluate(rules: rules, current: current, prior: nil)
        let second = MetricAlertEvaluator.evaluate(rules: rules, current: current, prior: nil)
        XCTAssertTrue(first.isEmpty)
        XCTAssertEqual(first, second, "evaluate is deterministic regardless of the skip log")
    }
}
