import Foundation

/// A row of a per-device scan snapshot: one Mac, stamped with the pass that scanned it.
protocol DeviceScanRow: Codable, Sendable {
    var deviceId: String { get }
    var scannedAt: String? { get set }
}
extension MDMCommandHealthRecord: DeviceScanRow {}
extension DDMDeviceStatusRecord: DeviceScanRow {}

/// One call type's attempts and failures over a round, for the round's 25% rule.
struct DeviceScanTally: Codable, Equatable, Sendable {
    var attempted = 0
    var failed = 0

    static func + (a: Self, b: Self) -> Self {
        Self(attempted: a.attempted + b.attempted, failed: a.failed + b.failed)
    }
}

/// One trip of the per-device scan through the fleet that a pass left unfinished
/// (`StateFileStore.deviceScanRound`). A peer can write it: read it through
/// `DeviceScanPasses.round(in:now:)`.
struct DeviceScanRound: Codable, Equatable, Sendable {
    var started: Date
    /// When the last pass ran; an open round takes at most one pass a local day.
    var lastPass: Date
    /// Every Mac a pass of this round attempted, answered or not: each is done for the round.
    var attempted: [String]
    /// Targets no pass of this round had attempted when the last pass ended.
    var remaining: Int
    var history = DeviceScanTally()
    var statusItems = DeviceScanTally()
    /// The scan kinds `collect_skip` turned off when the round started (Jamf Pro); nil reads as
    /// none. A round whose set differs from today's is not continued.
    var turnedOff: [String]?

    /// About 12,000 Mac ids fit many times over.
    static let fileLimit = 4 * 1024 * 1024
}

/// Pure rules of the scan passes (large-fleet design L3): the order a pass takes the fleet,
/// and the merge that keeps one snapshot holding the whole fleet.
enum DeviceScanPasses {

    /// A carried row older than this is dropped, so a Mac that stopped answering reads as not
    /// scanned rather than as its old state.
    static let rowAgeLimit: TimeInterval = 21 * 86_400

    /// How long after its last pass an open round still counts as in progress for freshness.
    static let inProgressWindow: TimeInterval = 2 * 86_400

    /// The open round, if any. A round with nothing left, a start or last pass more than the
    /// clock-skew tolerance ahead of now, or a start older than `rowAgeLimit` reads as absent.
    static func round(in store: StateFileStore?, now: Date) -> DeviceScanRound? {
        guard let r = store?.deviceScanRound(), r.remaining > 0 else { return nil }
        let ahead = now.addingTimeInterval(SharedWorkspace.clockSkewTolerance)
        guard r.started <= ahead, r.lastPass <= ahead,
              r.started >= now.addingTimeInterval(-rowAgeLimit) else { return nil }
        return r
    }

    /// True while a round is open and its last pass is recent: the scan kinds are in progress,
    /// not missing.
    static func scanInProgress(_ store: StateFileStore?, now: Date) -> Bool {
        guard let r = round(in: store, now: now) else { return false }
        return now.timeIntervalSince(r.lastPass) <= inProgressWindow
    }

    /// The scan's targets from a `computers` snapshot: safe ids, each once, in snapshot order,
    /// with how many unsafe ids were left out. Nil when the data is not a list of computers.
    static func scanTargets(from data: Data)
        -> (targets: [ReportEngine.DeviceScanTarget], unsafe: Int)? {
        guard let all = try? JSONDecoder().decode([ReportEngine.DeviceScanTarget].self, from: data)
        else { return nil }
        var targets: [ReportEngine.DeviceScanTarget] = []
        var seen = Set<String>()
        var unsafe = 0
        for t in all {
            guard CLIBridge.isSafeDeviceIdentifier(t.id) else { unsafe += 1; continue }
            // A device listed twice in `computers` is scanned once.
            if seen.insert(t.id).inserted { targets.append(t) }
        }
        return (targets, unsafe)
    }

    /// Scanned and total Macs of the open round, for every target and for the DDM-eligible
    /// ones; nil when no round is open or the `computers` snapshot cannot be read.
    struct RoundProgress: Equatable, Sendable {
        let macs: (scanned: Int, total: Int)
        let ddm: (scanned: Int, total: Int)

        static func == (a: Self, b: Self) -> Bool {
            a.macs == b.macs && a.ddm == b.ddm
        }
    }

    static func roundProgress(dataDir: URL, stateDir: URL?, now: Date = Date()) -> RoundProgress? {
        guard let stateDir,
              let round = round(in: StateFileStore(directory: stateDir), now: now),
              let url = FileManager.newestJSONFile(
                  in: dataDir.appendingPathComponent("computers", isDirectory: true)),
              let data = BoundedFile.readSnapshotLogged(url),
              let targets = scanTargets(from: data)?.targets else { return nil }
        let attempted = Set(round.attempted)
        let eligible = targets.filter(isDDMEligible)
        return RoundProgress(
            macs: (targets.filter { attempted.contains($0.id) }.count, targets.count),
            ddm: (eligible.filter { attempted.contains($0.id) }.count, eligible.count))
    }

