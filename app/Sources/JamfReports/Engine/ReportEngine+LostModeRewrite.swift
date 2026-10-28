import Foundation

extension ReportEngine {

    /// In the `state` folder; present once a workspace's mobile snapshots have been rewritten.
    static let lostModeRewriteMarker = "lost-mode-rewrite.done"

    /// Snapshots written before 2.11 still hold the lost-mode text `saveCollectedPayload` now
    /// drops, and the folder can sit in a shared workspace. Rewrites each such snapshot in place,
    /// once per workspace, with the reducer collect uses. Not a source: it records no failure and
    /// logs no `[partial]`. A refused `state` or kind folder warns and skips, so nothing is
    /// marked done; a failed write leaves the marker unwritten so the next collect retries.
    static func rewriteLostModeTextOnce(
        dataDir: URL, now: Date = Date(),
        onLine: @Sendable (CLIBridge.LogLine) -> Void
    ) {
        guard let stateDir = WorkspacePaths.confinedFolderOrWarn(
            ["state"], under: dataDir, onLine: onLine) else { return }
        let marker = stateDir.appendingPathComponent(lostModeRewriteMarker)
        guard BoundedFile.stateText(marker) == nil else { return }
        guard let dir = WorkspacePaths.confinedFolderOrWarn(
            [MobileFleetService.deviceKind], under: dataDir, onLine: onLine) else { return }

        let result = rewriteLostModeText(in: dir)
        if !result.unreadable.isEmpty {
            let names = result.unreadable.sorted()
            let shown = names.prefix(10).joined(separator: ", ")
            let more = names.count > 10 ? " and \(names.count - 10) more" : ""
            onLine(.init(timestamp: Date(), level: .warn,
                text: "[warn] lost-mode text not checked in \(result.unreadable.count) mobile "
                    + "device snapshot(s) that are not readable JSON: \(shown)\(more)"))
        }
        guard result.writeFailures == 0 else { return }
        do {
            try FileManager.default.createDirectory(
                at: stateDir, withIntermediateDirectories: true)
            try Data(SummaryJSONParser.dateFormatter.string(from: now).utf8)
                .write(to: marker, options: .atomic)
        } catch {
            onLine(.init(timestamp: Date(), level: .warn,
                text: "[warn] lost-mode rewrite marker not written: "
                    + "\(error.localizedDescription)"))
        }
        if result.rewritten > 0 {
            onLine(.init(timestamp: Date(), level: .info,
                text: "[info] removed lost-mode text from \(result.rewritten) mobile device "
                    + "snapshots"))
        }
    }

    private static func rewriteLostModeText(
        in dir: URL
    ) -> (rewritten: Int, unreadable: [String], writeFailures: Int) {
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.pathExtension.lowercased() == "json" }
        var rewritten = 0, writeFailures = 0
        var unreadable: [String] = []
        for file in files {
            guard let data = try? BoundedFile.read(
                    file, limit: BoundedFile.snapshotLimit, followSymlinks: false, inside: dir),
                  let stripped = droppingLostModeText(data) else {
                unreadable.append(file.lastPathComponent)
                continue
            }
            if stripped == data { continue }
            do {
                // Atomic (temp file + rename), as saveSnapshot: a crash never tears a snapshot.
                try stripped.write(to: file, options: .atomic)
                try? FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: file.path)
                rewritten += 1
            } catch {
                writeFailures += 1
                continue
            }
            // Only an existing entry is refreshed: stamping an unlisted file would vouch for it.
            if SnapshotManifest.lists(file) {
                try? SnapshotManifest.record(snapshotFile: file, data: stripped)
            }
        }
        return (rewritten, unreadable, writeFailures)
    }
}
