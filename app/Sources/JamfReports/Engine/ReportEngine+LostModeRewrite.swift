import Foundation

extension ReportEngine {

    /// In the `state` folder; present once a workspace's mobile snapshots have been rewritten.
    static let lostModeRewriteMarker = "lost-mode-rewrite.done"

    /// Both kinds can hold the text: `mobile-device-inventory-details` is the legacy inventory
    /// snapshot, whose SECURITY section is the same Jamf Pro record. No reader in the app names
    /// the four keys, so their spelling is the one `lostModeTextKeys` already removes.
    private static let lostModeKinds = [MobileFleetService.deviceKind,
                                        MobileFleetService.legacyInventoryKind]

    private struct LostModeTally {
        var rewritten = 0
        var unparsable: [String] = []
        var unreadable: [String] = []
        var writeFailed: [String] = []
        var folderFailed = false

        /// A file that cannot be parsed or can never be read (too large, not regular, a link)
        /// is final: the next pass would fail the same way. Everything else may succeed on a retry.
        var isComplete: Bool {
            unreadable.isEmpty && writeFailed.isEmpty && !folderFailed
        }
    }

    /// Collect's entry: resolves the workspace's data and archive folders, then runs the pass.
    static func rewriteLostModeTextOnce(
        profile: String, workspacePaths: WorkspacePaths.Type,
        onLine: @Sendable (CLIBridge.LogLine) -> Void
    ) {
        guard let dataDir = try? workspacePaths.dataDir(for: profile) else { return }
        var archive: URL?
        if let workspace = ProfileService.workspaceURL(for: profile) {
            let config = SharedConfigPin.effectiveRetention(
                SnapshotRetentionService.loadRetentionConfig(workspace: workspace),
                check: SharedConfigPin.check(profile: profile))
            archive = lostModeArchiveRoot(config: config, workspace: workspace, onLine: onLine)
        }
        rewriteLostModeTextOnce(dataDir: dataDir, archiveRoot: archive, onLine: onLine)
    }

    /// The root the retention sweep archives into (`resolvedArchiveRoot`, which falls back to
    /// `_archive` for a refused `archive_dir`), when it resolves inside the workspace;
    /// otherwise nil with one `[warn]`, because a folder outside it is not ours to rewrite.
    static func lostModeArchiveRoot(
        config: RetentionConfig?, workspace: URL,
        onLine: @Sendable (CLIBridge.LogLine) -> Void
    ) -> URL? {
        let base = workspace.resolvingSymlinksInPath().standardizedFileURL
        let root = SnapshotRetentionService.resolvedArchiveRoot(
            config: config, workspace: workspace, onLine: onLine)
        let resolved = root.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path == base.path || resolved.path.hasPrefix(base.path + "/") else {
            warnNotSwept("it is outside the workspace", onLine)
            return nil
        }
        return resolved
    }

    private static func warnNotSwept(
        _ why: String, _ onLine: @Sendable (CLIBridge.LogLine) -> Void
    ) {
        onLine(.init(timestamp: Date(), level: .warn,
            text: "[warn] lost-mode rewrite: the snapshot archive was not checked because "
                + "\(why); old mobile snapshots there may still hold lost-mode text"))
    }

