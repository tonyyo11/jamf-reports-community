import Foundation

/// What merging a Platform API workspace (the source) into a Jamf Pro workspace (the target)
/// does, file by file, decided before anything is written. The executor runs `steps` in order
/// and journals the whole value, so a resumed merge never re-decides (P7, R11).
struct WorkspaceMergePlan: Codable, Equatable, Sendable {
    enum Area: String, Codable, CaseIterable, Sendable {
        case snapshots, state, summaries, chartHistory, sofa, runHistory, backups, reports, config
    }

    /// The fixed steps after the files, in this order.
    enum Tail: String, Codable, CaseIterable, Sendable {
        case archiveSourceConfig, writePlatformSlot, copyBenchmarks
        // The pin goes last: if the move fails the source is still live and keeps its pin.
        case retargetSchedules, rewritePolicy, moveSource, removeSourcePin
    }

    enum Action: Codable, Equatable, Sendable {
        /// The target lacks the name. `archive` is where the source's file goes instead when the
        /// target gains the name before the step runs (R7).
        case copy
        /// Same name, same SHA-256. Listed so the sheet can count it; the executor does nothing.
        case skipIdentical
        /// Same name, different bytes: the target keeps its file, the source's goes to `archive`.
        case archiveSource
        /// Both have the day: `target.filling(from: source)` is written to `target`, after both
        /// originals are copied into the archive (`archive` for the target's, `sourceArchive`).
        case fillSummary(sourceArchive: String)
        /// State: the source side is newer. The target's file (if any, also one that appears
        /// after planning) goes to `archive`, then the source's file replaces it.
        case replaceState
        /// State: the source side is newer and lacks this target file. It moves to `archive`.
        case archiveTarget
        /// A backup folder the target lacks, copied whole with its `.jrc-host` stamp.
        case copyFolder
        case tail(Tail)

        /// The case name without its payload, the key `counts()` groups by.
        var name: String {
            switch self {
            case .copy: "copy"
            case .skipIdentical: "skipIdentical"
            case .archiveSource: "archiveSource"
            case .fillSummary: "fillSummary"
            case .replaceState: "replaceState"
            case .archiveTarget: "archiveTarget"
            case .copyFolder: "copyFolder"
            case .tail: "tail"
            }
        }
    }

    struct Step: Codable, Equatable, Sendable {
        var area: Area
        var action: Action
        /// Absolute paths. Empty for a tail step that needs none.
        var source: String
        var target: String
        var archive: String?
    }

    /// Workspace IDs.
    var source: String
    var target: String
    /// `yyyyMMdd-HHmmss`, local time.
    var stamp: String
    /// `<root>/_merged/<source path component>-<stamp>` (R9).
    var mergedFolder: String
    var steps: [Step]
    /// Top-level config keys whose values differ between the two config.yaml files (R5).
    var differingConfigKeys: [String]
    /// Source folders read from outside the source workspace (R10).
    var outsideSourceFolder: [String]
    /// Exclusion lists that held both workspaces when planned, which keep the target excluded
    /// (`mergingExclusion`): the policy's and, by label, each schedule's. Decided here so a
    /// step run twice leaves the same lists.
    /// Product logins the source names that the target lacks; the merge drops them (R5).
    var droppedConnections: [Connection] = []
    struct Connection: Codable, Equatable, Sendable {
        /// Product name as the sheet shows it.
        var product: String
        var profile: String
    }
    var keepTargetExcludedInPolicy = false
    var keepTargetExcludedInSchedules: [String] = []

    /// Where a summary's two originals are archived before a fill (`side`: "target" or
    /// "source"), so a fill the executor falls back to uses the plan's paths.
    static func summaryArchive(mergedFolder: String, side: String, name: String) -> URL {
        URL(fileURLWithPath: mergedFolder, isDirectory: true)
            .appendingPathComponent("archive/summaries/\(side)/\(name)")
    }

    /// A path the plan names lies outside the workspaces folder.
    struct ConfinementError: Error, LocalizedError, Equatable {
        let what: String
        var errorDescription: String? {
            L("The merge plan names a path outside the workspaces folder (\(what)); nothing was changed.")
        }
    }

