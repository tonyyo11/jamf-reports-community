import Foundation

/// Demo data for the screens past the Overview, one section per screen. Every
/// value is written against the rest of `DemoData`: the 524-Mac fleet, the
/// Meridian devices in `deviceInventory`, the schedules in `scheduledRuns`, and
/// dates on or before `referenceDate`.
extension DemoData {

    /// A demo folder as a subtitle shows it. Demo mode names the default root,
    /// never this Mac's configured one, which may be a synced team folder.
    static func workspaceDisplayPath(_ subpath: String) -> String {
        "~/Jamf-Reports/\(org.profile)/\(subpath)"
    }

    // MARK: - Patch Compliance

    /// Zoom Workplace, which a demo Mac fails to patch but `patchTitleSummary`
    /// (the Devices screen's titles) does not list. Its counts put the fleet on
    /// the Patch trend's final 87.5% both ways it is measured: weighted by
    /// device (1,799 of 2,056) and as the mean of the four titles' rates, which
    /// is how a daily summary records it.
    static let zoomPatchTitle = PatchTitleSummary(
        title: "Zoom Workplace", latestVersion: "6.0.2",
        compliant: 378, total: 520, complianceLabel: "72.7%")

    /// Every title Patch Compliance tracks: the Devices screen's titles, plus
    /// Zoom Workplace unless `patchTitleSummary` already lists it.
    static let patchTitles: [PatchTitleSummary] = {
        let listed = Set(patchTitleSummary.map(\.title))
        return patchTitleSummary + [zoomPatchTitle].filter { !listed.contains($0.title) }
    }()

    /// A demo title's ID: its 1-based position in `patchTitles`.
    static func patchTitleID(_ title: String) -> String {
        guard let index = patchTitles.firstIndex(where: { $0.title == title }) else { return "" }
        return String(index + 1)
    }

    /// When each title's latest version shipped. Zoom's is past the 30 days
    /// Patch Compliance flags.
    private static let patchReleaseDates: [String: String] = [
        "Google Chrome": "2026-04-16T17:00:00Z",
        "Mozilla Firefox": "2026-04-14T15:00:00Z",
        "Jamf Self Service for macOS": "2026-04-07T16:00:00Z",
        "Zoom Workplace": "2026-03-18T18:00:00Z",
    ]

    /// Title ID → release date, the lookup `PatchReleaseDateService` builds.
    static let patchReleaseLookup: [String: String] = Dictionary(
        patchTitles.compactMap { title in
            patchReleaseDates[title.title].map { (patchTitleID(title.title), $0) }
        },
        uniquingKeysWith: { first, _ in first }
    )

    /// One row per failing Mac and title, from the patch failures the Devices
    /// screen shows: seven failures on four Macs, Apr 21–25.
    static let patchFailures: [PatchFailureRow] = deviceInventory.flatMap { device in
        device.patchFailures.map { failure in
            PatchFailureRow(
                policy: failure.title,
                policyId: patchTitleID(failure.title),
                device: device.name,
                deviceId: device.id,
                statusDate: failure.date,
                attempt: patchAttempts(failure.status),
                lastAction: failure.status,
                serial: device.serial,
                osVersion: device.osVersion,
                username: device.user
            )
        }
    }

    /// Install attempts behind a status: a failed one has used all three.
    private static func patchAttempts(_ status: String) -> Int {
        switch status {
        case "Failed": return 3
        case "Retrying": return 2
        default: return 1
        }
    }

    static let patchStatus = PatchStatusService.Snapshot(
        titles: patchTitles.map { title in
            PatchStatusRow(
                title: title.title, id: patchTitleID(title.title),
                onLatest: title.compliant, onOther: title.total - title.compliant,
                total: title.total, latest: title.latestVersion,
                compliancePct: title.complianceLabel)
        },
        failures: patchFailures,
        sourceFile: nil,
        snapshotDate: referenceDate
    )

    // MARK: - OS Updates

    /// The fleet against its macOS Sequoia 15.4 plans: the 385 Macs on a
    /// current release have completed and three are in error. Of 24 plans, the
    /// six failed or in exception and the one canceled are the failed-plans rows.
    static let updateStatus = UpdateStatusService.Snapshot(
        total: totalDevices,
        planTotal: 24,
        statusBreakdown: [
            .init(label: "COMPLETED", count: 385, colorHex: 0x30D158),
            .init(label: "PENDING", count: 92, colorHex: 0x007AFF),
            .init(label: "INSTALLING", count: 44, colorHex: 0x007AFF),
            .init(label: "ERROR", count: 3, colorHex: 0xFF453A),
        ],
        planStateBreakdown: [
            .init(label: "PlanCompleted", count: 12, colorHex: 0x30D158),
            .init(label: "PlanActive", count: 3, colorHex: 0x007AFF),
            .init(label: "PlanPending", count: 2, colorHex: 0x007AFF),
            .init(label: "PlanFailed", count: 3, colorHex: 0xFF453A),
            .init(label: "PlanException", count: 3, colorHex: 0xFF453A),
            .init(label: "PlanCanceled", count: 1, colorHex: 0xFF453A),
        ],
        errorDevices: updateErrorDevices,
        failedPlans: updateFailedPlans,
        sourceFile: nil,
        snapshotDate: referenceDate,
        scanFailuresAvailable: true
    )

