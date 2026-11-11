import Foundation

extension ReportEngine {
    /// Judges the login once per collect and keeps the verdict in `state/site-scope.json`.
    /// An API-client, Platform, School or Security Cloud login is `notApplicable` whatever was
    /// saved. Any other login is judged only when this run saved `computers` and `overview` was
    /// saved this run or is stamped today (overview is the 12 h tier, computers the 48 h one);
    /// mobile devices count only when saved this run. A run that cannot judge, a nil auth
    /// method and an `unknown` verdict leave the earlier file and attention item.
    static func recordSiteScope(
        workspacePaths: WorkspacePaths.Type, profile: String, auth: JamfCLIAuthMethod?,
        dataDir: URL, savedKinds: Set<String>, now: Date = Date(),
        onLine: @Sendable (CLIBridge.LogLine) -> Void
    ) {
        var scope = SiteScope.evaluate(
            auth: auth, overview: nil, computers: nil, mobileDevices: nil)
        if auth == nil { return }
        if scope == .unknown {
            guard savedKinds.contains("computers"),
                  let overviewURL = newestKindSnapshot("overview", in: dataDir),
                  savedKinds.contains("overview") || CloudStorage.snapshotTimestamp(of: overviewURL)
                    .map({ Calendar.current.isDate($0, inSameDayAs: now) }) == true
            else { return }
            func rows(_ url: URL?) -> [Any]? {
                url.flatMap { BoundedFile.readLogged($0, inside: dataDir) }.flatMap {
                    (try? JSONSerialization.jsonObject(with: $0)) as? [Any]
                }
            }
            let mobile = savedKinds.contains(MobileFleetService.deviceKind)
                ? newestKindSnapshot(MobileFleetService.deviceKind, in: dataDir)
                    .flatMap { BoundedFile.readLogged($0, inside: dataDir) }
                    .flatMap {
                        try? JSONDecoder().decode([MobileDeviceInventoryItem].self, from: $0)
                    }
                : nil
            scope = SiteScope.evaluate(
                auth: auth, overview: rows(overviewURL),
                computers: rows(newestKindSnapshot("computers", in: dataDir)),
                mobileDevices: mobile)
            if scope == .unknown { return }
        }
        var saved = false
        if let stateDir = workspacePaths.confinedFolderOrWarn(
            ["state"], under: dataDir, onLine: onLine) {
            do {
                try SiteScopeRecord(scope: scope, collectedAt: now, profile: profile)
                    .save(stateDir: stateDir)
                saved = true
            } catch {
                onLine(.init(timestamp: now, level: .warn,
                    text: "[warn] site scope not saved: \(error.localizedDescription)"))
            }
        }
        if let summary = scope.summary {
            onLine(.init(timestamp: now, level: .warn, text: warnLine(summary)))
            AttentionLog.raise(.siteLimitedLogin, "This login sees \(summary) in Jamf Pro")
        } else if saved {
            AttentionLog.clear(.siteLimitedLogin)
        }
    }

    private static func newestKindSnapshot(_ kind: String, in dataDir: URL) -> URL? {
        FileManager.newestSnapshotFile(in: dataDir.appendingPathComponent(kind, isDirectory: true))
    }

    static func warnLine(_ summary: String) -> String {
        "[warn] this login sees \(summary) in Jamf Pro (a site-limited user account); "
            + "reports cover only what it sees"
    }
}
