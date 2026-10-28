import AppKit
import CoreGraphics
import SwiftUI
import XCTest
@testable import JamfReports

final class ChartPaletteTests: XCTestCase {
    private typealias Band = ComplianceBandingService.Band

    // MARK: Contrast

    /// WCAG 2.x relative luminance and contrast ratio of two sRGB hex colours.
    private func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        func luminance(_ hex: UInt32) -> Double {
            func channel(_ shift: UInt32) -> Double {
                let c = Double((hex >> shift) & 0xFF) / 255
                return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
        }
        let (hi, lo) = (max(luminance(a), luminance(b)), min(luminance(a), luminance(b)))
        return (hi + 0.05) / (lo + 0.05)
    }

    /// Dark: the app's window and card surfaces (`Theme.Colors.winBG`, `winBG2`, `winBG3`) and
    /// the HTML report's dark `--bg`, `--bg2` and `--card`. Light: white, the export canvas
    /// (`Theme.Chart.backgroundLight`) and the HTML report's `--bg`.
    private let darkSurfaces: [UInt32] = [0x1D1D1F, 0x232326, 0x2A2A2E, 0x1A1A2E, 0x16213E, 0x0F3460]
    private let lightSurfaces: [UInt32] = [0xFFFFFF, 0xF8FAFC, 0xF5F7FA]

    /// Ratios checked on 2026-10-28 (WCAG; the lowest over all surfaces of the scheme):
    /// every dark slot 4.61 to 4.68, every light slot 4.83 to 4.94, every band and the
    /// neutral grey 3.38 to 3.45 against the lightest dark and the darkest light surface.
    func testEverySlotKeepsFourAndAHalfToOneOnItsSchemesSurfaces() {
        for slot in 0..<ChartPalette.slotCount {
            for surface in darkSurfaces {
                XCTAssertGreaterThanOrEqual(
                    contrast(ChartPalette.hex(slot: slot, scheme: .dark), surface), 4.5,
                    "dark slot \(slot) on \(String(surface, radix: 16))")
            }
            for surface in lightSurfaces {
                XCTAssertGreaterThanOrEqual(
                    contrast(ChartPalette.hex(slot: slot, scheme: .light), surface), 4.5,
                    "light slot \(slot) on \(String(surface, radix: 16))")
            }
        }
    }

    /// A band is one colour on both schemes, so it must clear 3:1 (non-text graphics) on all
    /// six surfaces. The supervision pair and the neutral grey are held to the same minimum.
    func testBandsNeutralAndSupervisionKeepThreeToOneOnTheirSurfaces() {
        let everywhere = Band.allCases.map(ChartPalette.hex(forBand:)) + [ChartPalette.neutralHex]
        for hex in everywhere {
            for surface in darkSurfaces + lightSurfaces {
                XCTAssertGreaterThanOrEqual(contrast(hex, surface), 3.0,
                                            "\(String(hex, radix: 16)) on \(String(surface, radix: 16))")
            }
        }
        for hex in [UInt32(0x3987E5), 0xD95926] {
            for surface in darkSurfaces {
                XCTAssertGreaterThanOrEqual(contrast(hex, surface), 3.0)
            }
        }
    }

    /// Status colours say ok/warn/danger and nothing else: no series slot may be one.
    func testNoSlotIsAStatusColour() {
        let status: Set<UInt32> = [0x30D158, 0xFF9F0A, 0xFF453A, 0xFFA39A, 0xFFCE7A, 0x0A84FF]
        for slot in 0..<ChartPalette.slotCount {
            XCTAssertFalse(status.contains(ChartPalette.hex(slot: slot, scheme: .dark)))
            XCTAssertFalse(status.contains(ChartPalette.hex(slot: slot, scheme: .light)))
        }
    }

    func testSlotsAreDistinctWithinEachScheme() {
        for scheme in [ChartPalette.Scheme.dark, .light] {
            let hexes = (0..<ChartPalette.slotCount).map { ChartPalette.hex(slot: $0, scheme: scheme) }
            XCTAssertEqual(Set(hexes).count, hexes.count)
        }
    }

    // MARK: Stable assignment