    private static let updateProductKey = "macOS Sequoia 15.4"

    /// The three Macs in ERROR. The first two are the Devices screen's Macs on
    /// macOS 14.7.4 and 13.7.6.
    private static let updateErrorDevices: [UpdateErrorDevice] = [
        updateErrorDevice("MERIDIAN-DK-MBA", "FVFYK2N5P8R3", "14.7.4", "d.kim",
                          updated: "2026-04-24T14:12:00Z"),
        updateErrorDevice("MERIDIAN-LV-MBA", "FVFXJ8L2R4M7", "13.7.6", "l.vasquez",
                          updated: "2026-04-23T16:40:00Z"),
        updateErrorDevice("MERIDIAN-GH-MBP", "C02WL8K3HV2D", "12.7.6", "g.hughes",
                          updated: "2026-04-22T09:05:00Z"),
    ]

    private static func updateErrorDevice(
        _ name: String, _ serial: String, _ os: String, _ user: String, updated: String
    ) -> UpdateErrorDevice {
        UpdateErrorDevice(
            name: name, serial: serial, deviceType: "Computer", osVersion: os,
            username: user, status: "ERROR", productKey: updateProductKey, updated: updated)
    }

    /// Every plan that did not finish: three failed, three in exception and one
    /// canceled, as the plan-state donut counts them.
    private static let updateFailedPlans: [UpdateFailedPlan] = [
        failedPlan("MERIDIAN-DK-MBA", "FVFYK2N5P8R3", "14.7.4", "d.kim",
                   "PlanFailed", "Install", "Insufficient disk space",
                   "2026-04-24T14:12:00Z"),
        failedPlan("MERIDIAN-LV-MBA", "FVFXJ8L2R4M7", "13.7.6", "l.vasquez",
                   "PlanException", "Download", "Network timeout after 3 retries",
                   "2026-04-23T16:40:00Z"),
        failedPlan("MERIDIAN-GH-MBP", "C02WL8K3HV2D", "12.7.6", "g.hughes",
                   "PlanFailed", "Validate", "Signature verification failed",
                   "2026-04-22T09:05:00Z"),
        failedPlan("MERIDIAN-NP-MBA", "FVFZM2L7Q9K4", "14.7.4", "n.patel",
                   "PlanException", "Install", "Power management conflict",
                   "2026-04-25T01:15:00Z"),
        failedPlan("MERIDIAN-EM-MBP", "C02XN4R8JG2T", "13.7.6", "e.moreau",
                   "PlanFailed", "Restart", "Failed to apply updates on restart",
                   "2026-04-21T20:30:00Z"),
        failedPlan("MERIDIAN-KO-MM", "FVFYL9P3N7J2", "14.7.4", "k.okafor",
                   "PlanException", "Download", "Storage full during download",
                   "2026-04-22T11:20:00Z"),
        failedPlan("MERIDIAN-SN-MBA", "FVFXM6K2P4H8", "14.7.4", "s.nguyen",
                   "PlanCanceled", "Install", "User canceled installation",
                   "2026-04-21T15:10:00Z"),
    ]

    private static func failedPlan(
        _ name: String, _ serial: String, _ os: String, _ user: String,
        _ state: String, _ action: String, _ error: String, _ lastEvent: String
    ) -> UpdateFailedPlan {
        UpdateFailedPlan(
            name: name, serial: serial, deviceType: "Computer", osVersion: os,
            username: user, state: state, action: action, version: "15.4",
            error: error, lastEvent: lastEvent)
    }

    // MARK: - Policy & Profile Health

