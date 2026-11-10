import CryptoKit
import Foundation

/// Applies a `WorkspaceMergePlan` to disk under the tick lock. Every step can run twice: a copy
/// never overwrites other bytes, an archive copy is made once, and the tail checks what is
/// already done. Nothing the user can see is deleted; replaced files go to the archive first.
enum WorkspaceMergeExecutor {
    struct Dependencies: Sendable {
        var hold: @Sendable (_ body: @Sendable () async throws -> Void) async throws -> Void
        /// Takes the shared-workspace claim for the merge; `.blocked` names the peer.
        var acquireClaim: @Sendable (_ workspace: String) -> SharedWorkspace.ClaimDecision
        /// Drops this Mac's claim; never another host's.
        var releaseClaim: @Sendable (_ workspace: String) -> Void
        var writePlatformSlot: @Sendable (_ profile: String, _ workspace: String) throws -> Void
        var copyBenchmarks: @Sendable (_ source: String, _ target: String) throws -> Void
        var retargetSchedules: @Sendable (_ from: String, _ to: String, _ keepTargetIn: Set<String>)
            throws -> Void
        var rewritePolicy: @Sendable (_ from: String, _ to: String, _ keepTargetExcluded: Bool)
            async -> Void
        var appSupport: URL

        /// `holdingTickLock(purpose: .merge)`, the shared-workspace claim, the real writers.
        /// `rewritePolicy` is supplied by the caller (the GUI owns the policy).
        static func live(rewritePolicy: @escaping @Sendable (String, String, Bool) async -> Void)
            -> Dependencies {
            Dependencies(
                hold: { body in try await CLIBridge.holdingTickLock(purpose: .merge, body) },
                acquireClaim: {
                    SharedWorkspace.acquire(profile: $0, operation: "merge", ttl: claimTTL)
                },
                releaseClaim: { SharedWorkspace.release(profile: $0) },
                writePlatformSlot: { profile, workspace in
                    try ProfilesConfigWriter.save(.platform, to: profile, workspace: workspace)
                },
                copyBenchmarks: { try WorkspaceMergeExecutor.copyBenchmarks($0, $1) },
                retargetSchedules: { try ScheduleStore().retarget(from: $0, to: $1, keepTargetIn: $2) },
                rewritePolicy: rewritePolicy,
                appSupport: AppSupport.directory())
        }
    }

    /// Long enough for a large merge; a crashed one stops blocking peers after this, and this
    /// Mac's own resume takes its claim back at once.
    static let claimTTL: TimeInterval = 2 * 3600

    enum RunError: Error, LocalizedError, Equatable {
        case peerClaim(workspace: String, host: String)
        /// Another merge's journal is pending for the target: resume it or start over first.
        case pendingMerge(source: String)
        /// The target holds a merge journal that cannot be read; Start over moves it aside.
        case unreadableJournal
        /// The target's merge files were not started on this Mac; only Start over clears them.
        case foreignJournal
        /// Refused before the journal was written: nothing changed.
        case notStarted(reason: String)
        case step(index: Int, reason: String)

        var errorDescription: String? {
            switch self {
            case .peerClaim(let workspace, let host):
                L("\(ConfigSchema.displayText(host)) is working in \(workspace) — try the merge again when it finishes.")
            case .pendingMerge(let source):
                L("A merge of \(ConfigSchema.displayText(source)) into this workspace did not finish. Resume it or start over before merging another workspace.")
            case .unreadableJournal:
                L("A merge into this workspace did not finish and its record can't be read. Choose Start over on the Environment card before merging again.")
            case .foreignJournal:
                L("A merge into this workspace was started on another Mac, or its files changed. Choose Start over on the Environment card before merging again.")
            case .notStarted(let reason):
                L("The merge did not start: \(reason)")
            case .step(let index, let reason):
                L("Merge step \(index + 1) did not finish: \(reason)")
            }
        }
    }

    /// Runs `journal.plan` from `journal.done`, saving the journal after each step. Test seam:
    /// `stopAfter` throws `CancellationError` once that many steps have run in this call.
    static func run(
        _ journal: WorkspaceMergeJournal, deps: Dependencies, stopAfter: Int? = nil,
        progress: @Sendable (_ done: Int, _ total: Int) -> Void = { _, _ in }
    ) async throws {
        try await deps.hold {
            try await runHeld(journal, deps: deps, stopAfter: stopAfter, progress: progress)
        }
    }