    /// `path` as a URL when it is absolute, has no `..` and lies strictly below `base` (a
    /// component-wise check: `Jamf-Reports-evil` is not below `Jamf-Reports`), else nil.
    static func confined(_ path: String, under base: URL) -> URL? {
        guard path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let bases = [base.standardizedFileURL.path, base.resolvingSymlinksInPath().path]
        return bases.contains { url.path.hasPrefix($0 + "/") } ? url : nil
    }

    /// Every path the plan names, the one check before a step runs, a journal is retired or
    /// Start over moves files. No step names Application Support: per-Mac state steps (pin,
    /// schedules, policy) go through the executor's dependencies, never a plan path.
    func requireConfined(root: URL = ProfileService.workspacesRoot()) throws {
        guard Self.confined(mergedFolder, under: root.appendingPathComponent("_merged")) != nil
        else { throw ConfinementError(what: "merged folder") }
        for name in [source, target] {
            guard let folder = ProfileService.workspaceURL(for: name),
                  Self.confined(folder.path, under: root) != nil
            else { throw ConfinementError(what: "workspace folder") }
        }
        for (index, step) in steps.enumerated() {
            var paths = [step.source, step.target, step.archive ?? ""]
            if case .fillSummary(let sourceArchive) = step.action { paths.append(sourceArchive) }
            for path in paths where !path.isEmpty {
                guard Self.confined(path, under: root) != nil else {
                    throw ConfinementError(
                        what: "step \(index + 1), \(URL(fileURLWithPath: path).lastPathComponent)")
                }
            }
        }
    }

    /// How many steps of each action each area has, for the sheet. Tail steps are left out.
    func counts() -> [Area: [String: Int]] {
        var result: [Area: [String: Int]] = [:]
        for step in steps {
            if case .tail = step.action { continue }
            result[step.area, default: [:]][step.action.name, default: 0] += 1
        }
        return result
    }

    enum PlanError: Error, LocalizedError, Equatable {
        case noWorkspace(String)
        case sameWorkspace
        case unreadable(area: String, reason: String)

        var errorDescription: String? {
            switch self {
            case .noWorkspace(let name): "There is no workspace folder for \(name)."
            case .sameWorkspace: "A workspace cannot be merged into itself."
            case .unreadable(let area, let reason): "Cannot read \(area): \(reason)"
            }
        }
    }

    /// Lists both workspaces and decides each file. Hashes only names both sides hold.
    /// `root` is for tests: it must equal the workspaces root `WorkspacePaths` follows, since
    /// the subfolders come from there.
    static func make(
        source: String, target: String, now: Date = Date(),
        root: URL = ProfileService.workspacesRoot(),
        schedules: [ScheduleRecord] = ScheduleStore().load(),
        policy: AutomationPolicy = .current()
    ) throws -> WorkspaceMergePlan {
        guard let sourceID = WorkspaceID(source) else { throw PlanError.noWorkspace(source) }
        guard let targetID = WorkspaceID(target) else { throw PlanError.noWorkspace(target) }
        guard ProfileName.folderKey(source) != ProfileName.folderKey(target) else {
            throw PlanError.sameWorkspace
        }
        for id in [sourceID, targetID] {
            let folder = WorkspacePaths.workspaceURL(for: id, under: root)
            guard FileManager.default.fileExists(atPath: folder.path) else {
                throw PlanError.noWorkspace(id.name)
            }
            // A linked workspace folder would be moved as a link, leaving its data live.
            if FileManager.isLink(folder) {
                throw PlanError.unreadable(area: id.name, reason: "it is a symbolic link")
            }
        }
        let stamp = Self.stampFormatter.string(from: now)
        let merged = root.appendingPathComponent("_merged", isDirectory: true)
            .appendingPathComponent("\(sourceID.pathComponent)-\(stamp)", isDirectory: true)
        let sourceWS = WorkspacePaths.workspaceURL(for: sourceID, under: root)
        let targetWS = WorkspacePaths.workspaceURL(for: targetID, under: root)
        let builder = Builder(
            source: source, target: target, merged: merged.path)
        try builder.addAll(sourceWorkspace: sourceWS, targetWorkspace: targetWS)
        let tail = Tail.allCases.map {
            Step(area: .config, action: .tail($0), source: "", target: "")
        }
        return WorkspaceMergePlan(
            source: source, target: target, stamp: stamp, mergedFolder: merged.path,
            steps: builder.steps + tail,
            differingConfigKeys: try builder.differingKeys(source: sourceWS, target: targetWS),
            outsideSourceFolder: builder.outside,
            droppedConnections: Self.droppedConnections(source: source, target: target, root: root),
            keepTargetExcludedInPolicy: policy.excludedWorkspaces.excludesBoth(source, target),
            keepTargetExcludedInSchedules: schedules
                .filter { $0.excludedWorkspaces.excludesBoth(source, target) }.map(\.label))
    }

