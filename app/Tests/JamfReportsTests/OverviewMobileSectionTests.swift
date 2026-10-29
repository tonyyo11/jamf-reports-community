import XCTest
@testable import JamfReports

/// The Overview's Mobile Devices section and the composition rule behind it (mobile spec 3.2):
/// which device types an environment holds, which sections and score cards that leaves out,
/// and the section's tiles. Every figure is invented.
@MainActor
final class OverviewMobileSectionTests: XCTestCase {

    private typealias Metric = TrendSeries.Metric

    private func summary(
        macs: Int, mobileCount: Int? = nil, mobile: MobileSummary? = nil
    ) -> DailySummary {
        DailySummary(
            date: "2026-10-28", totalDevices: macs, fileVaultPct: nil, compliancePct: nil,
            staleCount: nil, osCurrentPct: nil, crowdstrikePct: nil, patchPct: nil,
            mobileDeviceCount: mobileCount, mobile: mobile)
    }

    private func mobileFigures(
        supervised: MobileSummary.Share? = .init(met: 100, of: 118),
        passcode: MobileSummary.Share? = .init(met: 110, of: 115),
        osCurrent: MobileSummary.Share? = .init(met: 90, of: 112),
        stale: Int? = 6, jailbroken: Int? = 0, updateErrors: Int? = nil
    ) -> MobileSummary {
        MobileSummary(
            managed: 118, unmanaged: 2, supervised: supervised, passcode: passcode,
            dataProtection: nil, activationLock: nil, osCurrent: osCurrent, stale: stale,
            jailbroken: jailbroken, updateErrors: updateErrors)
    }

    // MARK: - Composition from the newest summary

    func testCompositionReadsMacsAndMobileFromTheSummary() {
        XCTAssertEqual(EnvironmentComposition(summary: summary(macs: 40, mobileCount: 12)), .mixed)
        XCTAssertEqual(
            EnvironmentComposition(summary: summary(macs: 40, mobile: mobileFigures())), .mixed)
        XCTAssertEqual(EnvironmentComposition(summary: summary(macs: 0, mobileCount: 12)),
                       .mobileOnly, "totalDevices 0 is how a mobile-only summary says no Macs")
        XCTAssertEqual(EnvironmentComposition(summary: summary(macs: 40)), .macsOnly)
    }

    /// An absent mobile count is no evidence of mobile devices, and a zero count is none; a
    /// summary with neither kind of device says nothing about the environment.
    func testAbsentOrZeroMobileCountIsNoMobileAndNoDevicesIsUnknown() {
        XCTAssertEqual(EnvironmentComposition(summary: summary(macs: 40, mobileCount: nil)),
                       .macsOnly)
        XCTAssertEqual(EnvironmentComposition(summary: summary(macs: 40, mobileCount: 0)),
                       .macsOnly)
        XCTAssertEqual(EnvironmentComposition(summary: summary(macs: 0, mobileCount: 0)), .unknown)
        XCTAssertEqual(EnvironmentComposition(summary: summary(macs: 0)), .unknown)
        XCTAssertEqual(EnvironmentComposition(summary: nil), .unknown)
    }

    /// The writer gives `totalDevices` 0 on a day a mixed fleet's Mac sources are past the cache
    /// age while the mobile list landed; that one day must not read as mobile only.
    func testOneDayWithNoMacsAfterADayWithMacsStaysMixed() {
        let mobileDay = summary(macs: 0, mobileCount: 30)
        XCTAssertEqual(
            EnvironmentComposition(summary: mobileDay, previous: summary(macs: 40, mobileCount: 30)),
            .mixed)
        XCTAssertEqual(
            EnvironmentComposition(summary: mobileDay, previous: summary(macs: 0, mobileCount: 30)),
            .mobileOnly, "Two days in a row with no Macs is mobile only")
        XCTAssertEqual(EnvironmentComposition(summary: mobileDay, previous: nil), .mobileOnly,
                       "A first summary has no earlier day to disagree")
    }

    func testCompositionOfTheSummaryTheWriterProducesForAMobileOnlyFleet() {
        let written = ReportEngine.mobileOnlySummary(
            date: "2026-10-28", mobileDeviceCount: 30, mobile: mobileFigures(),
            collectionSources: nil, collectedByHost: nil)
        XCTAssertEqual(EnvironmentComposition(summary: written), .mobileOnly)
    }

