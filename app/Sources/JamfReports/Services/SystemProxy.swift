import CFNetwork
import Foundation

/// The system HTTPS proxy, for the background runs only. launchd gives the tick no shell proxy
/// variables, so a scheduled collect behind a proxy has none; `--tick` and `--scheduled-run`
/// read the one System Settings holds and `CLIBridge.environmentForJamfCLI` hands it to jamf-cli
/// as `HTTPS_PROXY`. The GUI and the included CLI inherit the shell's variables and never read
/// this. Not read: PAC files and auto-discovery, which need a URL to resolve against. A proxy
/// that names a user is not passed, since the URL would put the credential in a child's
/// environment.
enum SystemProxy {

    enum Reading: Equatable, Sendable {
        case none
        case use(host: String, port: Int)
        case skipped(reason: String)

        /// The `HTTPS_PROXY` value; the host and port only, never a credential.
        var url: String? {
            guard case .use(let host, let port) = self else { return nil }
            return "http://\(host):\(port)"
        }

        /// The line a run's record carries; nil when no system proxy is set.
        var runLine: String? {
            switch self {
            case .none: nil
            case .use(let host, let port): "[info] using the system proxy \(host):\(port)"
            case .skipped(let reason): "[warn] the system proxy is not used: \(reason)"
            }
        }
    }

    private static let userKeys = ["HTTPSUser", "HTTPSUsername", "HTTPSPassword"]

    /// Reads a `CFNetworkCopySystemProxySettings` dictionary.
    static func reading(from settings: [String: Any]?) -> Reading {
        guard let settings,
              (settings[kCFNetworkProxiesHTTPSEnable as String] as? NSNumber)?.boolValue == true,
              let host = (settings[kCFNetworkProxiesHTTPSProxy as String] as? String)?
                .trimmingCharacters(in: .whitespaces), !host.isEmpty
        else { return .none }
        let hasUser = userKeys.contains {
            !((settings[$0] as? String) ?? "").isEmpty
        }
        if hasUser || host.contains("@") {
            return .skipped(reason: "it carries a user name or password")
        }
        let hostCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        guard host.unicodeScalars.allSatisfy(hostCharacters.contains) else {
            return .skipped(reason: "its host is not a plain name or IPv4 address")
        }
        guard let port = (settings[kCFNetworkProxiesHTTPSPort as String] as? NSNumber)?.intValue,
              (1...65535).contains(port)
        else { return .skipped(reason: "it names no usable port") }
        return .use(host: host, port: port)
    }

    static func current() -> Reading {
        reading(from: CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any])
    }

    private static let installed = Installed()

    /// What `--tick` and `--scheduled-run` read at start; `environmentForJamfCLI` and each run's
    /// record read it back. A skipped proxy is warned about once, here, on stderr and in the log.
    static func installForScheduledRun(_ reading: Reading = current()) {
        installed.set(reading)
        if case .skipped = reading, let line = reading.runLine {
            fputs(line + "\n", stderr)
            AppLogger.schedule.warning("\(line, privacy: .public)")
        }
    }

    static var scheduledRun: Reading { installed.get() }

    private final class Installed: @unchecked Sendable {
        private let lock = NSLock()
        private var reading = Reading.none
        func set(_ value: Reading) { lock.withLock { reading = value } }
        func get() -> Reading { lock.withLock { reading } }
    }
}