    private static func runHeld(
        _ start: WorkspaceMergeJournal, deps: Dependencies, stopAfter: Int?,
        progress: @Sendable (Int, Int) -> Void
    ) async throws {
        let plan = start.plan
        do { try plan.requireConfined() } catch {
            throw RunError.notStarted(reason: error.localizedDescription)
        }
        var held: [String] = []
        defer { held.forEach(deps.releaseClaim) }
        // A source already moved (a resumed merge) has no folder to claim; claiming it would
        // create one at its old name.
        for workspace in [plan.source, plan.target]
        where ProfileService.workspaceURL(for: workspace).map(exists) ?? false {
            try claim(workspace, deps: deps)
            held.append(workspace)
        }
        // A finished journal handed in again (read before `state` retired it): nothing to do.
        if start.isFinished { return }
        let files = try startFiles(start, deps: deps)
        var journal = start
        journal.done = files.done
        let total = plan.steps.count
        AppLogger.event(
            .collect, .notice,
            "workspace merge started: \(total - journal.done) of \(total) steps to run")
        var ran = 0
        while journal.done < total {
            let index = journal.done
            // The claim has no heartbeat: renewing it before each step pushes its expiry, so a
            // merge longer than `claimTTL` is never taken over by a peer mid-run.
            for workspace in held { try claim(workspace, deps: deps) }
            let step = plan.steps[index]
            do {
                try await perform(step, plan: plan, deps: deps)
            } catch {
                throw RunError.step(index: index, reason: error.localizedDescription)
            }
            // The source's folder is gone; nothing is claimed or released at its old name.
            if step.action == .tail(.moveSource) { held.removeAll { $0 == plan.source } }
            journal.done += 1
            // Before the journal file, so this Mac's count can lag a crash but never lead it.
            try WorkspaceMergeJournal.markStarted(
                planSHA256: files.planSHA256, target: plan.target, mergedFolder: plan.mergedFolder,
                done: journal.done, appSupport: deps.appSupport)
            if journal.done == total {
                do {
                    try journal.retire(progressAt: files.progress, planAt: files.plan,
                                       planData: files.planData, appSupport: deps.appSupport)
                } catch {
                    // The next Resume reruns the last step, then retires.
                    AppLogger.event(.collect, .error,
                                    "merge journal not retired: \(error.localizedDescription)")
                }
            } else {
                try WorkspaceMergeJournal.write(
                    .init(done: journal.done, planSHA256: files.planSHA256,
                          mergedFolder: plan.mergedFolder),
                    to: files.progress)
            }
            progress(journal.done, total)
            ran += 1
            if let stopAfter, ran >= stopAfter, journal.done < total { throw CancellationError() }
        }
        AppLogger.event(.collect, .notice, "workspace merge finished: \(total) steps")
    }

    /// Start over: the unfinished merge's files move into its merged folder as
    /// `merge-plan.json` and `merge-journal.json`, the record of how far it got; nothing is
    /// deleted. Runs under the merge hold and the target's claim, so it never moves a journal
    /// a run is using. A journal that cannot be read goes to `_merged/<target>-unfinished-<now>`.
    static func startOver(target: String, deps: Dependencies, now: Date = Date()) async throws {
        try await deps.hold {
            let holds = ProfileService.workspaceURL(for: target).map(exists) ?? false
            if holds { try claim(target, deps: deps) }
            defer { if holds { deps.releaseClaim(target) } }
            try moveJournalAside(target: target, appSupport: deps.appSupport, now: now)
            WorkspaceMergeJournal.clearStarted(target: target, appSupport: deps.appSupport)
        }
    }

    private static func moveJournalAside(target: String, appSupport: URL, now: Date) throws {
        let progressURL = try WorkspaceMergeJournal.location(target: target)
        let planURL = try WorkspaceMergeJournal.planLocation(target: target)
        let moves = [(progressURL, WorkspaceMergeJournal.recordName),
                     (planURL, WorkspaceMergeJournal.recordPlanName)].filter { exists($0.0) }
        guard !moves.isEmpty else { return }
        let folder = try startOverFolder(target: target, appSupport: appSupport, now: now)
        for (file, name) in moves {
            let destination = folder.appendingPathComponent(name)
            try prepareParent(of: destination)
            // moveItem refuses a taken name, so an earlier record is never replaced.
            try FileManager.default.moveItem(at: file, to: destination)
        }
    }