    /// The source's Protect, Security Cloud and School logins whose slot the target leaves blank;
    /// `platform` is what the merge moves and `jamf_pro` is the workspace itself.
    private static func droppedConnections(
        source: String, target: String, root: URL
    ) -> [Connection] {
        let from = EnvironmentProfiles.read(workspace: source, under: root)
        let to = EnvironmentProfiles.read(workspace: target, under: root)
        let slots: [(String, String?, String?)] = [
            ("Jamf Protect", from.protect, to.protect),
            ("Security Cloud", from.securityCloud, to.securityCloud),
            ("Jamf School", from.jamfSchool ?? from.foreignSchool, to.jamfSchool ?? to.foreignSchool),
        ]
        return slots.compactMap { product, name, existing in
            name.flatMap { existing == nil ? Connection(product: product, profile: $0) : nil }
        }
    }

    static var stampFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }
}

// MARK: - Listing and deciding

private final class Builder {
    let source: String
    let target: String
    let merged: String
    let archive: URL
    var steps: [WorkspaceMergePlan.Step] = []
    var outside: [String] = []

    typealias Area = WorkspaceMergePlan.Area

    init(source: String, target: String, merged: String) {
        self.source = source
        self.target = target
        self.merged = merged
        archive = URL(fileURLWithPath: merged, isDirectory: true).appendingPathComponent("archive")
    }

    func addAll(sourceWorkspace: URL, targetWorkspace: URL) throws {
        try wrap("snapshots") { try addSnapshots() }
        try wrap("state") { try addState() }
        try wrap("summaries") { try addSummaries() }
        try wrap("chart history") { try addChartHistory() }
        try wrap("sofa") { try addSOFA() }
        try wrap("run history") { try addRunHistory() }
        try wrap("backups") { try addBackups(sourceWorkspace, targetWorkspace) }
        try wrap("reports") { try addReports() }
        try noteOutside(sourceWorkspace)
    }

    private func wrap(_ area: String, _ body: () throws -> Void) throws {
        do { try body() } catch let error as WorkspaceMergePlan.PlanError {
            throw error
        } catch {
            throw WorkspaceMergePlan.PlanError.unreadable(
                area: area, reason: error.localizedDescription)
        }
    }

    // MARK: Areas

    private func addSnapshots() throws {
        let srcData = try WorkspacePaths.dataDir(for: source)
        let tgtData = try WorkspacePaths.dataDir(for: target)
        for kind in try Self.children(of: srcData, directories: true)
        where !(kind == "state" || kind == "sofa" || kind.hasPrefix("_") || kind.hasPrefix(".")) {
            let srcKind = srcData.appendingPathComponent(kind)
            try Self.requireNotLink(srcKind)
            let rels = try Self.children(of: srcKind, directories: false).map { "\(kind)/\($0)" }
            try addRule7(.snapshots, srcData, tgtData, rels)
        }
    }

    private func addState() throws {
        let srcDir = try WorkspacePaths.stateDir(for: source)
        let tgtDir = try WorkspacePaths.stateDir(for: target)
        let srcFiles = try Self.children(of: srcDir, directories: false)
        let tgtFiles = try Self.children(of: tgtDir, directories: false)
        let kinds = Set((srcFiles + tgtFiles).filter { $0.hasSuffix(".last") }
            .map { String($0.dropLast(".last".count)) })
        func kind(of name: String) -> String? {
            let prefix = String(name.prefix { $0 != "." })
            return kinds.contains(prefix) ? prefix : nil
        }
        var orphans: [String] = []
        for name in srcFiles where kind(of: name) == nil { orphans.append(name) }
        try addRule7(.state, srcDir, tgtDir, orphans)
        for kind in kinds.sorted() {
            let srcLast = StateFileStore(directory: srcDir).lastRun(report: kind)
            let tgtLast = StateFileStore(directory: tgtDir).lastRun(report: kind)
            guard let srcLast, tgtLast.map({ srcLast > $0 }) ?? true else { continue }
            let sourceNames = srcFiles.filter { Self.kindPrefix($0) == kind }
            for name in sourceNames {
                _ = try Self.requireTargetClear(tgtDir, name, area: .state)
                // Archive path named even when the target lacks the file: a collect may write
                // it before the step runs.
                steps.append(step(.state, .replaceState, srcDir, tgtDir, name, archived: true))
            }
            for name in tgtFiles
            where Self.kindPrefix(name) == kind && !sourceNames.contains(name) {
                steps.append(step(.state, .archiveTarget, srcDir, tgtDir, name, archived: true))
            }
        }
    }

