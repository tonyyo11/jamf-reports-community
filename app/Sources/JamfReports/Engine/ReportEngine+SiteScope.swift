import Foundation

extension ReportEngine {
    /// Judges the login once per collect, from the snapshots this run just saved, and keeps
    /// the verdict in `state/site-scope.json`. A run that saved only one of the two inputs
    /// (a tier refresh) and an `unknown` verdict leave the earlier file and attention item.
    static func recordSiteScope(
        profile: String, auth: JamfCLIAuthMethod?, dataDir: URL, savedKinds: Set<String>,
        stateDir: URL?, now: Date = Date(), onLine: (CLIBridge.LogLine) -> Void
    ) {
        guard savedKinds.contains("overview"), savedKinds.contains("computers"),
              let stateDir else { return }
        func newest(_ kind: String, saved: Bool = true) -> [Any]? {
            guard saved,
                  let url = FileManager.newestSnapshotFile(
                    in: dataDir.appendingPathComponent(kind, isDirectory: true)),
                  let data = BoundedFile.readLogged(url, inside: dataDir) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [Any]
        }
        let scope = SiteScope.evaluate(
            auth: auth, overview: newest("overview"), computers: newest("computers"),
            mobileDevices: newest(
                MobileFleetService.deviceKind,
                saved: savedKinds.contains(MobileFleetService.deviceKind)))
        if scope == .unknown { return }
        do {
            try SiteScopeRecord(scope: scope, collectedAt: now, profile: profile)
                .save(stateDir: stateDir)
        } catch {
            onLine(.init(timestamp: now, level: .warn,
                text: "[warn] site scope not saved: \(error.localizedDescription)"))
        }
        guard let summary = scope.summary else {
            AttentionLog.clear(.siteLimitedLogin)
            return
        }
        onLine(.init(timestamp: now, level: .warn, text: warnLine(summary)))
        AttentionLog.raise(.siteLimitedLogin, "This login sees \(summary) in Jamf Pro")
    }

    static func warnLine(_ summary: String) -> String {
        "[warn] this login sees \(summary) in Jamf Pro (a site-limited user account); "
            + "reports cover only what it sees"
    }
}
