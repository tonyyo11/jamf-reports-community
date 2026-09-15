import Foundation

// MARK: - SchoolDashboard

/// Swift port of the Python `SchoolDashboard` class.
/// Generates Excel sheets from cached jamf-cli school JSON snapshots.
/// Missing snapshots are silently skipped — sheets that have no data do not appear.
///
/// Sheet plan mirrors Python's `SchoolDashboard.sheet_plan()`:
///   School Overview, Device Groups, Users, Classes, Apps, Profiles,
///   Locations, DEP Devices, iBeacons,
///   Device Inventory, OS Versions, Device Status, Stale Devices.
struct SchoolDashboard: Sendable {

    let config: ReportConfig
    let dataDir: URL
    let workbook: Workbook

    private var staleThreshold: Int { config.thresholds?.resolvedStaleDays ?? 30 }

    // MARK: - writeAll

    /// Write all Jamf School sheets; skip missing snapshots, collect unexpected failures.
    ///
    /// Returns `(written, failures)` where:
    /// - `written`: sheets successfully generated.
    /// - `failures`: sheets that threw an unexpected error (not `SheetSkippable`).
    ///   A non-empty `failures` list means the caller should emit a partial-success log.
    ///
    /// `SchoolDashboardError.noCachedData` (and any `SheetSkippable` conformer) is treated
    /// as an expected-absent skip — tenants that haven't collected school snapshots get
    /// empty written lists, not failures.
    @discardableResult
    func writeAll() -> (written: [String], failures: [SheetFailure]) {
        let plan: [(String, () throws -> Void)] = [
            ("School Overview", writeSchoolOverview),
            ("Device Groups", writeSchoolDeviceGroups),
            ("Users", writeSchoolUsers),
            ("Classes", writeSchoolClasses),
            ("Apps", writeSchoolApps),
            ("Profiles", writeSchoolProfiles),
            ("Locations", writeSchoolLocations),
            ("DEP Devices", writeSchoolDepDevices),
            ("iBeacons", writeSchoolIBeacons),
            ("Device Inventory", writeSchoolDeviceInventory),
            ("OS Versions", writeSchoolOSVersions),
            ("Device Status", writeSchoolDeviceStatus),
            ("Stale Devices", writeSchoolStaleDevices),
        ]
        var written: [String] = []
        var failures: [SheetFailure] = []
        for (name, fn) in plan {
            do {
                try fn()
                written.append(name)
            } catch let skippable as SheetSkippable {
                // Cached data absent — expected for tenants that haven't collected school snapshots.
                print("  [skip] \(name): \(skippable)")
            } catch {
                let label = "\(type(of: error)): \(error)"
                failures.append(SheetFailure(sheet: name, error: label))
                print("  [fail] \(name): unexpected error — \(label)")
            }
        }
        return (written, failures)
    }

    // MARK: - School Overview

    func writeSchoolOverview() throws {
        // jamf-cli prints one {section, resource, value} row per overview line.
        let raw = try loadSchoolJSON(names: ["school-overview", "school_overview"])
        let items = flattenSchoolList(raw)
        let ws = workbook.addSheet("School Overview")
        ws.setColumnWidth(0, 0, 36)
        ws.setColumnWidth(1, 1, 24)
        var row = ws.writeSheetHeader(
            title: "School Overview",
            subtitle: "Generated: \(ISO8601DateFormatter().string(from: Date()))",
            ncols: 2
        )
        ws.write("Resource", row: row, col: 0, format: .header)
        ws.write("Value", row: row, col: 1, format: .header)
        row += 1
        for item in items {
            ws.write(stringField(item, ["resource"]), row: row, col: 0, format: .cell)
            ws.write(stringField(item, ["value"]), row: row, col: 1, format: .cell)
            row += 1
        }
    }

    // MARK: - Device Groups

