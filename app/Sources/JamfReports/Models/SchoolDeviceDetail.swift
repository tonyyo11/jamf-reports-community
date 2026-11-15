import Foundation

/// What the Jamf School per-device scan (`school-device-detail`) holds, by lowercased UDID. A
/// field a device did not report, or reported as the wrong type, is nil.
struct SchoolDeviceDetail: Sendable, Equatable {
    struct Row: Sendable, Equatable {
        /// jamf-cli's `deviceEnrollType`, as School gives it ("dep").
        var enrollType: String?
        /// `totalCapacity`, read as gigabytes (the unit jamf-cli does not state).
        var capacityGB: Int?
        /// `batteryLevel`, 0 to 100; 0 may be an empty battery or a device that has none.
        var battery: Int?
    }

    var rows: [String: Row] = [:]
    /// The snapshot's date: when the scan landed.
    var date: Date

    static let kind = ReportEngine.schoolDeviceDetailKind

    func row(forUDID udid: String) -> Row? { rows[udid.lowercased()] }

    init(rows: [String: Row] = [:], date: Date) {
        self.rows = rows
        self.date = date
    }

    /// Rows are the allow-listed objects of one snapshot; one without a UDID is dropped.
    init(snapshotRows: [[String: Any]], date: Date) {
        var rows: [String: Row] = [:]
        for object in snapshotRows {
            guard let udid = object["udid"] as? String,
                  !udid.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            rows[udid.lowercased()] = Row(
                enrollType: Self.text(object["deviceEnrollType"]),
                capacityGB: Self.whole(object["totalCapacity"], in: 0...Int.max),
                battery: Self.whole(object["batteryLevel"], in: 0...100))
        }
        self.init(rows: rows, date: date)
    }

    private static func text(_ value: Any?) -> String? {
        (value as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    /// A whole number of the right type (never a boolean), within `range`.
    private static func whole(_ value: Any?, in range: ClosedRange<Int>) -> Int? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              let whole = wholeInt(n.doubleValue), range.contains(whole) else { return nil }
        return whole
    }
}
