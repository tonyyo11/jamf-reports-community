import Foundation

/// Demo data for the screens past the Overview, one section per screen. Every
/// value is written against the rest of `DemoData`: the 524-Mac fleet, the
/// Meridian devices in `deviceInventory`, the schedules in `scheduledRuns`, and
/// dates on or before `referenceDate`.
extension DemoData {

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
}