    func writeSchoolDeviceGroups() throws {
        let raw = try loadSchoolJSON(names: ["school-device-groups", "school_device_groups"])
        let items = flattenSchoolList(raw)
        let ws = workbook.addSheet("Device Groups")
        ws.setColumnWidth(0, 0, 40)
        ws.setColumnWidth(1, 1, 14)
        ws.setColumnWidth(2, 2, 50)
        var row = ws.writeSheetHeader(
            title: "Device Groups",
            subtitle: "Generated: \(ISO8601DateFormatter().string(from: Date()))",
            ncols: 3
        )
        let hdrs = ["Group Name", "Device Count", "Location ID"]
        for (col, h) in hdrs.enumerated() { ws.write(h, row: row, col: col, format: .header) }
        row += 1
        let sorted = items.sorted { lhs, rhs in
            countFrom(lhs) > countFrom(rhs)
        }
        for item in sorted {
            ws.write(stringField(item, ["name", "groupName", "group_name"]),
                     row: row, col: 0, format: .cell)
            ws.write(countFrom(item), row: row, col: 1, format: .cell)
            ws.write(stringField(item, ["locationId"]), row: row, col: 2, format: .cell)
            row += 1
        }
    }

    // MARK: - Users

    func writeSchoolUsers() throws {
        let raw = try loadSchoolJSON(names: ["school-users", "school_users"])
        let items = flattenSchoolList(raw)
        let ws = workbook.addSheet("Users")
        ws.setColumnWidth(0, 1, 20)
        ws.setColumnWidth(2, 2, 20)
        ws.setColumnWidth(3, 3, 32)
        ws.setColumnWidth(4, 5, 24)
        var row = ws.writeSheetHeader(
            title: "Users",
            subtitle: "Generated: \(ISO8601DateFormatter().string(from: Date()))",
            ncols: 6
        )
        // jamf-cli has no user role, only an account status.
        let hdrs = ["Username", "First Name", "Last Name", "Email", "Location ID", "Status"]
        for (col, h) in hdrs.enumerated() { ws.write(h, row: row, col: col, format: .header) }
        row += 1
        for item in items {
            ws.write(stringField(item, ["username", "userName"]), row: row, col: 0, format: .cell)
            ws.write(stringField(item, ["firstName", "first_name"]), row: row, col: 1, format: .cell)
            ws.write(stringField(item, ["lastName", "last_name"]), row: row, col: 2, format: .cell)
            ws.write(stringField(item, ["email", "emailAddress"]), row: row, col: 3, format: .cell)
            ws.write(stringField(item, ["locationId"]), row: row, col: 4, format: .cell)
            ws.write(stringField(item, ["status"]), row: row, col: 5, format: .cell)
            row += 1
        }
    }

    // MARK: - Classes

    func writeSchoolClasses() throws {
        let raw = try loadSchoolJSON(names: ["school-classes", "school_classes"])
        let items = flattenSchoolList(raw)
        let ws = workbook.addSheet("Classes")
        ws.setColumnWidth(0, 0, 36)
        ws.setColumnWidth(1, 3, 20)
        var row = ws.writeSheetHeader(
            title: "Classes",
            subtitle: "Generated: \(ISO8601DateFormatter().string(from: Date()))",
            ncols: 4
        )
        // jamf-cli has a teacher headcount, not teacher names.
        let hdrs = ["Class Name", "Student Count", "Teacher Count", "Location ID"]
        for (col, h) in hdrs.enumerated() { ws.write(h, row: row, col: col, format: .header) }
        row += 1
        for item in items {
            ws.write(stringField(item, ["name", "className"]), row: row, col: 0, format: .cell)
            ws.write(intField(item, ["studentCount", "student_count", "students"]),
                     row: row, col: 1, format: .cell)
            ws.write(intField(item, ["teacherCount"]), row: row, col: 2, format: .cell)
            ws.write(stringField(item, ["locationId"]), row: row, col: 3, format: .cell)
            row += 1
        }
    }

    // MARK: - Apps