    static func roundProgress(profile: String) -> RoundProgress? {
        guard let dataDir = try? WorkspacePaths.dataDir(for: profile) else { return nil }
        return roundProgress(dataDir: dataDir, stateDir: try? WorkspacePaths.stateDir(for: profile))
    }

    /// The row's own scan time, else its file's snapshot stamp.
    static func scanDate(_ scannedAt: String?, fileStamp: Date?) -> Date? {
        scannedAt.flatMap(ISO8601Time.parse) ?? fileStamp
    }

    /// A DDM-enabled Mac with a management id: the Macs `ddm-device-status` holds a row for.
    static func isDDMEligible(_ t: ReportEngine.DeviceScanTarget) -> Bool {
        t.ddmEnabled && t.managementId != nil
    }

    /// The rows of `kind`'s newest snapshot, each stamped with its file's time when it has none;
    /// empty with no snapshot, nil when one is there but cannot be read or decoded.
    static func earlierRows<Row: DeviceScanRow>(
        kind: String, dataDir: URL, as type: Row.Type
    ) -> [Row]? {
        let dir = dataDir.appendingPathComponent(kind, isDirectory: true)
        guard let url = FileManager.newestJSONFile(in: dir) else { return [] }
        guard let data = BoundedFile.readSnapshotLogged(url),
              let rows = try? JSONDecoder().decode([Row].self, from: data) else { return nil }
        let stamp = CloudStorage.snapshotTimestamp(of: url).map(ISO8601Time.string)
        return rows.map { row in
            var row = row
            if row.scannedAt == nil { row.scannedAt = stamp }
            return row
        }
    }

    /// One site's Macs before the next (sites by id, compared as numbers; no site last), then
    /// oldest scan first within a site, never scanned first, then the `computers` order. A
    /// Mac's time is the older of its rows; a row it should have and lacks makes it never scanned.
    static func passOrder(
        _ targets: [ReportEngine.DeviceScanTarget],
        health: [MDMCommandHealthRecord], ddm: [DDMDeviceStatusRecord]
    ) -> [ReportEngine.DeviceScanTarget] {
        let healthDates = latestDates(health)
        let ddmDates = latestDates(ddm)
        func date(_ t: ReportEngine.DeviceScanTarget) -> Date? {
            guard let h = healthDates[t.id] else { return nil }
            guard isDDMEligible(t) else { return h }
            return ddmDates[t.id].map { min($0, h) }
        }
        return targets.enumerated()
            .map { (index: $0.offset, target: $0.element, date: date($0.element)) }
            .sorted { a, b in
                if let order = siteOrder(a.target.siteId, b.target.siteId) { return order }
                switch (a.date, b.date) {
                case (nil, nil): return a.index < b.index
                case (nil, _): return true
                case (_, nil): return false
                case let (x?, y?): return x != y ? x < y : a.index < b.index
                }
            }
            .map(\.target)
    }

    /// Whether site `a` goes before site `b`; nil when they are the same site.
    private static func siteOrder(_ a: String?, _ b: String?) -> Bool? {
        switch (a, b) {
        case (nil, nil): return nil
        case (nil, _): return false
        case (_, nil): return true
        case let (x?, y?):
            guard x != y else { return nil }
            if let i = Int(x), let j = Int(y), i != j { return i < j }
            return x < y
        }
    }

    /// The saved snapshot: this pass's rows, plus the earlier row of every Mac in `carry` (still
    /// a target, not attempted this pass) scanned within `rowAgeLimit`. Sorted by device id.
    static func merged<Row: DeviceScanRow>(
        scanned: [Row], earlier: [Row], carry: Set<String>, now: Date
    ) -> [Row] {
        let cutoff = now.addingTimeInterval(-rowAgeLimit)
        var seen = Set(scanned.map(\.deviceId))
        let carried = earlier.filter { row in
            guard carry.contains(row.deviceId),
                  let date = scanDate(row.scannedAt, fileStamp: nil), date >= cutoff
            else { return false }
            return seen.insert(row.deviceId).inserted
        }
        return (scanned + carried).sorted { $0.deviceId < $1.deviceId }
    }

    /// The oldest row's scan time (`scannedAt`, else the file's stamp); nil when none is known.
    static func oldestScan<Row: DeviceScanRow>(_ rows: [Row], fileStamp: Date?) -> Date? {
        rows.compactMap { scanDate($0.scannedAt, fileStamp: fileStamp) }.min()
    }

    static func latestDates<Row: DeviceScanRow>(_ rows: [Row]) -> [String: Date] {
        var out: [String: Date] = [:]
        for row in rows {
            guard let d = scanDate(row.scannedAt, fileStamp: nil) else { continue }
            out[row.deviceId] = max(out[row.deviceId] ?? d, d)
        }
        return out
    }
}
