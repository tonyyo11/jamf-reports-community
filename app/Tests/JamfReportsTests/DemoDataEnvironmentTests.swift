import XCTest
@testable import JamfReports

/// Each demo workspace is its own environment: the products, the screens that read them, the
/// School district and the history all follow the workspace picked in demo mode.
@MainActor
final class DemoDataEnvironmentTests: XCTestCase {

    private let prod = "meridian-prod"
    private let edu = "meridianedu"
    private let sandbox = "meridian-sandbox"
    private let msp = "meridian-msp"

    private func store(_ workspace: String) -> WorkspaceStore {
        let store = WorkspaceStore(
            demoMode: true, tickerRegistrar: StubTickerRegistrar(), jamfCLIProfileNames: { [] })
        store.setProfile(workspace)
        XCTAssertEqual(store.profile, workspace)
        return store
    }

    // MARK: - Products

    func testEachWorkspaceHasItsOwnProducts() {
        typealias P = EnvironmentProducts.Product
        let expected: [String: Set<P>] = [
            prod: [.jamfPro, .platform, .protect], edu: [.jamfSchool],
            sandbox: [.jamfPro], msp: [.jamfPro, .protect],
        ]
        XCTAssertEqual(Set(DemoData.cliProfiles.map(\.name)), Set(expected.keys))
        for (workspace, products) in expected {
            XCTAssertEqual(DemoData.environmentProducts(for: workspace).products, products, workspace)
            XCTAssertEqual(store(workspace).environmentProducts.products, products, workspace)
        }
        XCTAssertEqual(EnvironmentProducts.demo, DemoData.environmentProducts(for: prod))
    }

    func testProfilesAndConnectionNameTheProductsTheyLogInTo() {
        for profile in DemoData.cliProfiles {
            XCTAssertEqual(profile.product, DemoData.product(for: profile.name), profile.name)
        }
        XCTAssertEqual(DemoData.cliProfiles.first { $0.name == edu }?.product, .school)
        let members = DemoData.connections.flatMap(\.members)
        XCTAssertEqual(members.map(\.profile), [prod], "only meridian-prod has a Platform slot")
        XCTAssertTrue(members.allSatisfy { $0.product == .pro })
    }

    func testEnvironmentCardShowsTheWorkspacesSlots() {
        func filled(_ workspace: String) -> [ProfilesConfigWriter.Slot: String] {
            DemoData.environmentCard(for: workspace).rows
                .reduce(into: [:]) { $0[$1.slot] = $1.profile }
        }
        XCTAssertEqual(filled(prod), [
            .jamfPro: prod, .platform: "meridian-prod-platform", .protect: "meridian-prod-protect",
        ])
        XCTAssertEqual(filled(edu), [.jamfSchool: edu])
        XCTAssertEqual(filled(sandbox), [.jamfPro: sandbox])
        XCTAssertEqual(filled(msp), [.jamfPro: msp, .protect: "meridian-msp-protect"])
        let platform = DemoData.environmentCard(for: prod).rows.first { $0.slot == .platform }
        XCTAssertEqual(platform?.authMethod, "platform")
        XCTAssertEqual(platform?.level, .environment)
        for profile in DemoData.cliProfiles {
            for row in DemoData.environmentCard(for: profile.name).rows {
                if let date = row.newestSnapshot { XCTAssertLessThanOrEqual(date, DemoData.referenceDate) }
            }
        }
    }

    func testTabsFollowTheWorkspace() {
        func shown(_ workspace: String) -> Set<Tab> {
            let visibility = store(workspace).tabVisibility(hiddenRaw: "")
            return Set(Tab.allCases.filter { visibility.isVisible($0) })
        }
        XCTAssertEqual(shown(edu), Tab.schoolTabs)
        let all = Set(Tab.allCases)
        XCTAssertEqual(shown(prod), all.subtracting([.schoolDevices]))
        XCTAssertEqual(shown(sandbox), all.subtracting(
            [.schoolDevices, .protectDashboard, .complianceBenchmarks, .mobileFleet]))
        XCTAssertEqual(shown(msp), all.subtracting(
            [.schoolDevices, .complianceBenchmarks, .mobileFleet]))
    }

