import Foundation
import Observation

/// Which workspaces the Environment card offers to merge into the current one (R2, R4).
enum WorkspaceMergeCandidates {
    /// Workspaces that can merge into `target`: a folder, Jamf Pro, a Platform API profile, not
    /// `target`. Empty when `target` is itself a Platform API profile or a School workspace, or
    /// when its `platform` slot names a profile that is not one of these (remove it first).
    static func list(
        target: String, targetPlatformSlot: String?, profiles: [JamfCLIProfile],
        hasWorkspace: (String) -> Bool
    ) -> [String] {
        guard let own = profiles.first(where: { $0.name == target }),
              own.status != .error, own.product.canBeProWorkspace, own.auth != .platform
        else { return [] }
        let names = profiles.filter {
            $0.name != target && $0.status != .error && $0.product.canBeProWorkspace
                && $0.auth == .platform && hasWorkspace($0.name)
        }.map(\.name)
        guard let slot = targetPlatformSlot else { return names }
        return names.filter { $0 == slot }
    }
}

/// The merge sheet's state machine. Every effect is a dependency, so no test launches jamf-cli
/// or touches a workspace.
@MainActor
@Observable
final class WorkspaceMergeModel {
    enum Phase: Equatable {
        case choose
        case checking
        case refused(String)
        case ready(WorkspaceMergePlan)
        case running(done: Int, total: Int)
        case finished(mergedFolder: String)
        case failed(String)
    }

    struct Dependencies: Sendable {
        var hostVerdict: @Sendable (_ target: String, _ source: String) async
            -> PlatformHostCheck.Verdict
        var makePlan: @Sendable (_ source: String, _ target: String) async throws
            -> WorkspaceMergePlan
        var run: @Sendable (WorkspaceMergeJournal,
            @escaping @Sendable (Int, Int) -> Void) async throws -> Void
        /// The journal on disk now; a resume never trusts one read earlier.
        var pending: @Sendable (_ target: String) -> WorkspaceMergeJournal?

        /// `rewritePolicy` is the GUI's: it owns the stored `AutomationPolicy`.
        static func live(
            rewritePolicy: @escaping @Sendable (String, String) async -> Void
        ) -> Dependencies {
            Dependencies(
                hostVerdict: { target, source in
                    // jamf-cli blocks, so it runs off the main actor.
                    await Task.detached {
                        guard let binary = ExecutableLocator.locate("jamf-cli") else {
                            return PlatformHostCheck.Verdict.unknown
                        }
                        let urls = PlatformHostCheck.live(target, source, binary)
                        return PlatformHostCheck.verdict(
                            jamfProURL: urls.jamfPro, platformJamfProURL: urls.platform)
                    }.value
                },
                makePlan: { source, target in
                    try await Task.detached {
                        try WorkspaceMergePlan.make(source: source, target: target)
                    }.value
                },
                run: { journal, progress in
                    try await WorkspaceMergeExecutor.run(
                        journal, deps: .live(rewritePolicy: rewritePolicy), progress: progress)
                },
                pending: { WorkspaceMergeJournal.pending(target: $0) })
        }
    }

    var phase: Phase = .choose
    let target: String
    private let deps: Dependencies

    init(target: String, deps: Dependencies) {
        self.target = target
        self.deps = deps
    }

    /// True while the sheet must not close.
    var isBusy: Bool {
        switch phase {
        case .checking, .running: true
        default: false
        }
    }

    func choose(source: String) async {
        phase = .checking
        switch await deps.hostVerdict(target, source) {
        case .same:
            break
        case .different(let jamfPro, let platform):
            phase = .refused(L("\(ConfigSchema.displayText(source)) reaches \(ConfigSchema.displayText(platform)), not this workspace's Jamf Pro (\(ConfigSchema.displayText(jamfPro))). Nothing was changed."))
            return
        case .unknown:
            phase = .refused(L("Could not confirm that \(ConfigSchema.displayText(source)) reaches the same Jamf Pro as \(ConfigSchema.displayText(target)). Nothing was changed. You can still add \(ConfigSchema.displayText(source)) as this workspace's Platform API profile from the Add sheet."))
            return
        }
        do {
            phase = .ready(try await deps.makePlan(source, target))
        } catch {
            phase = .refused(ConfigSchema.fullDisplayText(error.localizedDescription).text)
        }
    }

    func merge() async {
        guard case .ready(let plan) = phase else { return }
        await run(WorkspaceMergeJournal(plan: plan, done: 0))
    }

    func resume() async {
        let target = target, read = deps.pending
        guard let journal = await Task.detached(operation: { read(target) }).value else {
            phase = .failed(L("There is no unfinished merge to resume."))
            return
        }
        await run(journal)
    }

    private func run(_ journal: WorkspaceMergeJournal) async {
        let total = journal.plan.steps.count
        phase = .running(done: journal.done, total: total)
        do {
            try await deps.run(journal) { [weak self] done, total in
                Task { @MainActor in self?.progress(done, total) }
            }
            phase = .finished(mergedFolder: journal.plan.mergedFolder)
        } catch {
            phase = .failed(ConfigSchema.fullDisplayText(error.localizedDescription).text)
        }
    }

    private func progress(_ done: Int, _ total: Int) {
        // A late hop must not pull a finished or failed sheet back to running.
        if case .running = phase { phase = .running(done: done, total: total) }
    }
}
