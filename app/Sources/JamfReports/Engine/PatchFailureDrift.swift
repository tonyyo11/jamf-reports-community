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

    /// By Jamf ID, then policy ID: numerically when both parse as numbers, else as text.
    private static func sorted(_ rows: [PatchFailureRow]) -> [PatchFailureRow] {
        func before(_ lhs: String, _ rhs: String) -> Bool? {
            let (a, b) = (lhs.trimmingCharacters(in: .whitespaces),
                          rhs.trimmingCharacters(in: .whitespaces))
            guard a != b else { return nil }
            if let x = Int(a), let y = Int(b) { return x < y }
            return a < b
        }
        return rows.sorted {
            before($0.deviceId, $1.deviceId) ?? before($0.policyId, $1.policyId) ?? false
        }
    }

    /// The `patch-device-failures` file stamped `landedStamp` and the newest from an earlier
    /// local day. A same-day rescan is never the baseline.
    static func pair(dataDir: URL, landedStamp: Date) -> (current: URL, baseline: URL)? {
        let files = TrendStore.datedSnapshots(of: kind, in: dataDir)
        guard let current = files.last(where: { $0.date == landedStamp }) else { return nil }
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: landedStamp)
        guard let baseline = files.last(where: { calendar.startOfDay(for: $0.date) < day })
        else { return nil }
        return (current.url, baseline.url)
    }

    /// Nil when either scan cannot be read or decoded.
    static func load(
        current: URL, baseline: URL, dataDir: URL, computers: ComputerDateIndex
    ) -> PatchFailureDrift? {
        func rows(_ url: URL) -> [PatchFailureRow]? {
            guard let data = try? BoundedFile.read(
                url, limit: BoundedFile.limit(forKind: kind), followSymlinks: false,
                inside: dataDir) else { return nil }
            return try? JSONDecoder().decode([PatchFailureRow].self, from: data)
        }
        guard let now = rows(current), let before = rows(baseline) else { return nil }
        return PatchFailureDrift(current: now, baseline: before, computers: computers)
    }

    static let kind = "patch-device-failures"
}
