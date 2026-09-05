import Foundation

// MARK: - `jamf-cli pro ddm-status status-items <managementId> --output json`
// Verified on prod 2026-09-04. `value` is JSON null for unset items.

struct DDMStatusItemsPayload: Decodable, Sendable {
    let statusItems: [DDMStatusItem]
}

struct DDMStatusItem: Decodable, Sendable, Equatable {
    let key: String
    let value: String?
    let lastUpdateTime: String?
}

// MARK: - `jamf-cli pro classic-computer-history get <id> --subset commands --output json`
// Classic API, XML→JSON: a bucket holding nothing is the STRING "", and a
// bucket holding exactly one command has `command` as an OBJECT, not an array.
// Verified on prod 2026-09-04 across four devices.

struct ComputerHistoryCommands: Decodable, Sendable {
    let commands: Buckets

    struct Buckets: Decodable, Sendable {
        let completed: Bucket
        let failed: Bucket
        let pending: Bucket
    }

    struct Bucket: Decodable, Sendable {
        let command: [HistoryCommand]

        private enum Keys: String, CodingKey { case command }

        init(from decoder: Decoder) throws {
            // "" → nothing in this bucket.
            if let single = try? decoder.singleValueContainer(),
               (try? single.decode(String.self)) != nil {
                command = []
                return
            }
            let c = try decoder.container(keyedBy: Keys.self)
            if let many = try? c.decode([HistoryCommand].self, forKey: .command) {
                command = many
            } else if let one = try? c.decode(HistoryCommand.self, forKey: .command) {
                command = [one]
            } else {
                command = []
            }
        }
    }

    struct HistoryCommand: Decodable, Sendable, Equatable {
        let name: String?
        let status: String?
        let issuedEpoch: Int?

        private enum Keys: String, CodingKey {
            case name, status
            case issuedEpoch = "issued_epoch"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            name = try c.decodeIfPresent(String.self, forKey: .name)
            status = try c.decodeIfPresent(String.self, forKey: .status)
            issuedEpoch = try c.decodeIfPresent(AnyCodable.self, forKey: .issuedEpoch)?.intValue
        }
    }
}

// MARK: - Persisted snapshot rows (what the scan loop writes to disk)

/// One DDM-enabled Mac's declaration and software-update status. Only
/// allow-listed status items ever reach this type — see
/// `DeviceScanBuilders.statusItemAllowList`.
struct DDMDeviceStatusRecord: Codable, Sendable, Equatable {
    let deviceId: String
    let name: String
    let managementId: String
    let osVersion: String?
    let reportDate: String?
    /// False when the status-items call 404'd: the device is DDM-enabled per
    /// inventory but has never reported. Not an error.
    let ddmReported: Bool
    let declarations: [Declaration]
    let softwareUpdate: SoftwareUpdate

    struct Declaration: Codable, Sendable, Equatable {
        let identifier: String
        let active: Bool?
        let valid: Bool?
    }

    struct SoftwareUpdate: Codable, Sendable, Equatable {
        let pendingOSVersion: String?
        let installState: String?
        let failureReason: String?
        static let empty = SoftwareUpdate(
            pendingOSVersion: nil, installState: nil, failureReason: nil)
    }
}

/// One Mac's MDM command health, reduced from its Classic history.
struct MDMCommandHealthRecord: Codable, Sendable, Equatable {
    let deviceId: String
    let name: String
    let failedCount: Int
    let pendingCount: Int
    let failedCommands: [String]
    /// Age in days of the oldest pending command, nil when none is pending.
    let oldestPendingDays: Int?
}
