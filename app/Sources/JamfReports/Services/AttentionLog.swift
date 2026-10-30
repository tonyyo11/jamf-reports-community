import Foundation
import os

/// The attention items one run raises and clears (2.11), kept in status files so the app can
/// point an admin at them. Bound to the running task (`current`), so an emit site deep in the
/// engine records through `raise`/`clear` beside its `[warn]` line with no recorder of its own.
///
/// A commit merges the run's changes into the workspace's open set (the `attention` array of the
/// status file in `automation/` written last, by `attention_at`) and writes the result into the
/// run's own status file, else into the app record (`WorkspaceStore.appCollectRunLabel`'s).
/// It never creates `automation/`, so a workspace a run refused before recording is not written.
final class AttentionLog: Sendable {
    @TaskLocal static var current: AttentionLog?

    /// The run's own status file and the name of its Run History log.
    struct Record: Sendable {
        let statusURL: URL
        let runLog: String?
    }

    private struct State: Sendable {
        var changes: [AttentionCode: AttentionChange] = [:]
        var record: Record?
    }

    let profile: String
    /// Without a record of its own, commit into the app record; false for a scheduled run,
    /// which records only once its recorder exists.
    let usesAppRecord: Bool
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(profile: String, usesAppRecord: Bool) {
        self.profile = profile
        self.usesAppRecord = usesAppRecord
    }

    var changes: [AttentionCode: AttentionChange] { state.withLock { $0.changes } }

    /// Commit into this run's status file, naming its log for Run History.
    func record(into statusURL: URL, runLog: String?) {
        state.withLock { $0.record = Record(statusURL: statusURL, runLog: runLog) }
    }

    /// Records `code` for the current run, beside its `[warn]` line. A no-op outside a run.
    static func raise(_ code: AttentionCode, _ message: String) {
        guard let log = current else { return }
        let clean = AttentionItem.sanitized(message, profile: log.profile)
        log.state.withLock { $0.changes[code] = .raised(clean) }
    }

    /// The check behind `codes` ran and passed.
    static func clear(_ codes: AttentionCode...) {
        guard let log = current else { return }
        log.state.withLock { state in
            for code in codes { state.changes[code] = .cleared }
        }
    }

    /// Runs `body` with a log for `profile` bound, then commits it. Inside a run already
    /// recording for `profile`, `body` joins that run instead.
    static func recording<T: Sendable>(
        profile: String,
        usesAppRecord: Bool = true,
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> T
    ) async rethrows -> T {
        if current?.profile == profile { return try await body() }
        let log = AttentionLog(profile: profile, usesAppRecord: usesAppRecord)
        defer { log.commit() }
        return try await $current.withValue(log, operation: body)
    }

    /// Writes this run's changes; nothing when there are none or nowhere to write them.
    func commit(now: Date = Date()) {
        let (changes, record) = state.withLock { ($0.changes, $0.record) }
        guard !changes.isEmpty, let workspace = ProfileService.workspaceURL(for: profile),
              let folder = Self.existingAutomationFolder(in: workspace) else { return }
        guard let target = record?.statusURL ?? (usesAppRecord
            ? folder.appendingPathComponent("\(WorkspaceStore.appCollectRunLabel)_status.json")
            : nil) else { return }
        let newest = Self.newestRecord(inFolder: folder)
        let merged = AttentionItem.merging(
            newest?.items ?? [], changes, profile: profile, runLog: record?.runLog, now: now)
        // Stamped after the set it merged, so a peer whose clock runs ahead cannot make this
        // commit read as older and lose it.
        let at = max(now.timeIntervalSince1970, (newest?.at ?? 0) + 0.001)
        Self.write(merged, at: at, into: target)
    }

    // MARK: - Reading

    /// `profile`'s open items, as the status file that recorded attention last holds them.
    static func openItems(profile: String) -> [AttentionItem] {
        guard let workspace = ProfileService.workspaceURL(for: profile),
              let folder = existingAutomationFolder(in: workspace) else { return [] }
        return openItems(inFolder: folder).filter { $0.profile == profile }
    }

    static func openItems(inFolder folder: URL) -> [AttentionItem] {
        newestRecord(inFolder: folder)?.items ?? []
    }

    private static func newestRecord(
        inFolder folder: URL
    ) -> (at: Double, items: [AttentionItem])? {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return files.filter { $0.lastPathComponent.hasSuffix("_status.json") }
            .compactMap(stored(in:))
            .max { $0.at < $1.at }
    }

    /// The `attention` keys of the status file at `url`, for a rewrite to carry over.
    static func storedKeys(in url: URL) -> [String: Any] {
        guard let data = try? BoundedFile.read(
                  url, limit: BoundedFile.documentLimit, followSymlinks: false),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return json.filter { [attentionKey, attentionAtKey].contains($0.key) }
    }

    /// The latest `attention_at` a record may carry (the year 3000). A peer that planted a
    /// later one would otherwise stay newest for good: no later commit could pass it.
    static let maxAttentionAt: Double = 32_503_680_000

    private static let attentionKey = "attention"
    private static let attentionAtKey = "attention_at"

    /// Decodes the attention keys leniently: a file without them is no record, and an item a
    /// newer build wrote with a code this one does not know is left out.
    private struct Stored: Decodable {
        let attention: [Lossy]?
        let attentionAt: Double?

        enum CodingKeys: String, CodingKey {
            case attention
            case attentionAt = "attention_at"
        }
    }

    private struct Lossy: Decodable {
        let item: AttentionItem?
        init(from decoder: any Decoder) throws { item = try? AttentionItem(from: decoder) }
    }

    private static func stored(in url: URL) -> (at: Double, items: [AttentionItem])? {
        guard let data = try? BoundedFile.read(
                  url, limit: BoundedFile.documentLimit, followSymlinks: false) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let stored = try? decoder.decode(Stored.self, from: data),
              let at = stored.attentionAt, at <= maxAttentionAt, let items = stored.attention
        else { return nil }
        return (at, items.compactMap { $0.item?.clampingCount() })
    }

    // MARK: - Writing

    private static func write(_ items: [AttentionItem], at: Double, into target: URL) {
        var payload: [String: Any] = [
            "label": String(target.lastPathComponent.dropLast("_status.json".count)),
        ]
        if let data = try? BoundedFile.read(
               target, limit: BoundedFile.documentLimit, followSymlinks: false),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            payload = existing
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            payload[attentionKey] = try JSONSerialization.jsonObject(
                with: encoder.encode(items))
            payload[attentionAtKey] = at
            try ScheduledRunRecorder.replaceStatusFile(at: target, with: payload)
        } catch {
            AppLogger.schedule.error(
                """
                AttentionLog: could not write \(target.lastPathComponent, privacy: .private): \
                \(error.localizedDescription, privacy: .private)
                """)
        }
    }

    /// `automation/` when it exists and is not a link; never created here.
    private static func existingAutomationFolder(in workspace: URL) -> URL? {
        guard let folder = try? WorkspacePaths.confinedFolder(["automation"], under: workspace)
        else { return nil }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory)
            && isDirectory.boolValue ? folder : nil
    }
}