    // MARK: - Availability per section

    func testAvailabilityPerSectionPerComposition() {
        let macSections: [OverviewSection] = [
            .osDistribution, .topFailingRules, .securityAgents, .recentActivity,
        ]
        let everywhere: [OverviewSection] = [
            .aiInsight, .managedDevices, .scoreCards, .workspaceStatus,
        ]
        for composition in [EnvironmentComposition.macsOnly, .mixed, .unknown] {
            for section in macSections {
                XCTAssertEqual(section.availability(in: composition), .shown,
                               "\(section) in \(composition)")
            }
        }
        for section in macSections {
            XCTAssertEqual(section.availability(in: .mobileOnly).reason,
                           "No Macs in this environment.", "\(section)")
        }
        for composition in [EnvironmentComposition.macsOnly, .mixed, .mobileOnly, .unknown] {
            for section in everywhere {
                XCTAssertEqual(section.availability(in: composition), .shown,
                               "\(section) in \(composition)")
            }
        }
        XCTAssertEqual(OverviewSection.mobileDevices.availability(in: .mixed), .shown)
        XCTAssertEqual(OverviewSection.mobileDevices.availability(in: .mobileOnly), .shown)
        XCTAssertEqual(OverviewSection.mobileDevices.availability(in: .macsOnly).reason,
                       "No mobile devices in the latest daily summary.")
        XCTAssertNotNil(OverviewSection.mobileDevices.availability(in: .unknown).reason,
                        "No evidence of mobile devices yet: nothing to draw")
    }

    func testEverySectionHasAnAvailabilityInEveryComposition() {
        for section in OverviewSection.allCases {
            for composition in [EnvironmentComposition.macsOnly, .mixed, .mobileOnly, .unknown] {
                let availability = section.availability(in: composition)
                XCTAssertEqual(availability.isShown, availability.reason == nil)
            }
        }
    }

    // MARK: - Saved layouts

    /// A layout saved before the section existed gets it at the end, shown; nothing else moves.
    func testASavedLayoutGainsTheMobileSectionAtTheEndShown() {
        let saved = OverviewLayout(
            order: OverviewSection.allCases.filter { $0 != .mobileDevices }.reversed(),
            hidden: [.recentActivity])
        let parsed = OverviewLayout.parse(saved.serialized)

        XCTAssertEqual(parsed.order.last, .mobileDevices)
        XCTAssertEqual(
            Array(parsed.order.dropLast()),
            OverviewSection.allCases.filter { $0 != .mobileDevices }.reversed())
        XCTAssertTrue(parsed.isVisible(.mobileDevices))
        XCTAssertEqual(parsed.hidden, [.recentActivity])
    }

    func testRawValueIsStableAndTheStandardLayoutPairsItBesideMacOSDistribution() {
        XCTAssertEqual(OverviewSection.mobileDevices.rawValue, "mobileDevices")
        XCTAssertTrue(OverviewSection.mobileDevices.isHalfWidth)
        let rows = OverviewLayout.rows(OverviewLayout.standard.visible) { $0.isHalfWidth }
        XCTAssertTrue(rows.contains([.osDistribution, .mobileDevices]))
    }

    // MARK: - Score cards

    func testMetricsAreOfferedByDeviceType() {
        let policy = SecurityControlPolicy.default
        XCTAssertTrue(Metric.fileVault.isOffered(under: policy, in: .macsOnly))
        XCTAssertTrue(Metric.fileVault.isOffered(under: policy, in: .mixed))
        XCTAssertFalse(Metric.fileVault.isOffered(under: policy, in: .mobileOnly))
        XCTAssertTrue(Metric.managedDevices.isOffered(under: policy, in: .unknown))
        XCTAssertFalse(Metric.mobilePasscode.isOffered(under: policy, in: .macsOnly))
        XCTAssertFalse(Metric.mobilePasscode.isOffered(under: policy, in: .unknown))
        XCTAssertTrue(Metric.mobilePasscode.isOffered(under: policy, in: .mixed))
        XCTAssertTrue(Metric.mobilePasscode.isOffered(under: policy, in: .mobileOnly))
        for metric in Metric.allCases {
            XCTAssertTrue(metric.isOffered(under: policy), "\(metric): the default is unknown")
        }
    }

