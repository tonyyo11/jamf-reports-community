import XCTest
@testable import JamfReports

/// The store's reading of the environment (mobile spec 3.2): the composition from injected
/// summaries, which score cards it offers, and edits to the saved selection. The saved
/// selection persists to UserDefaults, so each test puts back what it found.
@MainActor
final class WorkspaceStoreMobileCompositionTests: XCTestCase {

    private typealias Metric = TrendSeries.Metric

    private nonisolated(unsafe) var savedCards: String?

    override func setUp() {
        super.setUp()
        savedCards = UserDefaults.standard.string(forKey: WorkspaceStore.scoreCardsKey)
    }

    override func tearDown() {
        if let savedCards {
            UserDefaults.standard.set(savedCards, forKey: WorkspaceStore.scoreCardsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: WorkspaceStore.scoreCardsKey)
        }
        super.tearDown()
    }

    private func day(_ date: String, macs: Int, mobile: Int?) -> DailySummary {
        DailySummary(
            date: date, totalDevices: macs, fileVaultPct: nil, compliancePct: nil,
            staleCount: nil, osCurrentPct: nil, crowdstrikePct: nil, patchPct: nil,
            mobileDeviceCount: mobile)
    }

    private func store(
        demo: Bool = false, summaries: [DailySummary] = [], cards: [Metric]? = nil,
        range: TrendRange = .all
    ) -> WorkspaceStore {
        let store = WorkspaceStore(demoMode: demo)
        if let cards { store.selectedScoreCards = cards }
        let generation = store.trendStore.beginLoading()
        store.trendStore.apply(
            TrendStore.TrendSnapshot(
                summaries: summaries, latestSnapshotDate: nil, hasEverFetchedLive: false,
                bandSeries: [:], baselineNames: []),
            profile: store.profile, range: range, generation: generation)
        return store
    }

    private let mobileOnlyDays = [
        "2026-10-27", "2026-10-28",
    ].map { DailySummary(
        date: $0, totalDevices: 0, fileVaultPct: nil, compliancePct: nil, staleCount: nil,
        osCurrentPct: nil, crowdstrikePct: nil, patchPct: nil, mobileDeviceCount: 30) }

    // MARK: - Composition

    func testCompositionFollowsTheNewestSummaries() {
        XCTAssertEqual(store().environmentComposition, .unknown)
        XCTAssertEqual(
            store(summaries: [day("2026-10-28", macs: 40, mobile: nil)]).environmentComposition,
            .macsOnly)
        XCTAssertEqual(
            store(summaries: [day("2026-10-28", macs: 40, mobile: 12)]).environmentComposition,
            .mixed)
        XCTAssertEqual(store(summaries: mobileOnlyDays).environmentComposition, .mobileOnly)
    }

    /// A short range keeps one summary in the filtered list; the day before still counts.
    func testThePreviousDayComesFromEverythingLoadedNotTheRange() {
        let days = [day("2026-08-01", macs: 40, mobile: 12), day("2026-10-28", macs: 0, mobile: 12)]
        let store = store(summaries: days, range: .w4)

        XCTAssertEqual(store.trendStore.filteredSummaries.count, 1, "The range drops August")
        XCTAssertEqual(store.environmentComposition, .mixed)
    }

    func testASingleSummaryWithNoMacsIsUnknownAndAGapBetweenDaysStillAgrees() {
        XCTAssertEqual(
            store(summaries: [day("2026-10-28", macs: 0, mobile: 12)]).environmentComposition,
            .unknown)
        let gap = [day("2026-09-01", macs: 0, mobile: 12), day("2026-10-28", macs: 0, mobile: 12)]
        XCTAssertEqual(store(summaries: gap).environmentComposition, .mobileOnly)
    }

    func testTheNewestTwoSummariesAreByDateWhateverTheLoadedOrder() {
        let days = [
            day("2026-10-28", macs: 1, mobile: nil), day("2026-10-26", macs: 1, mobile: nil),
            day("2026-10-27", macs: 1, mobile: nil),
        ]
        let pair = store(summaries: days).trendStore.newestTwoSummaries

        XCTAssertEqual(pair.newest?.date, "2026-10-28")
        XCTAssertEqual(pair.previous?.date, "2026-10-27")
        XCTAssertNil(store().trendStore.newestTwoSummaries.newest)
    }

    func testOneMacLessDayDoesNotFlipAMixedEnvironment() {
        let days = [day("2026-10-27", macs: 40, mobile: 12), day("2026-10-28", macs: 0, mobile: 12)]
        XCTAssertEqual(store(summaries: days).environmentComposition, .mixed)
    }

    func testDemoModeIsMixedWhateverTheSummariesSay() {
        XCTAssertEqual(store(demo: true, summaries: mobileOnlyDays).environmentComposition, .mixed)
    }

