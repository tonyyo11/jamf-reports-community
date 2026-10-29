import CFNetwork
import Foundation

/// The system HTTPS proxy, for the background runs only. launchd gives the tick no shell proxy
/// variables, so a scheduled collect behind a proxy has none; `--tick` and `--scheduled-run`
/// read the one System Settings holds and `CLIBridge.environmentForJamfCLI` hands it to jamf-cli
/// as `HTTPS_PROXY`, with the bypass list as `NO_PROXY`. The GUI and the included CLI never read
/// this: they use whatever proxy variables their own environment has. Not read: PAC files and
/// auto-discovery, which need a URL to resolve against, and "exclude simple hostnames", which
/// `NO_PROXY` cannot say. A proxy that names a user is not passed, since the credential would
/// land in a child's environment.
enum SystemProxy {

    struct Proxy: Equatable, Sendable {
        let host: String
        let port: Int
        /// The bypass list as `NO_PROXY` text; nil when System Settings bypasses nothing.
        let noProxy: String?
        /// Bypass entries `NO_PROXY` cannot express, left out. Counted, never named.
        let untranslated: Int
    }

    enum Reading: Equatable, Sendable {
        case none
        case use(Proxy)
        case skipped(reason: String)

        /// The `HTTPS_PROXY` value; the host and port only, never a credential.
        var url: String? {
            guard case .use(let proxy) = self else { return nil }
            return "http://\(proxy.host):\(proxy.port)"
        }

        var noProxy: String? {
            guard case .use(let proxy) = self else { return nil }
            return proxy.noProxy
        }

        /// The lines a run's record carries. The host stays out: neither redactor masks a bare
        /// internal host name, and the run record is copied and exported.
        var runLines: [String] {
            switch self {
            case .none: []
            case .use(let proxy):
                ["[info] using the system HTTPS proxy"]
                    + (proxy.untranslated > 0 ? [
                        "[warn] \(proxy.untranslated) system proxy bypass "
                            + "entries cannot be passed to jamf-cli and are ignored"] : [])
            case .skipped(let reason): ["[warn] the system proxy is not used: \(reason)"]
            }
        }
    }

    private static let userKeys = ["HTTPSUser", "HTTPSUsername", "HTTPSPassword"]
    private static let hostCharacters = Set(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")

    /// Reads a `CFNetworkCopySystemProxySettings` dictionary.
    static func reading(from settings: [String: Any]?) -> Reading {
        guard let settings,
              (settings[kCFNetworkProxiesHTTPSEnable as String] as? NSNumber)?.boolValue == true,
              let host = (settings[kCFNetworkProxiesHTTPSProxy as String] as? String)?
                .trimmingCharacters(in: .whitespaces), !host.isEmpty
        else { return .none }
        let hasUser = userKeys.contains { !((settings[$0] as? String) ?? "").isEmpty }
        if hasUser || host.contains("@") {
            return .skipped(reason: "it carries a user name or password")
        }
        guard host.allSatisfy(hostCharacters.contains) else {
            return .skipped(reason: "its host is not a plain name or IPv4 address")
        }
        guard let port = (settings[kCFNetworkProxiesHTTPSPort as String] as? NSNumber)?.intValue,
              (1...65535).contains(port)
        else { return .skipped(reason: "it names no usable port") }
        let entries = settings[kCFNetworkProxiesExceptionsList as String] as? [String] ?? []
        let translated = entries.map(noProxyEntry)
        let kept = translated.compactMap { $0 }
        var untranslated = translated.count - kept.count
        if (settings[kCFNetworkProxiesExcludeSimpleHostnames as String] as? NSNumber)?
            .boolValue == true { untranslated += 1 }
        return .use(Proxy(
            host: host, port: port, noProxy: kept.isEmpty ? nil : kept.joined(separator: ","),
            untranslated: untranslated))
    }

    /// One System Settings bypass entry in the form Go's `NO_PROXY` takes: `*.example.gov`
    /// becomes `.example.gov`, a short CIDR such as `169.254/16` gets its zero octets, and a
    /// plain host, IPv4 address or `*` passes. Nil for anything else (IPv6, other wildcards).
    static func noProxyEntry(_ raw: String) -> String? {
        let entry = raw.trimmingCharacters(in: .whitespaces)
        if entry == "*" { return entry }
        let body = entry.hasPrefix("*.") ? String(entry.dropFirst()) : entry
        let parts = body.split(separator: "/", omittingEmptySubsequences: false)
        guard !body.isEmpty, parts.count <= 2,
              body.allSatisfy({ hostCharacters.contains($0) || $0 == "/" })
        else { return nil }
        guard parts.count == 2 else { return body }
        let octets = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(octets.count),
              octets.allSatisfy({ Int($0).map { $0 <= 255 } == true }),
              let prefix = Int(parts[1]), (0...32).contains(prefix)
        else { return nil }
        let padded = octets + Array(repeating: Substring("0"), count: 4 - octets.count)
        return padded.joined(separator: ".") + "/\(prefix)"
    }

    static func current() -> Reading {
        reading(from: CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any])
    }

    private static let installed = Installed()

    /// What `--tick` and `--scheduled-run` read at start; `environmentForJamfCLI` and each run's
    /// record read it back. A skipped proxy is warned about here, once per process (stderr and
    /// the log), and again in each run's record, which is what Run History shows.
    static func installForScheduledRun(_ reading: Reading = current()) {
        installed.set(reading)
        if case .skipped = reading, let line = reading.runLines.first {
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