    func testAMixedFleetShowsTheSavedCardsAndNoMobileDefault() {
        let selected: [Metric] = [.stability, .fileVault]
        let shown = OverviewScoreCards.shown(
            selected: selected, composition: .mixed, isOffered: { _ in true })
        XCTAssertEqual(shown, selected, "A mixed fleet keeps today's Overview")
    }

    func testAMobileOnlyEnvironmentFiltersTheSelectionThenFallsBackToTheMobileDefaults() {
        let offered: (Metric) -> Bool = { $0.isOffered(under: .default, in: .mobileOnly) }
        let macOnly: [Metric] = [.stability, .activeDevices, .fileVault, .compliance]

        XCTAssertEqual(
            OverviewScoreCards.shown(
                selected: macOnly, composition: .mobileOnly, isOffered: offered),
            [.mobileOSCurrent, .mobilePasscode, .mobileSupervised, .mobileDataProtection])
        XCTAssertEqual(
            OverviewScoreCards.shown(
                selected: macOnly + [.mobileStale], composition: .mobileOnly, isOffered: offered),
            [.mobileStale], "One offered card in the selection is all that shows")
        XCTAssertEqual(
            OverviewScoreCards.shown(selected: [], composition: .mobileOnly, isOffered: offered),
            [], "A person who chose no cards keeps none")
    }

    /// The defaults stand in only for a mobile-only environment: a Mac environment whose
    /// selection offers nothing shows the notice, as before.
    func testTheMobileDefaultsStandInOnlyOnAMobileOnlyEnvironment() {
        let none: (Metric) -> Bool = { _ in false }
        XCTAssertEqual(
            OverviewScoreCards.shown(
                selected: [.fileVault], composition: .macsOnly, isOffered: none),
            [])
        XCTAssertEqual(
            OverviewScoreCards.shown(selected: [.fileVault], composition: .mixed, isOffered: none),
            [])
    }

    /// The first edit on a mobile-only environment starts from the cards on screen, and the
    /// Mac cards the person saved stay in the selection for a Mac environment.
    func testTheFirstEditWhileTheDefaultsStandInAdoptsThemAndKeepsTheMacCards() {
        let offered: (Metric) -> Bool = { $0.isOffered(under: .default, in: .mobileOnly) }
        let saved: [Metric] = [.stability, .fileVault]

        let adopted = OverviewScoreCards.adopting(
            selected: saved, composition: .mobileOnly, isOffered: offered)
        XCTAssertEqual(adopted, saved + OverviewScoreCards.mobileDefaults)

        XCTAssertEqual(
            OverviewScoreCards.adopting(
                selected: adopted, composition: .mobileOnly, isOffered: offered),
            adopted, "Adopting twice changes nothing")
        XCTAssertEqual(
            OverviewScoreCards.adopting(
                selected: saved, composition: .mixed, isOffered: { _ in true }),
            saved, "Where the saved cards apply there is nothing to adopt")
        XCTAssertEqual(
            OverviewScoreCards.adopting(selected: [], composition: .mobileOnly, isOffered: offered),
            [])
    }

    func testOnlyTheLastShownCardOnAMobileOnlyEnvironmentIsHeld() {
        let one: [Metric] = [.mobileStale]
        XCTAssertTrue(OverviewScoreCards.isLastOnMobileOnly(
            .mobileStale, shown: one, composition: .mobileOnly))
        XCTAssertFalse(OverviewScoreCards.isLastOnMobileOnly(
            .mobileStale, shown: one + [.mobilePasscode], composition: .mobileOnly))
        XCTAssertFalse(OverviewScoreCards.isLastOnMobileOnly(
            .mobileStale, shown: one, composition: .mixed), "A mixed fleet may show none")
    }