    private func addSummaries() throws {
        let srcDir = try WorkspacePaths.summariesDir(for: source)
        let tgtDir = try WorkspacePaths.summariesDir(for: target)
        _ = try Self.children(of: tgtDir, directories: false)  // refuses a linked folder
        var others: [String] = []
        for name in try Self.children(of: srcDir, directories: false) {
            let isCanonical = CloudStorage.isCanonicalSummaryFilename(name)
            let inTarget = isCanonical
                ? try Self.requireTargetClear(tgtDir, name, area: .summaries) : false
            if isCanonical, inTarget {
                func archived(_ side: String) -> String {
                    WorkspaceMergePlan.summaryArchive(mergedFolder: merged, side: side, name: name)
                        .path
                }
                steps.append(.init(
                    area: .summaries,
                    action: .fillSummary(sourceArchive: archived("source")),
                    source: srcDir.appendingPathComponent(name).path,
                    target: tgtDir.appendingPathComponent(name).path,
                    archive: archived("target")))
            } else if isCanonical {
                steps.append(step(.summaries, .copy, srcDir, tgtDir, name))
            } else {
                others.append(name)
            }
        }
        try addRule7(.summaries, srcDir, tgtDir, others)
    }

    private func addChartHistory() throws {
        let srcDir = try WorkspacePaths.historicalDir(for: source)
        let tgtDir = try WorkspacePaths.historicalDir(for: target)
        let rels = try Self.recursive(srcDir).filter { !$0.hasPrefix("summaries/") }
        try addRule7(.chartHistory, srcDir, tgtDir, rels)
    }

    private func addSOFA() throws {
        let srcDir = try WorkspacePaths.dataDir(for: source).appendingPathComponent("sofa")
        let tgtDir = try WorkspacePaths.dataDir(for: target).appendingPathComponent("sofa")
        try addRule7(.sofa, srcDir, tgtDir, try Self.recursive(srcDir))
    }

    private func addRunHistory() throws {
        let srcLogs = try WorkspacePaths.runHistoryDir(for: source)
        let tgtLogs = try WorkspacePaths.runHistoryDir(for: target)
        try addRule7(.runHistory, srcLogs, tgtLogs, try Self.logsKept(srcLogs, tgtLogs),
                     archiveArea: "runHistory/logs")
        // Only the per-schedule status files; coordination files stay with the source (R6).
        let srcAuto = srcLogs.deletingLastPathComponent()
        let statuses = try Self.children(of: srcAuto, directories: false)
            .filter { $0.hasSuffix("_status.json") }
        try addRule7(.runHistory, srcAuto, tgtLogs.deletingLastPathComponent(), statuses,
                     archiveArea: "runHistory/status")
    }

    private func addBackups(_ srcWS: URL, _ tgtWS: URL) throws {
        let srcDir = try WorkspacePaths.confinedFolder(["backups"], under: srcWS)
        let tgtDir = try WorkspacePaths.confinedFolder(["backups"], under: tgtWS)
        let have = Set(try Self.children(of: tgtDir, directories: true))
        let copying = try Self.children(of: srcDir, directories: true)
            .filter { !$0.hasPrefix(".") && !have.contains($0) }
        // Scheduled backups past the newest `defaultKeepCount` of both folders together would
        // make the target's next prune delete its own; they stay in the moved source folder.
        // A name with no parseable stamp is never pruned by order, so it is copied.
        var pool: [(key: (Date, Int), name: String?)] = []
        var dropped = Set<String>()
        for (dir, names, fromSource) in [(tgtDir, Array(have), false), (srcDir, copying, true)] {
            for name in names where BackupMaintenance.isScheduledBackup(dir.appendingPathComponent(name)) {
                guard let stamp = CloudStorage.backupDirectoryTimestamp(name: name) else { continue }
                pool.append(((stamp.date, stamp.sequence), fromSource ? name : nil))
                if fromSource { dropped.insert(name) }
            }
        }
        dropped.subtract(pool.sorted { $0.key > $1.key }.prefix(BackupMaintenance.defaultKeepCount)
            .compactMap(\.name))
        for name in copying where !dropped.contains(name) {
            try Self.requireNotLink(srcDir.appendingPathComponent(name))
            steps.append(step(.backups, .copyFolder, srcDir, tgtDir, name))
        }
    }

