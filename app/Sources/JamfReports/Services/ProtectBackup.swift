import Foundation

/// How one product's part of a backup ended, as `manifest.json` records it under
/// `products.<product>`. A manifest written before Protect joined backups has no `products`
/// key and reads as nil.
struct BackupProductResult: Sendable, Hashable {
    enum State: String, Sendable, Hashable {
        case ok, partial, failed
        /// Not attempted; `reason` says why.
        case skipped
    }

    var state: State
    var exitCode: Int32?
    var reason: String?
    /// Files per resource folder (a document at the top level counts as one object).
    var objectCounts: [String: Int] = [:]
    /// True when jamf-cli left a `_failures.yaml` naming the resources it could not export.
    var hasFailuresFile = false

    /// A Protect part that did not come out whole.
    var isIncomplete: Bool { state == .partial || state == .failed }

    /// Partial only because a clean run exported nothing (a tenant with nothing to export).
    var isEmptyExport: Bool {
        state == .partial && exitCode == 0 && !hasFailuresFile && objectCounts.isEmpty
    }

    /// Retention keeps this backup: its Protect part failed or lost resources. An empty export
    /// is not kept, or every scheduled backup of an empty tenant would stay forever.
    var keepsBackupFromPruning: Bool { isIncomplete && !isEmptyExport }

    /// A Protect part that releases older incomplete ones for pruning.
    var isComplete: Bool { state == .ok || isEmptyExport }

    var objectTotal: Int { objectCounts.values.reduce(0, +) }

    /// For a Jamf Pro result: the backup holds no Jamf Pro files, because the part failed or the
    /// operator has not allowed it on this storage.
    var leavesNoJamfProBackup: Bool { state == .failed || state == .skipped }

    /// A count a manifest may hold: a whole number from 0 to `Int32.max`, as the Platform count
    /// checks read one. `manifest.json` sits in a folder a peer can write, and a larger value
    /// would trap `objectTotal`'s sum.
    static func manifestCounts(_ raw: Any?) -> [String: Int] {
        (raw as? [String: Any] ?? [:]).compactMapValues { value in
            guard let count = value as? Int, (0...Int(Int32.max)).contains(count) else { return nil }
            return count
        }
    }

    /// One sentence for the Backups screen about this Jamf Protect part.
    var protectSummary: String {
        let counts = objectCounts.sorted { $0.key < $1.key }
            .map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        let found = "\(objectTotal) object\(objectTotal == 1 ? "" : "s")"
            + (counts.isEmpty ? "" : " (\(counts))")
        if isEmptyExport { return "The latest backup includes Jamf Protect: it has no objects." }
        switch state {
        case .ok:
            return "The latest backup includes Jamf Protect: \(found)."
        case .partial:
            return "The latest backup's Jamf Protect part is incomplete: \(found) saved. "
                + (hasFailuresFile
                    ? "Resources that failed are listed in "
                        + "\(ProtectBackup.folderName)/\(ProtectBackup.failuresFileName) "
                        + "in the backup folder. "
                    : "")
                + "It is kept until a later backup's Jamf Protect part completes."
        case .failed:
            let code = exitCode.map { " (exit \($0))" } ?? ""
            return "The latest backup has no Jamf Protect part: the Protect backup failed\(code). "
                + "It is kept until a later backup's Jamf Protect part completes."
        case .skipped:
            return "Jamf Protect was not backed up: \(reason ?? "skipped")."
        }
    }

    var manifestValue: [String: Any] {
        var value: [String: Any] = ["state": state.rawValue]
        if let exitCode { value["exit_code"] = Int(exitCode) }
        if let reason { value["reason"] = reason }
        if !objectCounts.isEmpty { value["object_counts"] = objectCounts }
        if hasFailuresFile { value["failures_file"] = ProtectBackup.failuresFileName }
        return value
    }

    init(state: State, exitCode: Int32? = nil, reason: String? = nil,
         objectCounts: [String: Int] = [:], hasFailuresFile: Bool = false) {
        self.state = state
        self.exitCode = exitCode
        self.reason = reason
        self.objectCounts = objectCounts
        self.hasFailuresFile = hasFailuresFile
    }