    /// `hashValue` is seeded per process, so equality inside one run cannot prove stability:
    /// these pins are the FNV-1a slot of each key and must never move.
    func testAssignmentIsAFunctionOfTheKeyAcrossRuns() {
        XCTAssertEqual(ChartPalette.hex(forVersion: "26.7", scheme: .dark),
                       ChartPalette.hex(slot: 8, scheme: .dark))
        XCTAssertEqual(ChartPalette.hex(forVersion: "14.7.6", scheme: .light),
                       ChartPalette.hex(slot: 1, scheme: .light))
        XCTAssertEqual(ChartPalette.hex(forTitle: "Firefox", scheme: .dark),
                       ChartPalette.hex(slot: 2, scheme: .dark))
        XCTAssertEqual(ChartPalette.hex(forMetric: .agent("CrowdStrike Falcon"), scheme: .dark),
                       ChartPalette.hex(slot: 8, scheme: .dark))
    }

    func testAVersionKeepsItsColourWhenTheFleetChanges() {
        let alone = ChartPalette.hex(forVersion: "26.7", scheme: .dark)
        // None of these shares 26.7's slot (8), so adding or dropping them moves nothing.
        let fleet = ["15.7.2", "14.7.6", "12.7.6", "27.0", "26.7"]
        XCTAssertEqual(ChartPalette.hexes(for: .version, keys: fleet, scheme: .dark)[4], alone)
        XCTAssertEqual(
            ChartPalette.hexes(for: .version, keys: Array(fleet.dropLast(2)) + ["26.7"],
                               scheme: .dark).last, alone)
    }

    func testOneReleaseSpelledTwoWaysIsOneColour() {
        let hexes = ChartPalette.hexes(
            for: .version, keys: ["macOS 26.7", "26.7.0", "iOS 26.7"], scheme: .light)
        XCTAssertEqual(Set(hexes).count, 1)
    }

    /// "15.6" and "15.7.10" both hash to slot 5: the key that sorts first keeps it and the
    /// other takes the next free slot, so a chart never draws two versions alike.
    func testTwoVersionsOnOneSlotAreSeparatedByAChartThatDrawsBoth() {
        let home = ChartPalette.hex(forVersion: "15.7.10", scheme: .dark)
        XCTAssertEqual(home, ChartPalette.hex(forVersion: "15.6", scheme: .dark))
        let both = ChartPalette.hexes(for: .version, keys: ["15.7.10", "15.6"], scheme: .dark)
        XCTAssertEqual(both[1], home)
        XCTAssertEqual(both[0], ChartPalette.hex(slot: 6, scheme: .dark))
    }

    func testAChartOfManyKeysUsesEverySlotOnceBeforeRepeating() {
        let keys = (0..<ChartPalette.slotCount).map { "Title \($0)" }
        let hexes = ChartPalette.hexes(for: .title, keys: keys, scheme: .dark)
        XCTAssertEqual(Set(hexes).count, ChartPalette.slotCount)
        let more = ChartPalette.hexes(for: .title, keys: keys + ["Extra"], scheme: .dark)
        XCTAssertEqual(more.count, ChartPalette.slotCount + 1)
    }

    func testOtherRowsAreTheNeutralGreyAndTakeNoSlot() {
        let hexes = ChartPalette.hexes(
            for: .version, keys: ["26.7", "Other (3 versions)", "Other"], scheme: .dark)
        XCTAssertEqual(hexes[1], ChartPalette.neutralHex)
        XCTAssertEqual(hexes[2], ChartPalette.neutralHex)
        XCTAssertNotEqual(hexes[0], ChartPalette.neutralHex)
    }

    func testVersionAndTitleWithTheSameTextDoNotShareAHash() {
        let slots = (0..<ChartPalette.slotCount).filter { slot in
            let key = "Sonoma \(slot)"
            return ChartPalette.hex(forTitle: key, scheme: .dark)
                != ChartPalette.hex(forVersion: key, scheme: .dark)
        }
        XCTAssertFalse(slots.isEmpty)
    }

    // MARK: Metrics and bands