    func testDataSourcesPlanFollowsTheWorkspace() {
        let school = DemoData.sourcesPlan(for: edu)
        XCTAssertTrue(school.sources.contains { $0.product == .school })
        XCTAssertFalse(school.sources.contains { $0.product == .jamfPro })
        // meridianedu's School profile has no Platform API fields: blueprints skip, never cached.
        let blueprints = school.sources.first { $0.kind == ReportEngine.schoolBlueprintsKind }
        XCTAssertNotNil(blueprints?.skipReason)
        XCTAssertNil(DemoData.cacheDate(for: [ReportEngine.schoolBlueprintsKind], profile: edu))
        XCTAssertEqual(
            SchoolPlatformRow.state(
                resolved: DemoData.resolvedProfile(edu, workspace: edu), lastCheck: nil),
            .notConfigured)
        XCTAssertTrue(DemoData.sourcesPlan(for: msp).sources.contains { $0.product == .protect })
        XCTAssertFalse(DemoData.sourcesPlan(for: sandbox).sources.contains { $0.product == .protect })
        let platformSkipped = DemoData.sourcesPlan(for: sandbox).sources(for: .platformAPI)
        XCTAssertFalse(platformSkipped.isEmpty)
        XCTAssertTrue(platformSkipped.allSatisfy { $0.skipReason != nil },
                      "no Platform API profile on meridian-sandbox")
        XCTAssertTrue(DemoData.sourcesPlan(for: prod).sources(for: .platformAPI)
            .contains { $0.skipReason == nil })
    }

    // MARK: - Jamf School

    func testSchoolFleetIsOneFact() throws {
        let snapshot = DemoData.schoolSnapshot
        let macs = snapshot.devices.filter { $0.platform == "macOS" }
        let index = try XCTUnwrap(DemoData.cliProfiles.firstIndex { $0.name == edu })
        XCTAssertEqual(macs.count, DemoData.deviceCount(forProfileAt: index))
        XCTAssertEqual(macs.count, DemoData.schoolMacCount)
        XCTAssertEqual(snapshot.devices.count - macs.count,
                       DemoData.schoolIPadCount + DemoData.schoolAppleTVCount)
        XCTAssertEqual(snapshot.trashedCount, DemoData.schoolTrashedCount)
        XCTAssertEqual(snapshot.overview.first { $0.resource == "Devices" }?.value,
                       "\(snapshot.devices.count)")
        let collected = try XCTUnwrap(snapshot.collectedAt)
        XCTAssertLessThanOrEqual(collected, DemoData.referenceDate)
        XCTAssertTrue(snapshot.devices.allSatisfy { ($0.lastCheckin ?? .distantFuture) <= collected })
        XCTAssertEqual(Set(snapshot.devices.map(\.id)).count, snapshot.devices.count)

        let summary = try XCTUnwrap(DemoData.schoolSummary)
        XCTAssertEqual(summary.totalDevices, macs.count)
        XCTAssertEqual(summary.mobileDeviceCount, snapshot.devices.count - macs.count)
        XCTAssertEqual(summary.staleCount, macs.filter {
            $0.isStale(atDays: 30, now: DemoData.referenceDate)
        }.count, "the screens' now and the summary's agree")
        XCTAssertGreaterThan(summary.staleCount ?? 0, 0)
        XCTAssertEqual(summary.mobile?.managed, snapshot.devices.filter {
            $0.platform != "macOS" && $0.isManaged == true
        }.count)
    }

