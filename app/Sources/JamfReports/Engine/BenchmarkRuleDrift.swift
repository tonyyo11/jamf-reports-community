import Foundation

/// Compliance Benchmark rules that started failing between two `compliance-rules` snapshots.
/// A rule is keyed by benchmark and rule ID (its title when it has none). A rule that cannot
/// be compared is counted in `notCompared`, never listed: an unknown failure count on either
/// side, a benchmark only one file holds, a rule only the current file holds, and a key
/// repeated within one file.
struct BenchmarkRuleDrift {
    typealias Rule = ComplianceBenchmarksService.Snapshot.Rule

    let newlyFailing: [Rule]
    let notCompared: Int

    init(current: [Rule], baseline: [Rule]) {
        func keyed(_ rules: [Rule]) -> (unique: [String: Rule], repeated: Set<String>) {
            var unique: [String: Rule] = [:], repeated: Set<String> = []
            for rule in rules {
                if unique.updateValue(rule, forKey: rule.id) != nil { repeated.insert(rule.id) }
            }
            for key in repeated { unique[key] = nil }
            return (unique, repeated)
        }
        let now = keyed(current), before = keyed(baseline)
        let shared = Set(current.map(\.benchmark)).intersection(baseline.map(\.benchmark))
        var notCompared = current.filter { now.repeated.contains($0.id) }.count
        var newlyFailing: [Rule] = []
        for rule in now.unique.values.sorted(by: { $0.id < $1.id }) {
            guard shared.contains(rule.benchmark), !before.repeated.contains(rule.id),
                  let old = before.unique[rule.id],
                  let was = old.failed, let isNow = rule.failed
            else { notCompared += 1; continue }
            if was == 0 && isNow > 0 { newlyFailing.append(rule) }
        }
        self.newlyFailing = newlyFailing
        self.notCompared = notCompared
    }

    /// The `compliance-rules` file stamped `landedStamp` and the newest from an earlier local
    /// day. Nil when either is missing.
    static func pair(dataDir: URL, landedStamp: Date) -> (current: URL, baseline: URL)? {
        SnapshotPair.landed("compliance-rules", in: dataDir, stamp: landedStamp)
    }

    /// The drift between the two files `pair` names, or why one could not be read.
    static func load(
        current: URL, baseline: URL, dataDir: URL
    ) -> Result<BenchmarkRuleDrift, SnapshotReadFailure> {
        func rules(_ url: URL) -> Result<[Rule], SnapshotReadFailure> {
            SnapshotPair.read(url, limit: BoundedFile.limit(forKind: "compliance-rules"),
                              dataDir: dataDir).flatMap {
                ComplianceBenchmarksService.decodeRules(in: $0).map { .success($0) }
                    ?? .failure(SnapshotReadFailure(.undecodable))
            }
        }
        return rules(current).flatMap { now in
            rules(baseline).map { BenchmarkRuleDrift(current: now, baseline: $0) }
        }
    }
}