    func testEveryMetricHasOneColourAndNoMacMetricsShareOne() {
        let macMetrics = TrendSeries.Metric.allCases.filter { $0 != .mscpBandTrend }
        for scheme in [ChartPalette.Scheme.dark, .light] {
            let hexes = macMetrics.map { ChartPalette.hex(forMetric: $0, scheme: scheme) }
            XCTAssertEqual(Set(hexes).count, hexes.count, "\(scheme)")
        }
        XCTAssertEqual(ChartPalette.hex(forMetric: .mscpBandTrend, scheme: .dark),
                       ChartPalette.hex(forMetric: .compliance, scheme: .dark))
        for metric in TrendSeries.Metric.mobileMetrics {
            XCTAssertEqual(ChartPalette.hex(forMetric: metric, scheme: .light),
                           ChartPalette.hex(forMetric: metric, scheme: .light))
        }
    }

    func testMetricColourIsTheSameFromEveryReader() {
        for metric in TrendSeries.Metric.allCases + TrendSeries.Metric.mobileMetrics {
            XCTAssertEqual(metric.colorHex, ChartPalette.hex(forMetric: metric, scheme: .dark))
            XCTAssertEqual(ChartPalette.cgColor(forMetric: metric),
                           ChartPalette.cgColor(hex: ChartPalette.hex(forMetric: metric, scheme: .light)))
        }
    }

    func testBandColoursAreFixedAndEveryReaderAgrees() {
        XCTAssertEqual(Band.allCases.map(ChartPalette.hex(forBand:)),
                       [0x26984C, 0x2A85EE, 0xA4810D, 0xCF6911, 0xEA5041, ChartPalette.neutralHex])
        XCTAssertEqual(Band.allCases.map(\.colorHex), Band.allCases.map(ChartPalette.hex(forBand:)))
        XCTAssertEqual(ChartPalette.complianceBandColorsWithNoData,
                       Band.allCases.map { ChartPalette.cgColor(hex: ChartPalette.hex(forBand: $0)) })
        XCTAssertEqual(DemoData.complianceBands.map(\.colorHex),
                       [Band.pass, .low, .medLow, .medium, .high].map(\.colorHex))
    }

    func testCGColorKeepsTheChannels() {
        XCTAssertEqual(ChartPalette.cgColor(hex: 0x30D158).components?.first ?? 0, 0x30 / 255.0,
                       accuracy: 0.001)
    }

    func testLegendTextWidthGrowsWithTheLabel() {
        XCTAssertGreaterThan(ChartRenderer.textWidth("Med-Low (11–30)", fontSize: 9),
                             ChartRenderer.textWidth("Pass", fontSize: 9))
    }

    // MARK: Consumers

    func testOverviewMacOSDistributionReadsVersionColoursFromThePalette() {
        let built = OverviewLiveDataLoader.osDistribution(
            counts: ["15.7.10": 50, "14.7.6": 30, "13.7.8": 12, "12.7.6": 5, "11.7.10": 3],
            latestByMajor: [15: "15.7.10"], limit: 4)
        let shown = ["15.7.10", "14.7.6", "13.7.8"]
        XCTAssertEqual(built.rows.prefix(3).map(\.colorHex),
                       ChartPalette.hexes(for: .version, keys: shown, scheme: .dark))
        XCTAssertEqual(built.rows.last?.colorHex, ChartPalette.neutralHex)
    }

    func testComputersMacOSVersionsReadVersionColoursFromThePalette() {
        func mac(_ id: String, _ os: String) -> DeviceInventoryRecord {
            var device = DeviceInventoryRecord.empty(id: id, source: "computers")
            device.osVersion = os
            return device
        }
        let snapshot = DeviceInventorySnapshot(
            devices: [mac("a", "15.4"), mac("b", "14.7")], patchTitles: [], sourceFiles: [],
            warnings: [], generatedAt: "", generatedDate: nil, isDemo: false)
        let rows = snapshot.osDistribution
        XCTAssertEqual(rows.map(\.colorHex),
                       ChartPalette.hexes(for: .version, keys: rows.map(\.version), scheme: .dark))
    }