    func writeSchoolApps() throws {
        let raw = try loadSchoolJSON(names: ["school-apps", "school_apps"])
        let items = flattenSchoolList(raw)
        let ws = workbook.addSheet("Apps")
        ws.setColumnWidth(0, 0, 40)
        ws.setColumnWidth(1, 1, 20)
        ws.setColumnWidth(2, 3, 20)
        var row = ws.writeSheetHeader(
            title: "Apps",
            subtitle: "Generated: \(ISO8601DateFormatter().string(from: Date()))",
            ncols: 4
        )
        // jamf-cli has no install or managed count per app.
        let hdrs = ["App Name", "Bundle ID", "Vendor", "Platform"]
        for (col, h) in hdrs.enumerated() { ws.write(h, row: row, col: col, format: .header) }
        row += 1
        for item in items {
            ws.write(stringField(item, ["name", "appName"]), row: row, col: 0, format: .cell)
            ws.write(stringField(item, ["bundleId", "bundle_id", "bundleID"]),
                     row: row, col: 1, format: .cell)
            ws.write(stringField(item, ["vendor"]), row: row, col: 2, format: .cell)
            ws.write(stringField(item, ["platform"]), row: row, col: 3, format: .cell)
            row += 1
        }
    }

    // MARK: - Profiles

    func writeSchoolProfiles() throws {
        let raw = try loadSchoolJSON(names: ["school-profiles", "school_profiles"])
        let items = flattenSchoolList(raw)
        let ws = workbook.addSheet("Profiles")
        ws.setColumnWidth(0, 0, 40)
        ws.setColumnWidth(1, 1, 34)
        ws.setColumnWidth(2, 3, 16)
        var row = ws.writeSheetHeader(
            title: "Profiles",
            subtitle: "Generated: \(ISO8601DateFormatter().string(from: Date()))",
            ncols: 4
        )
        // jamf-cli has no category, device count or enabled flag per profile.
        let hdrs = ["Profile Name", "Identifier", "Platform", "Location ID"]
        for (col, h) in hdrs.enumerated() { ws.write(h, row: row, col: col, format: .header) }
        row += 1
        for item in items {
            ws.write(stringField(item, ["name", "profileName"]), row: row, col: 0, format: .cell)
            ws.write(stringField(item, ["identifier"]), row: row, col: 1, format: .cell)
            ws.write(stringField(item, ["platform"]), row: row, col: 2, format: .cell)
            ws.write(stringField(item, ["locationId"]), row: row, col: 3, format: .cell)
            row += 1
        }
    }

    // MARK: - Locations

    func writeSchoolLocations() throws {
        let raw = try loadSchoolJSON(names: ["school-locations", "school_locations"])
        let items = flattenSchoolList(raw)
        let ws = workbook.addSheet("Locations")
        ws.setColumnWidth(0, 0, 36)
        ws.setColumnWidth(1, 2, 20)
        var row = ws.writeSheetHeader(
            title: "Locations",
            subtitle: "Generated: \(ISO8601DateFormatter().string(from: Date()))",
            ncols: 3
        )
        // jamf-cli has no device count or street address per location.
        let hdrs = ["Location Name", "Is District", "City"]
        for (col, h) in hdrs.enumerated() { ws.write(h, row: row, col: col, format: .header) }
        row += 1
        for item in items {
            ws.write(stringField(item, ["name", "locationName"]), row: row, col: 0, format: .cell)
            ws.write(boolField(item, ["isDistrict"]), row: row, col: 1, format: .cell)
            ws.write(stringField(item, ["city"]), row: row, col: 2, format: .cell)
            row += 1
        }
    }

    // MARK: - DEP Devices