    private func addReports() throws {
        guard let srcDir = WorkspacePaths.readableReportsDir(for: source) else {
            throw WorkspaceMergePlan.PlanError.unreadable(
                area: "reports", reason: "the source's reports folder was refused")
        }
        guard let tgtDir = WorkspacePaths.readableReportsDir(for: target) else {
            throw WorkspaceMergePlan.PlanError.unreadable(
                area: "reports", reason: "the target's reports folder was refused")
        }
        try addRule7(.reports, srcDir, tgtDir, try Self.recursive(srcDir))
    }

    private func noteOutside(_ workspace: URL) throws {
        let inside = workspace.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        var folders = [try WorkspacePaths.dataDir(for: source),
                       try WorkspacePaths.historicalDir(for: source)]
        if let reports = WorkspacePaths.readableReportsDir(for: source) {
            folders.append(reports)
        }
        for folder in folders {
            let path = folder.resolvingSymlinksInPath().standardizedFileURL.path
            if !(path + "/").hasPrefix(inside), !outside.contains(path) { outside.append(path) }
        }
    }

    func differingKeys(source sourceWS: URL, target targetWS: URL) throws -> [String] {
        func mapping(_ ws: URL) throws -> [String: Any] {
            let file = ws.appendingPathComponent("config.yaml")
            do {
                return try ConfigLoader.rawMapping(fromYAML: ConfigLoader.readText(at: file))
            } catch {
                throw WorkspaceMergePlan.PlanError.unreadable(
                    area: "config", reason: "\(ws.lastPathComponent)/config.yaml: "
                        + error.localizedDescription)
            }
        }
        func canonical(_ value: Any?) -> Data? {
            value.flatMap {
                try? JSONSerialization.data(withJSONObject: [$0], options: .sortedKeys)
            }
        }
        let src = try mapping(sourceWS), tgt = try mapping(targetWS)
        return Set(src.keys).union(tgt.keys)
            .filter {
                $0 != "profiles" && $0 != "jamf_cli" && canonical(src[$0]) != canonical(tgt[$0])
            }
            .sorted()
    }

    // MARK: Rules

    /// R7 for each relative path the source holds. `archiveArea` overrides the archive
    /// subfolder (default: the area name), so Run History's logs and status files stay apart.
    private func addRule7(
        _ area: Area, _ srcRoot: URL, _ tgtRoot: URL, _ rels: [String],
        archiveArea: String? = nil
    ) throws {
        for rel in rels {
            let src = srcRoot.appendingPathComponent(rel)
            let tgt = tgtRoot.appendingPathComponent(rel)
            let exists = try Self.requireTargetClear(tgtRoot, rel, area: area)
            guard exists else {
                steps.append(step(area, .copy, srcRoot, tgtRoot, rel, archived: true,
                                  archiveArea: archiveArea))
                continue
            }
            guard let a = BoundedFile.sha256Hex(src), let b = BoundedFile.sha256Hex(tgt) else {
                throw WorkspaceMergePlan.PlanError.unreadable(
                    area: area.rawValue, reason: "could not hash \(rel)")
            }
            steps.append(step(area, a == b ? .skipIdentical : .archiveSource,
                              srcRoot, tgtRoot, rel, archived: a != b, archiveArea: archiveArea))
        }
    }