    /// The merged folder this Mac recorded for the merge, when it is one under `<root>/_merged`
    /// with no record files yet; the journal's own copy is peer-writable and never read.
    private static func startOverFolder(
        target: String, appSupport: URL, now: Date
    ) throws -> URL {
        let mergedRoot = ProfileService.workspacesRoot()
            .appendingPathComponent("_merged", isDirectory: true)
        if let note = WorkspaceMergeJournal.started(target: target, appSupport: appSupport),
           let url = WorkspaceMergePlan.confined(note.mergedFolder, under: mergedRoot),
           url.deletingLastPathComponent().path == mergedRoot.standardizedFileURL.path,
           !url.lastPathComponent.hasPrefix("."),
           ![WorkspaceMergeJournal.recordName, WorkspaceMergeJournal.recordPlanName].contains(
            where: { exists(url.appendingPathComponent($0)) }) {
            return url
        }
        guard let id = WorkspaceID(target) else { throw StepError("\(target) is not a workspace") }
        let stamp = WorkspaceMergePlan.stampFormatter.string(from: now)
        return mergedRoot.appendingPathComponent("\(id.pathComponent)-unfinished-\(stamp)",
                                                 isDirectory: true)
    }

    private struct JournalFiles {
        let progress: URL
        let plan: URL
        let planData: Data
        /// Steps to skip: the journal's count capped by this Mac's record.
        var done = 0
        var planSHA256: String { WorkspaceMergeJournal.sha256Hex(planData) }
    }

    /// The journal's two files for this run. A fresh run writes them; a resume of the pending
    /// merge reads its plan file back. Every refusal here comes before any write.
    private static func startFiles(
        _ start: WorkspaceMergeJournal, deps: Dependencies
    ) throws -> JournalFiles {
        let plan = start.plan
        let progressURL: URL, planURL: URL
        do {
            progressURL = try WorkspaceMergeJournal.location(target: plan.target)
            planURL = try WorkspaceMergeJournal.planLocation(target: plan.target)
        } catch {
            throw RunError.notStarted(reason: error.localizedDescription)
        }
        // Never overwrite another merge's journal, nor one that cannot be read.
        let (state, readPlan) = WorkspaceMergeJournal.read(
            target: plan.target, appSupport: deps.appSupport)
        switch state {
        case .unreadable:
            throw RunError.unreadableJournal
        case .foreign:
            throw RunError.foreignJournal
        case .pending(let other) where other.plan != plan:
            throw RunError.pendingMerge(source: other.plan.source)
        case .pending(let other):
            guard let readPlan else { throw RunError.unreadableJournal }
            return JournalFiles(progress: progressURL, plan: planURL, planData: readPlan,
                                done: min(start.done, other.done))
        case .none:
            // A resume whose journal was moved aside (Start over elsewhere) must not restart
            // as a fresh merge and later replace the record Start over kept.
            guard start.done == 0 else {
                throw RunError.notStarted(reason: "the unfinished merge's journal is gone")
            }
        }
        let data: Data
        do {
            data = try WorkspaceMergeJournal.encodedPlan(plan)
            // Noted first: a plan file with no note would read as a peer's.
            try WorkspaceMergeJournal.markStarted(
                planSHA256: WorkspaceMergeJournal.sha256Hex(data), target: plan.target,
                mergedFolder: plan.mergedFolder, done: 0, appSupport: deps.appSupport)
            try WorkspaceMergeJournal.write(planData: data, to: planURL)
        } catch {
            WorkspaceMergeJournal.clearStarted(target: plan.target, appSupport: deps.appSupport)
            throw RunError.notStarted(reason: error.localizedDescription)
        }
        let files = JournalFiles(progress: progressURL, plan: planURL, planData: data)
        do {
            try WorkspaceMergeJournal.write(
                .init(done: start.done, planSHA256: files.planSHA256,
                      mergedFolder: plan.mergedFolder),
                to: progressURL)
        } catch {
            WorkspaceMergeJournal.clearStarted(target: plan.target, appSupport: deps.appSupport)
            // The plan file alone would read as unreadable; it is this run's own, just written.
            do { try FileManager.default.removeItem(at: planURL) } catch {
                AppLogger.event(.collect, .error,
                                "merge plan not removed: \(error.localizedDescription)")
            }
            throw RunError.notStarted(reason: error.localizedDescription)
        }
        return files
    }

    private static func claim(_ workspace: String, deps: Dependencies) throws {
        if case .blocked(let claim) = deps.acquireClaim(workspace) {
            throw RunError.peerClaim(workspace: workspace, host: claim.host.display)
        }
    }

    // MARK: - Steps

