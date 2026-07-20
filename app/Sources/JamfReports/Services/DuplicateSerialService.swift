import Foundation

/// Reads the latest `pro report duplicate-serials` snapshot (jamf-cli v1.23.0+)
/// and groups its flat rows by shared serial number for `AuditView`'s
/// data-integrity section.
///
/// A duplicated serial (typically a logic-board swap re-enrolling as a fresh
/// computer record) breaks every serial-joined lookup — both jamf-cli's own
/// `--serial` resolution and this app's serial-keyed cross-source correlation.
/// Surfacing it is a trust feature, not a cosmetic one.
struct DuplicateSerialService: Sendable {

    // MARK: - Row

    /// One duplicated computer record. Not Identifiable: the AuditView Table
    /// iterates `SerialGroup`s, not records — add identity only when a view
    /// iterates records directly (assign it once at load per #185, never a
    /// per-access computed id).
    struct Record: Sendable, Equatable {
        let recordId: String
        let name: String
        let lastContact: String
    }

    /// A serial shared by two or more records, in the CLI's own order
    /// (ascending numeric id — stale record first, matching its "delete the
    /// stale record" recommendation).
    struct SerialGroup: Identifiable, Sendable, Equatable {
        var id: String { serial }
        let serial: String
        let records: [Record]
    }

    // MARK: - Snapshot

    struct Snapshot: Sendable, Equatable {
        let groups: [SerialGroup]
        /// True when the snapshot file decoded successfully, even to zero
        /// groups. Distinguishes "never collected" (older jamf-cli, or no
        /// collect run yet) from "collected — fleet is clean."
        let isDetected: Bool
        /// True when a snapshot file EXISTS but could not be read or decoded.
        /// Kept separate from `isDetected == false` so the view never tells an
        /// operator with a current jamf-cli to upgrade it.
        let readFailed: Bool

        var affectedRecordCount: Int { groups.reduce(0) { $0 + $1.records.count } }

        static let empty = Snapshot(groups: [], isDetected: false, readFailed: false)
        static let unreadable = Snapshot(groups: [], isDetected: false, readFailed: true)
    }

    // MARK: - Load

    /// Returns the newest duplicate-serials snapshot for `profile`.
    /// Returns `.empty` (undecoded) when no snapshot exists.
    static func load(profile: String) -> Snapshot {
        guard let dir = try? WorkspacePaths.dataDir(for: profile) else { return .empty }
        let kindDir = dir.appendingPathComponent("duplicate-serials", isDirectory: true)
        return load(url: FileManager.newestJSONFile(in: kindDir))
    }

    /// Test seam: load directly from an arbitrary file URL.
    static func load(url: URL?) -> Snapshot {
        guard let url else { return .empty }
        guard let data = try? Data(contentsOf: url) else {
            AppLogger.collect.warning(
                "DuplicateSerialService: could not read duplicate-serials file \(url.lastPathComponent, privacy: .public)"
            )
            return FileManager.default.fileExists(atPath: url.path) ? .unreadable : .empty
        }
        guard let rows = try? JSONDecoder().decode([DuplicateSerialRow].self, from: data) else {
            AppLogger.collect.warning(
                "DuplicateSerialService: failed to decode duplicate-serials at \(url.lastPathComponent, privacy: .public)"
            )
            return .unreadable
        }
        return Snapshot(groups: groupedBySerial(rows), isDetected: true, readFailed: false)
    }

    // MARK: - Internals

    /// Groups flat rows by serial, preserving each group's row order (the CLI
    /// already emits ascending-numeric-id order within a serial group). A
    /// blank serial is dropped defensively — the CLI itself never emits one,
    /// but grouping must not misbehave if a future shape does.
    static func groupedBySerial(_ rows: [DuplicateSerialRow]) -> [SerialGroup] {
        var order: [String] = []
        var bySerial: [String: [Record]] = [:]
        for row in rows {
            let serial = (row.serial ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !serial.isEmpty else { continue }
            let idString = row.id?.stringValue ?? ""
            let recordId = idString.isEmpty ? "—" : idString
            let record = Record(
                recordId: recordId,
                name: row.name ?? recordId,
                lastContact: row.lastContact ?? ""
            )
            if bySerial[serial] == nil { order.append(serial) }
            bySerial[serial, default: []].append(record)
        }
        return order.map { serial in SerialGroup(serial: serial, records: bySerial[serial] ?? []) }
    }
}