    /// Snapshots written before 2.11 still hold the lost-mode text `saveCollectedPayload` now
    /// drops, and the folder can sit in a shared workspace. Rewrites each such snapshot in place,
    /// once per workspace, with the reducer collect uses. Not a source: it records no failure and
    /// logs no `[partial]`. The marker is written only when no file was unreadable or failed to
    /// write and no folder was refused or unlistable; those retry on the next collect. A file
    /// that is not JSON is warned about and not retried. The file's mtime changes and a link
    /// swapped in after the folder check is not caught, as in `saveSnapshot`. The stamp-before-
    /// write ordering assumes `JSONSerialization` with sorted keys gives the same bytes on the
    /// next pass; a peer Mac on another macOS that formats doubles differently would leave a
    /// permanent `.mismatch`. After a crash between the stamp and the write, a generate with no
    /// collect in between refuses on that file until the next collect repairs it.
    static func rewriteLostModeTextOnce(
        dataDir: URL, archiveRoot: URL?, now: Date = Date(),
        limit: Int = BoundedFile.inventoryLimit,
        onLine: @Sendable (CLIBridge.LogLine) -> Void
    ) {
        guard let stateDir = WorkspacePaths.confinedFolderOrWarn(
            ["state"], under: dataDir, onLine: onLine) else { return }
        let marker = stateDir.appendingPathComponent(lostModeRewriteMarker)
        guard BoundedFile.stateText(marker) == nil else { return }

        var tally = LostModeTally()
        for kind in lostModeKinds {
            if let dir = WorkspacePaths.confinedFolderOrWarn(
                [kind], under: dataDir, onLine: onLine) {
                rewriteLostModeFolder(dir, label: kind, limit: limit, tally: &tally)
            } else {
                tally.folderFailed = true
            }
            guard let archiveRoot else { continue }
            do {
                let dir = try WorkspacePaths.confinedFolder(
                    ["jamf-cli-data", kind], under: archiveRoot)
                rewriteLostModeFolder(dir, label: "archive/\(kind)", limit: limit, tally: &tally)
            } catch {
                tally.folderFailed = true
                onLine(.init(timestamp: Date(), level: .warn,
                    text: "[warn] lost-mode rewrite: archive/\(kind) is not used: "
                        + "\(WorkspacePaths.refusal(of: error))"))
            }
        }
        report(tally, onLine)
        guard tally.isComplete else { return }
        do {
            try FileManager.default.createDirectory(
                at: stateDir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try Data(SummaryJSONParser.dateFormatter.string(from: now).utf8)
                .write(to: marker, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: marker.path)
        } catch {
            onLine(.init(timestamp: Date(), level: .warn,
                text: "[warn] lost-mode rewrite marker not written: "
                    + "\(error.localizedDescription)"))
        }
    }

    private static func report(
        _ tally: LostModeTally, _ onLine: @Sendable (CLIBridge.LogLine) -> Void
    ) {
        func warn(_ names: [String], _ what: String) {
            guard !names.isEmpty else { return }
            // File names are peer-chosen: displayText strips line breaks that could forge a line.
            let shown = names.sorted().prefix(10).map(ConfigSchema.displayText)
                .joined(separator: ", ")
            let more = names.count > 10 ? " and \(names.count - 10) more" : ""
            onLine(.init(timestamp: Date(), level: .warn,
                text: "[warn] lost-mode rewrite: \(names.count) mobile device snapshot(s) "
                    + "\(what): \(shown)\(more)"))
        }
        warn(tally.unparsable, "cannot be read or parsed and may still contain lost-mode "
            + "text; delete or replace them (they are rechecked only while another failure "
            + "keeps this pass from finishing)")
        warn(tally.unreadable, "could not be read; will retry on the next collect")
        warn(tally.writeFailed, "could not be rewritten; will retry on the next collect")
        if tally.rewritten > 0 {
            onLine(.init(timestamp: Date(), level: .info,
                text: "[info] removed lost-mode text from \(tally.rewritten) mobile device "
                    + "snapshots"))
        }
    }

    private static func isPermanentReadFailure(_ error: Error) -> Bool {
        guard let failure = error as? BoundedFile.Failure else { return false }
        switch failure {
        case .tooLarge, .notRegular: return true
        case .unreadable(let code): return code == ELOOP || code == EMLINK
        }
    }

    private static func rewriteLostModeFolder(
        _ dir: URL, label: String, limit: Int, tally: inout LostModeTally
    ) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory) else {
            return
        }
        guard isDirectory.boolValue,
              let listed = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            tally.folderFailed = true
            return
        }
        let manifest = SnapshotManifest.entries(in: dir)
        // manifest.json holds hashes only; the rest are snapshots and their sync-conflict copies.
        let files = listed.filter {
            $0.pathExtension.lowercased() == "json"
                && $0.lastPathComponent != SnapshotManifest.fileName
        }
        for file in files {
            let name = "\(label)/\(file.lastPathComponent)"
            let data: Data
            do {
                data = try BoundedFile.read(file, limit: limit, followSymlinks: false, inside: dir)
            } catch {
                if isPermanentReadFailure(error) {
                    tally.unparsable.append(name)
                } else {
                    tally.unreadable.append(name)
                }
                continue
            }
            guard let stripped = droppingLostModeText(data, sortedKeys: true) else {
                tally.unparsable.append(name)
                continue
            }
            if stripped == data { continue }
            // Stamp the stripped hash BEFORE the write, and only when the original bytes verify:
            // a tampered file stays a mismatch, and a crash between the two leaves an entry the
            // next pass reproduces exactly (the bytes are key-sorted), so it is never left stale.
            let restamp = manifest[file.lastPathComponent]?.lowercased()
                == SnapshotManifest.sha256Hex(data)
            if restamp, (try? SnapshotManifest.record(snapshotFile: file, data: stripped)) == nil {
                tally.writeFailed.append(name)
                continue
            }
            do {
                // Atomic (temp file + rename), as saveSnapshot: a crash never tears a snapshot.
                try stripped.write(to: file, options: .atomic)
                try? FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: file.path)
                tally.rewritten += 1
            } catch {
                tally.writeFailed.append(name)
                if restamp { try? SnapshotManifest.record(snapshotFile: file, data: data) }
            }
        }
    }
}
