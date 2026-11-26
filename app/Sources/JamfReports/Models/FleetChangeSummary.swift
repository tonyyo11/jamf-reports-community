import Foundation

/// What changed since the newest earlier-day snapshot, stored in the daily summary (wave B2).
/// Each part is decoded on its own, so one malformed part costs that part only.
struct FleetChangeSummary: Codable, Sendable, Equatable {
    var computers: ComputerChanges?
    var benchmarks: BenchmarkChanges?
    var patch: PatchChanges?

    private enum CodingKeys: String, CodingKey { case computers, benchmarks, patch }

    init(
        computers: ComputerChanges? = nil, benchmarks: BenchmarkChanges? = nil,
        patch: PatchChanges? = nil
    ) {
        self.computers = computers
        self.benchmarks = benchmarks
        self.patch = patch
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        computers = try? container.decodeIfPresent(ComputerChanges.self, forKey: .computers)
        benchmarks = try? container.decodeIfPresent(BenchmarkChanges.self, forKey: .benchmarks)
        patch = try? container.decodeIfPresent(PatchChanges.self, forKey: .patch)
    }

    var isEmpty: Bool { computers == nil && benchmarks == nil && patch == nil }

    /// Each part this summary measured replaces the older one; one it did not keeps it.
    func filling(from older: FleetChangeSummary?) -> FleetChangeSummary {
        FleetChangeSummary(
            computers: computers ?? older?.computers,
            benchmarks: benchmarks ?? older?.benchmarks,
            patch: patch ?? older?.patch)
    }

    /// Drops a part whose numbers cannot be true (a hand edit, a peer's bad write); nil when
    /// no part is left.
    func validated() -> FleetChangeSummary? {
        let result = FleetChangeSummary(
            computers: computers.flatMap { $0.isValid ? $0 : nil },
            benchmarks: benchmarks.flatMap { $0.isValid ? $0 : nil },
            patch: patch.flatMap { $0.isValid ? $0 : nil })
        return result.isEmpty ? nil : result
    }

    static func inRange(_ counts: [Int?]) -> Bool {
        counts.allSatisfy { ($0 ?? 0) >= 0 && ($0 ?? 0) <= SummaryJSONParser.maxSummaryNumber }
    }
}

/// The Mac half: `SnapshotFleetDrift` between this run's `computers` snapshot and the newest
/// earlier-day one. A nil count was not measured, never 0.
struct ComputerChanges: Codable, Sendable, Equatable {
    /// Why a snapshot could not be read. A value this build does not know (a later build's)
    /// reads as `readError`, so the part still decodes.
    enum UnreadableReason: String, Codable, Sendable {
        case tooLarge = "too_large", undecodable, readError = "read_error"

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Self(rawValue: raw) ?? .readError
        }
    }

    var currentStamp: String?
    var baselineStamp: String?
    var currentCount: Int?
    var priorCount: Int?
    var staleDays: Int?
    var staleBasis: [String]?
    /// `SecurityControlPolicy.fileVaultFingerprint` when the counts were taken.
    var fileVaultRule: String?
    var baselineUnreadable: Bool?
    var baselineUnreadableReason: UnreadableReason?
    var largeChangePercent: Int?
    var joined: Int?
    var left: Int?
    var osChanged: Int?
    var becameStale: Int?
    var noLongerStale: Int?
    var fileVaultOff: Int?
    var fileVaultStoppedReporting: Int?
    var unidentified: Int?
    var ambiguous: Int?

    private enum CodingKeys: String, CodingKey {
        case currentStamp = "current_stamp", baselineStamp = "baseline_stamp"
        case currentCount = "current_count", priorCount = "prior_count"
        case staleDays = "stale_days", staleBasis = "stale_basis"
        case fileVaultRule = "filevault_rule", baselineUnreadable = "baseline_unreadable"
        case baselineUnreadableReason = "baseline_unreadable_reason"
        case largeChangePercent = "large_change_percent"
        case joined, left, osChanged = "os_changed", becameStale = "became_stale"
        case noLongerStale = "no_longer_stale", fileVaultOff = "filevault_off"
        case fileVaultStoppedReporting = "filevault_stopped_reporting"
        case unidentified, ambiguous
    }

    private var changeCounts: [Int?] {
        [joined, left, osChanged, becameStale, noLongerStale, fileVaultOff,
         fileVaultStoppedReporting, unidentified, ambiguous]
    }

    /// An unreadable baseline carries no counts; otherwise joined and left need both totals
    /// and cannot exceed the larger; no count is negative or past `maxSummaryNumber`.
    var isValid: Bool {
        let all = changeCounts + [currentCount, priorCount, staleDays, largeChangePercent]
        guard FleetChangeSummary.inRange(all) else { return false }
        if baselineUnreadable == true { return changeCounts.allSatisfy { $0 == nil } }
        guard joined != nil || left != nil else { return true }
        guard let currentCount, let priorCount else { return false }
        let bound = max(currentCount, priorCount)
        return (joined ?? 0) <= bound && (left ?? 0) <= bound
    }
}

/// Compliance Benchmark rules that went from passing everywhere to failing somewhere.
struct BenchmarkChanges: Codable, Sendable, Equatable {
    var currentStamp: String?
    var baselineStamp: String?
    var newlyFailing: Int?
    var notCompared: Int?
    /// A `compliance-rules` file of the pair is there but could not be read: no counts.
    var baselineUnreadable: Bool?
    var baselineUnreadableReason: ComputerChanges.UnreadableReason?

    private enum CodingKeys: String, CodingKey {
        case currentStamp = "current_stamp", baselineStamp = "baseline_stamp"
        case newlyFailing = "newly_failing", notCompared = "not_compared"
        case baselineUnreadable = "baseline_unreadable"
        case baselineUnreadableReason = "baseline_unreadable_reason"
    }

    var isValid: Bool {
        guard FleetChangeSummary.inRange([newlyFailing, notCompared]) else { return false }
        return baselineUnreadable != true || (newlyFailing == nil && notCompared == nil)
    }
}

/// Patch policy failures between two scans. `stopped_failing` is a pair jamf-cli no longer
/// lists as failed, which is not the same as fixed (see `PatchFailureDrift`).
struct PatchChanges: Codable, Sendable, Equatable {
    var currentStamp: String?
    var baselineStamp: String?
    var startedFailing: Int?
    var stoppedFailing: Int?
    var leftOut: Int?
    var notInComputers: Int?
    /// The stamp of the `computers` file the dropped pairs were checked against, so the
    /// Computers screen can rebuild the same lists.
    var computersStamp: String?
    /// A scan of the pair, or the computers file, is there but could not be read: no counts.
    var baselineUnreadable: Bool?
    var baselineUnreadableReason: ComputerChanges.UnreadableReason?

    private enum CodingKeys: String, CodingKey {
        case currentStamp = "current_stamp", baselineStamp = "baseline_stamp"
        case computersStamp = "computers_stamp"
        case startedFailing = "started_failing", stoppedFailing = "stopped_failing"
        case leftOut = "left_out", notInComputers = "not_in_computers"
        case baselineUnreadable = "baseline_unreadable"
        case baselineUnreadableReason = "baseline_unreadable_reason"
    }

    var isValid: Bool {
        let counts = [startedFailing, stoppedFailing, leftOut, notInComputers]
        guard FleetChangeSummary.inRange(counts) else { return false }
        return baselineUnreadable != true || counts.allSatisfy { $0 == nil }
    }
}
