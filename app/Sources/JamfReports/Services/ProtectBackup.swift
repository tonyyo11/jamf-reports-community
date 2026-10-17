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

    /// A Protect part that did not come out whole; the backup is never auto-pruned.
    var isIncomplete: Bool { state == .partial || state == .failed }

    var objectTotal: Int { objectCounts.values.reduce(0, +) }

    /// One sentence for the Backups screen about this Jamf Protect part.
    var protectSummary: String {
        let counts = objectCounts.sorted { $0.key < $1.key }
            .map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        let found = "\(objectTotal) object\(objectTotal == 1 ? "" : "s")"
            + (counts.isEmpty ? "" : " (\(counts))")
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
                + "It is never pruned automatically."
        case .failed:
            let code = exitCode.map { " (exit \($0))" } ?? ""
            return "The latest backup has no Jamf Protect part: the Protect backup failed\(code). "
                + "It is never pruned automatically."
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
            objectCounts: object["object_counts"] as? [String: Int] ?? [:],
            hasFailuresFile: object["failures_file"] is String)
    }

    /// The Protect result in a decoded `manifest.json`, or nil for a backup without one.
    static func protect(inManifest manifest: [String: Any]) -> BackupProductResult? {
        BackupProductResult(
            manifestValue: (manifest["products"] as? [String: Any])?["protect"])
    }

    /// The Protect result recorded in `backupDir`'s manifest, or nil.
    static func protect(inBackup backupDir: URL) -> BackupProductResult? {
        guard let data = try? Data(contentsOf: backupDir.appendingPathComponent("manifest.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return protect(inManifest: manifest)
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
    /// sight on a shared workspace).
    static func plan(
        config: ReportConfig?,
        workspaceProfile: String,
        pinAllows: () -> Bool,
        sharedStorage: () -> String?
    ) -> Plan {
        let detected = ProfileProductType.detect(from: config, profile: workspaceProfile)
        guard detected.type == .jamfPro, detected.runsProtect else { return .notConnected }
        guard pinAllows() else {
            return .skip(reason: "protect.profile changed in the shared config.yaml and is not "
                + "confirmed on this Mac (Config Doctor)")
        }
        let protectProfile = config?.protect?.resolvedProfile ?? ""
        guard !protectProfile.isEmpty else {
            return .skip(reason: "protect.enabled is set but protect.profile is empty")
        }
        guard ProfileService.isValid(protectProfile) else {
            return .skip(reason: "protect.profile is not a usable jamf-cli profile name")
        }
        if let place = sharedStorage() {
            return .skip(reason: "this workspace is \(place), and Protect backup files can hold "
                + "third-party credentials that would sync to every Mac that shares it")
        }
        return .run(profile: protectProfile)
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
        if exit == CLIBridge.exitCodeTimedOut {
            state = .failed
        } else if exit == 0 {
            state = failures ? .partial : .ok
        } else if (exit == CLIBridge.exitCodePartialFailure || failures), !counts.isEmpty {
            state = .partial
        } else {
            state = .failed
        }
        // A failed run's files are discarded, so the record claims none.
        return BackupProductResult(
            state: state, exitCode: exit,
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
    /// plan allows it. Nil means Protect is not part of this workspace. Never throws: a
    /// Protect failure leaves the Jamf Pro backup standing, and says so with a `[warn]` line
    /// and a `[partial]` line, which Run History reads as Partial.
    func backupProtect(
        profile: String,
        workspace: URL,
        staging: URL,
        executable: URL,
        timeout: TimeInterval,
        sharedStorage: () -> String?,
        onLine: @Sendable @escaping (LogLine) -> Void
    ) async -> BackupProductResult? {
        let config = try? ConfigLoader.load(from: workspace.appendingPathComponent("config.yaml"))
        let plan = ProtectBackup.plan(
            config: config, workspaceProfile: profile,
            pinAllows: { SharedConfigPin.protectAllowed(profile: profile) },
            sharedStorage: sharedStorage)
        let protectProfile: String
        switch plan {
        case .notConnected:
            return nil
        case .skip(let reason):
            onLine(.init(timestamp: Date(), level: .warn,
                         text: "[warn] Jamf Protect not backed up: \(reason). "
                             + "The Jamf Pro backup is unaffected."))
            return BackupProductResult(state: .skipped, reason: reason)
        case .run(let name):
            protectProfile = name
        }

        let output = staging.appendingPathComponent(ProtectBackup.folderName, isDirectory: true)
        guard let validated = WorkspacePathGuard.validate(output, under: workspace) else {
            let reason = "the Protect backup path was rejected by the path guard"
            onLine(.init(timestamp: Date(), level: .warn,
                         text: "[warn] Jamf Protect not backed up: \(reason)."))
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
        reportProtectBackup(result, exit: exit, timeout: timeout, output: validated, onLine: onLine)
        return result
    }

    private func reportProtectBackup(
        _ result: BackupProductResult, exit: Int32, timeout: TimeInterval, output: URL,
        onLine: @Sendable (LogLine) -> Void
    ) {
        switch result.state {
        case .ok:
            onLine(.init(timestamp: Date(), level: .ok,
                         text: "[ok] Jamf Protect configuration backed up "
                             + "(\(result.objectTotal) objects)"))
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
            detail = "see the lines above for the resources that failed"
        }
        onLine(.init(timestamp: Date(), level: .warn,
                     text: "[warn] Jamf Protect backup is "
                         + "\(result.state == .partial ? "PARTIAL" : "FAILED"): \(detail)"))
        onLine(.init(timestamp: Date(), level: .warn,
                     text: "[partial] Jamf Protect configuration is not fully backed up; "
                         + "the Jamf Pro backup is complete"))
    }
}
