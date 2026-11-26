import Foundation

/// Patch policy failures that appeared or dropped off between two `patch-device-failures`
/// scans. jamf-cli lists a failure only once it reaches FAILED (a download still retrying is
/// PENDING and left out), so a pair that drops off is "no longer listed", never "fixed".
/// Pairs are keyed by Jamf ID and policy ID, never by name.
struct PatchFailureDrift {
    let startedFailing: [PatchFailureRow]
    let noLongerListed: [PatchFailureRow]
    /// Rows with an empty Jamf ID or policy ID: the current scan's plus the baseline's.
    let leftOut: Int
    /// Dropped pairs whose Mac is not in the computers snapshot (retired, or unknown).
    let notInComputers: Int

    init(current: [PatchFailureRow], baseline: [PatchFailureRow], computers: ComputerDateIndex) {
        func key(_ row: PatchFailureRow) -> String? {
            let device = row.deviceId.trimmingCharacters(in: .whitespacesAndNewlines)
            let policy = row.policyId.trimmingCharacters(in: .whitespacesAndNewlines)
            return device.isEmpty || policy.isEmpty ? nil : "\(device)\u{1F}\(policy)"
        }
        /// The first row of each key, and how many rows had no key.
        func keyed(_ rows: [PatchFailureRow]) -> (rows: [String: PatchFailureRow], empty: Int) {
            var out: [String: PatchFailureRow] = [:], empty = 0
            for row in rows {
                guard let key = key(row) else { empty += 1; continue }
                if out[key] == nil { out[key] = row }
            }
            return (out, empty)
        }
        let now = keyed(current), before = keyed(baseline)
        leftOut = now.empty + before.empty
        startedFailing = Self.sorted(now.rows.filter { before.rows[$0.key] == nil }.map(\.value))
        let dropped = before.rows.filter { now.rows[$0.key] == nil }.map(\.value)
        let known = dropped.filter {
            computers.contains(
                jamfID: $0.deviceId.trimmingCharacters(in: .whitespacesAndNewlines), serial: nil)
        }
        noLongerListed = Self.sorted(known)
        notInComputers = dropped.count - known.count
    }

    /// By Jamf ID, then policy ID, comparing digit runs as numbers (a strict weak order).
    private static func sorted(_ rows: [PatchFailureRow]) -> [PatchFailureRow] {
        func order(_ lhs: String, _ rhs: String) -> ComparisonResult {
            lhs.trimmingCharacters(in: .whitespaces)
                .compare(rhs.trimmingCharacters(in: .whitespaces), options: .numeric)
        }
        // A raw string compare breaks the numeric ties ("01" and "1"), so the order is total.
        return rows.sorted {
            for result in [order($0.deviceId, $1.deviceId), order($0.policyId, $1.policyId),
                           $0.deviceId.compare($1.deviceId), $0.policyId.compare($1.policyId)]
            where result != .orderedSame {
                return result == .orderedAscending
            }
            return false
        }
    }

    /// The `patch-device-failures` file stamped `landedStamp` and the newest from an earlier
    /// local day. A same-day rescan is never the baseline.
    static func pair(dataDir: URL, landedStamp: Date) -> (current: URL, baseline: URL)? {
        SnapshotPair.landed(kind, in: dataDir, stamp: landedStamp)
    }

    /// The drift, or why a scan could not be read.
    static func load(
        current: URL, baseline: URL, dataDir: URL, computers: ComputerDateIndex
    ) -> Result<PatchFailureDrift, SnapshotReadFailure> {
        func rows(_ url: URL) -> Result<[PatchFailureRow], SnapshotReadFailure> {
            SnapshotPair.read(url, limit: BoundedFile.limit(forKind: kind), dataDir: dataDir)
                .flatMap { data in
                    (try? JSONDecoder().decode([PatchFailureRow].self, from: data))
                        .map { .success($0) }
                        ?? .failure(SnapshotReadFailure(.undecodable, file: url))
                }
        }
        return rows(current).flatMap { now in
            rows(baseline).map {
                PatchFailureDrift(current: now, baseline: $0, computers: computers)
            }
        }
    }

    static let kind = "patch-device-failures"
}
