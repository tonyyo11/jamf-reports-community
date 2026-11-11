import Foundation

/// The Jamf Security Cloud device risk list (`security risk list`), the one Security Cloud
/// command the app runs. Each row is cut to an allow-list before it is saved: the list carries a
/// user's name and email, a phone number and a location, none of which a snapshot may hold.
extension ReportEngine {
    static let securityRiskKind = "security-risk"

    /// Starts the `[partial]` line for a Security Cloud collect that threw, naming no source.
    static let securityCollectFailedMarker = "[partial] security collect failed: "

    /// The top-level row keys that reach disk, and `hardwareSpec.osType` below.
    static let securityRiskRowKeys: [String] = [
        "guid", "externalId", "riskCategory", "status", "connectorState", "deploymentState",
        "lastDnsTraffic",
    ]

    static func securityCommandMatrix(profile: String) -> [(args: [String], kind: String)] {
        [(["-p", profile, "--no-input", "security", "risk", "list", "--output", "json"],
          securityRiskKind)]
    }

    /// The payload as an array of rows holding only `securityRiskRowKeys` and
    /// `hardwareSpec.osType`, each kept only when it is a string, a number or a boolean; a row
    /// that is not an object is dropped. A top-level `null` is an empty list. Nil, so nothing is
    /// saved, for any other payload: the text must not reach disk on a guess.
    static func reducingSecurityRisk(_ data: Data) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(
            with: data, options: [.fragmentsAllowed]) else { return nil }
        let rows: [Any]
        if object is NSNull { rows = [] } else if let array = object as? [Any] {
            rows = array
        } else { return nil }
        func isScalar(_ value: Any) -> Bool { value is String || value is NSNumber }
        let kept: [[String: Any]] = rows.compactMap { row in
            guard let row = row as? [String: Any] else { return nil }
            var reduced = row.filter { securityRiskRowKeys.contains($0.key) && isScalar($0.value) }
            if let osType = (row["hardwareSpec"] as? [String: Any])?["osType"], isScalar(osType) {
                reduced["hardwareSpec"] = ["osType": osType]
            }
            return reduced
        }
        return try? JSONSerialization.data(withJSONObject: kept, options: [.sortedKeys])
    }

    /// Runs `security risk list` for `profile` and saves the reduced rows. Returns the kinds that
    /// landed; a failure is a `[partial]` line and a recorded failure, never a throw (jamf-cli
    /// missing and an invalid profile do throw, as in `protectCollect`).
    @discardableResult
    static func securityCollect(
        profile: String,
        dataDir: URL,
        collectSkip: Set<String> = [],
        locateJamfCLI: @Sendable () -> URL? = { ExecutableLocator.locate("jamf-cli") },
        onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void
    ) async throws -> [String] {
        let commands = securityCommandMatrix(profile: profile)
        let skipped = commands.filter { collectSkip.contains($0.kind) }.map(\.kind)
        let running = commands.map(\.kind).filter { !skipped.contains($0) }
        for line in collectPlanLines(
            profile: profile, running: running,
            skipped: skipped.isEmpty
                ? [] : [(CollectSkipReason.collectSkip.planLabel, skipped)]) {
            onLine(.init(timestamp: Date(), level: .info, text: line))
        }
        for kind in skipped {
            onLine(.init(timestamp: Date(), level: .info, text: "[skip] \(kind): "
                + (CollectSkipReason.collectSkip.skipDetail ?? "")))
        }
        guard !running.isEmpty else { return [] }
        guard let bin = locateJamfCLI() else { throw ReportEngineError.jamfCLINotFound }
        guard ProfileService.isValid(profile) else {
            throw ReportEngineError.invalidProfile(profile)
        }
        let bridge = CLIBridge()
        let stateStore = WorkspacePaths
            .confinedFolderOrWarn(["state"], under: dataDir, onLine: onLine)
            .map(StateFileStore.init(directory:))
        let collectStart = Date()
        var unlanded: [String] = []
        for (args, kind) in commands where running.contains(kind) {
            onLine(.init(timestamp: Date(), level: .info,
                         text: "[info] collecting \(kind) for \(profile)"))
            let watcher = StderrSignalWatcher()
            let result: (Int32, Data)?
            do {
                result = try await bridge.runAndCapture(
                    executable: bin, arguments: args,
                    environment: CLIBridge.environmentForJamfCLI(),
                    timeout: collectKindTimeout, onLine: watcher.forwarding(to: onLine))
            } catch {
                onLine(.init(timestamp: Date(), level: .warn,
                    text: "[warn] \(kind): launch failed — \(error.localizedDescription)"))
                result = nil
            }
            guard let (exitCode, data) = result else {
                unlanded.append(kind)
                stateStore?.record(.failed(exitCode: nil), report: kind, at: collectStart)
                continue
            }
            if exitCode == 0, let payload = jsonPayload(from: data),
               let reduced = reducingSecurityRisk(payload) {
                try saveSnapshot(data: reduced, kind: kind, dataDir: dataDir)
                stateStore?.record(.landed, report: kind, at: collectStart)
                onLine(.init(timestamp: Date(), level: .ok,
                             text: "[ok] \(kind): \(reduced.count) bytes"))
            } else if exitCode == 0 {
                onLine(.init(timestamp: Date(), level: .warn,
                    text: "[warn] \(kind): output is not a JSON array — snapshot not saved"))
                unlanded.append(kind)
                stateStore?.record(.failed(exitCode: exitCode), report: kind, at: collectStart)
            } else {
                let cause = FailureCause.classify(
                    exitCode: exitCode, stdout: data,
                    sawForbiddenOnStderr: watcher.sawForbidden,
                    sawKeychainLockedOnStderr: watcher.sawKeychainLocked)
                onLine(.init(timestamp: Date(), level: .warn,
                             text: "[warn] \(kind): exit \(exitCode) — skipped"
                                + causeSuffix(cause)))
                unlanded.append(kind)
                stateStore?.record(
                    .failed(exitCode: exitCode), report: kind, at: collectStart, cause: cause)
            }
        }
        reportUnlanded(unlanded, attempted: running.count, onLine: onLine)
        return running.filter { !unlanded.contains($0) }
    }
}
