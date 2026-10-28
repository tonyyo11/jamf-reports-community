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

    /// Ratios checked on 2026-10-28 (WCAG; the lowest over all surfaces of the scheme): every
    /// dark slot and shade 4.61 to 4.68 or better, every light one 4.83 to 4.94 or better,
    /// every band and the neutral grey 3.38 to 3.45 against the lightest dark and the darkest
    /// light surface.
    func testEverySlotAndShadeKeepsFourAndAHalfToOneOnItsSchemesSurfaces() {
        let tables: [(name: String, count: Int, hex: (Int, Int, ChartPalette.Scheme) -> UInt32)] = [
            ("slot", ChartPalette.slotCount, { ChartPalette.hex(slot: $0, shade: $1, scheme: $2) }),
            ("agent", ChartPalette.agentSlotCount,
             { ChartPalette.hex(agentSlot: $0, shade: $1, scheme: $2) }),
        ]
        for table in tables {
            for slot in 0..<table.count {
                for shade in 0..<ChartPalette.shadeCount {
                    for surface in darkSurfaces {
                        XCTAssertGreaterThanOrEqual(
                            contrast(table.hex(slot, shade, .dark), surface), 4.5,
                            "dark \(table.name) \(slot).\(shade) on \(String(surface, radix: 16))")
                    }
                    for surface in lightSurfaces {
                        XCTAssertGreaterThanOrEqual(
                            contrast(table.hex(slot, shade, .light), surface), 4.5,
                            "light \(table.name) \(slot).\(shade) on \(String(surface, radix: 16))")
                    }
                }
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

    /// Status colours say ok/warn/danger and nothing else: no series colour may be one exactly.
    /// Near matches are accepted (the FileVault green and the stale orange sit beside the
    /// status green and amber); a metric's meaning is in its label and legend, and CLAUDE.md's
    /// rule is that a series never *borrows* `Theme.Colors`, which this still catches.
    func testNoSeriesColourIsAStatusColour() {
        let status: Set<UInt32> = [0x30D158, 0xFF9F0A, 0xFF453A, 0xFFA39A, 0xFFCE7A, 0x0A84FF]
        for slot in 0..<ChartPalette.slotCount + ChartPalette.agentSlotCount {
            for shade in 0..<ChartPalette.shadeCount {
                for scheme in [ChartPalette.Scheme.dark, .light] {
                    let hex = slot < ChartPalette.slotCount
                        ? ChartPalette.hex(slot: slot, shade: shade, scheme: scheme)
                        : ChartPalette.hex(agentSlot: slot - ChartPalette.slotCount,
                                           shade: shade, scheme: scheme)
                    XCTAssertFalse(status.contains(hex))
                }
            }
        }
    }

    func testEveryColourIsDistinctWithinEachScheme() {
        for scheme in [ChartPalette.Scheme.dark, .light] {
            var hexes: [UInt32] = []
            for shade in 0..<ChartPalette.shadeCount {
                hexes += (0..<ChartPalette.slotCount).map {
                    ChartPalette.hex(slot: $0, shade: shade, scheme: scheme)
                }
                hexes += (0..<ChartPalette.agentSlotCount).map {
                    ChartPalette.hex(agentSlot: $0, shade: shade, scheme: scheme)
                }
            }
            XCTAssertEqual(Set(hexes).count, hexes.count)
        }
    }

    // MARK: Stable assignment

    /// `hashValue` is seeded per process, so equality inside one run cannot prove stability:
    /// these pins are the release slot (versions) or the FNV-1a slot and shade (titles,
    /// agents) of each key and must never move.
    func testAssignmentIsAFunctionOfTheKeyAcrossRuns() {
        // 26 closes up on 15 as release 20, slot 8; minor 7 is shade 1.
        XCTAssertEqual(ChartPalette.hex(forVersion: "26.7", scheme: .dark),
                       ChartPalette.hex(slot: 8, shade: 1, scheme: .dark))
        // Slot 2; minor 7 + patch 6 = 13 is shade 1.
        XCTAssertEqual(ChartPalette.hex(forVersion: "14.7.6", scheme: .light),
                       ChartPalette.hex(slot: 2, shade: 1, scheme: .light))
        XCTAssertEqual(ChartPalette.hex(forTitle: "Firefox", scheme: .dark),
                       ChartPalette.hex(slot: 2, shade: 1, scheme: .dark))
        XCTAssertEqual(ChartPalette.hex(forMetric: .agent("CrowdStrike Falcon"), scheme: .dark),
                       ChartPalette.hex(agentSlot: 0, shade: 2, scheme: .dark))
    }

    /// Under the first design these keys shared hashes and were moved by the other keys in
    /// their chart. A key's colour is now its own, so a chart's colour for it is always the
    /// single-key colour, whatever else is drawn with it.
    func testAVersionsColourIsTheSameWhateverElseIsCharted() {
        let fleet = ["15.7.10", "15.6", "15.7.2", "13.7.8", "12.7.6", "26.6", "27.0", "14.7.6"]
        for scheme in [ChartPalette.Scheme.dark, .light] {
            let all = ChartPalette.hexes(for: .version, keys: fleet, scheme: scheme)
            let subset = ChartPalette.hexes(
                for: .version, keys: Array(fleet.reversed().prefix(3)), scheme: scheme)
            for (key, hex) in zip(fleet, all) {
                XCTAssertEqual(hex, ChartPalette.hex(forVersion: key, scheme: scheme), key)
            }
            for (key, hex) in zip(fleet.reversed().prefix(3), subset) {
                XCTAssertEqual(hex, ChartPalette.hex(forVersion: key, scheme: scheme), key)
            }
        }
    }

    func testATitlesColourIsTheSameWhateverElseIsCharted() {
        let titles = (0..<30).map { "Title \($0)" } + ["Firefox", "Google Chrome", "Zoom"]
        for scheme in [ChartPalette.Scheme.dark, .light] {
            let all = ChartPalette.hexes(for: .title, keys: titles, scheme: scheme)
            let subset = ChartPalette.hexes(for: .title, keys: ["Zoom", "Firefox"], scheme: scheme)
            for (key, hex) in zip(titles, all) {
                XCTAssertEqual(hex, ChartPalette.hex(forTitle: key, scheme: scheme), key)
            }
            XCTAssertEqual(subset, [all[all.count - 1], all[all.count - 3]])
        }
    }

    func testConsecutiveMajorsAlwaysHaveDistinctHues() {
        // macOS 10 would share a hue with 28 (and 11 with 29); neither pair is supported at once.
        let macOS = ["11", "12", "13", "14", "15", "26", "27", "28"]
        let iOS = ["15", "16", "17", "18", "26", "27"]
        for majors in [macOS, iOS] {
            let hexes = majors.map { ChartPalette.hex(forVersion: $0, scheme: .dark) }
            XCTAssertEqual(Set(hexes).count, majors.count, "\(majors)")
        }
    }

    func testMinorAndPatchStepTheShadeOfOneHue() {
        // Same major, so the same slot; 26.6, 26.7 and 26.8 take the three shades in turn.
        let shades = ["26.6", "26.7", "26.8"].map { ChartPalette.hex(forVersion: $0, scheme: .dark) }
        XCTAssertEqual(shades, (0..<3).map { ChartPalette.hex(slot: 8, shade: $0, scheme: .dark) })
        XCTAssertNotEqual(ChartPalette.hex(forVersion: "15.7.10", scheme: .light),
                          ChartPalette.hex(forVersion: "15.7.2", scheme: .light))
    }

    func testOneReleaseSpelledTwoWaysIsOneColour() {
        let hexes = ChartPalette.hexes(
            for: .version, keys: ["macOS 26.7", "26.7.0", "iOS 26.7"], scheme: .light)
        XCTAssertEqual(Set(hexes).count, 1)
    }

    func testOtherAndUnknownAreExactlyTheNeutralGrey() {
        for key in ["Other", "other", "Unknown", "Other (3 versions)"] {
            XCTAssertEqual(ChartPalette.hex(forVersion: key, scheme: .dark), ChartPalette.neutralHex)
            XCTAssertEqual(ChartPalette.hex(forTitle: key, scheme: .light), ChartPalette.neutralHex)
        }
        XCTAssertNotEqual(ChartPalette.hex(forTitle: "Other Software", scheme: .dark),
                          ChartPalette.neutralHex)
    }

    func testVersionAndTitleWithTheSameTextDoNotShareAHash() {
        let differing = (0..<ChartPalette.slotCount).filter { index in
            let key = "Sonoma \(index)"
            return ChartPalette.hex(forTitle: key, scheme: .dark)
                != ChartPalette.hex(forVersion: key, scheme: .dark)
        }
        XCTAssertFalse(differing.isEmpty)
    }

    func testAgentsNeverShareAColourWithAMetric() {
        let names = DemoData.securityAgents.map(\.name) + ["CrowdStrike Falcon", "Nessus", "Jamf Protect"]
        for scheme in [ChartPalette.Scheme.dark, .light] {
            let metrics = Set((TrendSeries.Metric.allCases + TrendSeries.Metric.mobileMetrics)
                .map { ChartPalette.hex(forMetric: $0, scheme: scheme) })
            for name in names {
                XCTAssertFalse(metrics.contains(ChartPalette.hex(forMetric: .agent(name), scheme: scheme)),
                               name)
            }
        }
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
        // A mobile metric is its Mac counterpart's colour.
        let counterpart: [TrendSeries.Metric: TrendSeries.Metric] = [
            .mobileManaged: .managedDevices, .mobileOSCurrent: .osCurrent,
            .mobilePasscode: .fileVault, .mobileSupervised: .firewall,
            .mobileDataProtection: .sip, .mobileStale: .stale, .mobileJailbroken: .securityScore,
        ]
        XCTAssertEqual(Set(counterpart.keys), Set(TrendSeries.Metric.mobileMetrics))
        for (mobile, mac) in counterpart {
            XCTAssertEqual(ChartPalette.hex(forMetric: mobile, scheme: .light),
                           ChartPalette.hex(forMetric: mac, scheme: .light))
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

    /// The dark rule and the print override have the same specificity, so the override must
    /// come later, inside `@media print`, or a report printed from the dark theme keeps its
    /// light-on-dark colours on white paper.
    func testPrintReassertsTheLightColoursUnderTheDarkTheme() throws {
        let css = HtmlSectionFormatters.additionalCSS
        let dark = try XCTUnwrap(css.range(
            of: "[data-theme=\"dark\"] .cohort-bar-fill { background: var(--bar-dark"))
        let printBlock = try XCTUnwrap(css.range(of: "@media print"))
        XCTAssertLessThan(dark.lowerBound, printBlock.lowerBound)
        let printCSS = css[printBlock.lowerBound...]
        XCTAssertTrue(printCSS.contains(
            "[data-theme=\"dark\"] .cohort-bar-fill { background: var(--bar, var(--accent)); }"))
        XCTAssertTrue(printCSS.contains("[data-theme=\"dark\"] .chart-series { color: var(--c); }"))
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
        XCTAssertEqual(hex(Theme.ChartColors.color(forMetric: .stability)),
                       ChartPalette.hex(forMetric: .stability, scheme: .dark))
        XCTAssertEqual(hex(Theme.ChartColors.color(forMetric: .stability, scheme: .light)),
                       ChartPalette.hex(forMetric: .stability, scheme: .light))
        XCTAssertEqual(Theme.ChartColors.colors(forVersions: ["26.7", "Other"]).map(hex),
                       ChartPalette.hexes(for: .version, keys: ["26.7", "Other"], scheme: .dark))
        XCTAssertEqual(Theme.ChartColors.colors(forTitles: ["Firefox"], scheme: .light).map(hex),
                       ChartPalette.hexes(for: .title, keys: ["Firefox"], scheme: .light))
    }
}
