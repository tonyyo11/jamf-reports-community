import Foundation

/// Reads the latest mobile device snapshots from jamf-cli (list, inventory-details,
/// and profiles) and prepares them for the `MobileFleetView`. Decoupled from the
/// SwiftUI view for unit testing.
///
/// The view consumes a single `Snapshot` value containing device lists, KPI counts,
/// OS distribution, and config profiles. Returns `.empty` when no mobile data
/// sources exist — many tenants don't manage mobile devices.
struct MobileFleetService: Sendable {

    /// Slice kind used by the MobileFleetView supervision donut so the view
    /// can pick a colour without leaking string literals.
    enum SupervisionRole: Sendable {
        case supervised, unsupervised, unmanaged
    }

    /// Everything the MobileFleetView needs from mobile device snapshots.
    /// Provides both light and rich device data sources, with computed KPIs
    /// preferring rich data when available.
    struct Snapshot: Sendable, Equatable {
        let isDetected: Bool
        let lightDevices: [MobileDeviceListRow]
        let richDevices: [MobileDeviceInventoryItem]
        let profiles: [MobileConfigProfileRow]
        let sourceFile: URL?
        let snapshotDate: Date?

        // MARK: - Computed properties

        var totalDevices: Int {
            richDevices.isEmpty ? lightDevices.count : richDevices.count
        }

        var iPadCount: Int {
            if !richDevices.isEmpty {
                return richDevices.filter { device in
                    (device.deviceType?.localizedCaseInsensitiveContains("iPad") == true)
                }.count
            } else {
                return lightDevices.filter { device in
                    (device.type?.localizedCaseInsensitiveContains("iPad") == true)
                }.count
            }
        }

        var iPhoneCount: Int {
            if !richDevices.isEmpty {
                return richDevices.filter { device in
                    (device.deviceType?.localizedCaseInsensitiveContains("iPhone") == true)
                }.count
            } else {
                return lightDevices.filter { device in
                    (device.type?.localizedCaseInsensitiveContains("iPhone") == true)
                }.count
            }
        }

        var appleTVCount: Int {
            if !richDevices.isEmpty {
                return richDevices.filter { device in
                    (device.deviceType?.localizedCaseInsensitiveContains("TV") == true) ||
                    (device.deviceType?.localizedCaseInsensitiveContains("AppleTV") == true)
                }.count
            } else {
                return lightDevices.filter { device in
                    (device.type?.localizedCaseInsensitiveContains("TV") == true) ||
                    (device.type?.localizedCaseInsensitiveContains("AppleTV") == true)
                }.count
            }
        }

        var managedCount: Int {
            richDevices.filter { $0.general?.managed == true }.count
        }

        var unmanagedCount: Int {
            richDevices.filter { $0.general?.managed == false }.count
        }

        var supervisedCount: Int {
            richDevices.filter { $0.general?.supervised == true }.count
        }

        /// Bucket count of supervised / unsupervised / unmanaged devices for the
        /// MobileFleetView supervision donut. Unmanaged dominates over
        /// supervised: an unmanaged device's supervised flag may be stale, so
        /// we surface it as the more actionable bucket.
        var supervisionBreakdown: [(label: String, count: Int, role: SupervisionRole)] {
            let unmanaged = unmanagedCount
            let supervised = richDevices.filter {
                $0.general?.managed == true && $0.general?.supervised == true
            }.count
            let unsupervised = richDevices.filter {
                $0.general?.managed == true && $0.general?.supervised == false
            }.count
            return [
                ("Supervised", supervised, .supervised),
                ("Unsupervised", unsupervised, .unsupervised),
                ("Unmanaged", unmanaged, .unmanaged),
            ]
        }

        /// Per-method counts derived from `general.deviceOwnershipType`. Maps the
        /// raw enum to a human label; falls back to the raw value for forward
        /// compatibility when Jamf adds new methods. Sorted descending by count.
        var enrollmentMethodDistribution: [(method: String, count: Int)] {
            let raw = richDevices.compactMap { device -> String? in
                guard let value = device.general?.deviceOwnershipType?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
                else { return nil }
                return Self.enrollmentMethodLabel(for: value)
            }
            let grouped = Dictionary(grouping: raw) { $0 }
            return grouped
                .map { (method: $0.key, count: $0.value.count) }
                .sorted { lhs, rhs in
                    if lhs.count != rhs.count { return lhs.count > rhs.count }
                    return lhs.method < rhs.method
                }
        }

        /// Number of managed apps reported for a rich device. Returns 0 when
        /// the `applications` array is `nil` (jamf-cli wasn't asked for the
        /// APPLICATIONS section) or empty.
        func managedAppCount(for device: MobileDeviceInventoryItem) -> Int {
            device.applications?.count ?? 0
        }

        /// Map a raw `deviceOwnershipType` value to a display label that matches
        /// the Python side's `_mobile_enrollment_label`. Unknown values pass
        /// through unchanged for forward compatibility.
        static func enrollmentMethodLabel(for raw: String) -> String {
            switch raw {
            case "Institutional": return "ADE / Institutional"
            case "UserEnrollment": return "User Enrollment"
            case "AccountDrivenUserEnrollment": return "Account-Driven User Enrollment"
            case "AccountDrivenDeviceEnrollment": return "Account-Driven Device Enrollment"
            case "Personal": return "Personal / BYOD"
            case "PersonalDeviceProfile": return "Personal Device Profile (legacy)"
            default: return raw
            }
        }

