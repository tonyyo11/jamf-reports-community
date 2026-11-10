import Foundation

/// A merge in progress: the whole plan and how many of its steps have finished, so a merge
/// stopped by a crash or a quit resumes where it was and never decides anything again (R11).
/// On disk it is two files under `<target>/automation/`: `.merge-plan.json`, written once when
/// the merge starts (a large workspace plans thousands of steps), and `.merge-journal.json`, the
/// step count and the plan file's SHA-256, saved after every step.
struct WorkspaceMergeJournal: Equatable, Sendable {
    var plan: WorkspaceMergePlan
    /// Steps finished, counted from the start of `plan.steps`.
    var done: Int

    /// What the target's automation folder says about an unfinished merge.
    enum Pending: Equatable, Sendable {
        case none
        case pending(WorkspaceMergeJournal)
        /// A file is there but cannot be read, or the two files do not belong together. It is
        /// never overwritten: a new merge is refused until Start over moves it aside.
        case unreadable(String)
        /// A plan and journal this Mac did not start (a peer's, or edited since). Never run or
        /// retired here; only Start over, which moves the two files aside.
        case foreign(String)

        var isUnreadable: Bool {
            if case .unreadable = self { return true }
            return false
        }
        var isForeign: Bool {
            if case .foreign = self { return true }
            return false
        }
        var canResume: Bool {
            if case .pending = self { return true }
            return false
        }
    }

    /// The contents of `.merge-journal.json`.
    struct Progress: Codable, Equatable, Sendable {
        var done: Int
        var planSHA256: String
        /// Where Start over puts the files when the plan itself cannot be read.
        var mergedFolder: String
    }

    /// This Mac's note that it started a merge: the plan's SHA-256, kept in Application Support
    /// because the plan and journal sit in a folder a peer can write.
    struct Started: Codable, Equatable, Sendable {
        var planSHA256: String
        var target: String
    }

    /// A plan's steps hold absolute paths; 64 MB covers hundreds of thousands of them.
    static let planLimit = BoundedFile.snapshotLimit
    static let recordName = "merge-journal.json"
    static let recordPlanName = "merge-plan.json"

    var isFinished: Bool { done >= plan.steps.count }

    var mergedFolder: URL { URL(fileURLWithPath: plan.mergedFolder, isDirectory: true) }
    /// `<merged>/merge-journal.json`, the record of a finished or abandoned merge.
    var recordURL: URL { mergedFolder.appendingPathComponent(Self.recordName) }
    var recordPlanURL: URL { mergedFolder.appendingPathComponent(Self.recordPlanName) }

    /// `<target>/automation/.merge-journal.json`, through `WorkspacePaths.confinedFolder`.
    static func location(target: String) throws -> URL {
        try automation(target).appendingPathComponent(".merge-journal.json")
    }

    /// `<target>/automation/.merge-plan.json`.
    static func planLocation(target: String) throws -> URL {
        try automation(target).appendingPathComponent(".merge-plan.json")
    }

    private static func automation(_ target: String) throws -> URL {
        guard let workspace = ProfileService.workspaceURL(for: target) else {
            throw WorkspacePaths.PathError.invalidProfile(target)
        }
        return try WorkspacePaths.confinedFolder(["automation"], under: workspace)
    }

    /// `<appSupport>/merge-started-<target>.json`, per Mac and never in the workspace.
    static func startedLocation(target: String, appSupport: URL) -> URL {
        appSupport.appendingPathComponent(
            "merge-started-\(ProfileName.pathComponent(target)).json")
    }

    static func markStarted(planSHA256: String, target: String, appSupport: URL) throws {
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        try AtomicInstall.write(
            JSONEncoder().encode(Started(planSHA256: planSHA256, target: target)),
            to: startedLocation(target: target, appSupport: appSupport), mode: 0o600)
    }

    /// The plan hash this Mac recorded for `target`, nil when it started none.
    static func started(target: String, appSupport: URL) -> Started? {
        guard let data = try? BoundedFile.read(
            startedLocation(target: target, appSupport: appSupport),
            limit: BoundedFile.documentLimit, followSymlinks: false),
              let note = try? JSONDecoder().decode(Started.self, from: data),
              note.target == target else { return nil }
        return note
    }

