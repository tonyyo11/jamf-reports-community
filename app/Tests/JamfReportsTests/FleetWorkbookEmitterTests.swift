import XCTest
@testable import JamfReports

/// v2.4.0: consolidated fleet workbook emitter. Synthetic fixtures only.
final class FleetWorkbookEmitterTests: XCTestCase {

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

    private func sampleModel() -> FleetWorkbookModel {
        FleetWorkbookModel.build(
            groupName: "Production Fleet",
            summariesByProfile: [
                ("a", [
                    s("2026-06-01", devices: 100, fileVault: 98, sip: 100, firewall: 95,
                      gatekeeper: 100, compliance: 80, security: 97,
                      bands: ["NIST": band(pass: 80, low: 15, high: 5)]),
                    s("2026-06-02", devices: 100, fileVault: 99, sip: 100, firewall: 96,
                      gatekeeper: 100, compliance: 82, security: 98,
                      bands: ["NIST": band(pass: 85, low: 12, high: 3)]),
                ]),
                ("b", [
                    s("2026-06-02", devices: 50, fileVault: 90, sip: 100, firewall: 88,
                      gatekeeper: 100, compliance: 70, security: 92,
                      bands: ["NIST": band(pass: 40, low: 8, high: 2)]),
                ]),
            ],
            lookbackDays: 7, timestamp: "2026-06-18_101010"
        )!
    }

    func testWorkbookHasAllFiveSheets() {
        let wb = FleetWorkbookEmitter.workbook(for: sampleModel())
        for name in ["Fleet Summary", "Per-Profile Breakdown",
                     "Security Posture", "Compliance", "Fleet Trend"] {
            XCTAssertNotNil(wb.sheet(named: name), "missing sheet \(name)")
        }
    }

    func testEmitReturnsNilWhenNoData() throws {
        let url = try FleetWorkbookEmitter.emit(
            group: ReportGroup(name: "g", profiles: ["x"]),
            lookbackDays: 7, timestamp: "t",
            outputDir: FileManager.default.temporaryDirectory,
            summariesFor: { _ in [] })
        XCTAssertNil(url)
    }

    func testEmitWritesXlsxFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let summaries = [
            s("2026-06-18", devices: 100, fileVault: 98, sip: 100, compliance: 80,
              security: 97, bands: ["NIST": band(pass: 90, low: 10)]),
        ]
        let url = try FleetWorkbookEmitter.emit(
            group: ReportGroup(name: "Prod Fleet", profiles: ["a"]),
            lookbackDays: 7, timestamp: "2026-06-18_101010",
            outputDir: dir, summariesFor: { _ in summaries })
        let written = try XCTUnwrap(url)
        XCTAssertEqual(written.pathExtension, "xlsx")
        XCTAssertTrue(FileManager.default.fileExists(atPath: written.path))
    }
}
