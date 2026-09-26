import Foundation

/// Reads the latest mobile device snapshots from jamf-cli (list, inventory-details,
/// and profiles) and prepares them for the `MobileFleetView`. Decoupled from the
/// SwiftUI view for unit testing.
///
/// The view consumes a single `Snapshot` value containing device lists, KPI counts,
/// OS distribution, and config profiles. Returns `.empty` when no mobile data
/// sources exist — many tenants don't manage mobile devices.
struct MobileFleetService: Sendable {

    /// The supervision donut's buckets, in slice order. The view picks a colour
    /// per case and filters the devices table by it; the raw value is the label
    /// the legend shows.
    enum SupervisionRole: String, Sendable, CaseIterable {
        case supervised = "Supervised"
        case unsupervised = "Unsupervised"
        case unmanaged = "Unmanaged"

        var label: String { rawValue }
    }

    /// One plotted slice of the supervision donut.
    typealias SupervisionSlice = (role: SupervisionRole, count: Int)

    /// The donut bucket a device falls in, or nil when it cannot be placed: an
    /// unknown management state, or a managed device whose supervision state
    /// is unknown. Unmanaged wins over supervised, because an unmanaged
    /// device's supervised flag may be stale.
    static func supervisionRole(of device: MobileDeviceInventoryItem) -> SupervisionRole? {
        guard let managed = device.general?.managed else { return nil }
        guard managed else { return .unmanaged }
        guard let supervised = device.general?.supervised else { return nil }
        return supervised ? .supervised : .unsupervised
    }

    /// The slice at an angle value. An angle value is the running device count
    /// at an angle, so walk the plotted slices in order: a slice owns the values
    /// up to and including its running total, and the first also owns 0. Nil
    /// below 0 or past the ring's total. Pass the exact array the chart plots,
    /// or a click resolves against slices that were never drawn.
    static func role(
        atAngleValue value: Double, in slices: [SupervisionSlice]
    ) -> SupervisionRole? {
        guard value >= 0 else { return nil }
        var runningTotal = 0
        for slice in slices where slice.count > 0 {
            runningTotal += slice.count
            if value <= Double(runningTotal) { return slice.role }
        }
        return nil
    }

    /// The slice under a click at `point`, relative to the donut's plot, or nil
    /// in the hole or outside the ring. Charts draws the ring across the plot's
    /// shorter side, starting at 12 o'clock and running clockwise.
    static func role(
        at point: CGPoint, plotSize: CGSize, innerRadiusRatio: Double,
        in slices: [SupervisionSlice]
    ) -> SupervisionRole? {
        let total = slices.reduce(0) { $0 + max($1.count, 0) }
        let outer = min(plotSize.width, plotSize.height) / 2
        guard total > 0, outer > 0 else { return nil }
        let dx = point.x - plotSize.width / 2
        let dy = point.y - plotSize.height / 2
        let radius = (dx * dx + dy * dy).squareRoot()
        guard radius >= outer * innerRadiusRatio, radius <= outer else { return nil }
        var radians = atan2(dx, -dy)
        if radians < 0 { radians += 2 * .pi }
        return role(atAngleValue: radians / (2 * .pi) * Double(total), in: slices)
    }