    func writeSchoolDepDevices() throws {
        let raw = try loadSchoolJSON(names: ["school-dep-devices", "school_dep_devices"])
        let items = flattenSchoolList(raw)
        let ws = workbook.addSheet("DEP Devices")
        ws.setColumnWidth(0, 0, 18)
        ws.setColumnWidth(1, 1, 28)
        ws.setColumnWidth(2, 4, 20)
        var row = ws.writeSheetHeader(
            title: "DEP Devices",
            subtitle: "Generated: \(ISO8601DateFormatter().string(from: Date()))",
            ncols: 5
        )
        let hdrs = ["Serial", "Device Name", "Model", "Status", "Profile"]
        for (col, h) in hdrs.enumerated() { ws.write(h, row: row, col: col, format: .header) }
        row += 1
        for item in items {
            ws.write(stringField(item, ["serialNumber", "serial_number", "serial"]),
                     row: row, col: 0, format: .cell)
            ws.write(stringField(item, ["deviceName", "device_name", "name"]),
                     row: row, col: 1, format: .cell)
            ws.write(stringField(item, ["model"]), row: row, col: 2, format: .cell)
            ws.write(stringField(item, ["status"]), row: row, col: 3, format: .cell)
            ws.write(stringField(item, ["profileName", "profile_name"]),
                     row: row, col: 4, format: .cell)
            row += 1
        }
    }

    // MARK: - iBeacons

    func writeSchoolIBeacons() throws {
        let raw = try loadSchoolJSON(names: ["school-ibeacons", "school_ibeacons"])
        let items = flattenSchoolList(raw)
        let ws = workbook.addSheet("iBeacons")
        ws.setColumnWidth(0, 1, 28)
        ws.setColumnWidth(2, 2, 36)
        ws.setColumnWidth(3, 4, 12)
        var row = ws.writeSheetHeader(
            title: "iBeacons",
            subtitle: "Generated: \(ISO8601DateFormatter().string(from: Date()))",
            ncols: 5
        )
        let hdrs = ["Name", "UUID", "Description", "Major", "Minor"]
        for (col, h) in hdrs.enumerated() { ws.write(h, row: row, col: col, format: .header) }
        row += 1
        for item in items {
            ws.write(stringField(item, ["name"]), row: row, col: 0, format: .cell)
            ws.write(stringField(item, ["uuid", "UUID"]), row: row, col: 1, format: .cell)
            ws.write(stringField(item, ["description"]), row: row, col: 2, format: .cell)
            ws.write(intField(item, ["major"]), row: row, col: 3, format: .cell)
            ws.write(intField(item, ["minor"]), row: row, col: 4, format: .cell)
            row += 1
        }
    }

    // MARK: - Device Inventory (from school-devices bridge snapshot)

    func writeSchoolDeviceInventory() throws {
        let raw = try loadSchoolJSON(names: ["school-devices", "school_devices"])
        let items = flattenSchoolList(raw)
        let ws = workbook.addSheet("Device Inventory")
        ws.setColumnWidth(0, 0, 28)
        ws.setColumnWidth(1, 1, 18)
        ws.setColumnWidth(2, 3, 16)
        ws.setColumnWidth(4, 5, 22)
        var row = ws.writeSheetHeader(
            title: "Device Inventory",
            subtitle: "Generated: \(ISO8601DateFormatter().string(from: Date()))",
            ncols: 6
        )
        let hdrs = ["Device Name", "Serial", "Model", "OS Version", "Managed", "Last Checkin"]
        for (col, h) in hdrs.enumerated() { ws.write(h, row: row, col: col, format: .header) }
        row += 1
        for item in items {
            ws.write(stringField(item, ["name", "deviceName"]), row: row, col: 0, format: .cell)
            ws.write(stringField(item, ["serialNumber", "serial"]), row: row, col: 1, format: .cell)
            ws.write(stringField(item, ["model"]), row: row, col: 2, format: .cell)
            ws.write(stringField(item, ["os"]), row: row, col: 3, format: .cell)
            ws.write(boolField(item, ["isManaged"]), row: row, col: 4, format: .cell)
            ws.write(stringField(item, ["lastCheckin", "last_checkin", "lastContactTime"]),
                     row: row, col: 5, format: .cell)
            row += 1
        }
    }

    // MARK: - OS Versions (from school-devices)