    func testSummariesAreLoadedOnlyOnceTheTrendStoreHasReadTheProfile() {
        let fresh = WorkspaceStore(demoMode: false)
        XCTAssertFalse(fresh.summariesLoaded, "Not read yet is not the same as empty")
        XCTAssertTrue(store().summariesLoaded, "Loaded and empty")
        XCTAssertTrue(store(demo: true).summariesLoaded)
    }

    // MARK: - Offered cards

    func testCardsAreOfferedByTheEnvironmentsDeviceTypes() {
        let macs = store(summaries: [day("2026-10-28", macs: 40, mobile: nil)])
        XCTAssertTrue(macs.isOffered(.fileVault))
        XCTAssertFalse(macs.isOffered(.mobilePasscode))

        let mixed = store(summaries: [day("2026-10-28", macs: 40, mobile: 12)])
        XCTAssertTrue(mixed.isOffered(.fileVault))
        XCTAssertTrue(mixed.isOffered(.mobilePasscode))

        let mobile = store(summaries: mobileOnlyDays)
        XCTAssertFalse(mobile.isOffered(.fileVault))
        XCTAssertTrue(mobile.isOffered(.mobilePasscode))
    }

    func testDemoModeOffersNoMobileCardBecauseTheDemoHistoryHasNone() {
        let demo = store(demo: true)
        XCTAssertFalse(demo.isOffered(.mobilePasscode))
        XCTAssertTrue(demo.isOffered(.fileVault))
    }

    // MARK: - Editing the selection

    private let macCards: [Metric] = [.stability, .fileVault]

    func testAMobileOnlyEnvironmentShowsTheDefaultsWithoutRewritingTheSelection() {
        let store = store(summaries: mobileOnlyDays, cards: macCards)

        XCTAssertEqual(store.shownScoreCards, OverviewScoreCards.mobileDefaults)
        XCTAssertEqual(store.selectedScoreCards, macCards)
    }

    func testTheFirstEditAdoptsTheDefaultsAndKeepsTheMacCards() {
        let store = store(summaries: mobileOnlyDays, cards: macCards)

        store.setScoreCard(.mobileStale, shown: true)

        XCTAssertEqual(
            store.selectedScoreCards,
            macCards + OverviewScoreCards.mobileDefaults + [.mobileStale])
        XCTAssertEqual(store.shownScoreCards, OverviewScoreCards.mobileDefaults + [.mobileStale])
    }

    func testTheLastShownCardOnAMobileOnlyEnvironmentCannotBeSwitchedOff() {
        let store = store(summaries: mobileOnlyDays, cards: [.mobileStale])

        store.setScoreCard(.mobileStale, shown: false)

        XCTAssertEqual(store.selectedScoreCards, [.mobileStale], "The selection is untouched")
        XCTAssertEqual(store.shownScoreCards, [.mobileStale])
    }

    /// A refusal edits nothing: it does not append the mobile defaults to the stored selection.
    func testRefusingTheLastCardLeavesTheSelectionExactlyAsSaved() {
        let saved: [Metric] = [.fileVault, .mobileStale]
        let store = store(summaries: mobileOnlyDays, cards: saved)

        store.setScoreCard(.mobileStale, shown: false)

        XCTAssertEqual(store.selectedScoreCards, saved)
    }

    func testSwitchingOffDownToTheLastCardStopsThere() {
        let store = store(summaries: mobileOnlyDays, cards: macCards)

        for metric in OverviewScoreCards.mobileDefaults { store.setScoreCard(metric, shown: false) }

        XCTAssertEqual(store.shownScoreCards, [.mobileDataProtection])
        XCTAssertEqual(store.selectedScoreCards, macCards + [.mobileDataProtection],
                       "The Mac cards stay for a Mac environment")
    }

    func testAMixedEnvironmentMayShowNoCards() {
        let store = store(
            summaries: [day("2026-10-28", macs: 40, mobile: 12)], cards: [.fileVault])

        store.setScoreCard(.fileVault, shown: false)

        XCTAssertEqual(store.selectedScoreCards, [])
        XCTAssertEqual(store.shownScoreCards, [])
    }

    func testMovingACardWhileTheDefaultsStandInAdoptsThemFirst() {
        let store = store(summaries: mobileOnlyDays, cards: macCards)

        store.moveScoreCard(.mobileOSCurrent, to: .mobileDataProtection)

        XCTAssertEqual(store.shownScoreCards, [
            .mobilePasscode, .mobileSupervised, .mobileDataProtection, .mobileOSCurrent,
        ])
        XCTAssertEqual(Array(store.selectedScoreCards.prefix(2)), macCards)
    }
}
