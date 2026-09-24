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
}
