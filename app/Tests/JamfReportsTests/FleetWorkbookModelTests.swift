import XCTest
@testable import JamfReports

/// v2.4.0: pure aggregator behind the consolidated fleet workbook. Synthetic
/// fixtures only — never prod data.
final class FleetWorkbookModelTests: XCTestCase {

    private func s(
        _ date: String, devices: Int, fileVault: Double? = nil,
        sip: Double? = nil, firewall: Double? = nil, gatekeeper: Double? = nil,
        compliance: Double? = nil, security: Double? = nil,
        bands: [String: MSCPBandCounts]? = nil
    ) -> DailySummary {
        DailySummary(
            date: date, totalDevices: devices, fileVaultPct: fileVault,
            compliancePct: compliance, staleCount: 0, osCurrentPct: nil, crowdstrikePct: nil,
            patchPct: nil, sipPct: sip, firewallPct: firewall, gatekeeperPct: gatekeeper,
            securityScore: security, mscpBands: bands
        )
    }

    private func band(
        pass: Int = 0, low: Int = 0, medLow: Int = 0,
        medium: Int = 0, high: Int = 0, noData: Int = 0
    ) -> MSCPBandCounts {
        MSCPBandCounts(pass: pass, low: low, medLow: medLow, medium: medium, high: high, noData: noData)
    }

    func testNilWhenAllProfilesEmpty() {
        XCTAssertNil(FleetWorkbookModel.build(
            groupName: "g", summariesByProfile: [("a", []), ("b", [])],
            lookbackDays: 7, timestamp: "t"))
    }

    func testUniversalDelegatesToFleetRollup() {
        let m = FleetWorkbookModel.build(
            groupName: "g",
            summariesByProfile: [("a", [s("2026-06-01", devices: 100, fileVault: 90, sip: 100)])],
            lookbackDays: 7, timestamp: "t")!
        let keys = Set(m.universal.map(\.key))
        XCTAssertTrue(keys.contains("sip"))
        XCTAssertFalse(keys.contains("compliance"))
    }

    func testTrendDeviceWeightedPerDate() {
        let m = FleetWorkbookModel.build(
            groupName: "g",
            summariesByProfile: [
                ("a", [s("2026-06-01", devices: 100, fileVault: 90)]),
                ("b", [s("2026-06-01", devices: 100, fileVault: 70)]),
            ],
            lookbackDays: 7, timestamp: "t")!
        let point = m.trend.first { $0.date == "2026-06-01" }!
        XCTAssertEqual(point.fileVaultPct ?? 0, 80, accuracy: 0.001)
        XCTAssertEqual(point.devices, 200)
    }

    func testTrendUnionOfDates() {
        let m = FleetWorkbookModel.build(
            groupName: "g",
            summariesByProfile: [
                ("a", [s("2026-06-01", devices: 10), s("2026-06-02", devices: 10)]),
                ("b", [s("2026-06-02", devices: 10)]),
            ],
            lookbackDays: 7, timestamp: "t")!
        XCTAssertEqual(Set(m.trend.map(\.date)), ["2026-06-01", "2026-06-02"])
        XCTAssertEqual(m.trend.first { $0.date == "2026-06-01" }!.devices, 10)
        XCTAssertEqual(m.trend.first { $0.date == "2026-06-02" }!.devices, 20)
    }

    func testSameBaselineSumsIntoOneGroup() {
        let m = FleetWorkbookModel.build(
            groupName: "g",
            summariesByProfile: [
                ("a", [s("2026-06-01", devices: 10, bands: ["NIST": band(pass: 8, low: 2)])]),
                ("b", [s("2026-06-01", devices: 10, bands: ["NIST": band(pass: 6, high: 4)])]),
            ],
            lookbackDays: 7, timestamp: "t")!
        XCTAssertEqual(m.bandGroups.count, 1)
        XCTAssertEqual(m.bandGroups[0].baseline, "NIST")
        XCTAssertEqual(m.bandGroups[0].bands.pass, 14)
        XCTAssertEqual(m.bandGroups[0].bands.high, 4)
        XCTAssertEqual(Set(m.bandGroups[0].profiles), ["a", "b"])
    }

    func testDifferentBaselinesNeverBlend() {
        let m = FleetWorkbookModel.build(
            groupName: "g",
            summariesByProfile: [
                ("a", [s("2026-06-01", devices: 10, bands: ["NIST": band(pass: 8)])]),
                ("b", [s("2026-06-01", devices: 10, bands: ["CIS L1": band(pass: 6)])]),
            ],
            lookbackDays: 7, timestamp: "t")!
        XCTAssertEqual(Set(m.bandGroups.map(\.baseline)), ["NIST", "CIS L1"])
    }

    func testPerProfileRowCarriesOwnBaselineAndCompliance() {
        let m = FleetWorkbookModel.build(
            groupName: "g",
            summariesByProfile: [
                ("a", [s("2026-06-01", devices: 10, compliance: 67,
                         bands: ["NIST": band(pass: 8, low: 2)])]),
            ],
            lookbackDays: 7, timestamp: "t")!
        let row = m.perProfile.first { $0.profile == "a" }!
        XCTAssertEqual(row.baselineNames, ["NIST"])
        XCTAssertEqual(row.compliancePct ?? 0, 67, accuracy: 0.001)
    }
}
