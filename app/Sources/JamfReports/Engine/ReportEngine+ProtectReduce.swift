import Foundation

/// The jamf-cli version gate: one table for every source an older jamf-cli cannot serve.
extension ReportEngine {

    /// The sources a jamf-cli older than this cannot serve: `dashboard` is the 1.31.0 command,
    /// and the server-health commands were first run on 1.38.0 (the gate moves down only after
    /// a run on an older one).
    static let minimumJamfCLI: [String: String] = [
        dashboardKind: "1.31.0",
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
}