    func writeSchoolOSVersions() throws {
        let raw = try loadSchoolJSON(names: ["school-devices", "school_devices"])
        let items = flattenSchoolList(raw)
        var counts: [String: Int] = [:]
        for item in items {
            let os = stringField(item, ["os"])
            counts[majorVersion(from: os), default: 0] += 1
        }
        let ws = workbook.addSheet("OS Versions")
        ws.setColumnWidth(0, 0, 20)
        ws.setColumnWidth(1, 1, 14)
        var row = ws.writeSheetHeader(
            title: "OS Versions",
            subtitle: "Generated: \(ISO8601DateFormatter().string(from: Date()))",
            ncols: 2
        )
        ws.write("OS Version", row: row, col: 0, format: .header)
        ws.write("Count", row: row, col: 1, format: .header)
        row += 1
        for (ver, count) in counts.sorted(by: { $0.key > $1.key }) {
            ws.write(ver, row: row, col: 0, format: .cell)
            ws.write(count, row: row, col: 1, format: .cell)
            row += 1
        }
    }

    // MARK: - Device Status (from school-devices)

    func writeSchoolDeviceStatus() throws {
        let raw = try loadSchoolJSON(names: ["school-devices", "school_devices"])
        let items = flattenSchoolList(raw)
        var managed = 0
        var unmanaged = 0
        var supervised = 0
        for item in items {
            if let b = item["isManaged"] as? Bool { b ? (managed += 1) : (unmanaged += 1) }
            if let b = item["isSupervised"] as? Bool, b { supervised += 1 }
        }
        let ws = workbook.addSheet("Device Status")
        ws.setColumnWidth(0, 0, 28)
        ws.setColumnWidth(1, 1, 14)
        var row = ws.writeSheetHeader(
            title: "Device Status",
            subtitle: "Generated: \(ISO8601DateFormatter().string(from: Date()))",
            ncols: 2
        )
        ws.write("Status", row: row, col: 0, format: .header)
        ws.write("Count", row: row, col: 1, format: .header)
        row += 1
        let pairs: [(String, Int)] = [
            ("Total Devices", items.count),
            ("Managed", managed),
            ("Unmanaged", unmanaged),
            ("Supervised", supervised),
        ]
        for (label, count) in pairs {
            ws.write(label, row: row, col: 0, format: .cell)
            ws.write(count, row: row, col: 1, format: .cell)
            row += 1
        }
    }

    // MARK: - Stale Devices (from school-devices)

    func writeSchoolStaleDevices() throws {
        let raw = try loadSchoolJSON(names: ["school-devices", "school_devices"])
        let items = flattenSchoolList(raw)
        let stale = items.filter { item -> Bool in
            let checkin = stringField(item, ["lastCheckin", "last_checkin", "lastContactTime"])
            let days = daysSince(checkin)
            return days > staleThreshold
        }
        let ws = workbook.addSheet("Stale Devices")
        ws.setColumnWidth(0, 0, 28)
        ws.setColumnWidth(1, 1, 18)
        ws.setColumnWidth(2, 2, 24)
        ws.setColumnWidth(3, 3, 18)
        var row = ws.writeSheetHeader(
            title: "Stale Devices (>\(staleThreshold) days)",
            subtitle: "Generated: \(ISO8601DateFormatter().string(from: Date()))",
            ncols: 4
        )
        let hdrs = ["Device Name", "Serial", "Last Checkin", "Days Since Checkin"]
        for (col, h) in hdrs.enumerated() { ws.write(h, row: row, col: col, format: .header) }
        row += 1
        for item in stale {
            let checkin = stringField(item, ["lastCheckin", "last_checkin", "lastContactTime"])
            ws.write(stringField(item, ["name", "deviceName"]), row: row, col: 0, format: .cell)
            ws.write(stringField(item, ["serialNumber", "serial"]), row: row, col: 1, format: .cell)
            ws.write(checkin, row: row, col: 2, format: .cell)
            ws.write(daysSince(checkin), row: row, col: 3, format: .red)
            row += 1
        }
    }

    // MARK: - Private helpers