    private static func perform(
        _ step: WorkspaceMergePlan.Step, plan: WorkspaceMergePlan, deps: Dependencies
    ) async throws {
        let source = URL(fileURLWithPath: step.source)
        let target = URL(fileURLWithPath: step.target)
        let archive = step.archive.map { URL(fileURLWithPath: $0) }
        switch step.action {
        case .copy:
            let isStatus = step.area == .runHistory && target.lastPathComponent.hasSuffix("_status.json")
            if isStatus, let stripped = try? strippedStatus(source) {
                if exists(target), !isRegular(target) || BoundedFile.sha256Hex(target) != Self.sha256(stripped) {
                    try copyFallback(step, source: source, target: target, plan: plan)
                } else if !exists(target) {
                    try place(stripped, at: target, mode: 0o600)
                }
            } else if exists(target), !sameBytes(target, source) {
                try copyFallback(step, source: source, target: target, plan: plan)
            } else {
                try place(source, at: target)
            }
        case .skipIdentical:
            break
        case .archiveSource:
            try place(source, at: try required(archive))
        case .fillSummary(let sourceArchive):
            try fillSummary(source: source, target: target, targetArchive: try required(archive),
                            sourceArchive: URL(fileURLWithPath: sourceArchive))
        case .replaceState:
            // A target file the source's would replace goes to the archive first; one that
            // already holds the source's bytes was installed by an earlier run.
            if exists(target), !sameBytes(target, source) {
                let archive = try required(archive)
                if !exists(archive) {
                    try place(target, at: archive)
                } else if !sameBytes(target, archive) {
                    // Changed since the archive copy (after a crash): never replace it unseen.
                    throw StepError("\(target.lastPathComponent) changed since the merge began")
                }
            }
            try install(source, over: target)
        case .archiveTarget:
            guard exists(target) else { break }
            let archive = try required(archive)
            guard !exists(archive) else {
                throw StepError("the archive already holds \(target.lastPathComponent)")
            }
            try requireNoLinkedAncestor(target)
            try requireRegular(target)
            try prepareParent(of: archive)
            try FileManager.default.moveItem(at: target, to: archive)
        case .copyFolder:
            try copyFolder(source, to: target)
        case .tail(let tail):
            try await perform(tail, plan: plan, deps: deps)
        }
    }