    /// jamf-cli's policy checks carry two severities: `no_scope` is a warning
    /// and `no_category` is info. The table holds the 8 and 4 the tiles count.
    static let policyHealth = PolicyHealthService.Snapshot(
        summary: PolicyStatusSummary(
            totalPolicies: 47, enabled: 38, disabled: 9,
            configFindings: 12, warnings: 8, info: 4),
        findings: [
            noScopeFinding("12", "Microsoft Office 2019 - Install (Legacy)"),
            noScopeFinding("18", "Rosetta 2 - Install"),
            noScopeFinding("23", "Printer - Meridian East 3rd Floor"),
            noScopeFinding("31", "macOS Monterey - Upgrade"),
            noScopeFinding("36", "Test - Dock Reset"),
            noScopeFinding("40", "Cisco AnyConnect - Remove"),
            noScopeFinding("44", "Clinical Kiosk - Setup"),
            noScopeFinding("52", "Zoom Workplace - Update (Pilot)"),
            noCategoryFinding("7", "Rename Computer"),
            noCategoryFinding("9", "Set Time Server"),
            noCategoryFinding("15", "Enable Remote Management"),
            noCategoryFinding("58", "Collect Diagnostics"),
        ],
        profiles: [
            profileFailure("0-104", "Certificate Authority", "Computer", 15, 11,
                           "2026-04-24", "The certificate payload could not be installed"),
            profileFailure("1-109", "Chrome Enterprise", "Computer", 7, 6,
                           "2026-04-21", "Profile installation timed out"),
            profileFailure("2-107", "Dock Preferences", "Computer", 8, 5,
                           "2026-04-23", "Payload rejected by managed client"),
            profileFailure("3-102", "Exchange Email Setup", "Computer", 3, 3,
                           "2026-04-15", "Account already exists on device"),
            profileFailure("4-111", "Time Zone Settings", "Mobile Device", 1, 1,
                           "2026-04-08", "Device offline during push"),
        ],
        profileSummary: ProfileFailureSummary(
            totalErrors: 34, uniqueProfiles: 5, uniqueDevices: 22, days: 30),
        sourceFile: nil,
        snapshotDate: referenceDate
    )

    private static func noScopeFinding(_ id: String, _ policy: String) -> PolicyFinding {
        PolicyFinding(severity: "warning", policy: policy, policyId: id,
                      check: "no_scope", detail: "No targets in scope")
    }

    private static func noCategoryFinding(_ id: String, _ policy: String) -> PolicyFinding {
        PolicyFinding(severity: "info", policy: policy, policyId: id,
                      check: "no_category", detail: "Uncategorised")
    }

    private static func profileFailure(
        _ id: String, _ name: String, _ deviceType: String, _ errors: Int, _ devices: Int,
        _ lastError: String, _ topError: String
    ) -> PolicyHealthService.ProfileFailure {
        PolicyHealthService.ProfileFailure(
            id: id, name: name, deviceType: deviceType, errors: errors, devices: devices,
            lastError: lastError, topError: topError)
    }

    // MARK: - Groups & Searches

    /// 14 computer groups (9 smart, 5 static), 4 mobile device groups and 2
    /// advanced mobile searches, named for the demo fleet.
    static let groupInventory = GroupInventoryService.Snapshot(
        advancedMobileSearches: [
            AdvancedMobileSearchRow(
                id: "3", name: "iPads Not Inventoried in 7 Days",
                criteria: [
                    searchCriterion("Last Inventory Update", 0, "more than x days ago", "7"),
                    searchCriterion("Model", 1, "like", "iPad"),
                ],
                displayFields: ["Display Name", "Serial Number", "Username",
                                "Last Inventory Update"],
                siteId: "-1"),
            AdvancedMobileSearchRow(
                id: "5", name: "User-Enrolled Devices",
                criteria: [searchCriterion("Device Ownership Type", 0, "is", "User Enrollment")],
                displayFields: ["Display Name", "Username", "OS Version"],
                siteId: "-1"),
        ],
        classicComputerGroups: [
            ClassicGroupRow(demoID: 1, name: "All Managed Macs", isSmart: true),
            ClassicGroupRow(demoID: 2, name: "macOS Below 15.3.2", isSmart: true),
            ClassicGroupRow(demoID: 4, name: "FileVault Not Enabled", isSmart: true),
            ClassicGroupRow(demoID: 5, name: "Stale - No Check-in 30 Days", isSmart: true),
            ClassicGroupRow(demoID: 7, name: "CrowdStrike Falcon Not Running", isSmart: true),
            ClassicGroupRow(demoID: 9, name: "\(complianceBaseline) - Failing Rules",
                            isSmart: true),
            ClassicGroupRow(demoID: 11, name: "Google Chrome Not on Latest", isSmart: true),
            ClassicGroupRow(demoID: 14, name: "Clinical Department Macs", isSmart: true),
            ClassicGroupRow(demoID: 16, name: "Apple Silicon Macs", isSmart: true),
            ClassicGroupRow(demoID: 18, name: "Pilot - macOS Updates", isSmart: false),
            ClassicGroupRow(demoID: 21, name: "Executive Leadership", isSmart: false),
            ClassicGroupRow(demoID: 23, name: "Loaner Pool", isSmart: false),
            ClassicGroupRow(demoID: 26, name: "Lab Macs - Meridian East", isSmart: false),
            ClassicGroupRow(demoID: 29, name: "Exclusions - Patch Deferral", isSmart: false),
        ],
        classicMobileGroups: [
            ClassicGroupRow(demoID: 3, name: "All Managed iPads", isSmart: true),
            ClassicGroupRow(demoID: 6, name: "Clinical iPads", isSmart: true),
            ClassicGroupRow(demoID: 8, name: "iOS Below 18.2", isSmart: true),
            ClassicGroupRow(demoID: 12, name: "Loaner iPhones", isSmart: false),
        ],
        decodedAnySource: true,
        sourceFile: nil,
        snapshotDate: referenceDate
    )