    func testScoreCardRowsListMobileCardsOnlyWhereTheEnvironmentHasMobileDevices() {
        let mobile = Metric.mobileMetrics
        let mixed = OverviewCustomizeSheet.scoreCardRows(
            selected: [.stability], policy: .default, mobile: mobile, composition: .mixed)
        XCTAssertEqual(Set(mixed), Set(Metric.allCases + mobile))
        XCTAssertEqual(mixed.first, .stability)

        let macs = OverviewCustomizeSheet.scoreCardRows(
            selected: [], policy: .default, mobile: mobile, composition: .macsOnly)
        XCTAssertEqual(Set(macs), Set(Metric.allCases))

        let mobileOnly = OverviewCustomizeSheet.scoreCardRows(
            selected: [.stability, .mobileStale], policy: .default, mobile: mobile,
            composition: .mobileOnly)
        XCTAssertEqual(Set(mobileOnly), Set(mobile))
        XCTAssertEqual(mobileOnly.first, .mobileStale, "The hidden Mac card is not listed")
    }

    // MARK: - Tiles

    func testTheSectionHasTheSpecsFourLinesWithWhatEachCounts() {
        let tiles = mobileFigures(jailbroken: 1, updateErrors: 3).overviewTiles

        XCTAssertEqual(tiles.map(\.label), [
            "Devices", "OS current", "Passcode compliant", "Needs attention",
        ])
        XCTAssertEqual(tiles[0].value, "118")
        XCTAssertEqual(tiles[0].caption, "managed mobile devices")
        XCTAssertEqual(tiles[1].value, "80.4%")
        XCTAssertEqual(tiles[1].caption, "90 of 112 devices with a listed version")
        XCTAssertEqual(tiles[2].value, "95.7%")
        XCTAssertEqual(tiles[2].caption, "110 of 115 devices reporting")
        XCTAssertEqual(tiles[3].value, "6", "1 jailbroken + 2 unmanaged + 3 update errors")
        XCTAssertEqual(tiles[3].caption, "2 unmanaged, 1 jailbroken, 3 update errors")
        XCTAssertEqual(tiles.map(\.opensAudit), [false, false, false, true])
    }

    /// Each absent part contributes nothing, and a total of 0 hides the line.
    func testNeedsAttentionCountsOnlyWhatIsReportedAndHidesAtZero() {
        var figures = mobileFigures(jailbroken: nil, updateErrors: nil)
        XCTAssertEqual(figures.needsAttentionCount, 2, "Only the unmanaged devices are known")
        XCTAssertEqual(figures.overviewTiles.last?.caption, "2 unmanaged")

        figures.unmanaged = 0
        XCTAssertEqual(figures.needsAttentionCount, 0)
        XCTAssertEqual(figures.overviewTiles.map(\.label),
                       ["Devices", "OS current", "Passcode compliant"])
    }

    func testAShareNoDeviceReportsIsADashNeverZero() {
        let tiles = mobileFigures(passcode: .init(met: 0, of: 0), osCurrent: nil).overviewTiles

        for index in [1, 2] {
            XCTAssertEqual(tiles[index].value, MobileOverviewTile.dash, tiles[index].label)
            XCTAssertEqual(tiles[index].caption, MobileOverviewTile.unreported, tiles[index].label)
        }
        XCTAssertEqual(tiles[0].value, "118")
    }

    func testAShareOfNothingMetIsZeroPercentNotADash() {
        let tiles = mobileFigures(passcode: .init(met: 0, of: 9)).overviewTiles
        XCTAssertEqual(tiles[2].value, "0.0%")
        XCTAssertEqual(tiles[2].caption, "0 of 9 devices reporting")
    }

    // MARK: - Demo

    /// The demo section counts the same 25 devices the Mobile Devices screen lists.
    func testDemoFiguresMatchTheDemoMobileDevices() throws {
        let summary = try XCTUnwrap(DemoData.mobileSummary)
        let devices = MobileFleetView.makeDemoSnapshot().richDevices

        XCTAssertEqual(devices.count, DemoData.mobileDeviceCount)
        XCTAssertEqual(summary.managed, devices.filter { $0.general?.managed == true }.count)
        XCTAssertEqual(summary.managed + summary.unmanaged, devices.count)
        XCTAssertEqual(
            summary.supervised?.of, devices.filter { $0.general?.managed == true }.count)
        XCTAssertEqual(summary.passcode?.of, devices.count)
        XCTAssertEqual(summary.osCurrent?.of, devices.count)
        XCTAssertEqual(summary.stale, 0)
        XCTAssertTrue(summary.sharesAreConsistent)
        XCTAssertEqual(DemoData.composition, .mixed)
    }