    private static func perform(
        _ tail: WorkspaceMergePlan.Tail, plan: WorkspaceMergePlan, deps: Dependencies
    ) async throws {
        let merged = URL(fileURLWithPath: plan.mergedFolder, isDirectory: true)
        let sourceWS = try workspace(plan.source)
        switch tail {
        case .archiveSourceConfig:
            let config = sourceWS.appendingPathComponent("config.yaml")
            let copy = merged.appendingPathComponent("archive/config/config.yaml")
            // Resumed after the move: the config travelled with the folder and was archived.
            if exists(config) { try place(config, at: copy) }
        case .writePlatformSlot:
            if platformSlot(of: plan.target) != plan.source {
                try deps.writePlatformSlot(plan.source, plan.target)
            }
        case .copyBenchmarks:
            try deps.copyBenchmarks(plan.source, plan.target)
        case .retargetSchedules:
            try deps.retargetSchedules(
                plan.source, plan.target, Set(plan.keepTargetExcludedInSchedules))
        case .rewritePolicy:
            await deps.rewritePolicy(
                plan.source, plan.target, plan.keepTargetExcludedInPolicy)
        case .removeSourcePin:
            // App state, not workspace data: the one file a merge removes outright.
            if let pin = SharedConfigPin.storeURL(
                workspace: plan.source, appSupport: deps.appSupport), exists(pin) {
                try FileManager.default.removeItem(at: pin)
            }
        case .moveSource:
            let destination = merged.appendingPathComponent("workspace", isDirectory: true)
            if exists(destination), !exists(sourceWS) { return }
            guard !exists(destination) else {
                throw StepError("the merged folder already holds a workspace")
            }
            try prepareParent(of: destination)
            try requireNoLinkedAncestor(sourceWS)
            // Moved while still claimed; this Mac's claim then leaves the merged folder.
            try FileManager.default.moveItem(at: sourceWS, to: destination)
            let claimFile = destination.appendingPathComponent(
                "automation/\(SharedWorkspace.claimFilename)")
            if isRegular(claimFile) {
                do { try FileManager.default.removeItem(at: claimFile) } catch {
                    AppLogger.event(.collect, .error,
                                    "merge claim not removed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// The target gained `target` after planning (a scheduled collect before Merge, or between
    /// a crash and Resume): R7 keeps the target's file and archives the source's, and a daily
    /// summary is filled as if both had held it when the plan was made.
    private static func copyFallback(
        _ step: WorkspaceMergePlan.Step, source: URL, target: URL, plan: WorkspaceMergePlan
    ) throws {
        let name = target.lastPathComponent
        if step.area == .summaries, CloudStorage.isCanonicalSummaryFilename(name) {
            func archived(_ side: String) -> URL {
                WorkspaceMergePlan.summaryArchive(
                    mergedFolder: plan.mergedFolder, side: side, name: name)
            }
            try fillSummary(source: source, target: target, targetArchive: archived("target"),
                            sourceArchive: archived("source"))
        } else {
            try place(source, at: try required(step.archive.map { URL(fileURLWithPath: $0) }))
        }
    }

    private static func fillSummary(
        source: URL, target: URL, targetArchive: URL, sourceArchive: URL
    ) throws {
        if !exists(targetArchive) { try place(target, at: targetArchive) }
        if !exists(sourceArchive) { try place(source, at: sourceArchive) }
        // From the two originals, so a second run writes the same file.
        func summary(_ url: URL) throws -> DailySummary {
            try SummaryJSONParser.decode(BoundedFile.read(
                url, limit: SummaryJSONParser.maxSummaryFileBytes, followSymlinks: false))
        }
        let filled = try summary(targetArchive).filling(from: summary(sourceArchive))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]  // as `writeSummaryFile`
        let data = try encoder.encode(filled)
        // The target is the original (first run) or this output (a rerun); anything else
        // changed after a crash and is not replaced unseen.
        let current = BoundedFile.sha256Hex(target)
        guard isRegular(target), current == BoundedFile.sha256Hex(targetArchive)
                || current == SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined()
        else { throw StepError("\(target.lastPathComponent) changed since the merge began") }
        try requireNoLinkedAncestor(target)
        try AtomicInstall.write(data, to: target)
    }

    // MARK: - Config tail

    /// The target's `profiles.platform`, nil when it has none or the file does not read.
    private static func platformSlot(of workspace: String) -> String? {
        guard let url = ProfileService.workspaceURL(for: workspace)?
            .appendingPathComponent("config.yaml"),
            let text = try? ConfigLoader.readText(at: url),
            let root = try? ConfigLoader.rawMapping(fromYAML: text),
            let slots = root["profiles"] as? [String: Any] else { return nil }
        return (slots["platform"] as? String)?.trimmingCharacters(in: .whitespaces)
    }

    /// `platform.compliance_benchmarks` from the source, when the target lists none.
    static func copyBenchmarks(_ source: String, _ target: String) throws {
        func benchmarks(_ name: String) throws -> YAMLCodec.YAMLValue? {
            let url = try workspace(name).appendingPathComponent("config.yaml")
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let document = try YAMLCodec.decode(ConfigLoader.readText(at: url))
            guard case .mapping(let root) = document.root else { return nil }
            let value = root.value(for: "platform")?.mapping?.value(for: "compliance_benchmarks")
            return value?.sequence?.isEmpty == false ? value : nil
        }
        guard let list = try benchmarks(source), try benchmarks(target) == nil else { return }
        _ = try ConfigService.saveBlock(key: "platform", profile: target) { root in
            var block = root.value(for: "platform")?.mapping ?? .init(entries: [])
            block.set("compliance_benchmarks", value: list)
            root.set("platform", value: .mapping(block))
        }
    }

    // MARK: - Files

    private struct StepError: Error, LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    private static func workspace(_ name: String) throws -> URL {
        guard let url = ProfileService.workspaceURL(for: name) else {
            throw StepError("\(name) is not a workspace name")
        }
        return url
    }

    private static func required(_ archive: URL?) throws -> URL {
        guard let archive else { throw StepError("the plan names no archive for this step") }
        return archive
    }

    private static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path) || FileManager.isLink(url)
    }

    private static func isRegular(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }

    private static func requireRegular(_ url: URL) throws {
        guard isRegular(url) else {
            throw StepError("\(url.lastPathComponent) is not a regular file")
        }
    }

    /// Both are regular files with the same SHA-256.
    private static func sameBytes(_ a: URL, _ b: URL) -> Bool {
        guard isRegular(a), isRegular(b), let hash = BoundedFile.sha256Hex(a) else { return false }
        return hash == BoundedFile.sha256Hex(b)
    }

    /// Copies `source` to `destination` when nothing is there; the same bytes there is done.
    /// Anything else at `destination` is never overwritten.
    private static func place(_ source: URL, at destination: URL) throws {
        try requireNoLinkedAncestor(source)
        try requireRegular(source)
        if exists(destination) {
            guard sameBytes(destination, source) else {
                throw StepError("\(destination.lastPathComponent) already holds other content")
            }
            return
        }
        try prepareParent(of: destination)
        let staged = AtomicInstall.stagedURL(for: destination)
        do {
            try FileManager.default.copyItem(at: source, to: staged)
            try AtomicInstall.installExclusive(staged, at: destination)
        } catch {
            AtomicInstall.discard(staged)
            throw error
        }
    }

    /// The source's status file without the open attention items: `AttentionLog` reads the
    /// newest file's set, so a copied one would replace the target's.
    private static func strippedStatus(_ source: URL) throws -> Data {
        try requireNoLinkedAncestor(source)
        try requireRegular(source)
        let data = try BoundedFile.read(source, limit: BoundedFile.documentLimit, followSymlinks: false)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StepError("\(source.lastPathComponent) is not a status record")
        }
        object["attention"] = nil
        object["attention_at"] = nil
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// `data` written to `destination` when nothing is there, like `place`.
    private static func place(_ data: Data, at destination: URL, mode: Int) throws {
        try prepareParent(of: destination)
        let staged = AtomicInstall.stagedURL(for: destination)
        do {
            try data.write(to: staged, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: staged.path)
            try AtomicInstall.installExclusive(staged, at: destination)
        } catch {
            AtomicInstall.discard(staged)
            throw error
        }
    }

    /// A copy of `source` staged beside `destination`, then installed: a link at the name is
    /// replaced, never written through.
    private static func install(_ source: URL, over destination: URL) throws {
        try requireNoLinkedAncestor(source)
        try requireRegular(source)
        if exists(destination) { try requireRegular(destination) }
        try prepareParent(of: destination)
        let staged = AtomicInstall.stagedURL(for: destination)
        do {
            try FileManager.default.copyItem(at: source, to: staged)
            try AtomicInstall.install(staged, at: destination)
        } catch {
            AtomicInstall.discard(staged)
            throw error
        }
    }

    private static func copyFolder(_ source: URL, to destination: URL) throws {
        guard !exists(destination) else { return }
        guard !FileManager.isLink(source) else {
            throw StepError("\(source.lastPathComponent) is a link")
        }
        try requireNoLinkedAncestor(source)
        try prepareParent(of: destination)
        removeStagedCopies(of: destination)
        let staged = AtomicInstall.stagedURL(for: destination, isDirectory: true)
        do {
            try FileManager.default.copyItem(at: source, to: staged)
            try AtomicInstall.installExclusive(staged, at: destination)
        } catch {
            AtomicInstall.discard(staged)
            throw error
        }
    }

    /// Hidden `.<name>.tmp-*` folders a crashed copy of this backup left (real folders only,
    /// never a link): our own staged copies, which would otherwise stay forever.
    private static func removeStagedCopies(of destination: URL) {
        let parent = destination.deletingLastPathComponent()
        let prefix = ".\(destination.lastPathComponent).tmp-"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        for name in names where name.hasPrefix(prefix) {
            let url = parent.appendingPathComponent(name)
            var info = stat()
            guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { continue }
            do { try FileManager.default.removeItem(at: url) } catch {
                AppLogger.event(.collect, .error,
                                "merge staging not removed: \(error.localizedDescription)")
            }
        }
    }

    private static func prepareParent(of url: URL) throws {
        try requireNoLinkedAncestor(url)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    /// Refuses a link on the way to `url`, checked up to the workspaces root or the home folder
    /// (both may be links themselves: a synced root, `/var` in tests), so no write goes through
    /// a folder a peer swapped for a link after the plan was made.
    static func requireNoLinkedAncestor(_ url: URL) throws {
        let workspaces = ProfileService.workspacesRoot()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let stops = Set([workspaces, home].flatMap {
            [$0.standardizedFileURL.path, $0.resolvingSymlinksInPath().standardizedFileURL.path]
        } + ["/"])
        var current = url.deletingLastPathComponent().standardizedFileURL
        while !stops.contains(current.path) {
            if FileManager.isLink(current) {
                throw StepError("\(current.lastPathComponent) is a link")
            }
            current = current.deletingLastPathComponent()
        }
    }
}