    func testSchoolHistoryEndsOnTheSchoolSummary() async throws {
        let summary = try XCTUnwrap(DemoData.schoolSummary)
        let series = DemoData.trends(for: edu)
        XCTAssertEqual(series[.managedDevices]?.last, Double(summary.totalDevices))
        XCTAssertEqual(series[.stale]?.last, summary.staleCount.map(Double.init))
        XCTAssertEqual(series[.mobileManaged]?.last, summary.mobile.map { Double($0.managed) })
        XCTAssertNil(series[.fileVault], "School records no Mac security figure")
        XCTAssertNil(series[.osCurrent], "no SOFA feed in the demo, so no OS currency")

        let overview = await store(edu).loadFleetOverview(readSummaries: { _ in
            XCTFail("demo mode never reads a workspace"); return []
        })
        XCTAssertTrue(overview.isSchool)
        XCTAssertEqual(overview.summary?.date, summary.date)
        XCTAssertEqual(overview.summary?.totalDevices, summary.totalDevices)
        XCTAssertEqual(overview.summary?.mobile, summary.mobile)
        XCTAssertEqual(overview.summaries.map(\.date), DemoData.trendDates)
        XCTAssertNotNil(overview.summary?.osMajorCounts)
    }

    // MARK: - History

    func testMobileSeriesEndOnTheMobileSummary() throws {
        let mobile = try XCTUnwrap(DemoData.mobileSummary)
        let series = DemoData.trends(for: prod)
        let expected: [TrendSeries.Metric: Double?] = [
            .mobileManaged: Double(mobile.managed), .mobileOSCurrent: mobile.osCurrent?.pct,
            .mobilePasscode: mobile.passcode?.pct, .mobileSupervised: mobile.supervised?.pct,
            .mobileDataProtection: mobile.dataProtection?.pct,
            .mobileStale: mobile.stale.map(Double.init),
            .mobileJailbroken: mobile.jailbroken.map(Double.init),
        ]
        for (metric, last) in expected {
            XCTAssertEqual(series[metric]?.last, last ?? nil, "\(metric)")
            XCTAssertEqual(series[metric]?.count, last == nil ? nil : DemoData.trendDates.count)
        }
        XCTAssertEqual(series[.mobileManaged]?.last, Double(DemoData.mobileDeviceCount)
            - Double(mobile.unmanaged))
        for metric in TrendSeries.Metric.mobileMetrics {
            let values = series[metric] ?? []
            XCTAssertTrue(values.allSatisfy { $0 >= 0 }, "\(metric)")
            if !metric.isDeviceCount { XCTAssertTrue(values.allSatisfy { $0 <= 100 }, "\(metric)") }
        }
    }

    func testProtectSeriesEndOnTheProtectScreensRows() throws {
        let figures = try XCTUnwrap(DemoData.protectFigures(for: prod))
        XCTAssertEqual(figures.computers?.count, DemoData.protectPilotMacs.count)
        XCTAssertEqual(figures.computers?.count, DemoData.protectSnapshot.computers.count)
        XCTAssertEqual(figures.computers?.matched?.met, DemoData.protectPilotMacs.count,
                       "every pilot Mac is in the demo inventory")
        XCTAssertEqual(figures.alerts?.open, DemoData.protectSnapshot.alerts.filter(\.isOpen).count)
        XCTAssertEqual(figures.alerts?.counts?.values.reduce(0, +), figures.alerts?.open)
        let series = DemoData.trends(for: prod)
        XCTAssertEqual(series[.protectComputers]?.last, Double(DemoData.protectPilotMacs.count))
        XCTAssertEqual(series[.protectMatched]?.last, figures.computers?.matched?.pctOneDecimal)
        XCTAssertEqual(series[.protectOpenAlerts]?.last, figures.alerts.map { Double($0.open) })
        XCTAssertNil(DemoData.protectFigures(for: sandbox))
        XCTAssertNil(DemoData.protectFigures(for: edu))
    }