    private static func searchCriterion(
        _ name: String, _ priority: Int, _ searchType: String, _ value: String
    ) -> AdvancedMobileSearchCriterion {
        AdvancedMobileSearchCriterion(
            name: name, priority: priority, andOr: "and", searchType: searchType,
            value: value, openingParen: false, closingParen: false)
    }

    // MARK: - Generated Reports

    /// One file in the demo's Generated Reports folder.
    private struct ReportFile: Sendable {
        let name: String
        let bytes: Int64
        let date: String
        let source: String
        let sheets: Int
        let devices: Int?
    }

    private static let weeklyExecutive = "Weekly Executive Report"
    private static let mobileInventory = "Mobile Inventory (iPad)"

    /// Newest first, as `ReportLibrary.list` sorts them: the weekday Mobile
    /// Inventory (iPad) run's week and the last two Weekly Executive Reports,
    /// each with its HTML, named for their schedules in `scheduledRuns`.
    /// Workbooks carry that day's Mac count, as a summary would give them.
    private static let reportFiles: [ReportFile] = [
        reportFile("2026-04-24_073305", "xlsx", 702_464, "Apr 24, 07:33", mobileInventory),
        reportFile("2026-04-23_073248", "xlsx", 701_952, "Apr 23, 07:32", mobileInventory),
        reportFile("2026-04-22_073251", "xlsx", 700_416, "Apr 22, 07:32", mobileInventory),
        reportFile("2026-04-21_073244", "xlsx", 699_904, "Apr 21, 07:32", mobileInventory),
        reportFile("2026-04-20_073302", "xlsx", 699_392, "Apr 20, 07:33", mobileInventory),
        reportFile("2026-04-20_070231", "html", 2_412_877, "Apr 20, 07:02", weeklyExecutive),
        reportFile("2026-04-20_070214", "xlsx", 1_284_506, "Apr 20, 07:02", weeklyExecutive),
        reportFile("2026-04-13_070227", "html", 2_398_104, "Apr 13, 07:02", weeklyExecutive,
                   weeksAgo: 1),
        reportFile("2026-04-13_070209", "xlsx", 1_279_318, "Apr 13, 07:02", weeklyExecutive,
                   weeksAgo: 1),
    ]

    /// A report named the way `ReportEngine.resolveOutputURL` names one. The
    /// Executive template writes 9 sheets and the Asset template 10.
    private static func reportFile(
        _ stamp: String, _ ext: String, _ bytes: Int64, _ date: String, _ source: String,
        weeksAgo: Int = 0
    ) -> ReportFile {
        let isWorkbook = ext == "xlsx"
        let sheets = source == weeklyExecutive ? 9 : 10
        let lastWeek = totalDevicesTrend.count - 1 - weeksAgo
        let macs = Int((totalDevicesTrend[safe: lastWeek] ?? Double(totalDevices)).rounded())
        return ReportFile(
            name: "report_\(org.profile)_\(stamp).\(ext)", bytes: bytes, date: date,
            source: source, sheets: isWorkbook ? sheets : 0, devices: isWorkbook ? macs : nil)
    }

    /// The demo's Generated Reports list. The sidebar's badge counts it.
    static let generatedReports: [Report] = reportFiles.map { file in
        Report(name: file.name, size: FileDisplay.size(file.bytes), date: file.date,
               source: file.source, sheets: file.sheets, devices: file.devices)
    }

    /// Totals for the Generated Reports tiles. The files come from seven runs,
    /// fewer than `output.keep_latest_runs` keeps, so none have been archived.
    static let generatedReportStats = ReportLibrary.Stats(
        count: reportFiles.count,
        totalBytes: reportFiles.reduce(Int64(0)) { $0 + $1.bytes },
        archivedCount: 0
    )

    /// The archived summaries Trends reads: one per week in `trendDates`.
    static let snapshotFamilies: [SnapshotFamily] = [
        SnapshotFamily(
            name: "summaries", glob: "*summary*.json", snapshotCount: trendDates.count,
            latestDate: nil, totalBytes: Int64(trendDates.count) * 3_072,
            usedBy: "Trends · Overview score cards")
    ]
}

private extension ClassicGroupRow {
    /// The decoder's `init(from:)` replaces the memberwise initializer, so demo
    /// rows get their own.
    init(demoID: Int, name: String, isSmart: Bool) {
        self.id = demoID
        self.isSmart = isSmart
        self.name = name
    }
}
