import Foundation

/// Check for a Jamf Security Cloud login. `jamf-cli doctor` has no connection probe for one (the
/// login has no URL: one global host, tenancy in the JWT), so the check runs the same read-only
/// `security risk list` the collect runs, with the login named by `-p`.
enum SecurityCloudCheck {
    static let timeout: TimeInterval = 60

    static func arguments(profile: String) -> [String] {
        ReportEngine.securityCommandMatrix(profile: profile)[0].args
    }

    /// The card line for one answer. `lastError` is jamf-cli's last stderr line.
    static func summary(exit: Int32, data: Data, lastError: String?) -> String {
        if exit == 0 {
            let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            if object is NSNull { return L("Healthy · risk list answered, no devices") }
            if let rows = object as? [Any] {
                return rows.count == 1
                    ? L("Healthy · risk list answered, \(rows.count) device")
                    : L("Healthy · risk list answered, \(rows.count) devices")
            }
            return L("Risk list answered with data the app cannot read")
        }
        if exit == CLIBridge.exitCodeTimedOut {
            return L("No answer within \(Int(timeout)) s")
        }
        let reason = JamfCLIErrorEnvelope.parse(data)?.message ?? lastError
        guard let reason, !reason.isEmpty else { return L("Failed · exit \(exit)") }
        return L("Failed · \(ConfigSchema.displayText(LogRedactor.redact(reason)))")
    }

    /// Runs the check; nil when jamf-cli is not installed.
    static func run(profile: String) async -> String? {
        guard let bin = ExecutableLocator.locate("jamf-cli") else { return nil }
        let lastError = LastLineBox()
        do {
            let (exit, data) = try await CLIBridge().runAndCapture(
                executable: bin, arguments: arguments(profile: profile), timeout: timeout,
                onLine: { line in lastError.set(line.text) })
            return summary(exit: exit, data: data, lastError: lastError.value)
        } catch {
            return L("Failed · \(ConfigSchema.displayText(error.localizedDescription))")
        }
    }

    private final class LastLineBox: @unchecked Sendable {
        private let lock = NSLock()
        private var text: String?
        func set(_ value: String) { lock.withLock { text = value } }
        var value: String? { lock.withLock { text } }
    }
}
