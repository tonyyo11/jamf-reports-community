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

    /// Coarse device form factor. jamf-cli's `deviceType` is the OS family
    /// ("iOS") and cannot separate iPad from iPhone — that lives in the
    /// hardware model — so form factor is its own axis.
    enum FormFactor: Sendable, Equatable {
        case iPad, iPhone, appleTV, other
    }

    /// Classify a device by hardware model, preferring the precise
    /// `modelIdentifier` ("iPhone5,2" / "iPad13,1" / "AppleTV5,3"), then the
    /// marketing `model` string ("iPhone 5 (CDMA)"), then the OS-family
    /// `deviceType` (only useful for distinguishing tvOS, and for legacy/list
    /// shapes that put the form factor there).
    static func classifyFormFactor(
        model: String?, modelIdentifier: String?, deviceType: String?
    ) -> FormFactor {
        let ident = (modelIdentifier ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if ident.hasPrefix("iPad") { return .iPad }
        if ident.hasPrefix("iPhone") { return .iPhone }
        if ident.hasPrefix("AppleTV") { return .appleTV }

        if let m = model?.trimmingCharacters(in: .whitespacesAndNewlines),
           !m.isEmpty {
            if m.localizedCaseInsensitiveContains("iPad") { return .iPad }
            if m.localizedCaseInsensitiveContains("iPhone") { return .iPhone }
            if m.localizedCaseInsensitiveContains("Apple TV") ||
               m.localizedCaseInsensitiveContains("AppleTV") { return .appleTV }
        }

        if let t = deviceType?.trimmingCharacters(in: .whitespacesAndNewlines),
           !t.isEmpty {
            if t.localizedCaseInsensitiveContains("tvOS") ||
               t.localizedCaseInsensitiveContains("AppleTV") ||
               t.localizedCaseInsensitiveContains("TV") { return .appleTV }
            if t.localizedCaseInsensitiveContains("iPad") { return .iPad }
            if t.localizedCaseInsensitiveContains("iPhone") { return .iPhone }
        }
        return .other
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
        /// Per-kind newest-file dates for the freshness chip row. Keys are the
        /// on-disk kind names (`mobile-devices-list`,
        /// `mobile-device-inventory-details`, `classic-ios-profiles`); a kind
        /// absent from disk is absent from the map.
        var sourceDates: [String: Date] = [:]

        // MARK: - Computed properties

        var totalDevices: Int {
            richDevices.isEmpty ? lightDevices.count : richDevices.count
        }

        /// (model, modelIdentifier, deviceType) tuples for form-factor counting,
        /// drawn from whichever snapshot actually carries hardware model data.
        /// The richer `mobile-device-inventory-details` can arrive with a null
        /// `hardware` section while the lighter `mobile-devices-list` carries it
        /// (the dummy tenant is exactly this), so prefer the populated source
        /// rather than collapsing iPad/iPhone counts to 0 by classifying on the
        /// OS-family `deviceType` alone.
        private var formFactorInputs: [(model: String?, modelIdentifier: String?, deviceType: String?)] {
            let rich: [(String?, String?, String?)] = richDevices.map {
                ($0.hardware?.model, $0.hardware?.modelIdentifier, $0.deviceType)
            }
            if rich.contains(where: { $0.0 != nil || $0.1 != nil }) {
                return rich.map { (model: $0.0, modelIdentifier: $0.1, deviceType: $0.2) }
            }
            let light: [(String?, String?, String?)] = lightDevices.map {
                // Older flat list shape put the marketing name in top-level
                // `model` and the form factor in `type`; the current shape uses
                // `hardware.model` / `deviceType`. Coalesce so both classify.
                ($0.hardware?.model ?? $0.model, $0.hardware?.modelIdentifier, $0.deviceType ?? $0.type)
            }
            if light.contains(where: { $0.0 != nil || $0.1 != nil }) {
                return light.map { (model: $0.0, modelIdentifier: $0.1, deviceType: $0.2) }
            }
            // Neither snapshot carries a hardware model — fall back to the source
            // that drives `totalDevices` so form-factor + total stay aligned.
            let fallback = richDevices.isEmpty ? light : rich
            return fallback.map { (model: $0.0, modelIdentifier: $0.1, deviceType: $0.2) }
        }

        private func formFactorCount(_ factor: FormFactor) -> Int {
            formFactorInputs.filter {
                MobileFleetService.classifyFormFactor(
                    model: $0.model,
                    modelIdentifier: $0.modelIdentifier,
                    deviceType: $0.deviceType
                ) == factor
            }.count
        }

        var iPadCount: Int { formFactorCount(.iPad) }

        var iPhoneCount: Int { formFactorCount(.iPhone) }

        var appleTVCount: Int { formFactorCount(.appleTV) }

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
            lhs.snapshotDate == rhs.snapshotDate &&
            lhs.sourceDates == rhs.sourceDates
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

        let listURL = FileManager.newestJSONFile(in: listDir)
        let inventoryURL = FileManager.newestJSONFile(in: inventoryDir)
        let profilesURL = FileManager.newestJSONFile(in: profilesDir)

        return load(listURL: listURL, inventoryURL: inventoryURL, profilesURL: profilesURL)
    }

    /// Test seam: load directly from arbitrary file URLs.
    static func load(listURL: URL?, inventoryURL: URL?, profilesURL: URL?) -> Snapshot {
        guard listURL != nil || inventoryURL != nil || profilesURL != nil else {
            return .empty
        }

        // Track whether at least one loader decoded a non-nil result. A readable
        // empty file counts as "detected" (mirrors ProtectDashboardService). A URL
        // that is present but whose data cannot be decoded is a decode failure and
        // is logged; it does NOT count as detected.
        var readSomething = false
        let lightDevices = loadDeviceList(from: listURL, success: &readSomething)
        let richDevices = loadDeviceInventory(from: inventoryURL, success: &readSomething)
        let profiles = loadProfiles(from: profilesURL, success: &readSomething)

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

        // Per-kind freshness for the chip row, based on file presence — honest
        // even when a kind's own decode failed (see PatchStatusService).
        var sourceDates: [String: Date] = [:]
        for (kind, url) in [
            ("mobile-devices-list", listURL),
            ("mobile-device-inventory-details", inventoryURL),
            ("classic-ios-profiles", profilesURL),
        ] {
            guard let url, FileManager.default.fileExists(atPath: url.path),
                  let d = (try? url.resourceValues(
                      forKeys: [.contentModificationDateKey]
                  ))?.contentModificationDate
            else { continue }
            sourceDates[kind] = d
        }

        return Snapshot(
            isDetected: readSomething,
            lightDevices: lightDevices,
            richDevices: richDevices,
            profiles: profiles,
            sourceFile: sourceFile,
            snapshotDate: snapshotDate,
            sourceDates: sourceDates
        )
    }

    // MARK: - Summary count derivation

    /// Device count from a raw `mobile-devices-list` snapshot's bytes, for the
    /// "Managed Devices" summary/trend field. Tries the current bare-array
    /// shape first (mirrors `loadDeviceList`'s decode), then a
    /// `{totalCount, results}` envelope (preferring `totalCount` when
    /// present, falling back to `results.count`). Returns nil when the data
    /// decodes as neither — absence is never reported as 0.
    static func deviceCount(fromMobileDevicesListData data: Data) -> Int? {
        if let devices = try? JSONDecoder().decode([MobileDeviceListRow].self, from: data) {
            return devices.count
        }
        if let envelope = try? JSONDecoder().decode(MobileDevicesListEnvelope.self, from: data) {
            return envelope.totalCount ?? envelope.results?.count
        }
        return nil
    }

    private struct MobileDevicesListEnvelope: Decodable, Sendable {
        let totalCount: Int?
        let results: [MobileDeviceListRow]?
    }

    // MARK: - Internals

    private static func loadDeviceList(
        from url: URL?, success: inout Bool
    ) -> [MobileDeviceListRow] {
        guard let url else { return [] }
        guard let data = try? Data(contentsOf: url) else {
            AppLogger.collect.info(
                "MobileFleetService: could not read mobile-devices-list file \(url.lastPathComponent, privacy: .public)"
            )
            return []
        }
        guard let devices = try? JSONDecoder().decode([MobileDeviceListRow].self, from: data) else {
            AppLogger.collect.info(
                "MobileFleetService: failed to decode mobile-devices-list at \(url.lastPathComponent, privacy: .public)"
            )
            return []
        }
        success = true
        return devices
    }

    private static func loadDeviceInventory(
        from url: URL?, success: inout Bool
    ) -> [MobileDeviceInventoryItem] {
        guard let url else { return [] }
        guard let data = try? Data(contentsOf: url) else {
            AppLogger.collect.info(
                "MobileFleetService: could not read mobile-device-inventory-details file \(url.lastPathComponent, privacy: .public)"
            )
            return []
        }
        guard let devices = try? JSONDecoder().decode([MobileDeviceInventoryItem].self, from: data) else {
            AppLogger.collect.info(
                "MobileFleetService: failed to decode mobile-device-inventory-details at \(url.lastPathComponent, privacy: .public)"
            )
            return []
        }
        success = true
        return devices
    }

    private static func loadProfiles(
        from url: URL?, success: inout Bool
    ) -> [MobileConfigProfileRow] {
        guard let url else { return [] }
        guard let data = try? Data(contentsOf: url) else {
            AppLogger.collect.info(
                "MobileFleetService: could not read classic-ios-profiles file \(url.lastPathComponent, privacy: .public)"
            )
            return []
        }
        if let profiles = try? JSONDecoder().decode([MobileConfigProfileRow].self, from: data) {
            success = true
            return profiles
        }
        AppLogger.collect.info(
            "MobileFleetService: failed to decode classic-ios-profiles at \(url.lastPathComponent, privacy: .public)"
        )
        return []
    }
}