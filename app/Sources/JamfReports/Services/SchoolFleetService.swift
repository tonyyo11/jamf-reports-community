import Foundation

/// What a Jamf School workspace's snapshots say about its devices: the School Devices screen,
/// the Overview and Fleet Overview on a School workspace and the Getting Started checklist read
/// it. Reads the newest `school-devices`, `school-dep-devices` and `school-overview` snapshots
/// (jamf-cli's flattened lowerCamelCase rows); a field of an unexpected type reads as unknown.
/// History comes from the School daily summary (`ReportEngine.writeSchoolSummary`); these are
/// today's counts.
enum SchoolFleetService {

    static let devicesKind = "school-devices"
    static let depDevicesKind = "school-dep-devices"
    static let overviewKind = "school-overview"

    struct Device: Identifiable, Sendable, Equatable {
        let id: String
        let name: String
        let serial: String
        let model: String
        /// jamf-cli's `os`, "iOS 27.0.1" or "macOS 26.6.2".
        let os: String
        let isManaged: Bool?
        let isSupervised: Bool?
        let lastCheckin: Date?
        let inTrash: Bool
        /// jamf-cli's `udid`, for the Protect match; "" when the row has none.
        var udid = ""

        /// The platform word in `os` ("iOS", "iPadOS", "macOS", "tvOS"), or "Unknown".
        var platform: String {
            let word = os.prefix { !$0.isNumber && $0 != " " }
            return word.isEmpty ? "Unknown" : String(word)
        }

        /// Whole days since the last check-in, or nil when it is unknown.
        func daysSinceCheckin(now: Date) -> Int? {
            lastCheckin.map { max(0, Int(now.timeIntervalSince($0) / 86_400)) }
        }

        /// Stale when the last check-in is MORE than `days` days ago, the workspace's
        /// `thresholds.stale_device_days` rule. An unknown check-in is not stale.
        func isStale(atDays days: Int, now: Date) -> Bool {
            guard let age = daysSinceCheckin(now: now) else { return false }
            return age > days
        }
    }

    struct DEPDevice: Identifiable, Sendable, Equatable {
        let id: String
        let serial: String
        let name: String
        let model: String
        let status: String
        let profile: String
    }

    /// One `school overview` line: a School resource and its count, as jamf-cli prints it.
    struct OverviewRow: Sendable, Equatable, Identifiable {
        let section: String
        let resource: String
        let value: String
        var id: String { section + "/" + resource }
    }

    struct Snapshot: Sendable, Equatable {
        /// Devices not in School's trash.
        var devices: [Device] = []
        var trashedCount = 0
        var depDevices: [DEPDevice] = []
        var overview: [OverviewRow] = []
        var devicesDate: Date?
        var depDate: Date?
        var overviewDate: Date?

        static let empty = Snapshot()

        /// True once any School snapshot was read.
        var isDetected: Bool { devicesDate != nil || depDate != nil || overviewDate != nil }
        /// The newest snapshot's date: when School data was last collected.
        var collectedAt: Date? { [devicesDate, depDate, overviewDate].compactMap { $0 }.max() }

        var managedCount: Int { devices.filter { $0.isManaged == true }.count }
        var unmanagedCount: Int { devices.filter { $0.isManaged == false }.count }
        var supervisedCount: Int { devices.filter { $0.isSupervised == true }.count }

        func staleCount(atDays days: Int, now: Date = Date()) -> Int {
            devices.filter { $0.isStale(atDays: days, now: now) }.count
        }

        /// Device count per platform, largest first, then by name.
        var platformCounts: [(platform: String, count: Int)] {
            Dictionary(grouping: devices, by: \.platform)
                .map { ($0.key, $0.value.count) }
                .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
        }
    }

    static func load(profile: String) -> Snapshot {
        guard let dataDir = try? WorkspacePaths.dataDir(for: profile) else { return .empty }
        return load(dataDir: dataDir)
    }

