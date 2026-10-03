import XCTest
@testable import JamfReports

/// The scoped writers each set their keys through a pure function on the document's root
/// mapping, so the keys a screen edits can be read off the writer rather than listed again.
final class ConfigWriterKeysTests: XCTestCase {

    private func root(_ yaml: String) throws -> YAMLCodec.YAMLMapping {
        try XCTUnwrap(YAMLCodec.decode(yaml).root.mapping)
    }

    func testChartsApplySetsTheTwoOptionsAndKeepsTheRestOfTheBlock() throws {
        var mapping = try root("charts:\n  historical_csv_dir: snaps\n")
        ChartsConfigWriter.apply(
            ChartsOptions(savePNGs: false, perMajorCharts: true), to: &mapping)
        let charts = try XCTUnwrap(mapping.value(for: "charts")?.mapping)
        XCTAssertEqual(charts.value(for: "save_png")?.boolValue, false)
        XCTAssertEqual(
            charts.value(for: "os_adoption")?.mapping?.value(for: "per_major_charts")?.boolValue,
            true)
        XCTAssertEqual(charts.value(for: "historical_csv_dir")?.stringValue, "snaps")
    }

    func testNotifyApplySetsFourKeysAndKeepsAnotherTypedKey() throws {
        var mapping = try root("notify:\n  mention: ops\n")
        NotifyConfigWriter.apply(
            enabled: true, provider: "slack", url: " https://hooks.example.test/x ",
            detail: "minimal", to: &mapping)
        let notify = try XCTUnwrap(mapping.value(for: "notify")?.mapping)
        XCTAssertEqual(notify.entries.map(\.key), ["mention", "enabled", "provider", "url", "detail"])
        XCTAssertEqual(notify.value(for: "url")?.stringValue, "https://hooks.example.test/x")
    }

    func testAIApplyDropsTheRetiredKeysAndKeepsAnotherTypedKey() throws {
        var mapping = try root("ai:\n  lock_on_device: true\n  note: kept\n")
        var config = AIConfig()
        config.enabled = true
        AIConfigWriter.apply(config, to: &mapping)
        let ai = try XCTUnwrap(mapping.value(for: "ai")?.mapping)
        XCTAssertEqual(ai.entries.map(\.key), ["note", "enabled", "tier", "reasoning_level"])
    }
}