    init?(manifestValue: Any?) {
        guard let object = manifestValue as? [String: Any],
              let raw = object["state"] as? String, let state = State(rawValue: raw)
        else { return nil }
        self.init(
            state: state,
            exitCode: (object["exit_code"] as? Int).map { Int32(clamping: $0) },
            reason: object["reason"] as? String,
            objectCounts: Self.manifestCounts(object["object_counts"]),
            hasFailuresFile: object["failures_file"] is String)
    }

    /// The Protect result in a decoded `manifest.json`, or nil for a backup without one.
    static func protect(inManifest manifest: [String: Any]) -> BackupProductResult? {
        BackupProductResult(
            manifestValue: (manifest["products"] as? [String: Any])?["protect"])
    }

    /// The Protect result recorded in `backupDir`'s manifest, or nil.
    static func protect(inBackup backupDir: URL) -> BackupProductResult? {
        manifest(inBackup: backupDir).flatMap(protect(inManifest:))
    }

    /// The Jamf Pro result recorded in `backupDir`'s manifest, or nil (no Protect connected,
    /// or a backup from before 2.11, both of which hold a Jamf Pro backup).
    static func pro(inBackup backupDir: URL) -> BackupProductResult? {
        manifest(inBackup: backupDir).flatMap(pro(inManifest:))
    }

    /// The Jamf Pro result in a decoded `manifest.json`, or nil.
    static func pro(inManifest manifest: [String: Any]) -> BackupProductResult? {
        BackupProductResult(manifestValue: (manifest["products"] as? [String: Any])?["pro"])
    }