    // MARK: - Insight facts

    private func lines(_ input: FleetInsightInput) -> [String] {
        input.promptContext().components(separatedBy: "\n")
    }

    func testTheFleetInsightGainsTheMobileFactsOfAMixedFleet() {
        let input = FleetInsightInput.fleet(
            current: summary(macs: 40, mobileCount: 120, mobile: mobileFigures()), previous: nil)
        let text = lines(input)

        XCTAssertTrue(text.contains("- Managed mobile devices: 118"))
        XCTAssertTrue(text.contains {
            $0.hasPrefix("- Mobile passcode compliant on 95.7% of devices; not passcode compliant")
        })
        XCTAssertTrue(text.contains { $0.hasPrefix("- Stale mobile devices") && $0.hasSuffix("6") })
        XCTAssertTrue(text.contains("- Jailbroken mobile devices: 0"))
        XCTAssertTrue(text.contains {
            $0.contains("Mobile shares count only the mobile devices that report each field")
                && $0.contains("passcode 115")
        })
    }

    func testTheFleetInsightCountsUnmanagedAndUpdateErrorsLowerIsBetter() {
        let before = mobileFigures(updateErrors: 1)
        let input = FleetInsightInput.fleet(
            current: summary(
                macs: 40, mobileCount: 120, mobile: mobileFigures(updateErrors: 3)),
            previous: summary(macs: 40, mobileCount: 120, mobile: before))
        let text = lines(input)

        XCTAssertTrue(text.contains("- Unmanaged mobile devices: 2 (unchanged vs prior)"))
        XCTAssertTrue(text.contains {
            $0.hasPrefix("- Mobile devices with software update errors: 3")
                && $0.contains("up 2 vs prior, worse")
        })
    }

    func testTheFleetInsightLeavesOutAMobileFigureNoDeviceReports() {
        let input = FleetInsightInput.fleet(
            current: summary(
                macs: 40, mobileCount: 120,
                mobile: mobileFigures(
                    supervised: nil, osCurrent: nil, stale: nil, jailbroken: nil)),
            previous: nil)
        let joined = lines(input).joined(separator: "\n")

        XCTAssertFalse(joined.contains("supervised"))
        XCTAssertFalse(joined.contains("Mobile OS current"))
        XCTAssertFalse(joined.contains("Stale mobile devices"))
        XCTAssertFalse(joined.contains("Jailbroken"))
        XCTAssertFalse(joined.contains("update errors"), "No scan ran: not 0 errors")
        XCTAssertTrue(joined.contains("Mobile passcode compliant"))
    }

    func testTheFleetInsightHasNoMobileFactForAMacOnlyFleet() {
        let input = FleetInsightInput.fleet(current: summary(macs: 40), previous: nil)
        XCTAssertFalse(lines(input).joined().localizedCaseInsensitiveContains("mobile"))
    }

    /// A fleet with no Macs names its managed mobile devices once, not beside the stand-in.
    func testAMobileOnlyFleetNamesItsManagedDevicesOnce() {
        let input = FleetInsightInput.fleet(
            current: summary(macs: 0, mobileCount: 120, mobile: mobileFigures()), previous: nil)
        let managed = lines(input).filter { $0.contains("Managed mobile devices") }

        XCTAssertEqual(managed, ["- Managed mobile devices (no Macs in this fleet): 118"])
    }

    func testMobileFactsCarryTheirChangeSincePrior() {
        let before = mobileFigures(passcode: .init(met: 100, of: 115), stale: 4)
        let input = FleetInsightInput.fleet(
            current: summary(macs: 40, mobileCount: 120, mobile: mobileFigures()),
            previous: summary(macs: 40, mobileCount: 120, mobile: before))
        let text = lines(input)

        XCTAssertTrue(text.contains {
            $0.hasPrefix("- Mobile passcode compliant") && $0.contains("up 8.7 pp vs prior, better")
        })
        XCTAssertTrue(text.contains {
            $0.hasPrefix("- Stale mobile devices") && $0.contains("up 2 vs prior, worse")
        })
    }
}