    /// Refuses a link anywhere on the target path and a non-file at its end; true when a
    /// regular file is there. A copy must never write through a link.
    private static func requireTargetClear(_ root: URL, _ rel: String, area: Area) throws -> Bool {
        var current = root
        try requireNotLink(current)
        let parts = rel.split(separator: "/").map(String.init)
        for (index, part) in parts.enumerated() {
            current.appendPathComponent(part)
            try requireNotLink(current)
            if index == parts.count - 1, FileManager.default.fileExists(atPath: current.path),
               !isRegular(current) {
                throw WorkspaceMergePlan.PlanError.unreadable(
                    area: area.rawValue, reason: "\(rel) in the target is not a regular file")
            }
        }
        return isRegular(current)
    }

    /// `archived` puts the archive path under `<merged>/archive/<area>/<rel>` (R13). The
    /// `.archiveSource` and `.archiveTarget` actions name the file they archive there; `.copy`
    /// and `.replaceState` use it only when the target gained the file after planning.
    private func step(
        _ area: Area, _ action: WorkspaceMergePlan.Action, _ srcRoot: URL, _ tgtRoot: URL,
        _ rel: String, archived: Bool = false, archiveArea: String? = nil
    ) -> WorkspaceMergePlan.Step {
        .init(area: area, action: action,
              source: srcRoot.appendingPathComponent(rel).path,
              target: tgtRoot.appendingPathComponent(rel).path,
              archive: archived
                ? archive.appendingPathComponent(archiveArea ?? area.rawValue)
                    .appendingPathComponent(rel).path
                : nil)
    }

    // MARK: Listing

    /// The source's log files that are among the newest `ScheduledRunRecorder.maxRunLogs` of
    /// both folders together, by mtime as the recorder prunes. Copying older ones would make the
    /// target's next run prune its own logs; they stay in the moved source folder.
    private static func logsKept(_ srcLogs: URL, _ tgtLogs: URL) throws -> [String] {
        func dated(_ dir: URL, _ rels: [String], source: Bool) -> [(Date, String?)] {
            rels.map { rel in
                let file = dir.appendingPathComponent(rel)
                let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                return (date, source ? rel : nil)
            }
        }
        let recorderLogs = { (rels: [String]) in
            rels.filter { !$0.contains("/") && ScheduledRunRecorder.isRecorderLogName($0) }
        }
        let srcAll = try recursive(srcLogs)
        let pruned = dated(srcLogs, recorderLogs(srcAll), source: true)
            + dated(tgtLogs, recorderLogs(try recursive(tgtLogs)), source: false)
        let kept = Set(pruned.sorted { $0.0 > $1.0 }.prefix(ScheduledRunRecorder.maxRunLogs)
            .compactMap(\.1))
        // Files the recorder never prunes (other names, subfolders) are copied as before.
        let prunable = Set(recorderLogs(srcAll))
        return srcAll.filter { !prunable.contains($0) || kept.contains($0) }
    }

    private static func kindPrefix(_ name: String) -> String { String(name.prefix { $0 != "." }) }

    private static func isRegular(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }

    private static func requireNotLink(_ url: URL) throws {
        if FileManager.isLink(url) {
            throw WorkspaceMergePlan.PlanError.unreadable(
                area: url.lastPathComponent, reason: "it is a symbolic link")
        }
    }

    /// Names of the regular files (or real folders) directly in `dir`; empty when it is absent.
    private static func children(of dir: URL, directories: Bool) throws -> [String] {
        guard FileManager.default.fileExists(atPath: dir.path) || FileManager.isLink(dir) else {
            return []
        }
        try requireNotLink(dir)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        // Dot-files are staging leftovers and coordination files, never workspace data.
        return names.filter { !$0.hasPrefix(".") }.filter { name in
            let url = dir.appendingPathComponent(name)
            var info = stat()
            guard lstat(url.path, &info) == 0 else { return false }
            let type = info.st_mode & S_IFMT
            // A linked folder is listed so the caller refuses it rather than skipping it.
            return directories ? (type == S_IFDIR || type == S_IFLNK) : type == S_IFREG
        }.sorted()
    }

    /// Relative paths of every regular file below `dir`; a linked folder is refused.
    private static func recursive(_ dir: URL, prefix: String = "") throws -> [String] {
        var result: [String] = []
        for file in try children(of: dir, directories: false) { result.append(prefix + file) }
        for sub in try children(of: dir, directories: true) {
            result += try recursive(dir.appendingPathComponent(sub), prefix: "\(prefix)\(sub)/")
        }
        return result
    }
}