    private func loadSchoolJSON(names: [String]) throws -> Any {
        let fm = FileManager.default
        var candidates: [URL] = []
        for name in names {
            let subdir = dataDir.appendingPathComponent(name, isDirectory: true)
            if fm.fileExists(atPath: subdir.path),
               let files = try? fm.contentsOfDirectory(
                at: subdir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
               ) {
                candidates.append(contentsOf: files.filter {
                    $0.pathExtension == "json"
                    && $0.lastPathComponent.lowercased() != SnapshotManifest.fileName
                })
            }
        }
        guard !candidates.isEmpty else {
            throw SchoolDashboardError.noCachedData(names: names)
        }
        let newest = candidates.max {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))
                .flatMap(\.contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))
                .flatMap(\.contentModificationDate) ?? .distantPast
            return a < b
        }!
        let data = try Data(contentsOf: newest)
        return try JSONSerialization.jsonObject(with: data)
    }

    /// Normalize school JSON to a flat array of dicts, handling both array and
    /// envelope shapes (`{items: [...]}`, `{nodes: [...]}`, `{data: [...]}`).
    private func flattenSchoolList(_ raw: Any) -> [[String: Any]] {
        if let arr = raw as? [[String: Any]] { return arr }
        if let dict = raw as? [String: Any] {
            for key in ["items", "nodes", "data", "results"] {
                if let arr = dict[key] as? [[String: Any]] { return arr }
            }
        }
        return []
    }

    private func stringField(_ item: [String: Any], _ keys: [String]) -> String {
        for key in keys {
            if let s = item[key] as? String, !s.isEmpty { return s }
            if let v = item[key] { return "\(v)" }
        }
        return ""
    }

    private func intField(_ item: [String: Any], _ keys: [String]) -> Int {
        for key in keys {
            if let n = item[key] as? Int { return n }
            if let d = item[key] as? Double { return Int(d) }
            if let s = item[key] as? String, let n = Int(s) { return n }
        }
        return 0
    }

    private func boolField(_ item: [String: Any], _ keys: [String]) -> String {
        for key in keys {
            if let b = item[key] as? Bool { return b ? "Yes" : "No" }
        }
        return ""
    }

    private func countFrom(_ item: [String: Any]) -> Int {
        intField(item, ["members"])
    }

    /// jamf-cli's `lastCheckin` is "yyyy-MM-dd HH:mm:ss", which `DateParser` reads.
    private func daysSince(_ dateString: String) -> Int {
        guard !dateString.isEmpty else { return 0 }
        guard let date = DateParser().parse(dateString) else { return 0 }
        return Int(Date().timeIntervalSince(date) / 86400)
    }

    /// The major version in jamf-cli's `os`, which reads "Prefix Version" (e.g. "macOS 14.3").
    private func majorVersion(from os: String) -> String {
        guard let start = os.firstIndex(where: { $0.isNumber }) else { return "Unknown" }
        let numeric = os[start...].prefix(while: { $0.isNumber || $0 == "." })
        guard let major = numeric.split(separator: ".").first else { return "Unknown" }
        return String(major)
    }
}

// MARK: - SchoolCSVDashboard

/// Writes School CSV-derived sheets (Device Inventory from CSV, Stale Devices, etc.).
/// Currently a minimal stub — CSV parsing matches the device-level columns from
/// Jamf School CSV exports via `SchoolColumnMapper`-style logic.
struct SchoolCSVDashboard: Sendable {
    let config: ReportConfig
    let csvData: Data
    let workbook: Workbook

    init?(config: ReportConfig, csvData: Data, workbook: Workbook) {
        guard !csvData.isEmpty else { return nil }
        self.config = config
        self.csvData = csvData
        self.workbook = workbook
    }

    @discardableResult
    func writeAll() -> [String] {
        // CSV-driven school sheets use the same CSVParser as the Jamf Pro side.
        // For now this stub writes nothing additional — the bridge-driven
        // school-devices snapshot already produces Device Inventory via SchoolDashboard.
        return []
    }
}

// MARK: - Errors

enum SchoolDashboardError: Error, LocalizedError, SheetSkippable {
    case noCachedData(names: [String])

    var errorDescription: String? {
        switch self {
        case .noCachedData(let names):
            return "No cached school snapshot found for: \(names.joined(separator: ", "))"
        }
    }
}