    private static func manifest(inBackup backupDir: URL) -> [String: Any]? {
        guard let data = try? BoundedFile.read(
                backupDir.appendingPathComponent("manifest.json"),
                limit: BoundedFile.documentLimit, followSymlinks: false)
        else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

/// `jamf-cli protect backup`, added to every backup of a Jamf Pro workspace that has Protect
/// connected. The files go in the same staging folder as `pro backup`, under `protect/`.
enum ProtectBackup {
    static let folderName = "protect"
    static let failuresFileName = "_failures.yaml"

    /// Limit on one `protect backup`; the same as `pro backup`'s (`CLIBridge.backupTimeout`).
    nonisolated static let timeout: TimeInterval = CLIBridge.backupTimeout

    /// `--output` is the command's destination directory; the global `-o` does not apply.
    static func arguments(profile: String, outputDirectory: String) -> [String] {
        ["-p", profile, "--no-input", "protect", "backup", "--output", outputDirectory]
    }

    enum Plan: Equatable {
        /// Protect is not connected to this workspace: the backup is exactly as before.
        case notConnected
        case run(profile: String)
        case skip(reason: String)
    }

    /// Decides whether this backup includes Protect. The pin and storage checks are closures
    /// so a workspace without Protect never evaluates them (the pin check records a first
    /// sight on a shared workspace). `syncedStorageAllowed` is asked only on shared storage:
    /// `protect.backup_on_synced_storage` as this Mac may use it.
    static func plan(
        config: ReportConfig?,
        workspaceProfile: String,
        pinAllows: () -> Bool,
        protectRefusal: (String) -> String? = { _ in nil },
        sharedStorage: () -> String?,
        syncedStorageAllowed: () -> Bool = { false }
    ) -> Plan {
        let environment = EnvironmentProfiles.resolve(config: config, workspace: workspaceProfile)
        guard !environment.isSchool, environment.runsProtect else { return .notConnected }
        let key = environment.protectKey
        guard pinAllows() else {
            return .skip(reason: "\(key) changed in the shared config.yaml and is not "
                + "confirmed on this Mac (Config Doctor)")
        }
        guard let protectProfile = environment.protect else {
            return .skip(reason: "protect.enabled is set but protect.profile is empty")
        }
        guard ProfileService.isValid(protectProfile) else {
            return .skip(reason: "\(key) is not a usable jamf-cli profile name")
        }
        if let refusal = protectRefusal(protectProfile) { return .skip(reason: refusal) }
        if let place = sharedStorage(), !syncedStorageAllowed() {
            return .skip(reason: syncedStorageReason(place: place))
        }
        return .run(profile: protectProfile)
    }

    /// The concern and how to allow it; the organization's storage policy decides, not the app.
    static func syncedStorageReason(place: String) -> String {
        "this workspace is \(place), and a Protect backup contains action configurations with "
            + "request headers and data-forwarding settings. If your organization's storage "
            + "policy allows it, turn on Protect backups for this folder in Backups "
            + "(\(SharedConfigPin.Key.protectBackupOnSyncedStorage.rawValue))"
    }

    /// Where a Protect-connected workspace's backups sit on storage other Macs reach, and
    /// whether this Mac backs Protect up there. Nil when Protect is not connected or the
    /// storage is local. Probes the volume, so call it off the main actor.
    struct SyncedStorageChoice: Sendable, Equatable {
        let place: String
        let allowed: Bool
    }

    static func syncedStorageChoice(
        profile: String, config: ReportConfig?, appSupport: URL = AppSupport.directory()
    ) -> SyncedStorageChoice? {
        let detected = ProfileProductType.detect(from: config, profile: profile)
        guard detected.type == .jamfPro, detected.runsProtect,
              let workspace = ProfileService.workspaceURL(for: profile),
              let place = BackupMaintenance.sharedStorageDescription(
                workspace.appendingPathComponent("backups", isDirectory: true),
                profile: profile, volumeIsLocal: CloudStorage.isOnLocalVolume,
                pinnedIsShared: true)
        else { return nil }
        return SyncedStorageChoice(
            place: place,
            allowed: SharedConfigPin.protectBackupOnSyncedStorage(
                config?.protect?.backsUpOnSyncedStorage ?? false,
                profile: profile, appSupport: appSupport))
    }

    /// Classifies a finished `protect backup` from its exit code and what it left in
    /// `directory`. A resource that failed to export is listed in `_failures.yaml` while the
    /// run continues, and the exit is non-zero, so partial needs files as well as a failure.
    static func result(
        exit: Int32, directory: URL, fileManager: FileManager = .default
    ) -> BackupProductResult {
        let counts = objectCounts(in: directory, fileManager: fileManager)
        let failures = fileManager.fileExists(
            atPath: directory.appendingPathComponent(failuresFileName).path)
        let state: BackupProductResult.State
        var reason: String?
        if exit == CLIBridge.exitCodeTimedOut {
            state = .failed
        } else if exit == 0 {
            // An empty or unreadable folder after a clean exit is not a backup (counts read
            // as empty when the folder cannot be listed).
            if counts.isEmpty { reason = "no objects exported" }
            state = failures || counts.isEmpty ? .partial : .ok
        } else if (exit == CLIBridge.exitCodePartialFailure || failures), !counts.isEmpty {
            state = .partial
        } else {
            state = .failed
        }
        // A failed run's files are discarded, so the record claims none.
        return BackupProductResult(
            state: state, exitCode: exit, reason: reason,
            objectCounts: state == .failed ? [:] : counts,
            hasFailuresFile: state != .failed && failures)
    }

    /// Files per top-level resource folder; a document at the top level counts as one object
    /// under its name. Names starting with `_` or `.` (`_failures.yaml`, `_meta`) are not
    /// resources.
    static func objectCounts(
        in directory: URL, fileManager: FileManager = .default
    ) -> [String: Int] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return [:] }
        var counts: [String: Int] = [:]
        for entry in entries where !entry.lastPathComponent.hasPrefix("_") {
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values?.isDirectory == true {
                let files = fileManager.enumerator(
                    at: entry, includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles])?
                    .compactMap { $0 as? URL }
                    .filter {
                        (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?
                            .isRegularFile == true
                    }.count ?? 0
                if files > 0 { counts[entry.lastPathComponent] = files }
            } else if values?.isRegularFile == true {
                counts[entry.deletingPathExtension().lastPathComponent] = 1
            }
        }
        return counts
    }
}

