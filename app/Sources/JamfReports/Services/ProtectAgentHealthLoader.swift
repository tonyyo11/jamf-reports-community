import Foundation

/// Reads the snapshots `ProtectAgentHealth` compares the computers with. Every consumer measures
/// against the collection time of the `protect-computers` snapshot it read, so a report opened a
/// week later shows what that collect saw.
enum ProtectAgentHealthLoader {

    struct Result: Sendable, Equatable {
        let health: ProtectAgentHealth
        /// The wave E kinds whose newest file is there but could not be read.
        let unreadableKinds: [String]
    }

    /// Nil with no computers. `computersFile` is the `protect-computers` file the rows came from.
    static func load(
        dataDir: URL, computers: [ProtectComputerRow], computersFile: URL?, clock: Date = Date()
    ) -> Result? {
        guard !computers.isEmpty else { return nil }
        // A peer's fast clock cannot move the 24-hour cutoff past this Mac's own time.
        guard let now = computersFile.flatMap({ CloudStorage.snapshotTimestamp(of: $0) })
            .map({ min($0, clock) }) else {
            return Result(
                health: .notEvaluated(computerCount: computers.count, reason: .noCollectionTime),
                unreadableKinds: [])
        }
        var unreadable: [String] = []
        let published = loadPublished(dataDir: dataDir, unreadable: &unreadable)
        let installer = loadInstaller(dataDir: dataDir, now: now, unreadable: &unreadable)
        return Result(
            health: ProtectAgentHealth.evaluate(
                computers: computers, published: published, installer: installer, now: now),
            unreadableKinds: unreadable)
    }

    private static func folder(_ dataDir: URL, _ kind: String) -> URL {
        dataDir.appendingPathComponent(kind, isDirectory: true)
    }

    static func loadPublished(
        dataDir: URL, unreadable: inout [String]
    ) -> ProtectAgentHealth.Input<[ProtectAgentHealth.PublishedSignature]> {
        let kind = ReportEngine.protectSignatureVersionsKind
        guard let file = FileManager.newestJSONFile(in: folder(dataDir, kind)) else {
            return .unavailable(.notCollected(kind: kind))
        }
        guard let data = BoundedFile.readSnapshotLogged(file),
              let list = decodePublished(data) else {
            unreadable.append(kind)
            return .unavailable(.unreadable(kind: kind))
        }
        return .value(list)
    }

    /// The saved rows: `id` a digit string or a whole number, `created` an ISO 8601 time; a row
    /// missing either is skipped. Nil for anything but an array.
    static func decodePublished(_ data: Data) -> [ProtectAgentHealth.PublishedSignature]? {
        guard let rows = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
            return nil
        }
        return rows.compactMap { item in
            guard let row = item as? [String: Any],
                  let created = (row["created"] as? String).flatMap(ISO8601Time.parse)
            else { return nil }
            let id: Int?
            if let text = row["id"] as? String {
                id = text.allSatisfy(\.isASCII) && text.allSatisfy(\.isNumber) ? Int(text) : nil
            } else if let number = row["id"] as? NSNumber,
                      CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue == number.doubleValue.rounded() {
                id = Int(exactly: number.doubleValue)
            } else {
                id = nil
            }
            return id.map { ProtectAgentHealth.PublishedSignature(id: $0, created: created) }
        }
    }

    static func loadInstaller(
        dataDir: URL, now: Date, unreadable: inout [String]
    ) -> ProtectAgentHealth.Input<ProtectAgentHealth.InstallerBaseline> {
        let kind = ReportEngine.protectInstallerKind
        let dir = folder(dataDir, kind)
        guard let newest = FileManager.newestJSONFile(in: dir) else {
            return .unavailable(.notCollected(kind: kind))
        }
        guard let data = BoundedFile.readSnapshotLogged(newest),
              let versions = installerVersions(data) else {
            unreadable.append(kind)
            return .unavailable(.unreadable(kind: kind))
        }
        guard let version = versions.first else { return .unavailable(.noInstallerVersion) }
        guard let parts = ProtectAgentHealth.dottedVersion(version) else {
            return .unavailable(.installerNotAVersion(version))
        }
        guard let firstSeen = firstSeen(parts, in: dir, now: now) else {
            return .unavailable(.firstSeenUnknown(version))
        }
        return .value(.init(version: version, firstSeen: firstSeen))
    }

    /// The `installerVersion` of each saved row; nil for anything but an array of objects.
    static func installerVersions(_ data: Data) -> [String]? {
        guard let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return nil
        }
        return rows.compactMap { $0["installerVersion"] as? String }
    }

    /// The filename stamp of the oldest snapshot holding `version`, a stamp later than `now`
    /// read as `now`. Files with no stamp are skipped (a sync provider rewrites modification
    /// times), and so is one that cannot be read. Only the newest `maxInstallerFiles` are read,
    /// oldest first; nil when none of them holds the version, never a guessed date.
    static func firstSeen(_ version: [Int], in dir: URL, now: Date) -> Date? {
        let stamped = (FileManager.snapshotFolderEntries(in: dir) ?? [])
            .filter { FileManager.isSelectableSnapshot($0) && $0.pathExtension == "json" }
            .compactMap { url in CloudStorage.snapshotTimestamp(of: url).map { (url, $0) } }
            .sorted { FileManager.isOlderSnapshot($0.0, than: $1.0) }
        for (url, stamp) in stamped.suffix(ProtectAgentHealth.maxInstallerFiles) {
            guard let data = BoundedFile.readSnapshotLogged(url),
                  let versions = installerVersions(data) else { continue }
            let matches = versions.contains {
                ProtectAgentHealth.dottedVersion($0).map {
                    !ProtectAgentHealth.isLower($0, than: version)
                        && !ProtectAgentHealth.isLower(version, than: $0)
                } ?? false
            }
            if matches { return min(stamp, now) }
        }
        return nil
    }
}