    static func load(dataDir: URL) -> Snapshot {
        var snapshot = Snapshot()
        if let (rows, date) = newestRows(kind: devicesKind, in: dataDir) {
            snapshot = devicesSnapshot(rows: rows, date: date)
        }
        if let (rows, date) = newestRows(kind: depDevicesKind, in: dataDir) {
            snapshot.depDevices = rows.enumerated().map { depDevice(from: $1, index: $0) }
            snapshot.depDate = date
        }
        if let (rows, date) = newestRows(kind: overviewKind, in: dataDir) {
            snapshot.overview = rows.compactMap(overviewRow)
            snapshot.overviewDate = date
        }
        return snapshot
    }

    /// The devices of one `school-devices` file, or nil when it does not decode as a row list.
    static func devicesSnapshot(at file: URL, inside root: URL? = nil) -> Snapshot? {
        guard let rows = decodedRows(at: file, inside: root) else { return nil }
        return devicesSnapshot(rows: rows, date: snapshotDate(of: file))
    }

    private static func devicesSnapshot(rows: [[String: Any]], date: Date) -> Snapshot {
        var snapshot = Snapshot()
        let all = rows.enumerated().map { device(from: $1, index: $0) }
        snapshot.devices = all.filter { !$0.inTrash }
        snapshot.trashedCount = all.count - snapshot.devices.count
        snapshot.devicesDate = date
        return snapshot
    }

    // MARK: - Row readers

    static func device(from row: [String: Any], index: Int) -> Device {
        let serial = text(row, "serialNumber", "serial")
        return Device(
            id: nonEmpty(text(row, "udid"), serial, "row-\(index)"),
            name: text(row, "name", "deviceName"),
            serial: serial,
            model: text(row, "model"),
            os: text(row, "os"),
            isManaged: row["isManaged"] as? Bool,
            isSupervised: row["isSupervised"] as? Bool,
            lastCheckin: DateParser().parse(text(row, "lastCheckin")),
            inTrash: isTrashed(row),
            udid: text(row, "udid")
        )
    }

    /// A row in School's trash. Absent or not a boolean reads as not trashed.
    static func isTrashed(_ row: [String: Any]) -> Bool { row["inTrash"] as? Bool ?? false }

    /// The one fleet rule for a device or user list: trashed rows (`isTrashed`, which also
    /// decides `Device.inTrash`) are counted apart and never in a fleet figure. The workbook's
    /// device and user tabs read through it.
    static func partitionFleet(
        _ rows: [[String: Any]]
    ) -> (members: [[String: Any]], trashed: Int) {
        let members = rows.filter { !isTrashed($0) }
        return (members, rows.count - members.count)
    }

    static func depDevice(from row: [String: Any], index: Int) -> DEPDevice {
        let serial = text(row, "serialNumber", "serial")
        return DEPDevice(
            id: nonEmpty(serial, "row-\(index)"),
            serial: serial,
            name: text(row, "deviceName", "name"),
            model: text(row, "model"),
            status: text(row, "status"),
            profile: text(row, "profileName")
        )
    }

    static func overviewRow(from row: [String: Any]) -> OverviewRow? {
        let resource = text(row, "resource")
        guard !resource.isEmpty else { return nil }
        return OverviewRow(
            section: text(row, "section"), resource: resource, value: text(row, "value"))
    }

    // MARK: - Helpers

    private static func newestRows(kind: String, in dataDir: URL) -> ([[String: Any]], Date)? {
        let dir = dataDir.appendingPathComponent(kind, isDirectory: true)
        guard let file = FileManager.newestSnapshotFile(in: dir),
              let rows = decodedRows(at: file) else { return nil }
        return (rows, snapshotDate(of: file))
    }

    private static func decodedRows(at file: URL, inside root: URL? = nil) -> [[String: Any]]? {
        guard let data = BoundedFile.readLogged(file, inside: root) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
    }

    private static func snapshotDate(of file: URL) -> Date {
        CloudStorage.snapshotTimestamp(of: file)
            ?? (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            ?? Date.distantPast
    }

    /// The first key holding a string or number, as text; "" when none does.
    private static func text(_ row: [String: Any], _ keys: String...) -> String {
        for key in keys {
            if let s = row[key] as? String { return s }
            // `is Bool` is also true for a JSON 0 or 1, so test the CF type instead.
            if let n = row[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
                return n.stringValue
            }
        }
        return ""
    }

    private static func nonEmpty(_ values: String...) -> String {
        values.first { !$0.isEmpty } ?? ""
    }
}
