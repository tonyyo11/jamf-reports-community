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

        private enum Keys: String, CodingKey { case completed, failed, pending }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            completed = try c.decodeIfPresent(Bucket.self, forKey: .completed) ?? .empty
            failed = try c.decodeIfPresent(Bucket.self, forKey: .failed) ?? .empty
            pending = try c.decodeIfPresent(Bucket.self, forKey: .pending) ?? .empty
        }
    }

    struct Bucket: Decodable, Sendable {
        let command: [HistoryCommand]
        static let empty = Bucket(command: [])

        init(command: [HistoryCommand]) { self.command = command }

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
        let username: String?
        let issuedEpoch: Int?
        let failedEpoch: Int?
        let lastPushEpoch: Int?

        private enum Keys: String, CodingKey {
            case name, status, username
            case issuedEpoch = "issued_epoch"
            case failedEpoch = "failed_epoch"
            case lastPushEpoch = "last_push_epoch"
        }

        init(name: String?, status: String?, username: String? = nil,
             issuedEpoch: Int? = nil, failedEpoch: Int? = nil, lastPushEpoch: Int? = nil) {
            self.name = name; self.status = status; self.username = username
            self.issuedEpoch = issuedEpoch; self.failedEpoch = failedEpoch
            self.lastPushEpoch = lastPushEpoch
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            name = try c.decodeIfPresent(String.self, forKey: .name)
            status = try c.decodeIfPresent(String.self, forKey: .status)
            username = try c.decodeIfPresent(String.self, forKey: .username)
            issuedEpoch = try c.decodeIfPresent(AnyCodable.self, forKey: .issuedEpoch)?.intValue
            failedEpoch = try c.decodeIfPresent(AnyCodable.self, forKey: .failedEpoch)?.intValue
            lastPushEpoch = try c.decodeIfPresent(AnyCodable.self, forKey: .lastPushEpoch)?.intValue
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
    let osBuild: String?
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
        let reasonCode: String?
        let reasonText: String?
    }

    struct SoftwareUpdate: Codable, Sendable, Equatable {
        let pendingOSVersion: String?
        let pendingBuild: String?
        let installState: String?
        let installReason: String?
        let failureReason: String?
        let failureAt: String?
        let betaEnrollment: String?
        static let empty = SoftwareUpdate(
            pendingOSVersion: nil, pendingBuild: nil, installState: nil,
            installReason: nil, failureReason: nil, failureAt: nil, betaEnrollment: nil)
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