extension CLIBridge {
    /// Backs up Protect into `<staging>/protect` when the workspace has it connected and the
    /// plan allows it, whether or not the Jamf Pro backup succeeded. Nil means Protect is not
    /// part of this workspace. Never throws: a Protect failure leaves the Jamf Pro backup
    /// standing, and says so with a `[warn]` line and a `[partial]` line, which Run History
    /// reads as Partial.
    func backupProtect(
        profile: String,
        workspace: URL,
        staging: URL,
        executable: URL,
        timeout: TimeInterval,
        proState: BackupProductResult.State,
        sharedStorage: () -> String?,
        onLine: @Sendable @escaping (LogLine) -> Void
    ) async -> BackupProductResult? {
        let read = ProBackup.readConfig(profile: profile)
        if let detail = read.failure {
            // Whether Protect is connected cannot be told, so say so instead of leaving it out.
            // The error text can carry a path: it goes in the log line, not the manifest.
            let reason = "config.yaml does not decode, so Protect cannot be told from it"
            onLine(.init(timestamp: Date(), level: .warn,
                         text: "[warn] Jamf Protect not backed up: \(reason): \(detail). "
                             + "The Jamf Pro backup is unaffected."))
            AttentionLog.raise(
                .protectBackupSkipped, "Protect not backed up: config.yaml does not decode")
            return BackupProductResult(state: .skipped, reason: reason)
        }
        let config = read.config
        var refusal: String?
        if let named = EnvironmentProfiles.resolve(config: config, workspace: profile).protect {
            refusal = await ProfileAuthMethod.protectRefusal(profile: named)
        }
        var syncedPlace: String?
        let plan = ProtectBackup.plan(
            config: config, workspaceProfile: profile,
            pinAllows: { SharedConfigPin.protectAllowed(profile: profile) },
            protectRefusal: { _ in refusal },
            sharedStorage: { syncedPlace = sharedStorage(); return syncedPlace },
            syncedStorageAllowed: {
                SharedConfigPin.protectBackupOnSyncedStorage(
                    config?.protect?.backsUpOnSyncedStorage ?? false, profile: profile)
            })
        let protectProfile: String
        switch plan {
        case .notConnected:
            AttentionLog.clear(.protectBackupSkipped, .protectBackupPartial)
            return nil
        case .skip(let reason):
            onLine(.init(timestamp: Date(), level: .warn,
                         text: "[warn] Jamf Protect not backed up: \(reason). "
                             + "The Jamf Pro backup is unaffected."))
            AttentionLog.raise(.protectBackupSkipped, "Protect not backed up: \(reason)")
            return BackupProductResult(state: .skipped, reason: reason)
        case .run(let name):
            protectProfile = name
        }
        // Run on shared storage means the opt-in allowed it: say so for the audit trail.
        if let syncedPlace {
            onLine(.init(timestamp: Date(), level: .info,
                         text: "[info] backing up Jamf Protect to synced storage: this workspace "
                             + "is \(syncedPlace), and "
                             + "\(SharedConfigPin.Key.protectBackupOnSyncedStorage.rawValue) "
                             + "allows it on this Mac"))
        }

        let output = staging.appendingPathComponent(ProtectBackup.folderName, isDirectory: true)
        guard let validated = WorkspacePathGuard.validate(output, under: workspace) else {
            let reason = "the Protect backup path was rejected by the path guard"
            onLine(.init(timestamp: Date(), level: .warn,
                         text: "[warn] Jamf Protect not backed up: \(reason)."))
            AttentionLog.raise(.protectBackupSkipped, "Protect not backed up: \(reason)")
            return BackupProductResult(state: .skipped, reason: reason)
        }
        onLine(.init(timestamp: Date(), level: .info,
                     text: "[info] backing up Jamf Protect configuration (profile "
                         + "\(ConfigSchema.displayText(protectProfile)))"))
        let exit: Int32
        do {
            exit = try await run(
                executable: executable,
                arguments: ProtectBackup.arguments(
                    profile: protectProfile, outputDirectory: validated.path),
                environment: Self.environmentForJamfCLI(),
                timeout: timeout,
                onLine: onLine)
        } catch {
            exit = ReportEngine.launchFailureExitCode
            onLine(.init(timestamp: Date(), level: .fail,
                         text: "[error] could not run protect backup: \(error.localizedDescription)"))
        }
        let result = ProtectBackup.result(exit: exit, directory: validated)
        // It ran, so a skip is over; what it left decides the other code.
        AttentionLog.clear(.protectBackupSkipped)
        reportProtectBackup(
            result, exit: exit, timeout: timeout, output: validated, proState: proState,
            onLine: onLine)
        return result
    }