    /// The devices in `role`'s bucket, in their original order, or all of them
    /// when `role` is nil: the devices table's filter.
    static func devices(
        _ devices: [MobileDeviceInventoryItem], in role: SupervisionRole?
    ) -> [MobileDeviceInventoryItem] {
        guard let role else { return devices }
        return devices.filter { supervisionRole(of: $0) == role }
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

    /// Form factor of one list row, read from the same fields `Snapshot` counts
    /// iPads and iPhones with: the current shape's `hardware` and `deviceType`,
    /// or the older flat shape's top-level `model` and `type`.
    static func formFactor(of row: MobileDeviceListRow) -> FormFactor {
        classifyFormFactor(
            model: row.hardware?.model ?? row.model,
            modelIdentifier: row.hardware?.modelIdentifier,
            deviceType: row.deviceType ?? row.type
        )
    }

    /// Form factor of one inventory row. The collected inventory's `hardware`
    /// section is null and its `deviceType` is the OS family ("iOS"), so when
    /// the row's own fields name nothing, the model comes from `listRow`: the
    /// `mobile-devices-list` row with the same id.
    static func formFactor(
        of device: MobileDeviceInventoryItem, listRow: MobileDeviceListRow?
    ) -> FormFactor {
        let own = classifyFormFactor(
            model: device.hardware?.model,
            modelIdentifier: device.hardware?.modelIdentifier,
            deviceType: device.deviceType
        )
        guard own == .other, let listRow else { return own }
        return formFactor(of: listRow)
    }

    /// Text for the devices table's Type pill: the form factor when the model
    /// names one, otherwise the type jamf-cli reported, or "Unknown".
    static func typeLabel(for formFactor: FormFactor, deviceType: String?) -> String {
        switch formFactor {
        case .iPad: return "iPad"
        case .iPhone: return "iPhone"
        case .appleTV: return "Apple TV"
        case .other:
            let type = (deviceType ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return type.isEmpty ? "Unknown" : type
        }
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

        /// List rows keyed by id, to join an inventory row to its list row:
        /// jamf-cli's list `id` is the inventory's `mobileDeviceId`. The first
        /// row wins when an id repeats.
        var lightDevicesByID: [String: MobileDeviceListRow] {
            var byID: [String: MobileDeviceListRow] = [:]
            for row in lightDevices {
                guard let id = row.id, byID[id] == nil else { continue }
                byID[id] = row
            }
            return byID
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
        /// MobileFleetView supervision donut, counted through
        /// `MobileFleetService.supervisionRole(of:)` so the donut and the
        /// devices table's filter can never disagree about a device.
        var supervisionBreakdown: [(label: String, count: Int, role: SupervisionRole)] {
            var counts: [SupervisionRole: Int] = [:]
            for device in richDevices {
                guard let role = MobileFleetService.supervisionRole(of: device) else { continue }
                counts[role, default: 0] += 1
            }
            return SupervisionRole.allCases.map { role in
                (label: role.label, count: counts[role] ?? 0, role: role)
            }
        }

        /// The slices the donut plots: the breakdown without its empty buckets.
        /// The chart and the click path, which enters through
        /// `MobileFleetService.role(at:plotSize:innerRadiusRatio:in:)`, both read
        /// this one array.
        var supervisionSlices: [SupervisionSlice] {
            supervisionBreakdown
                .filter { $0.count > 0 }
                .map { (role: $0.role, count: $0.count) }
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

        /// Whether any rich device carries an `applications` array. The collect
        /// never requests the APPLICATIONS section, so on real snapshots it is
        /// null on every device.
        var reportsApplications: Bool {
            richDevices.contains { $0.applications != nil }
        }

        /// Number of managed apps reported for a rich device, or nil when no
        /// device in the snapshot carries the APPLICATIONS section: unknown, not
        /// zero. In a snapshot that has the section, a device without the array
        /// counts 0.
        func managedAppCount(for device: MobileDeviceInventoryItem) -> Int? {
            guard reportsApplications else { return nil }
            return device.applications?.count ?? 0
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

        // The three posture counts below are nil when no device in the snapshot
        // carries the field at all. The collected inventory holds only the
        // GENERAL section, which has none of them, so "absent everywhere" means
        // not collected; counting it as 0 compliant or "Clean" states a fact
        // the data does not hold.

        /// Devices reporting `passcodeCompliant == true`, or nil when no device
        /// reports the field.
        var passcodeCompliantCount: Int? {
            let reported = richDevices.compactMap { $0.general?.passcodeCompliant }
            guard !reported.isEmpty else { return nil }
            return reported.filter { $0 }.count
        }

        /// Devices reporting `activationLockEnabled == true`, or nil when no
        /// device reports the field.
        var activationLockEnabledCount: Int? {
            let reported = richDevices.compactMap { $0.general?.activationLockEnabled }
            guard !reported.isEmpty else { return nil }
            return reported.filter { $0 }.count
        }

        /// Devices whose jailbreak status is anything but "none", or nil when no
        /// device reports a status. A blank status is not a report.
        var jailbreakDetectedCount: Int? {
            let reported = richDevices.compactMap { device -> String? in
                guard let status = device.general?.jailbreakDetected?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !status.isEmpty
                else { return nil }
                return status
            }
            guard !reported.isEmpty else { return nil }
            return reported.filter { !$0.localizedCaseInsensitiveContains("none") }.count
        }

        var osDistribution: [(osVersion: String, count: Int)] {
            let osVersions: [String] = richDevices.compactMap { device in
                device.general?.osVersion?.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }

            let grouped = Dictionary(grouping: osVersions) { $0 }
            // Dictionary order changes between runs, so tied counts need a
            // tiebreak or their rows swap places between renders.
            let sorted = grouped.map { (osVersion: $0.key, count: $0.value.count) }
                .sorted { lhs, rhs in
                    if lhs.count != rhs.count { return lhs.count > rhs.count }
                    return lhs.osVersion.compare(rhs.osVersion, options: .numeric)
                        == .orderedDescending
                }
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