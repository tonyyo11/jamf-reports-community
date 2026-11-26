import Foundation

/// The jamf-cli version gate (one table for every source an older jamf-cli cannot
/// serve), and the Protect sources added in 2.13 (wave E) and what reaches disk of each.
extension ReportEngine {

    static let protectSignatureVersionsKind = "protect-signature-versions"
    static let protectInstallerKind = "protect-installer"

    /// The four Protect sources the dashboard and reports were built on; the "every Protect
    /// source off" rule reads these, so turning off a newer source never drops Protect.
    static let protectReportKinds = [
        "protect-overview", "protect-alerts", "protect-computers", "protect-plans",
    ]

    /// The sources a jamf-cli older than this cannot serve: `dashboard` is the 1.31.0 command;
    /// `threat-prevention-versions list` and the server-health commands were first run on
    /// 1.38.0; `downloads summary`, App Installers deployments and patch policies are gated at
    /// 1.35.0, the oldest command catalog that lists them (not checked on 1.29-1.34, where an
    /// unknown command would print help and read as a failed source).
    static let minimumJamfCLI: [String: String] = [
        dashboardKind: "1.31.0",
        protectSignatureVersionsKind: "1.38.0",
        protectInstallerKind: "1.35.0",
        "certificate-authority": "1.38.0",
        "jamf-pro-notifications": "1.38.0",
        "laps-pending-rotations": "1.38.0",
        "admin-accounts": "1.38.0",
        "api-integrations": "1.38.0",
        // The oldest catalog the app ships (1.35.0) lists both; earlier versions are unchecked.
        "app-installers-deployments": "1.35.0",
        "patch-policies": "1.35.0",
    ]

    /// Whether `installed` can serve `kind`: always for a kind with no entry.
    static func jamfCLIAllows(_ kind: String, installed: String?) -> Bool {
        guard let required = minimumJamfCLI[kind] else { return true }
        return JamfCLIInstaller.supports(required, installed: installed)
    }

    /// The skip reason for a gated kind `installed` cannot serve; nil otherwise.
    static func jamfCLISkip(_ kind: String, installed: String?) -> CollectSkipReason? {
        guard let required = minimumJamfCLI[kind],
              !JamfCLIInstaller.supports(required, installed: installed) else { return nil }
        return .needsJamfCLI(required: required, installed: installed)
    }

    /// Per kind, the only row keys saved. A kind listed here is never saved raw.
    static let reducedProtectKinds: [String: Set<String>] = [
        protectSignatureVersionsKind: ["id", "created"],
        protectInstallerKind: ["installerVersion"],
    ]

    /// The payload as an array of rows holding only the kind's keys, each kept only when it is
    /// a string, a number or a boolean. A top-level `null` is an empty list; for
    /// `protect-installer` a top-level object is one row. Nil, so nothing is saved, for a kind
    /// with no keep-list, any other payload, a row that is not an object or a row left with no
    /// kept key: a wrong shape must not land as a measured empty list.
    static func reducingProtect(kind: String, data: Data) -> Data? {
        guard let keys = reducedProtectKinds[kind],
              let object = try? JSONSerialization.jsonObject(
                  with: data, options: [.fragmentsAllowed]) else { return nil }
        let rows: [Any]
        if object is NSNull {
            rows = []
        } else if let array = object as? [Any] {
            rows = array
        } else if kind == protectInstallerKind, let row = object as? [String: Any] {
            rows = [row]
        } else {
            return nil
        }
        var kept: [[String: Any]] = []
        for row in rows {
            guard let row = row as? [String: Any] else { return nil }
            let reduced = row.filter {
                keys.contains($0.key) && ($0.value is String || $0.value is NSNumber)
            }
            guard !reduced.isEmpty else { return nil }
            kept.append(reduced)
        }
        return try? JSONSerialization.data(withJSONObject: kept, options: [.sortedKeys])
    }
}