    private func reportProtectBackup(
        _ result: BackupProductResult, exit: Int32, timeout: TimeInterval, output: URL,
        proState: BackupProductResult.State, onLine: @Sendable (LogLine) -> Void
    ) {
        // A clean run of a tenant with nothing to export is complete, as retention reads it.
        if result.isEmptyExport {
            onLine(.init(timestamp: Date(), level: .ok,
                         text: "[ok] Jamf Protect backed up: it has no objects to export"))
            AttentionLog.clear(.protectBackupPartial)
            return
        }
        switch result.state {
        case .ok:
            onLine(.init(timestamp: Date(), level: .ok,
                         text: "[ok] Jamf Protect configuration backed up "
                             + "(\(result.objectTotal) objects)"))
            AttentionLog.clear(.protectBackupPartial)
            return
        case .skipped:
            return
        case .partial, .failed:
            break
        }
        if exit == Self.exitCodeTimedOut {
            onLine(.init(timestamp: Date(), level: .fail,
                         text: "[error] protect backup stopped after the "
                             + "\(Int(timeout.rounded(.up))) s limit; the unfinished Protect "
                             + "files were discarded"))
        } else if exit != 0 {
            onLine(.init(timestamp: Date(), level: .fail,
                         text: "[error] " + Self.explainExit(exit, operation: "Protect backup")))
        }
        if result.state == .failed {
            // Nothing usable: the files that exist hold credentials for no benefit.
            if (try? FileManager.default.removeItem(at: output)) == nil,
               FileManager.default.fileExists(atPath: output.path) {
                onLine(.init(timestamp: Date(), level: .warn,
                             text: "[warn] the unfinished Protect folder could not be removed: "
                                 + "\(ProtectBackup.folderName)"))
            }
        }
        let detail: String
        if result.state == .failed {
            detail = "no Protect files were kept"
        } else if result.hasFailuresFile {
            detail = "resources that failed are listed in "
                + "\(ProtectBackup.folderName)/\(ProtectBackup.failuresFileName) "
                + "in the backup folder"
        } else {
            detail = result.reason ?? "see the lines above for the resources that failed"
        }
        onLine(.init(timestamp: Date(), level: .warn,
                     text: "[warn] Jamf Protect backup is "
                         + "\(result.state == .partial ? "PARTIAL" : "FAILED"): \(detail)"))
        AttentionLog.raise(
            .protectBackupPartial,
            "Protect backup \(result.state == .partial ? "partial" : "failed")"
                + (result.reason.map { ": \($0)" } ?? ""))
        onLine(.init(timestamp: Date(), level: .warn,
                     text: "[partial] Jamf Protect configuration is not fully backed up; "
                         + Self.proBackupClause(proState)))
    }

    /// How the Jamf Pro part of the same backup ended, for the Protect `[partial]` line.
    nonisolated static func proBackupClause(_ state: BackupProductResult.State) -> String {
        switch state {
        case .ok: "the Jamf Pro backup is complete"
        case .partial: "the Jamf Pro backup is partial too"
        case .failed: "the Jamf Pro backup failed too"
        case .skipped: "the Jamf Pro backup was skipped too"
        }
    }
}
