import XCTest
@testable import JamfReports

/// The server-health fields of the daily summary: credential expiries carried from the newest
/// snapshot, the notification count only when its kind landed, and what a rebuild keeps.
@MainActor
final class ServerHealthSummaryTests: XCTestCase {
    private let ws = "shsum"
    private let proFile = "profiles:\n  jamf_pro: shsum\n"

    private func makeRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SHSummary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(ws), withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        addTeardownBlock {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: root)
        }
    }

    private static var day: String { SummaryJSONParser.dateFormatter.string(from: .testNoon) }
    private func dataDir() throws -> URL { try WorkspacePaths.dataDir(for: ws) }

    private func summary() throws -> DailySummary {
        let file = try WorkspacePaths.summariesDir(for: ws)
            .appendingPathComponent("summary_\(Self.day).json")
        return try SummaryJSONParser.decode(Data(contentsOf: file))
    }

    private func writeMDMSummary() throws {
        let dir = try WorkspacePaths.summariesDir(for: ws)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = DailySummary(
            date: Self.day, totalDevices: 5, fileVaultPct: nil, compliancePct: nil,
            staleCount: nil, osCurrentPct: nil, crowdstrikePct: nil, patchPct: nil,
            source: "jamf-cli")
        ReportEngine.writeSummaryFile(
            base, to: dir.appendingPathComponent("summary_\(Self.day).json"), onLine: nil)
    }

    private func save(_ text: String, _ kind: String, stamp: String? = nil) throws {
        let dir = try dataDir()
        if let stamp {
            let folder = dir.appendingPathComponent(kind, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: folder.appendingPathComponent("\(kind)_\(stamp).json"))
        } else {
            try ReportEngine.saveSnapshot(data: Data(text.utf8), kind: kind, dataDir: dir)
        }
    }

    /// A CA expiring `days` after `Date.testNoon`, as the reduction saves it.
    private func ca(days: Double, stamp: String? = nil) throws {
        let seconds = Int(Date.testNoon.timeIntervalSince1970 + days * 86_400)
        try save(#"{"notAfter":\#(seconds)}"#, "certificate-authority", stamp: stamp)
    }

    private func finalize(
        _ yaml: String? = nil, landed: [EnvironmentProducts.Product: Set<String>],
        maxAge: Int = 168
    ) throws {
        let environment = EnvironmentProfiles.resolve(
            config: try ConfigLoader.loadFromString(yaml ?? proFile), workspace: ws)
        ReportEngine.finalizeEnvironmentSummary(
            summariesDir: try WorkspacePaths.summariesDir(for: ws), dataDir: try dataDir(),
            environment: environment, workspace: try WorkspaceID(validating: ws),
            landed: landed, day: .testNoon, maxCacheAgeHours: maxAge, onLine: { _ in })
    }

    func testACAExpiredYesterdayIsStoredAndDecodes() throws {
        try makeRoot()
        try writeMDMSummary()
        try ca(days: -1)
        try finalize(landed: [.jamfPro: ["computers"]])
        let s = try summary()
        let entry = try XCTUnwrap(s.serverCredentialExpiries?["ca"])
        XCTAssertTrue(entry.expires.hasSuffix("Z"), "an ISO instant: \(entry.expires)")
        XCTAssertEqual(entry.asOf.count, 10)
        XCTAssertEqual(s.serverCredentialSoonestDays, -1)
        XCTAssertTrue(s.numbersAreInRange)
        XCTAssertNil(s.jamfProNotificationCount, "the kind did not land")
    }

    func testExpiriesCarryOnADayTheirKindDidNotLandAndStopBeyondTheCacheAge() throws {
        try makeRoot()
        try writeMDMSummary()
        try ca(days: 40)
        try finalize(landed: [.jamfPro: ["computers"]])
        XCTAssertNotNil(try summary().serverCredentialExpiries?["ca"])
        // A snapshot past max_cache_age_hours is not carried; the earlier value stands.
        try FileManager.default.removeItem(
            at: try dataDir().appendingPathComponent("certificate-authority"))
        try ca(days: 10, stamp: "20200101T080000")
        try writeMDMSummary()
        try finalize(landed: [.jamfPro: ["computers"]])
        XCTAssertNil(try summary().serverCredentialExpiries)
    }

    func testNothingLandedStillWritesExpiriesFromTheNewestSnapshot() throws {
        try makeRoot()
        try writeMDMSummary()
        try ca(days: 40)
        try finalize(landed: [:])
        XCTAssertNotNil(try summary().serverCredentialExpiries?["ca"], "the .keptExisting guard")
    }

    func testNotificationCountIsWrittenOnlyWhenItsKindLanded() throws {
        try makeRoot()
        try writeMDMSummary()
        try save(#"[{"type":"A"},{"type":"A"},{}]"#, "jamf-pro-notifications")
        try finalize(landed: [.jamfPro: ["computers"]])
        XCTAssertNil(try summary().jamfProNotificationCount)
        try finalize(landed: [.jamfPro: ["jamf-pro-notifications"]])
        XCTAssertEqual(try summary().jamfProNotificationCount, 3)
        // An earlier run's count stands when this run did not measure it.
        try finalize(landed: [.jamfPro: ["computers"]])
        XCTAssertEqual(try summary().jamfProNotificationCount, 3)
        // A landed empty list is a measured zero.
        try save("[]", "jamf-pro-notifications")
        try finalize(landed: [.jamfPro: ["jamf-pro-notifications"]])
        XCTAssertEqual(try summary().jamfProNotificationCount, 0)
    }

    func testADETokensAreKeyedByIdWithTheDayAndNoName() throws {
        try makeRoot()
        try writeMDMSummary()
        try save(#"[{"id":"1","name":"Acme Corp ADE","tokenExpirationDate":"2027-03-01"},"#
            + #"{"id":"../x","name":"n","tokenExpirationDate":"2027-04-01"},"#
            + #"{"id":"2","name":"n","tokenExpirationDate":"soon"}]"#,
            "device-enrollment-instances")
        try finalize(landed: [.jamfPro: ["device-enrollment-instances"]])
        let s = try summary()
        XCTAssertEqual(s.serverCredentialExpiries?.keys.sorted(), ["ade:1"])
        XCTAssertEqual(s.serverCredentialExpiries?["ade:1"]?.expires, "2027-03-01")
        let file = try WorkspacePaths.summariesDir(for: ws)
            .appendingPathComponent("summary_\(Self.day).json")
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("Acme"))
    }

    func testAJamfSchoolEnvironmentGetsNoServerHealthFields() throws {
        try makeRoot()
        try writeMDMSummary()
        try ca(days: 40)
        try finalize("profiles:\n  jamf_school: shsum\n", landed: [.jamfSchool: ["school-devices"]])
        let s = try summary()
        XCTAssertNil(s.serverCredentialExpiries)
        XCTAssertNil(s.jamfProNotificationCount)
    }

    func testARebuildKeepsWhatTheNewSummaryDidNotMeasure() {
        let older = DailySummary(
            date: Self.day, totalDevices: 5, fileVaultPct: nil, compliancePct: nil,
            staleCount: nil, osCurrentPct: nil, crowdstrikePct: nil, patchPct: nil,
            source: "jamf-cli",
            serverCredentialExpiries: ["ca": .init(expires: "2027-01-01T00:00:00Z", asOf: Self.day)],
            jamfProNotificationCount: 2)
        let fresh = DailySummary(
            date: Self.day, totalDevices: 5, fileVaultPct: nil, compliancePct: nil,
            staleCount: nil, osCurrentPct: nil, crowdstrikePct: nil, patchPct: nil,
            source: "jamf-cli")
        let merged = fresh.filling(from: older)
        XCTAssertEqual(merged.serverCredentialExpiries, older.serverCredentialExpiries)
        XCTAssertEqual(merged.jamfProNotificationCount, 2)
        XCTAssertEqual(
            fresh.withEnvironment(products: nil, protect: nil, serverHealth: .init(
                expiries: nil, notificationCount: 7)).jamfProNotificationCount, 7)
    }

    func testTheSoonestDaysAreComputedFromEachSummarysOwnDate() {
        let summary = DailySummary(
            date: "2026-06-15", totalDevices: 5, fileVaultPct: nil, compliancePct: nil,
            staleCount: nil, osCurrentPct: nil, crowdstrikePct: nil, patchPct: nil,
            source: "jamf-cli",
            serverCredentialExpiries: [
                "ca": .init(expires: "2026-06-25T12:00:00Z", asOf: "2026-06-15"),
                "ade:1": .init(expires: "2026-06-20", asOf: "2026-06-15"),
                "ade:2": .init(expires: "garbage", asOf: "2026-06-15"),
            ])
        XCTAssertEqual(summary.serverCredentialSoonestDays, 5)
        XCTAssertEqual(TrendStore.environmentValue(.serverCredentialSoonestDays, in: summary), 5)
        XCTAssertNil(TrendStore.environmentValue(.jamfProNotifications, in: summary))
    }

    func testTheTrendMetricsAreOfferedOnlyOnAJamfProWorkspace() {
        XCTAssertTrue(TrendSeries.Metric.serverCredentialSoonestDays.isServerHealth)
        XCTAssertFalse(TrendSeries.Metric.schoolMetrics.contains(.serverCredentialSoonestDays))
        XCTAssertFalse(TrendSeries.Metric.allCases.contains(.jamfProNotifications))
        XCTAssertEqual(TrendSeries.Metric.serverCredentialSoonestDays.polarity, .higherIsBetter)
        XCTAssertEqual(TrendSeries.Metric.jamfProNotifications.polarity, .lowerIsBetter)
        XCTAssertEqual(
            TrendSeries.Metric(rawValue: "serverCredentialSoonestDays"), .serverCredentialSoonestDays)
        let domain = TrendsView.chartYDomain(
            metric: .serverCredentialSoonestDays, values: [-5, 40])
        XCTAssertEqual(domain.lowerBound, -5)
    }

    // MARK: - LAPS (opt-in)

    func testLAPSCountIsWrittenOnlyWhenItsKindLandedThisRun() throws {
        try makeRoot()
        try writeMDMSummary()
        try save(#"{"totalCount":4}"#, "laps-pending-rotations")
        try finalize(landed: [.jamfPro: ["computers"]])
        XCTAssertNil(try summary().lapsPendingCount)
        try finalize(landed: [.jamfPro: ["laps-pending-rotations"]])
        XCTAssertEqual(try summary().lapsPendingCount, 4)
        try finalize(landed: [.jamfPro: ["computers"]])
        XCTAssertEqual(try summary().lapsPendingCount, 4, "an earlier run's count stands")
        try save(#"{"totalCount":0}"#, "laps-pending-rotations")
        try finalize(landed: [.jamfPro: ["laps-pending-rotations"]])
        XCTAssertEqual(try summary().lapsPendingCount, 0, "a measured zero")
        XCTAssertTrue(try summary().numbersAreInRange)
    }

    func testAJamfSchoolEnvironmentGetsNoLAPSCount() throws {
        try makeRoot()
        try writeMDMSummary()
        try save(#"{"totalCount":4}"#, "laps-pending-rotations")
        try finalize("profiles:\n  jamf_school: shsum\n", landed: [.jamfSchool: ["school-devices"]])
        XCTAssertNil(try summary().lapsPendingCount)
    }

    func testLAPSMergesAndIsATrendAndAnAlertMetric() {
        let older = DailySummary(
            date: Self.day, totalDevices: 5, fileVaultPct: nil, compliancePct: nil,
            staleCount: nil, osCurrentPct: nil, crowdstrikePct: nil, patchPct: nil,
            source: "jamf-cli", lapsPendingCount: 3)
        let fresh = DailySummary(
            date: Self.day, totalDevices: 5, fileVaultPct: nil, compliancePct: nil,
            staleCount: nil, osCurrentPct: nil, crowdstrikePct: nil, patchPct: nil,
            source: "jamf-cli")
        XCTAssertEqual(fresh.filling(from: older).lapsPendingCount, 3)
        XCTAssertEqual(
            fresh.withEnvironment(products: nil, protect: nil, serverHealth: .init(
                expiries: nil, notificationCount: nil, lapsPendingCount: 9)).lapsPendingCount, 9)
        XCTAssertEqual(TrendStore.environmentValue(.lapsPending, in: older), 3)
        XCTAssertNil(TrendStore.environmentValue(.lapsPending, in: fresh))
        XCTAssertTrue(TrendSeries.Metric.lapsPending.isServerHealth)
        XCTAssertEqual(TrendSeries.Metric.lapsPending.polarity, .lowerIsBetter)
        XCTAssertEqual(TrendSeries.Metric(rawValue: "lapsPending"), .lapsPending)
        XCTAssertFalse(TrendSeries.Metric.allCases.contains(.lapsPending))
        XCTAssertEqual(AlertMetric.lapsPendingCount.rawValue, "laps_pending_count")
        XCTAssertEqual(AlertMetric.lapsPendingCount.value(in: older), 3)
        XCTAssertNil(AlertMetric.lapsPendingCount.value(in: fresh))
        XCTAssertFalse(AlertMetric.lapsPendingCount.isPercentage)
        let hits = MetricAlertEvaluator.evaluate(
            rules: [AlertRule(metric: "laps_pending_count", when: "above", threshold: 2)],
            current: older, prior: nil)
        XCTAssertEqual(hits.count, 1)
    }
}