    static func clearStarted(target: String, appSupport: URL) {
        let url = startedLocation(target: target, appSupport: appSupport)
        guard FileManager.default.fileExists(atPath: url.path) || FileManager.isLink(url) else {
            return
        }
        do { try FileManager.default.removeItem(at: url) } catch {
            AppLogger.event(.collect, .error,
                            "merge start note not removed: \(error.localizedDescription)")
        }
    }

    /// The pending journal for `target`, nil when there is none or it cannot be read.
    static func pending(target: String, appSupport: URL = AppSupport.directory())
        -> WorkspaceMergeJournal? {
        if case .pending(let journal) = state(target: target, appSupport: appSupport) {
            return journal
        }
        return nil
    }

    /// Reads both files. A finished journal left behind (its removal failed) is moved to its
    /// record and reads as none; anything that does not read cleanly is `.unreadable`.
    static func state(target: String, appSupport: URL = AppSupport.directory()) -> Pending {
        do {
            let progressURL = try location(target: target)
            let planURL = try planLocation(target: target)
            let hasProgress = present(progressURL), hasPlan = present(planURL)
            if !hasProgress, !hasPlan { return .none }
            guard hasProgress, hasPlan else {
                return unreadable("only one of the merge's two files is there")
            }
            let planData = try BoundedFile.read(planURL, limit: planLimit, followSymlinks: false)
            let progress = try readProgress(progressURL)
            guard progress.planSHA256 == sha256Hex(planData) else {
                return unreadable("the merge journal does not match its plan")
            }
            // Both files are peer-writable and agree by construction, so only this Mac's own
            // record of the plan's hash says the merge is one it started.
            guard started(target: target, appSupport: appSupport)?.planSHA256
                    == progress.planSHA256 else {
                return foreign("started on another Mac, or its files changed")
            }
            let plan = try JSONDecoder().decode(WorkspaceMergePlan.self, from: planData)
            guard (0...plan.steps.count).contains(progress.done) else {
                return unreadable("the merge journal counts \(progress.done) steps")
            }
            let journal = WorkspaceMergeJournal(plan: plan, done: progress.done)
            guard journal.isFinished else { return .pending(journal) }
            try journal.retire(progressAt: progressURL, planAt: planURL, planData: planData,
                               appSupport: appSupport)
            return .none
        } catch {
            return unreadable(error.localizedDescription)
        }
    }

    private static func foreign(_ reason: String) -> Pending {
        AppLogger.event(.collect, .error, "merge journal is not this Mac's: \(reason)")
        return .foreign(reason)
    }

    private static func unreadable(_ reason: String) -> Pending {
        AppLogger.event(.collect, .error, "merge journal could not be read: \(reason)")
        return .unreadable(reason)
    }

    static func readProgress(_ url: URL) throws -> Progress {
        try JSONDecoder().decode(Progress.self, from: BoundedFile.read(
            url, limit: BoundedFile.documentLimit, followSymlinks: false))
    }

    /// The plan as written to disk: compact, keys sorted.
    static func encodedPlan(_ plan: WorkspaceMergePlan) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(plan)
    }

    /// Writes the plan file and returns the SHA-256 the journal names.
    @discardableResult
    static func write(planData: Data, to url: URL) throws -> String {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AtomicInstall.write(planData, to: url, mode: 0o600)
        return sha256Hex(planData)
    }

    static func write(_ progress: Progress, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try AtomicInstall.write(try encoder.encode(progress), to: url, mode: 0o600)
    }

    /// Both record files go beside the archive, then the pending ones go.
    func retire(progressAt progressURL: URL, planAt planURL: URL, planData: Data,
                appSupport: URL) throws {
        try plan.requireConfined()
        let hash = try Self.write(planData: planData, to: recordPlanURL)
        try Self.write(Progress(done: done, planSHA256: hash, mergedFolder: plan.mergedFolder),
                       to: recordURL)
        try FileManager.default.removeItem(at: progressURL)
        try FileManager.default.removeItem(at: planURL)
        Self.clearStarted(target: plan.target, appSupport: appSupport)
    }

    static func sha256Hex(_ data: Data) -> String { SnapshotManifest.sha256Hex(data) }

    private static func present(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path) || FileManager.isLink(url)
    }
}