        var passcodeCompliantCount: Int {
            richDevices.filter { $0.general?.passcodeCompliant == true }.count
        }

        var activationLockEnabledCount: Int {
            richDevices.filter { $0.general?.activationLockEnabled == true }.count
        }

        var jailbreakDetectedCount: Int {
            richDevices.filter { device in
                guard let status = device.general?.jailbreakDetected,
                      !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return false
                }
                return !status.localizedCaseInsensitiveContains("none")
            }.count
        }

        var osDistribution: [(osVersion: String, count: Int)] {
            let osVersions: [String] = richDevices.compactMap { device in
                device.general?.osVersion?.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }

            let grouped = Dictionary(grouping: osVersions) { $0 }
            let sorted = grouped.map { (osVersion: $0.key, count: $0.value.count) }
                .sorted { $0.count > $1.count }
            return Array(sorted.prefix(10))
        }

        /// Freshness signal for `StaleDataBanner` consumers. Uses the same 36-hour
        /// threshold as TrendStore to align with the standard daily-schedule cadence.
        var cacheSource: CacheSource {
            CacheSource.from(snapshotDate: snapshotDate, withinHours: 36)
        }

        /// Empty snapshot used when no mobile device data exists.
        static let empty = Snapshot(
            isDetected: false,
            lightDevices: [],
            richDevices: [],
            profiles: [],
            sourceFile: nil,
            snapshotDate: nil
        )

        static func == (lhs: Snapshot, rhs: Snapshot) -> Bool {
            lhs.isDetected == rhs.isDetected &&
            lhs.lightDevices.count == rhs.lightDevices.count &&
            lhs.richDevices.count == rhs.richDevices.count &&
            lhs.profiles.count == rhs.profiles.count &&
            lhs.sourceFile == rhs.sourceFile &&
            lhs.snapshotDate == rhs.snapshotDate
        }
    }

    /// Returns the newest mobile device snapshot for `profile`. Returns `.empty`
    /// when no data is available — that's a normal state for tenants that don't
    /// manage mobile devices.
    static func load(profile: String) -> Snapshot {
        guard let dir = (try? WorkspacePaths.dataDir(for: profile)) else {
            return .empty
        }

        let listDir = dir.appendingPathComponent("mobile-devices-list", isDirectory: true)
        let inventoryDir = dir.appendingPathComponent("mobile-device-inventory-details", isDirectory: true)
        let profilesDir = dir.appendingPathComponent("classic-ios-profiles", isDirectory: true)

        let listURL = newestJSON(in: listDir)
        let inventoryURL = newestJSON(in: inventoryDir)
        let profilesURL = newestJSON(in: profilesDir)

        return load(listURL: listURL, inventoryURL: inventoryURL, profilesURL: profilesURL)
    }

    /// Test seam: load directly from arbitrary file URLs.
    static func load(listURL: URL?, inventoryURL: URL?, profilesURL: URL?) -> Snapshot {
        guard listURL != nil || inventoryURL != nil || profilesURL != nil else {
            return .empty
        }

        let lightDevices = listURL.flatMap(loadDeviceList) ?? []
        let richDevices = inventoryURL.flatMap(loadDeviceInventory) ?? []
        let profiles = profilesURL.flatMap(loadProfiles) ?? []

        // Determine source file and date from the most recent of the three
        let sourceFiles = [listURL, inventoryURL, profilesURL].compactMap { $0 }
        let sourceFile = sourceFiles.max { lhs, rhs in
            let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return l < r
        }

        let snapshotDate = sourceFile.flatMap { url in
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
        }

        return Snapshot(
            isDetected: true,
            lightDevices: lightDevices,
            richDevices: richDevices,
            profiles: profiles,
            sourceFile: sourceFile,
            snapshotDate: snapshotDate
        )
    }

    // MARK: - Internals

    private static func newestJSON(in dir: URL) -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return nil }
        guard let files = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        return files
            .filter { $0.pathExtension == "json" }
            .max { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return l < r
            }
    }

    private static func loadDeviceList(_ url: URL) -> [MobileDeviceListRow]? {
        guard let data = try? Data(contentsOf: url),
              let devices = try? JSONDecoder().decode([MobileDeviceListRow].self, from: data)
        else { return nil }
        return devices
    }

    private static func loadDeviceInventory(_ url: URL) -> [MobileDeviceInventoryItem]? {
        guard let data = try? Data(contentsOf: url),
              let devices = try? JSONDecoder().decode([MobileDeviceInventoryItem].self, from: data)
        else { return nil }
        return devices
    }

    private static func loadProfiles(_ url: URL) -> [MobileConfigProfileRow]? {
        guard let data = try? Data(contentsOf: url) else { return nil }

        // Try direct array decode first
        if let profiles = try? JSONDecoder().decode([MobileConfigProfileRow].self, from: data) {
            return profiles
        }

        // Fall back to any envelope structure
        return nil
    }
}