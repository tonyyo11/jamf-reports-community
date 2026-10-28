import Foundation
import XCTest

/// Jamf School rows for tests, built from the key-and-type shape captured from jamf-cli 1.33.0
/// `school <resource> list --output json` on 2026-10-28 (keys and JSON types only; no value was
/// kept). A row carries exactly the captured keys with synthetic values, so a test that needs a
/// key the capture lacks, or a type it contradicts, fails here instead of passing on a guess.
/// `school-ibeacons` captured zero rows, so it has no shape. `school-blueprints` needs Platform
/// fields the captured profile lacks (exit 1), so it has none either.
enum SchoolRows {
    enum JSONType { case string, int, bool }

    // Captured 2026-10-28, jamf-cli 1.33.0. A recapture is an edit to this table.
    static let shapes: [String: [String: JSONType]] = [
        "school-overview": ["resource": .string, "section": .string, "value": .string],
        "school-devices": [
            "inTrash": .bool, "isManaged": .bool, "isSupervised": .bool, "lastCheckin": .string,
            "model": .string, "name": .string, "os": .string, "serialNumber": .string,
            "udid": .string,
        ],
        "school-device-groups": [
            "description": .string, "id": .int, "isSmartGroup": .bool, "locationId": .int,
            "members": .int, "name": .string, "shared": .bool, "type": .string,
        ],
        "school-users": [
            "deviceCount": .int, "email": .string, "firstName": .string, "id": .int,
            "inTrash": .bool, "lastName": .string, "locationId": .int, "status": .string,
            "username": .string,
        ],
        "school-classes": [
            "description": .string, "deviceCount": .int, "locationId": .int, "name": .string,
            "source": .string, "studentCount": .int, "teacherCount": .int, "uuid": .string,
        ],
        "school-apps": [
            "adamId": .int, "bundleId": .string, "id": .int, "locationId": .int,
            "name": .string, "platform": .string, "vendor": .string, "version": .string,
        ],
        "school-profiles": [
            "description": .string, "id": .int, "identifier": .string, "locationId": .int,
            "name": .string, "platform": .string,
        ],
        "school-locations": [
            "city": .string, "id": .int, "isDistrict": .bool, "name": .string,
            "source": .string,
        ],
        "school-dep-devices": [
            "color": .string, "deviceName": .string, "id": .int, "locationId": .int,
            "model": .string, "profileName": .string, "serialNumber": .string,
            "status": .string,
        ],
    ]

    /// The synthetic row `n` of a kind: one value per captured key. Serials and UDIDs are
    /// `SCHOOL-SERIAL-001` style, never a value that could belong to a real device.
    private static func base(_ kind: String, _ n: Int) -> [String: Any] {
        let tag = String(format: "%03d", n)
        switch kind {
        case "school-overview":
            return ["section": "Devices", "resource": "Devices", "value": "\(n)"]
        case "school-devices":
            return [
                "name": "School Device \(tag)", "serialNumber": "SCHOOL-SERIAL-\(tag)",
                "udid": "SCHOOL-UDID-\(tag)", "model": "iPad (10th generation)",
                "os": "iPadOS 27.0.1", "isManaged": true, "isSupervised": true,
                "lastCheckin": "2026-10-18 09:00:00", "inTrash": false,
            ]
        case "school-device-groups":
            return [
                "id": n, "name": "School Group \(tag)", "description": "Group \(tag) description",
                "isSmartGroup": false, "members": 10 + n, "shared": true, "type": "static",
                "locationId": 100 + n,
            ]
        case "school-users":
            return [
                "id": n, "username": "school-user-\(tag)", "email": "user-\(tag)@example.invalid",
                "firstName": "First\(tag)", "lastName": "Last\(tag)", "status": "Active",
                "deviceCount": 2, "locationId": 100 + n, "inTrash": false,
            ]
        case "school-classes":
            return [
                "uuid": "SCHOOL-CLASS-UUID-\(tag)", "name": "School Class \(tag)",
                "description": "Class \(tag) description", "source": "manual",
                "studentCount": 18, "teacherCount": 3, "deviceCount": 18, "locationId": 100 + n,
            ]
        case "school-apps":
            return [
                "id": n, "locationId": 100 + n, "bundleId": "invalid.example.app\(tag)",
                "adamId": 9_000_000 + n, "name": "School App \(tag)",
                "vendor": "Example Vendor \(tag)", "version": "1.\(n).0", "platform": "iOS",
            ]
        case "school-profiles":
            return [
                "id": n, "locationId": 100 + n, "identifier": "invalid.example.profile\(tag)",
                "name": "School Profile \(tag)", "description": "Profile \(tag) description",
                "platform": "Shared",
            ]
        case "school-locations":
            return [
                "id": n, "name": "School Location \(tag)", "isDistrict": n == 1,
                "source": "manual", "city": "Example City \(tag)",
            ]
        case "school-dep-devices":
            return [
                "id": n, "serialNumber": "SCHOOL-SERIAL-\(tag)", "model": "iPad (10th generation)",
                "color": "Silver", "status": "Assigned", "deviceName": "School DEP Device \(tag)",
                "profileName": "School DEP Profile \(tag)", "locationId": 100 + n,
            ]
        default:
            preconditionFailure("\(kind) has no captured shape")
        }
    }

    /// Row `n` of `kind`. `overrides` must keep the captured type of a captured key;
    /// `omitting` drops keys (a row that lacks one); `malformed` sets a value of the wrong
    /// type on purpose, for the tests of what a decoder does with one.
    static func row(
        _ kind: String, _ n: Int = 1, _ overrides: [String: Any] = [:],
        omitting: Set<String> = [], malformed: [String: Any] = [:]
    ) -> [String: Any] {
        guard let shape = shapes[kind] else { preconditionFailure("\(kind) has no captured shape") }
        var row = base(kind, n)
        for (key, value) in overrides {
            guard let type = shape[key], matches(value, type) else {
                preconditionFailure("\(kind).\(key) override is not a captured key or type")
            }
            row[key] = value
        }
        for key in omitting { row[key] = nil }
        for (key, value) in malformed { row[key] = value }
        return row
    }

    static func device(
        _ n: Int = 1, _ overrides: [String: Any] = [:], omitting: Set<String> = [],
        malformed: [String: Any] = [:]
    ) -> [String: Any] {
        row("school-devices", n, overrides, omitting: omitting, malformed: malformed)
    }

    static func matches(_ value: Any, _ type: JSONType) -> Bool {
        switch type {
        case .string: return value is String
        case .bool: return value is Bool
        case .int: return value is Int
        }
    }

    /// The JSON text of a row list, as jamf-cli prints it.
    static func json(_ rows: [[String: Any]]) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: rows, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            preconditionFailure("rows are not JSON")
        }
        return text
    }

    /// Writes `<dataDir>/<kind>/<kind>_<stamp>.json`, the way a collect saves a snapshot.
    @discardableResult
    static func write(
        _ rows: [[String: Any]], kind: String, into dataDir: URL, stamp: String = "20261019T080000"
    ) throws -> URL {
        let dir = dataDir.appendingPathComponent(kind, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(kind)_\(stamp).json")
        try Data(json(rows).utf8).write(to: file)
        return file
    }
}