    func testSeriesFollowTheWorkspacesProducts() {
        let all = TrendSeries.Metric.mobileMetrics + TrendSeries.Metric.protectMetrics
        for metric in all { XCTAssertNil(DemoData.trends(for: sandbox)[metric], "\(metric)") }
        for metric in TrendSeries.Metric.mobileMetrics {
            XCTAssertNil(DemoData.trends(for: msp)[metric], "\(metric)")
        }
        for metric in TrendSeries.Metric.protectMetrics {
            XCTAssertNotNil(DemoData.trends(for: msp)[metric], "\(metric)")
        }
        for profile in DemoData.cliProfiles {
            for metric in TrendSeries.Metric.securityCloudMetrics {
                XCTAssertNil(DemoData.trends(for: profile.name)[metric], "no Security Cloud source")
            }
        }
        XCTAssertTrue(store(prod).isOffered(.mobilePasscode))
        XCTAssertTrue(store(prod).isOffered(.protectOpenAlerts))
        XCTAssertFalse(store(sandbox).isOffered(.protectOpenAlerts))
        XCTAssertFalse(store(prod).securityCloudMetricsOffered)
    }

    // MARK: - Fleet Overview

    func testEveryWorkspacesNewestDayCarriesItsDeviceMaps() async throws {
        for (index, profile) in DemoData.cliProfiles.enumerated() where profile.name != edu {
            let overview = await store(profile.name).loadFleetOverview()
            let summary = try XCTUnwrap(overview.summary, profile.name)
            let total = DemoData.deviceCount(forProfileAt: index)
            XCTAssertEqual(summary.totalDevices, total)
            let macOS = (summary.osMajorCounts ?? [:]).filter { $0.key.hasPrefix("macOS ") }
            XCTAssertEqual(macOS.values.reduce(0, +), total, profile.name)
            XCTAssertEqual(summary.modelFamilyCounts?.values.reduce(0, +), total, profile.name)
            XCTAssertEqual(summary.lastSeenBuckets?.computers?.total, total, profile.name)
            let mixed = DemoData.composition(for: profile.name) == .mixed
            XCTAssertEqual(summary.mobile, mixed ? DemoData.mobileSummary : nil, profile.name)
            XCTAssertEqual(summary.mobileDeviceCount, mixed ? DemoData.mobileDeviceCount : nil)
            XCTAssertEqual(summary.mobileFormFactorCounts != nil, mixed, profile.name)
            XCTAssertEqual(
                summary.products,
                DemoData.environmentProducts(for: profile.name).products.map(\.slotName).sorted())
            XCTAssertEqual(summary.protectComputerCount,
                           DemoData.protectFigures(for: profile.name)?.computers?.count)
        }
    }

    // MARK: - Run History and Reports

    func testSchoolRunsCollectSchoolSources() {
        let lines = DemoData.runHistory(for: edu).flatMap(\.lines).map(\.text)
        XCTAssertTrue(lines.contains { $0.contains("collecting school-devices") })
        XCTAssertFalse(lines.contains { $0.contains("collecting computers") })
        XCTAssertFalse(lines.contains { $0.contains("protect-") })
        XCTAssertNotNil(DemoData.cacheDate(for: ["school-devices"], profile: edu))
        XCTAssertNil(DemoData.cacheDate(for: ["computers"], profile: edu))
        XCTAssertNil(DemoData.cacheDate(for: ["school-devices"], profile: prod))
        XCTAssertNil(DemoData.cacheDate(for: ["protect-overview"], profile: sandbox))
    }

    func testReportsListTheWorkbooksCSVFolders() {
        let folders = DemoData.generatedReports.filter { $0.name.hasSuffix("_csv") }
        XCTAssertEqual(folders.count, 2)
        let names = Set(DemoData.generatedReports.map(\.name))
        for folder in folders {
            XCTAssertTrue(names.contains(String(folder.name.dropLast(4)) + ".xlsx"), folder.name)
            XCTAssertTrue(folder.source.hasPrefix(ReportLibrary.kindLabel(forFilename: folder.name)))
            XCTAssertEqual(folder.sheetsLabel, "—")
        }
    }
}
