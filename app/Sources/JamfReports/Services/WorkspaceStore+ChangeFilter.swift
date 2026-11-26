import Foundation

/// One snapshot pair under one rule: every kind of the pair shares the entry.
struct ChangeFilterCacheKey: Hashable, Sendable {
    var profile: String
    var demoMode: Bool
    /// The filter with its kind set to the pair's first kind.
    var pair: ChangeFilter
    var staleDays: Int
    var staleBasis: [String]
    var fileVaultFingerprint: String
}

extension WorkspaceStore {
    /// The Macs behind a count, compared off the main actor and cached for the session. Demo
    /// mode reads no disk. `.cancelled` when the caller's task was cancelled; never cached.
    func resolveChangeFilter(
        _ filter: ChangeFilter, rule: StaleRule, policy: SecurityControlPolicy
    ) async -> ChangeFilterResult {
        if demoMode { return DemoData.changeFilterResult(for: filter.kind) }
        let firstKind: ChangeKind = filter.kind.isPatch ? .patchStarted : .joined
        let key = ChangeFilterCacheKey(
            profile: profile, demoMode: demoMode, pair: filter.with(kind: firstKind),
            staleDays: rule.days, staleBasis: rule.basis.map(\.rawValue),
            fileVaultFingerprint: policy.fileVaultFingerprint)
        let profile = profile
        while !Task.isCancelled {
            if let hit = changeFilterCache[key]?[filter.kind] { return hit }
            let handle = changeFilterInFlight[key] ?? Task.detached(priority: .userInitiated) {
                guard let workspace = ProfileService.workspaceURL(for: profile) else {
                    return ChangeFilterResolver.uniform(filter, .fileGone)
                }
                let dataDir = (try? WorkspacePaths.dataDir(for: profile))
                    ?? workspace.appendingPathComponent("jamf-cli-data", isDirectory: true)
                return ChangeFilterResolver.resolveAll(
                    filter, dataDir: dataDir, rule: rule, policy: policy)
            }
            changeFilterInFlight[key] = handle
            let results = await withTaskCancellationHandler {
                await handle.value
            } onCancel: {
                handle.cancel()
            }
            if changeFilterInFlight[key] == handle { changeFilterInFlight[key] = nil }
            guard let result = results[filter.kind] else { break }
            if result.outcome != .cancelled {
                if key.profile == self.profile { changeFilterCache[key] = results }
                return result
            }
            // Another caller's cancel stopped a shared comparison; run it again for this one.
        }
        return ChangeFilterResult(outcome: .cancelled)
    }
}