    func testHTMLBarsDrawVersionsAndTitlesInPaletteColours() {
        let versions = HtmlSectionFormatters.renderBars(
            [(label: "26.7", count: 8), (label: "15.7.10", count: 2)], colored: .version)
        for scheme in [ChartPalette.Scheme.light, .dark] {
            let hex = String(format: "%06X", ChartPalette.hex(forVersion: "26.7", scheme: scheme))
            XCTAssertTrue(versions.contains(hex), hex)
        }
        XCTAssertTrue(versions.contains("--bar:#") && versions.contains(";--bar-dark:#"))

        let titles = HtmlSectionFormatters.renderPercentBars(
            [(label: "Firefox", pct: 80)], colored: .title)
        XCTAssertTrue(titles.contains(String(
            format: "--bar:#%06X", ChartPalette.hex(forTitle: "Firefox", scheme: .light))))

        let plain = HtmlSectionFormatters.renderBars([(label: "2024", count: 3)])
        XCTAssertFalse(plain.contains("--bar"), "a plain category keeps the accent")
    }

    func testHTMLBarColoursSurviveTheShowAllFold() {
        let rows = (0..<14).map { (label: "Title \($0)", count: 14 - $0) }
        let html = HtmlSectionFormatters.renderBars(rows, limit: 3, colored: .title)
        let expected = ChartPalette.hexes(for: .title, keys: rows.map(\.label), scheme: .light)
        for hex in expected { XCTAssertTrue(html.contains(String(format: "--bar:#%06X;", hex))) }
    }

    func testHTMLHistoryChartDrawsEachMetricInItsPaletteColour() {
        let report = HtmlReport(
            config: ReportConfig().withDefaults(),
            dataDir: URL(fileURLWithPath: "/tmp/nonexistent-palette-tests"))
        let svg = report.renderTimelineSVG(summaries: [
            .init(date: "2026-04-01", totalDevices: 90, fileVaultPct: 88, sipPct: 95,
                  compliancePct: 70),
            .init(date: "2026-05-01", totalDevices: 95, fileVaultPct: 92, sipPct: 97,
                  compliancePct: 75),
        ])
        for metric in [TrendSeries.Metric.fileVault, .sip, .compliance] {
            XCTAssertTrue(svg.contains(String(
                format: "--c:#%06X;--c-dark:#%06X",
                ChartPalette.hex(forMetric: metric, scheme: .light),
                ChartPalette.hex(forMetric: metric, scheme: .dark))))
        }
        XCTAssertFalse(svg.contains("#2D5EA2"))
    }

    func testWorkbookBandTrendReadsTheBandColours() {
        let counts = MSCPBandCounts(pass: 1, low: 1, medLow: 1, medium: 1, high: 1, noData: 0)
        let date = Date(timeIntervalSince1970: 1_780_000_000)
        let series = MSCPChartDataBuilder.toStackedSeries(points: [
            .init(date: date, counts: counts, isSalvaged: false)])
        XCTAssertEqual(series.map(\.color), ChartPalette.complianceBandColors)
    }

    @MainActor
    func testSwiftUIFacadeReadsTheSameHexes() {
        func hex(_ color: Color) -> UInt32 {
            let c = NSColor(color).usingColorSpace(.sRGB) ?? .black
            func byte(_ v: CGFloat) -> UInt32 { UInt32((v * 255).rounded()) }
            return byte(c.redComponent) << 16 | byte(c.greenComponent) << 8 | byte(c.blueComponent)
        }
        XCTAssertEqual(hex(Theme.ChartPalette.color(forMetric: .stability)),
                       ChartPalette.hex(forMetric: .stability, scheme: .dark))
        XCTAssertEqual(hex(Theme.ChartPalette.color(forMetric: .stability, scheme: .light)),
                       ChartPalette.hex(forMetric: .stability, scheme: .light))
        XCTAssertEqual(Theme.ChartPalette.colors(forVersions: ["26.7", "Other"]).map(hex),
                       ChartPalette.hexes(for: .version, keys: ["26.7", "Other"], scheme: .dark))
        XCTAssertEqual(Theme.ChartPalette.colors(forTitles: ["Firefox"], scheme: .light).map(hex),
                       ChartPalette.hexes(for: .title, keys: ["Firefox"], scheme: .light))
    }
}
