import CryptoKit
import Foundation

/// Options controlling a diagnostic-bundle run. Mirrors the Python
/// `cmd_diagnostic_bundle` flags: `redact == false` is `--no-redact`; each
/// `redact*` flag false is the matching `--keep-*` flag.
struct DiagnosticBundleOptions: Sendable {
    var logLookbackDays: Int = 7
    var summaryLimit: Int = 10
    /// Master switch. `false` == `--no-redact`: emits raw content.
    var redact: Bool = true
    var redactHostnames: Bool = true
    var redactSerials: Bool = true
    var redactEmails: Bool = true
    var redactDeviceNames: Bool = true
    var redactUsernames: Bool = true
}

enum DiagnosticBundleError: Error, LocalizedError {
    case invalidProfile(String)
    case archiveFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidProfile(let p): "Invalid profile: \(p)"
        case .archiveFailed(let msg): "Could not create diagnostic archive: \(msg)"
        }
    }
}

/// Native port of the Python `LogRedactor`. Reproduces the redaction *behavior*
/// (not the placeholder digests, which are intentionally per-instance random):
/// always-on credential patterns, exact-key JSON redaction, and stable
/// `<kind>-<8hex>` PII placeholders backed by HMAC-SHA256 with a fresh random
/// salt per instance. Stability holds within one bundle only — by design.
///
/// Not `Sendable`: an instance is created and used entirely within a single
/// `DiagnosticBundleService.buildBundle` call (off the main actor), never
/// crossing a concurrency boundary. The mutable cache/seeded state is therefore
/// safe without locking.
final class DiagnosticRedactor {
    private let redactHostnames: Bool
    private let redactSerials: Bool
    private let redactEmails: Bool
    private let redactDeviceNames: Bool
    private let redactUsernames: Bool

    /// 16-byte CSPRNG salt — matches Python `secrets.token_bytes(16)`.
    private let salt: SymmetricKey
    private var cache: [String: String] = [:]
    private var seededRegexes: [String: [NSRegularExpression]] = [:]
    private var scopeIDRegex: NSRegularExpression?
    private var serverHostRegex: NSRegularExpression?
    private var workspaceNameRegex: NSRegularExpression?

    private let secretPatterns: [(NSRegularExpression, String)]
    private let hostnameURLRE: NSRegularExpression
    private let hostnameBareRE: NSRegularExpression
    private let emailRE: NSRegularExpression
    private let serialRE: NSRegularExpression
    private let homePathRE: NSRegularExpression
    private let ipv4RE: NSRegularExpression
    private let phoneE164RE: NSRegularExpression
    private let phoneNANPRE: NSRegularExpression

    /// Literals per compiled alternation. Not a cap: a category with more is split across
    /// several regexes, since a cap dropped the shortest literals from redaction.
    private static let seedChunkSize = 5000
    private static let minSeedLen = 4
    private static let seededCategories =
        ["serial", "device", "udid", "host", "ip", "phone", "user", "email", "org"]

    /// Exact key match (lowercased) → value replaced with `REDACTED_<UPPER>`.
    static let sensitiveJSONKeys: Set<String> = [
        "client_secret", "client_id", "access_token", "refresh_token",
        "password", "secret", "api_key", "apikey", "authorization",
        "token", "bearer_token", "session_token", "pat", "private_key",
        "password_sha256", "institutional_recovery_key",
    ]

    /// Exact key match (lowercased) → PII category for placeholdering.
    static let piiJSONKeys: [String: String] = [
        "serial": "serial", "serialnumber": "serial", "serial_number": "serial",
        "computername": "device", "computer_name": "device",
        "devicename": "device", "device_name": "device",
        "displayname": "device", "assettag": "device", "asset_tag": "device",
        "managementid": "device", "management_id": "device",
        "udid": "udid",
        "hostname": "host", "host_name": "host", "host": "host",
        "collectedbyhost": "host",
        "ipaddress": "ip", "ip_address": "ip",
        "lastipaddress": "ip", "lastreportedip": "ip", "lastreportedipv4": "ip",
        "username": "user", "user_name": "user", "user": "user",
        "realname": "user", "real_name": "user",
        // operatorUserHost is "username@hostname-first-label"; the email regex
        // won't match (no TLD) and no other pattern covers name@machine.
        // Redact the full value under the "user" category.
        "operatoruserhost": "user",
        "email": "email", "emailaddress": "email", "email_address": "email",
        "phone": "phone", "phonenumber": "phone", "phone_number": "phone",
        "mobilephone": "phone", "mobile_phone": "phone",
        "telephone": "phone", "telephonenumber": "phone",
        "filevault2enabledusernames": "user",
        "building": "org", "department": "org", "room": "org", "position": "org",
    ]

    init(
        redactHostnames: Bool = true,
        redactSerials: Bool = true,
        redactEmails: Bool = true,
        redactDeviceNames: Bool = true,
        redactUsernames: Bool = true
    ) {
        self.redactHostnames = redactHostnames
        self.redactSerials = redactSerials
        self.redactEmails = redactEmails
        self.redactDeviceNames = redactDeviceNames
        self.redactUsernames = redactUsernames
        self.salt = SymmetricKey(size: .bits128)
        self.secretPatterns = Self.buildSecretPatterns()
        self.hostnameURLRE = Self.mustCompile(
            #"(https?://)([a-z0-9][a-z0-9\-\.]{1,253}\.[a-z]{2,63})\b"#, [.caseInsensitive])
        self.hostnameBareRE = Self.mustCompile(
            #"\b((?:[a-z0-9][a-z0-9\-]{0,62}\.)+jamfcloud\.(?:com|io))\b"#,
            [.caseInsensitive])
        self.emailRE = Self.mustCompile(
            #"\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b"#)
        self.serialRE = Self.mustCompile(#"\b[B-DF-HJ-NP-TV-Z0-9]{10,12}\b"#)
        self.homePathRE = Self.mustCompile(#"(/Users/)([A-Za-z0-9._-]+)"#)
        // The lookarounds keep a version such as `v1.2.3.4` or `1.2.3.4.5` out of the match.
        self.ipv4RE = Self.mustCompile(
            #"(?<![\w.\-])(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}"#
            + #"(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(?![\w\-]|\.\d)"#)
        // A phone number needs a leading `+` (E.164, digit groups split by single spaces, dots,
        // hyphens or parentheses, 7-15 digits in all) or separators (NANP), so a bare 10-digit
        // Jamf ID, a date or a timestamp is not one. The lookahead counts the digits; the
        // second guard keeps a `+2020-2026` year range out. The groups are possessive and
        // there is no end guard, so a trailing letter (`...0958x`) never shortens the match and
        // leaves digits behind. Known over-masking, accepted: `+2026-10-18` style text after a
        // plus sign and `+1.29.100.200`.
        self.phoneE164RE = Self.mustCompile(
            #"(?<![\w+])\+(?=(?:[ .\-()]*\d){7,15}(?![ .\-()]*\d))"#
            + #"(?!(?:19|20)\d\d[ .\-](?:19|20)\d\d\b)"#
            + #"[1-9]\d*+(?:[ .\-]?\(\d++\)|[ .\-]\d++)*+"#)
        self.phoneNANPRE = Self.mustCompile(
            #"(?<![\w.\-])\(?\d{3}\)?[ .\-]\d{3}[ .\-]\d{4}(?![\w\-]|\.\d)"#)
    }

    // MARK: - Public API

    /// Manifest `redaction_policy` body when redaction is enabled.
    func policy() -> [String: Any] {
        [
            "secrets": true,
            "hostnames": redactHostnames,
            "serials": redactSerials,
            "emails": redactEmails,
            "device_names_in_json": redactDeviceNames,
            "usernames": redactUsernames,
            "phones": true,
        ]
    }

    /// Redact free text: credential patterns (always), then the seeded scope IDs,
    /// then enabled PII regexes, then any literals seeded from `jamf-cli-data/`.
    func redactText(_ text: String) -> String {
        var out = text
        for (re, template) in secretPatterns {
            out = re.stringByReplacingMatches(
                in: out, range: NSRange(location: 0, length: (out as NSString).length),
                withTemplate: template)
        }
        // Before the serial pattern, which would otherwise cut a UUID's last segment out of it.
        out = redactScopeIDs(in: out)
        if redactHostnames {
            // The profile's own server, which the patterns below miss when it is on-prem and
            // written without a scheme (`jss.example.org:8443`). First, so a seeded literal
            // wins over the generic host patterns.
            if let serverHostRegex {
                out = replaceMatches(serverHostRegex, in: out) { g in
                    self.placeholder("host", (g[0] ?? "").lowercased())
                }
            }
            out = replaceMatches(hostnameURLRE, in: out) { g in
                (g[1] ?? "") + self.placeholder("host", g[2] ?? "")
            }
            out = replaceMatches(hostnameBareRE, in: out) { g in
                self.placeholder("host", g[0] ?? "")
            }
        }
        // After the hosts: a profile named after a label of its server (`jamf`, for
        // `jamf.agency.gov`) would otherwise break the host match and leave the domain.
        out = redactWorkspaceNames(in: out)
        // `ip` has no keep-flag, like the key-based rule and the seeded literals.
        out = replaceMatches(ipv4RE, in: out) { g in self.placeholder("ip", g[0] ?? "") }
        for re in [phoneE164RE, phoneNANPRE] {
            out = replaceMatches(re, in: out) { g in self.placeholder("phone", g[0] ?? "") }
        }
        if redactEmails {
            out = replaceMatches(emailRE, in: out) { g in self.placeholder("email", g[0] ?? "") }
        }
        if redactSerials {
            out = replaceMatches(serialRE, in: out) { g in self.placeholder("serial", g[0] ?? "") }
        }
        if redactUsernames {
            out = replaceMatches(homePathRE, in: out) { g in
                (g[1] ?? "") + self.placeholder("user", g[2] ?? "")
            }
        }
        for category in Self.seededCategories {
            guard piiEnabled(category), let chunks = seededRegexes[category] else { continue }
            for re in chunks {
                out = replaceMatches(re, in: out) { g in self.placeholder(category, g[0] ?? "") }
            }
        }
        return out
    }

    /// Recursively redact a JSON value (from `JSONSerialization`): sensitive keys
    /// become `REDACTED_<UPPER>`, PII keys become placeholders, strings are
    /// text-redacted, everything else recurses or passes through.
    func redactJSON(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (key, val) in dict {
                let keyLower = key.lowercased()
                if Self.sensitiveJSONKeys.contains(keyLower) {
                    out[key] = "REDACTED_\(keyLower.uppercased())"
                    continue
                }
                if let category = Self.piiJSONKeys[keyLower], piiEnabled(category) {
                    if let str = val as? String, !str.isEmpty {
                        out[key] = placeholder(category, str)
                        continue
                    }
                    if let names = val as? [String] {
                        out[key] = names.map { $0.isEmpty ? $0 : placeholder(category, $0) }
                        continue
                    }
                }
                out[key] = redactJSON(val)
            }
            return out
        }
        if let array = value as? [Any] {
            return array.map { redactJSON($0) }
        }
        if let str = value as? String {
            return redactText(str)
        }
        return value
    }

    /// Registers exact identifiers (a profile's tenant and environment IDs) to remove wherever
    /// they appear, in any case. jamf-cli echoes them in error text such as
    /// "Environment '<uuid>' not found", and they identify the organisation. Unlike a general
    /// UUID rule this leaves the other IDs readers match up, such as a host's hardware UUID.
    func seedScopeIDs(_ ids: [String]) {
        let literals = Set(ids.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .filter { $0.count >= Self.minSeedLen }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
        scopeIDRegex = literals.isEmpty ? nil : Self.mustCompile(
            literals.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|"),
            [.caseInsensitive])
    }

    /// Registers the profile's configured Jamf server (`host:port` and `host`) to remove
    /// wherever it appears, with or without a scheme. Applied only while hostname redaction is on.
    func seedServerHosts(_ hosts: [String]) {
        serverHostRegex = Self.boundedLiteralRegex(hosts)
    }

    /// Registers the workspace's profile name, as typed and as the app writes it in folder,
    /// label and file names. It is often the organisation's name, so it is removed wherever it
    /// appears, file names included.
    func seedWorkspaceNames(_ names: [String]) {
        // A workspace name is often the organisation's, and short ones ("CBP") are common.
        workspaceNameRegex = Self.boundedLiteralRegex(names, minLength: 2)
    }

    func redactWorkspaceNames(in text: String) -> String {
        guard let workspaceNameRegex else { return text }
        return replaceMatches(workspaceNameRegex, in: text) { g in
            self.placeholder("workspace", (g[0] ?? "").lowercased())
        }
    }

    /// Any of `literals` (`minLength` characters or more), in any case, not inside a longer name.
    private static func boundedLiteralRegex(
        _ literals: [String], minLength: Int = minSeedLen
    ) -> NSRegularExpression? {
        let kept = Set(literals.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .filter { $0.count >= minLength }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
        return kept.isEmpty ? nil : mustCompile(
            "(?<![A-Za-z0-9-])(?:"
                + kept.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
                + ")(?![A-Za-z0-9-])",
            [.caseInsensitive])
    }

    /// Harvest PII literals from `<dataDir>` JSON and compile per-category
    /// alternation regexes so the same identifiers are redacted from free text
    /// (e.g. inside log lines). Returns the count of distinct literals harvested
    /// (before the min-length filter), matching the Python seed count.
    @discardableResult
    func seedFromWorkspace(_ dataDir: URL) -> Int {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: dataDir, includingPropertiesForKeys: nil) else {
            return 0
        }
        var jsonFiles: [URL] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "json" {
            jsonFiles.append(url)
        }
        jsonFiles.sort { $0.path < $1.path }
        var sets: [String: Set<String>] = [:]
        for url in jsonFiles {
            // Each file is parsed whole; release it before the next, or a workspace of large
            // snapshots holds them all until the loop ends.
            autoreleasepool {
                guard let data = BoundedFile.readLogged(url),
                      let obj = try? JSONSerialization.jsonObject(with: data) else { return }
                harvest(obj, into: &sets)
            }
        }
        let total = sets.values.reduce(0) { $0 + $1.count }
        for (category, values) in sets { compileSeededRegex(category, from: values) }
        return total
    }

    // MARK: - Internals

    /// Compile one category's harvested literals into alternation regexes of
    /// `seedChunkSize` literals each and store them. Longest first across every
    /// chunk, so no alternation stops at a shorter literal that prefixes a longer
    /// one; ties sort by value, so the order is the same on every run. Extracted
    /// from `seedFromWorkspace` to keep that method's complexity within the
    /// project ceiling.
    private func compileSeededRegex(_ category: String, from values: Set<String>) {
        let literals = values.filter { $0.count >= Self.minSeedLen }
            .sorted { a, b in
                if a.count != b.count { return a.count > b.count }
                return a < b
            }
        guard !literals.isEmpty else { return }
        var chunks: [NSRegularExpression] = []
        for start in stride(from: 0, to: literals.count, by: Self.seedChunkSize) {
            let chunk = literals[start..<min(start + Self.seedChunkSize, literals.count)]
            // Whole-word only: seeding "Main" must not cut into "Maintenance".
            let alternation = chunk.map { NSRegularExpression.escapedPattern(for: $0) }
                .joined(separator: "|")
            let pattern = "(?<![A-Za-z0-9])(?:\(alternation))(?![A-Za-z0-9])"
            do {
                let regex = try NSRegularExpression(pattern: pattern)
                chunks.append(regex)
            } catch {
                // Seeding only augments free-text redaction; key-based and regex
                // PII/credential redaction are unaffected. Log so the rare
                // (length-limit) gap is observable rather than silent.
                AppLogger.collect.warning(
                    "DiagnosticRedactor: seed compile failed for \(category, privacy: .public)")
            }
        }
        if !chunks.isEmpty { seededRegexes[category] = chunks }
    }

    private func redactScopeIDs(in text: String) -> String {
        guard let scopeIDRegex else { return text }
        return replaceMatches(scopeIDRegex, in: text) { g in
            self.placeholder("org", (g[0] ?? "").lowercased())
        }
    }

    /// The placeholder for free text no pattern can find, such as a name or a justification an
    /// admin typed into config.yaml. `category` keeps its keep-flag; an empty value or a
    /// category the options keep comes back as written.
    func placeholderText(for value: String, category: String) -> String {
        guard !value.isEmpty, piiEnabled(category) else { return value }
        return placeholder(category, value)
    }

    private func placeholder(_ kind: String, _ value: String) -> String {
        let cacheKey = "\(kind)\u{0}\(value)"
        if let cached = cache[cacheKey] { return cached }
        let mac = HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: salt)
        let hex = mac.map { String(format: "%02x", $0) }.joined().prefix(8)
        let result = "\(kind)-\(hex)"
        cache[cacheKey] = result
        return result
    }

    /// `udid`, `ip`, `phone` and `org` have no keep-flag and are always redacted when
    /// redaction is enabled — matching Python `_pii_enabled`.
    private func piiEnabled(_ category: String) -> Bool {
        switch category {
        case "host": return redactHostnames
        case "serial": return redactSerials
        case "email": return redactEmails
        case "device": return redactDeviceNames
        case "user": return redactUsernames
        default: return true
        }
    }

    /// A bare `name` key is not a PII key (policies and profiles have one), but a computer
    /// record's `general.name` is the device name.
    private func harvestGeneralName(
        _ key: String, _ value: Any, into sets: inout [String: Set<String>]
    ) {
        guard key.lowercased() == "general", let general = value as? [String: Any],
              let name = (general["name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return }
        sets["device", default: []].insert(name)
    }

    private func harvest(_ value: Any, into sets: inout [String: Set<String>]) {
        if let dict = value as? [String: Any] {
            for (key, val) in dict {
                if let category = Self.piiJSONKeys[key.lowercased()], let str = val as? String {
                    let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { sets[category, default: []].insert(trimmed) }
                }
                harvestGeneralName(key, val, into: &sets)
                harvest(val, into: &sets)
            }
        } else if let array = value as? [Any] {
            for val in array { harvest(val, into: &sets) }
        }
    }

    /// Replace every match using a closure over the capture groups (group 0 is
    /// the whole match). Replaces in reverse so ranges stay valid mid-edit.
    private func replaceMatches(
        _ regex: NSRegularExpression, in text: String, _ transform: ([String?]) -> String
    ) -> String {
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        let mutable = NSMutableString(string: text)
        for match in matches.reversed() {
            var groups: [String?] = []
            for index in 0..<match.numberOfRanges {
                let range = match.range(at: index)
                groups.append(range.location == NSNotFound ? nil : ns.substring(with: range))
            }
            mutable.replaceCharacters(in: match.range, with: transform(groups))
        }
        return mutable as String
    }

    private static func buildSecretPatterns() -> [(NSRegularExpression, String)] {
        var patterns: [(NSRegularExpression, String)] = []
        func add(_ pattern: String, _ template: String, ci: Bool = true) {
            patterns.append((mustCompile(pattern, ci ? [.caseInsensitive] : []), template))
        }
        add(#"(client_secret["']?\s*[:=]\s*["']?)([^"'\s,}]{8,})(["']?)"#,
            "$1REDACTED_CLIENT_SECRET$3")
        add(#"(client_id["']?\s*[:=]\s*["']?)([A-Fa-f0-9\-]{20,}|[A-Za-z0-9_\-]{16,64})(["']?)"#,
            "$1REDACTED_CLIENT_ID$3")
        add(#"(Bearer\s+)[A-Za-z0-9._\-+/=]{20,}"#, "$1REDACTED_BEARER")
        add(#"\beyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\b"#,
            "REDACTED_JWT", ci: false)
        add(#"("access_token"\s*:\s*")[^"]+(")"#, "$1REDACTED_ACCESS_TOKEN$2", ci: false)
        add(#"("refresh_token"\s*:\s*")[^"]+(")"#, "$1REDACTED_REFRESH_TOKEN$2", ci: false)
        add(#"(password["']?\s*[:=]\s*["']?)([^"'\s,}]{1,})(["']?)"#, "$1REDACTED_PASSWORD$3")
        add(#"(api_?key["']?\s*[:=]\s*["']?)([^"'\s,}]{8,})(["']?)"#, "$1REDACTED_API_KEY$3")
        // Key name and separator, then the value; the lookahead skips an already-masked value.
        add(#"((?:\w*token\w*|\bpat|\w*private_key\w*)["']?\s*[:=]\s*["']?)"#
            + #"(?!REDACTED)([^"'\s,}]{8,})(["']?)"#,
            "$1REDACTED_TOKEN$3")
        add(#"(Authorization:\s*Basic\s+)[A-Za-z0-9+/=]{8,}"#, "$1REDACTED_BASIC_CREDENTIAL")
        add(#"(webhook_url\s*[:=]\s*["']?)(https?://[^\s"',}]+)(["']?)"#,
            "$1REDACTED_WEBHOOK_URL$3")
        // An incoming-webhook URL is itself a posting credential, and the SECRET
        // IS THE PATH — the later hostname pass masks only scheme+host, which
        // leaves the token intact and the URL reconstructable from a well-known
        // host. This app stores it at `notify.url` (NotifyConfig), which the
        // `webhook_url` pattern above never matches, so match on the endpoint
        // shape and replace the whole value. These run before hostname masking.
        // The host list is LogRedactor's, so the two redactors stay in step.
        for pattern in LogRedactor.webhookURLPatterns { add(pattern, "REDACTED_WEBHOOK_URL") }
        add(LogRedactor.signatureQueryPattern, LogRedactor.signatureQueryTemplate)
        // Any other endpoint an operator configures: a bare `url` key holding an
        // https value. `\b` keeps this off `webhook_url`/`base_url` (no word
        // boundary after an underscore), so it lands on `notify.url` and peers.
        add(#"(\burl\s*[:=]\s*["']?)(https?://[^\s"',}]+)(["']?)"#, "$1REDACTED_URL$3")
        return patterns
    }

    private static func mustCompile(
        _ pattern: String, _ options: NSRegularExpression.Options = []
    ) -> NSRegularExpression {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            preconditionFailure("Invalid built-in redaction pattern: \(pattern)")
        }
        return regex
    }
}

/// Produces the redacted diagnostic zip natively, without executing the bundled
/// Python script (CLAUDE.md: "the app itself never executes the bundled
/// script"). Bundles recent logs, last-N summaries, redacted config, a workspace
/// tree listing, and version metadata. Writes under
/// `~/Jamf-Reports/<profile>/diagnostics/` so `SystemActions.reveal` accepts the
/// result without widening the path allow-list.
enum DiagnosticBundleService {
    static let schemaVersion = 1

    /// Resolved source locations for a bundle run. Passed explicitly so the core
    /// is testable against a temp workspace without touching the home directory.
    struct Sources {
        let workspaceName: String
        let workspaceRoot: URL
        let logsDir: URL
        let summariesDir: URL
        let configURL: URL
        let dataDir: URL
        /// jamf-cli profile to diagnose via `doctor`. Empty disables the live
        /// doctor capture (e.g. tests that don't want a network probe).
        var cliProfile: String = ""
        /// The profile's tenant and environment IDs, redacted wherever they appear.
        var scopeIDs: [String] = []
        /// The profile's configured Jamf server, as `host:port` and `host`.
        var serverHosts: [String] = []
        /// Folders `makeSources` did not collect because they are symlinks, as skipped entries.
        /// `stageFiles` reads neither `logsDir` nor `summariesDir` when its entry is here.
        var refused: [ManifestEntry] = []
    }

    struct ManifestEntry {
        let path: String
        var size: Int?
        var redacted: Bool?
        var skipped: Bool?
        var reason: String?

        static func file(path: String, size: Int?, redacted: Bool) -> ManifestEntry {
            ManifestEntry(path: path, size: size, redacted: redacted, skipped: nil, reason: nil)
        }

        static func skipped(path: String, reason: String) -> ManifestEntry {
            ManifestEntry(path: path, size: nil, redacted: nil, skipped: true, reason: reason)
        }

        func asDict() -> [String: Any] {
            var dict: [String: Any] = ["path": path]
            if let size { dict["size"] = size }
            if let redacted { dict["redacted"] = redacted }
            if let skipped { dict["skipped"] = skipped }
            if let reason { dict["reason"] = reason }
            return dict
        }
    }

    /// Generate a bundle for `profile`, returning the written `.zip` URL. The zip goes to
    /// `~/Library/Logs/JamfReports/diagnostics/<profile>`, not into the workspace, which may be a
    /// folder other Macs read.
    static func generate(
        profile: String, options: DiagnosticBundleOptions = .init(), now: Date = Date()
    ) throws -> URL {
        let sources = try makeSources(profile: profile, options: options)
        let outputDir = try WorkspacePaths.diagnosticsDir(for: profile)
        // The per-profile folder is made 0700 by `buildBundle`; its parent holds every profile's.
        try makePrivateFolder(outputDir.deletingLastPathComponent())
        return try buildBundle(
            sources: sources, outputDir: outputDir,
            profileSlug: slug(profile), options: options, now: now)
    }

    /// The folders a bundle for `profile` reads. A fixed workspace folder that is a symlink is
    /// left out and recorded as a skipped manifest entry, so the bundle still builds.
    static func makeSources(profile: String, options: DiagnosticBundleOptions) throws -> Sources {
        guard let workspace = ProfileService.workspaceURL(for: profile)?
            .resolvingSymlinksInPath().standardizedFileURL else {
            throw DiagnosticBundleError.invalidProfile(profile)
        }
        var refused: [ManifestEntry] = []
        func folder(_ name: String, _ resolve: () throws -> URL) -> URL? {
            do { return try resolve() } catch {
                let reason = WorkspacePaths.refusal(of: error)
                let note = "DiagnosticBundle: \(name) not collected: \(reason)"
                AppLogger.collect.warning("\(note, privacy: .public)")
                refused.append(.skipped(path: name, reason: reason))
                return nil
            }
        }
        let logsDir = folder("automation/logs") { try WorkspacePaths.runHistoryDir(for: profile) }
        let summariesDir = folder("summaries") { try WorkspacePaths.summariesDir(for: profile) }
        // A refused folder keeps a nominal path that `stageFiles` never reads.
        return Sources(
            workspaceName: workspace.lastPathComponent,
            workspaceRoot: workspace,
            logsDir: logsDir ?? workspace.appendingPathComponent("automation/logs"),
            summariesDir: summariesDir ?? workspace.appendingPathComponent("summaries"),
            configURL: workspace.appendingPathComponent("config.yaml"),
            dataDir: try WorkspacePaths.dataDir(for: profile),
            cliProfile: profile,
            scopeIDs: options.redact ? scopeIDs(profile: profile) : [],
            serverHosts: options.redact ? serverHosts(profile: profile) : [],
            refused: refused
        )
    }

    private static func makePrivateFolder(_ url: URL) throws {
        let mode: [FileAttributeKey: Any] = [.posixPermissions: NSNumber(value: Int16(0o700))]
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true, attributes: mode)
        try FileManager.default.setAttributes(mode, ofItemAtPath: url.path)
    }

    private static let scopeIDKeys: Set<String> = ["tenant-id", "environment-id"]

    /// The tenant and environment IDs jamf-cli's config file holds for `profile`. The bundle runs
    /// no `config list`, so it reads the file the way `ProfileService.fallbackConfigProfiles`
    /// does. No file, or a profile without those keys (an instance profile), gives no IDs.
    ///
    /// The IDs of the profile's sibling environments (`ConnectionStore`, same credential) are
    /// added: they identify the same organisation. connections.json itself is never bundled.
    static func scopeIDs(
        profile: String,
        configURL: URL = ProfileService.jamfCLIConfigFileURL(),
        connections: ConnectionStore = ConnectionStore()
    ) -> [String] {
        let siblings = connections.scopeIDs(sharingConnectionWith: profile)
        guard FileManager.default.fileExists(atPath: configURL.path) else { return siblings }
        guard let text = ProfileService.readConfigFileText(at: configURL) else {
            AppLogger.collect.warning(
                "DiagnosticBundle: could not read the jamf-cli config; scope IDs not redacted")
            return siblings
        }
        return scopeIDs(profile: profile, inConfig: text) + siblings
    }

    /// Every server in the user's own jamf-cli config file, as `host:port` and `host` (just
    /// `host` when no port is set): the workspace's config.yaml is peer-writable on a shared
    /// folder, so it never decides which hosts are redacted, and over-redacting another
    /// profile's host costs nothing. `profile` is kept for callers. No file or no `url` gives
    /// none.
    static func serverHosts(
        profile: String,
        configURL: URL = ProfileService.jamfCLIConfigFileURL()
    ) -> [String] {
        (ProfileService.readConfigFile(at: configURL) ?? []).flatMap { entry in
            entry.url.map(hostForms(ofURL:)) ?? []
        }
    }

    /// Pure: `host:port` and `host` of a configured server URL, scheme, credentials and path
    /// removed.
    static func hostForms(ofURL url: String) -> [String] {
        var rest = Substring(url.trimmingCharacters(in: .whitespacesAndNewlines))
        if let scheme = rest.range(of: "://") { rest = rest[scheme.upperBound...] }
        rest = rest.prefix { !"/?#".contains($0) }
        if let at = rest.lastIndex(of: "@") { rest = rest[rest.index(after: at)...] }
        let hostPort = String(rest)
        if hostPort.isEmpty { return [] }
        // A bracketed IPv6 literal is kept whole; the IPv4 and hostname rules do not cover it.
        guard !hostPort.hasPrefix("["), let colon = hostPort.lastIndex(of: ":")
        else { return [hostPort] }
        return [hostPort, String(hostPort[..<colon])]
    }

    /// Pure: the `tenant-id` and `environment-id` values under `profile` in config text.
    static func scopeIDs(profile: String, inConfig text: String) -> [String] {
        scopeValues(profile: profile, inConfig: text).map(\.value)
    }

    /// Pure: the profile's environment ID (preferred) or tenant ID, with the level it names.
    static func platformScope(
        profile: String, inConfig text: String
    ) -> (id: String, level: Connection.Level)? {
        let values = scopeValues(profile: profile, inConfig: text)
        if let environment = values.first(where: { $0.key == "environment-id" }) {
            return (environment.value, .environment)
        }
        return values.first.map { ($0.value, .tenant) }
    }

    private static func scopeValues(
        profile: String, inConfig text: String
    ) -> [(key: String, value: String)] {
        let rows: [(indent: Int, text: String)] = text.components(separatedBy: .newlines)
            .compactMap { raw in
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
                return (raw.prefix { $0 == " " }.count, line)
            }
        guard let start = rows.firstIndex(where: { $0.indent == 0 && $0.text == "profiles:" })
        else { return [] }
        let body = rows[(start + 1)...].prefix { $0.indent > 0 }
        guard let nameIndent = body.first?.indent else { return [] }
        var inProfile = false
        var found: [(key: String, value: String)] = []
        for row in body {
            if row.indent == nameIndent, row.text.hasSuffix(":") {
                inProfile = ProfileService.unquotedYAMLKey(String(row.text.dropLast())) == profile
            } else if inProfile, let (key, value) = yamlPair(row.text),
                      scopeIDKeys.contains(key), !value.isEmpty {
                found.append((key, value))
            }
        }
        return found
    }

    /// `key: value` with the value's quotes or trailing ` # comment` removed.
    private static func yamlPair(_ line: String) -> (key: String, value: String)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let key = line[..<colon].trimmingCharacters(in: .whitespaces)
        var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        if let quote = value.first, quote == "\"" || quote == "'" {
            value = String(value.dropFirst().prefix { $0 != quote })
        } else if let comment = value.range(of: " #") {
            value = value[..<comment.lowerBound].trimmingCharacters(in: .whitespaces)
        }
        return (key, value)
    }

    /// Core builder: stage files into a temp dir, write the manifest, archive to
    /// `<outputDir>/jamf-reports-diagnostic-<slug>-<ts>.zip`, return the zip URL.
    static func buildBundle(
        sources: Sources, outputDir: URL, profileSlug: String,
        options: DiagnosticBundleOptions, now: Date
    ) throws -> URL {
        let fm = FileManager.default
        // 0o700: diagnostic output is per-user sensitive; no group/world read.
        try fm.createDirectory(
            at: outputDir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        // createDirectory attributes are a no-op when the directory already
        // exists (e.g. created 0o755 by an earlier app version) — tighten it.
        try? fm.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))], ofItemAtPath: outputDir.path
        )
        let stamp = timestamp(now)
        // Random suffix so a second app instance's defer-cleanup can't wipe this
        // run's staging mid-write if two bundles start in the same clock second.
        let token = String(format: "%08x", UInt32.random(in: 0...UInt32.max))
        let staging = outputDir.appendingPathComponent(
            ".staging-\(stamp)-\(token)", isDirectory: true)
        try? fm.removeItem(at: staging)
        // 0o700: staging dir holds unzipped sensitive content.
        try fm.createDirectory(
            at: staging, withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        defer { try? fm.removeItem(at: staging) }

        let redactor: DiagnosticRedactor? = options.redact ? makeRedactor(options) : nil
        redactor?.seedFromWorkspace(sources.dataDir)
        redactor?.seedScopeIDs(sources.scopeIDs)
        redactor?.seedServerHosts(sources.serverHosts)
        if !sources.cliProfile.isEmpty {
            redactor?.seedWorkspaceNames(
                [sources.cliProfile, sources.workspaceName, profileSlug]
                    + [ProfileName.pathComponent, ProfileName.labelComponent]
                        .map { $0(sources.cliProfile) })
        }

        let entries = try stageFiles(
            sources: sources, into: staging, redactor: redactor, options: options, now: now)
        let manifest = buildManifest(
            entries: entries, sources: sources, options: options, redactor: redactor, now: now)
        let manifestData = try JSONSerialization.data(
            withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try manifestData.write(to: staging.appendingPathComponent("manifest.json"))

        let zipSlug = redactor?.redactWorkspaceNames(in: profileSlug) ?? profileSlug
        let zipURL = outputDir.appendingPathComponent(
            "jamf-reports-diagnostic-\(zipSlug)-\(stamp).zip")
        try? fm.removeItem(at: zipURL)
        try archive(staging: staging, to: zipURL)
        // 0o600: zip holds potentially sensitive diagnostic content; restrict to
        // owner-read/write only. Best-effort: a failure to chmod is not fatal
        // (the zip was written and is still usable), but is logged.
        do {
            try fm.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: zipURL.path
            )
        } catch {
            let msg = error.localizedDescription
            AppLogger.collect.warning(
                "DiagnosticBundle: chmod zip failed: \(msg, privacy: .public)"
            )
        }
        return zipURL
    }

    /// Stage every bundle entry (except `manifest.json`) into `staging` and
    /// return their manifest entries. Exposed for tests to inspect the staged
    /// tree directly without round-tripping a zip.
    static func stageFiles(
        sources: Sources, into staging: URL, redactor: DiagnosticRedactor?,
        options: DiagnosticBundleOptions, now: Date
    ) throws -> [ManifestEntry] {
        var entries: [ManifestEntry] = sources.refused
        let refused = Set(sources.refused.map(\.path))
        if !refused.contains("automation/logs") {
            entries += collectLogs(
                from: sources.logsDir, into: staging, redactor: redactor,
                days: options.logLookbackDays, now: now)
        }
        if !refused.contains("summaries") {
            entries += collectSummaries(
                from: sources.summariesDir, into: staging, redactor: redactor,
                limit: options.summaryLimit)
        }
        entries += try collectConfig(from: sources.configURL, into: staging, redactor: redactor)
        entries += try collectWorkspaceTree(
            root: sources.workspaceRoot, name: sources.workspaceName,
            into: staging, redactor: redactor)
        entries += try collectVersions(into: staging, redactor: redactor)
        entries += collectDoctor(
            cliProfile: sources.cliProfile, into: staging, redactor: redactor)
        return entries
    }

    // MARK: - Collectors

    static func collectLogs(
        from logsDir: URL, into staging: URL, redactor: DiagnosticRedactor?,
        days: Int, now: Date
    ) -> [ManifestEntry] {
        let fm = FileManager.default
        let keys: [URLResourceKey] =
            [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let enumerator = fm.enumerator(at: logsDir, includingPropertiesForKeys: keys) else {
            return []
        }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        var urls: [URL] = []
        for case let url as URL in enumerator { urls.append(url) }
        urls.sort { $0.path < $1.path }
        var entries: [ManifestEntry] = []
        for url in urls {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true { continue }
            guard values?.isRegularFile == true else { continue }
            if let mtime = values?.contentModificationDate, mtime < cutoff { continue }
            let relative = relativePath(of: url, under: logsDir)
            let arcname = "logs/\(redactor?.redactWorkspaceNames(in: relative) ?? relative)"
            // The tail of a log past the limit, as Run History reads it, not a skipped file.
            guard let data = (try? BoundedFile.readTail(url, limit: 5 * 1024 * 1024))?.data else {
                entries.append(.skipped(path: arcname, reason: "could not read log"))
                continue
            }
            var content = String(decoding: data, as: UTF8.self)
            // Same chain as LogRedactor.redactedForSharing, so shared and bundled logs match.
            if let redactor { content = redactor.redactText(LogRedactor.redact(content)) }
            if (try? writeText(content, to: staging.appendingPathComponent(arcname))) == nil {
                entries.append(.skipped(path: arcname, reason: "could not stage log"))
                continue
            }
            entries.append(
                .file(path: arcname, size: content.utf8.count, redacted: redactor != nil))
        }
        return entries
    }

    private static func collectSummaries(
        from summariesDir: URL, into staging: URL, redactor: DiagnosticRedactor?, limit: Int
    ) -> [ManifestEntry] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let contents = try? fm.contentsOfDirectory(
            at: summariesDir, includingPropertiesForKeys: keys) else { return [] }
        let summaries = contents
            .filter { $0.lastPathComponent.hasPrefix("summary_")
                && $0.pathExtension.lowercased() == "json" }
            .filter(FileManager.isSelectableSnapshot)
            .sorted { FileManager.isOlderSnapshot($1, than: $0) }
            .prefix(limit)
        var entries: [ManifestEntry] = []
        for url in summaries {
            let arcname = "summaries/\(url.lastPathComponent)"
            if isSymlink(url) {
                entries.append(.skipped(path: arcname, reason: "symlink — skipped"))
                continue
            }
            guard let data = BoundedFile.readLogged(
                    url, limit: SummaryJSONParser.maxSummaryFileBytes),
                  let obj = try? JSONSerialization.jsonObject(with: data) else {
                entries.append(.skipped(path: arcname, reason: "could not parse summary"))
                continue
            }
            let redacted = redactor?.redactJSON(obj) ?? obj
            guard let out = try? JSONSerialization.data(
                withJSONObject: redacted, options: [.prettyPrinted, .sortedKeys]),
                (try? writeData(out, to: staging.appendingPathComponent(arcname))) != nil else {
                entries.append(.skipped(path: arcname, reason: "could not stage summary"))
                continue
            }
            // size omitted to match the Python summaries manifest entry, which
            // records only path + redacted.
            entries.append(ManifestEntry(
                path: arcname, size: nil, redacted: redactor != nil, skipped: nil, reason: nil))
        }
        return entries
    }

    private static func collectConfig(
        from configURL: URL, into staging: URL, redactor: DiagnosticRedactor?
    ) throws -> [ManifestEntry] {
        guard FileManager.default.fileExists(atPath: configURL.path) else { return [] }
        if isSymlink(configURL) {
            return [.skipped(path: "config.yaml", reason: "symlink — skipped")]
        }
        guard let data = try? ConfigLoader.readData(at: configURL) else {
            return [.skipped(path: "config.yaml", reason: "could not read config")]
        }
        var content = String(decoding: data, as: UTF8.self)
        if let redactor {
            // Comments are free text no pattern can find, so none are staged.
            content = YAMLCodec.removingComments(from: content)
            content = redactor.redactText(try redactingExceptionText(in: content, with: redactor))
        }
        try writeText(content, to: staging.appendingPathComponent("config.yaml"))
        return [.file(path: "config.yaml", size: content.utf8.count, redacted: redactor != nil)]
    }

    /// The `exceptions[]` fields an admin types as free text, with the category whose
    /// placeholder replaces each: a person's name, a justification and the two labels an admin
    /// invents (the entry's id and the finding it links to).
    private static let exceptionTextFields = [
        ("signed_off_by", "user"), ("description", "org"), ("id", "org"), ("linked_finding", "org"),
    ]

    /// Replaces those fields in each entry of every `exceptions` block with the redactor's
    /// placeholders: an earlier copy of a repeated key too, which the app does not read but the
    /// file still holds. Parsed with `YAMLCodec`, as the app reads the file, so a flow mapping or
    /// a block value is covered too. Only a block with something to replace is re-emitted (its
    /// quoting is normalized); every other line stays as written, and a file with nothing to
    /// replace comes back unchanged.
    static func redactingExceptionText(
        in yaml: String, with redactor: DiagnosticRedactor
    ) throws -> String {
        guard let document = try? YAMLCodec.decode(yaml) else {
            AppLogger.collect.warning(
                "DiagnosticBundle: config.yaml is not a mapping; exception text not replaced")
            return yaml
        }
        var lines = document.originalText.components(separatedBy: .newlines)
        var changed = false
        for range in YAMLCodec.topLevelBlockRanges(of: "exceptions", in: lines).reversed() {
            let block = lines[range].joined(separator: "\n")
            guard let edited = try redactingExceptionBlock(block, with: redactor) else { continue }
            lines.replaceSubrange(range, with: edited)
            changed = true
        }
        return changed ? lines.joined(separator: "\n") : yaml
    }

    /// The lines of one `exceptions:` block with its free text replaced, nil when it has none.
    private static func redactingExceptionBlock(
        _ block: String, with redactor: DiagnosticRedactor
    ) throws -> [String]? {
        guard let document = try? YAMLCodec.decode(block),
              case .mapping(var root) = document.root,
              case .sequence(let entries)? = root.value(for: "exceptions") else { return nil }
        var replaced = false
        let redacted = entries.map { entry -> YAMLCodec.YAMLValue in
            guard case .mapping(var fields) = entry else { return entry }
            for (key, category) in exceptionTextFields {
                guard case .scalar(let scalar)? = fields.value(for: key),
                      let text = scalarText(scalar) else { continue }
                let placeholder = redactor.placeholderText(for: text, category: category)
                if placeholder != text {
                    fields.set(key, value: .scalar(.string(placeholder)))
                    replaced = true
                }
            }
            return .mapping(fields)
        }
        guard replaced else { return nil }
        root.set("exceptions", value: .sequence(redacted))
        var edited = document
        edited.root = .mapping(root)
        let text = try YAMLCodec.encode(edited, replacingTopLevelKeys: ["exceptions"])
        return String(text.dropLast(text.hasSuffix("\n") ? 1 : 0)).components(separatedBy: "\n")
    }

    private static func scalarText(_ scalar: YAMLCodec.YAMLScalar) -> String? {
        switch scalar {
        case .string(let text): text
        case .int(let value): String(value)
        case .bool(let value): String(value)
        case .null: nil
        }
    }

    private static func collectWorkspaceTree(
        root: URL, name: String, into staging: URL, redactor: DiagnosticRedactor?
    ) throws -> [ManifestEntry] {
        var content = buildWorkspaceTree(root: root, name: name, maxDepth: 3)
        if let redactor { content = redactor.redactText(content) }
        try writeText(content, to: staging.appendingPathComponent("workspace_tree.txt"))
        return [.file(
            path: "workspace_tree.txt", size: content.utf8.count, redacted: redactor != nil)]
    }

    private static func collectVersions(
        into staging: URL, redactor: DiagnosticRedactor?
    ) throws -> [ManifestEntry] {
        // Swift-native version keys: the Python keys `python_version`/`platform`
        // have no meaning here (no bundled interpreter), so they're replaced
        // with honest `app_version`/`os_version` rather than phantom fields.
        let versions: [String: Any] = [
            "jamf_cli_version": jamfCLIVersion(),
            "app_version": appVersion(),
            "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
            "bundle_schema_version": schemaVersion,
        ]
        let redacted = redactor?.redactJSON(versions) ?? versions
        let data = try JSONSerialization.data(
            withJSONObject: redacted, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: staging.appendingPathComponent("versions.json"))
        return [ManifestEntry(
            path: "versions.json", size: data.count, redacted: nil, skipped: nil, reason: nil)]
    }

    /// Run `jamf-cli doctor` for `cliProfile` and stage the redacted JSON as
    /// `doctor.json`. Mirrors `collectVersions`' no-injection live-run pattern:
    /// jamf-cli already fingerprints secrets and reports env state, so the only
    /// PII is the server hostname — stripped by the redactor (it walks the
    /// decoded JSON's string values through `redactText`). Returns `[]` (no
    /// entry) when no profile is configured, the binary is absent, or the run
    /// fails — a diagnostic bundle should never fail on its own optional probe.
    static func collectDoctor(
        cliProfile: String, into staging: URL, redactor: DiagnosticRedactor?,
        binary: URL? = ExecutableLocator.locate("jamf-cli")
    ) -> [ManifestEntry] {
        guard !cliProfile.isEmpty, ProfileService.isValid(cliProfile) else { return [] }
        guard let binary else { return [] }
        if CLIBridge.codesignGate(executable: binary, onLine: CLIBridge.noOpOnLine) != nil {
            return []
        }
        // The probe drains both pipes while the child runs; nil is a launch failure or timeout.
        guard let result = JamfCLIProbe.run(
            executable: binary, arguments: ["-p", cliProfile, "doctor", "--output", "json"],
            timeout: 15), result.exitCode == 0 else { return [] }
        return stageDoctorJSON(result.stdout, into: staging, redactor: redactor)
    }

    /// Pure: parse `doctor` JSON, redact it, and write `doctor.json`. Split from
    /// the live run so redaction is unit-testable with a fixture. Returns a
    /// `.skipped` entry when the bytes aren't valid JSON.
    static func stageDoctorJSON(
        _ data: Data, into staging: URL, redactor: DiagnosticRedactor?
    ) -> [ManifestEntry] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else {
            return [.skipped(path: "doctor.json", reason: "could not parse doctor output")]
        }
        let redacted = redactor?.redactJSON(obj) ?? obj
        guard let out = try? JSONSerialization.data(
            withJSONObject: redacted, options: [.prettyPrinted, .sortedKeys]),
            (try? writeData(out, to: staging.appendingPathComponent("doctor.json"))) != nil else {
            return [.skipped(path: "doctor.json", reason: "could not stage doctor output")]
        }
        return [.file(path: "doctor.json", size: out.count, redacted: redactor != nil)]
    }

    // MARK: - Manifest + archive

    private static func buildManifest(
        entries: [ManifestEntry], sources: Sources, options: DiagnosticBundleOptions,
        redactor: DiagnosticRedactor?, now: Date
    ) -> [String: Any] {
        var policy: [String: Any] = ["enabled": redactor != nil]
        if let redactor {
            policy.merge(redactor.policy()) { _, new in new }
        }
        return [
            "schema_version": schemaVersion,
            "generated_at": iso8601(now),
            "workspace": redactor?.redactWorkspaceNames(in: sources.workspaceName)
                ?? sources.workspaceName,
            "log_lookback_days": options.logLookbackDays,
            "summary_limit": options.summaryLimit,
            "redaction_policy": policy,
            "files": entries.map { $0.asDict() },
        ]
    }

    private static func archive(staging: URL, to zipURL: URL) throws {
        // `ditto -c -k` makes a PKZip; without `--keepParent` the staging dir's
        // *contents* land at the archive root (logs/, summaries/, …). --norsrc
        // /--noextattr suppress AppleDouble (`._*`) and `__MACOSX` entries.
        let result = JamfCLIInstaller.runProcessSync(
            executable: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-c", "-k", "--norsrc", "--noextattr", staging.path, zipURL.path],
            // Scrubbed like every other spawn: no DYLD_INSERT_LIBRARIES et al. inherited.
            environment: CLIBridge.environmentForJamfCLI(),
            timeout: 30)
        if result.timedOut {
            throw DiagnosticBundleError.archiveFailed("ditto did not finish within 30 s")
        }
        guard result.exitCode == 0 else {
            throw DiagnosticBundleError.archiveFailed(
                result.stderr.isEmpty ? "ditto exit \(result.exitCode)" : result.stderr)
        }
    }

    // MARK: - Helpers

    private static func makeRedactor(_ options: DiagnosticBundleOptions) -> DiagnosticRedactor {
        DiagnosticRedactor(
            redactHostnames: options.redactHostnames,
            redactSerials: options.redactSerials,
            redactEmails: options.redactEmails,
            redactDeviceNames: options.redactDeviceNames,
            redactUsernames: options.redactUsernames)
    }

    private static func writeText(_ content: String, to url: URL) throws {
        try writeData(Data(content.utf8), to: url)
    }

    /// Write `data`, creating intermediate directories first. `Data.write(to:)`
    /// does not create parents, so staged subdirs (logs/, summaries/) must be
    /// made here or the write fails.
    private static func writeData(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private static func relativePath(of url: URL, under base: URL) -> String {
        let basePath = base.standardizedFileURL.path
        let fullPath = url.standardizedFileURL.path
        if fullPath.hasPrefix(basePath + "/") {
            return String(fullPath.dropFirst(basePath.count + 1))
        }
        return url.lastPathComponent
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
    }

    /// True when `url` is itself a symlink. Collectors skip symlinks so a planted
    /// link cannot pull an out-of-workspace file into the shared bundle. Uses
    /// `attributesOfItem` (lstat — never follows) so it is reliable on a freshly
    /// constructed URL; `URL.resourceValues(.isSymbolicLinkKey)` follows the link
    /// unless the value was pre-fetched by a directory enumerator.
    private static func isSymlink(_ url: URL) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    /// Build a depth-capped indented tree. Line 1 is the workspace basename
    /// only — never an absolute path. Files are sorted; dirs sorted for
    /// determinism. Mirrors the Python `_bundle_collect_workspace_tree` shape.
    private static func buildWorkspaceTree(root: URL, name: String, maxDepth: Int) -> String {
        var lines = ["\(name)/"]
        walkTree(root, depth: 0, maxDepth: maxDepth, lines: &lines)
        return lines.joined(separator: "\n")
    }

    private static func walkTree(
        _ dir: URL, depth: Int, maxDepth: Int, lines: inout [String]
    ) {
        let keys: [URLResourceKey] = [.isDirectoryKey]
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return }
        // lstat, so a symlinked folder is listed by name and never walked.
        let isDir: (URL) -> Bool = {
            var info = stat()
            return lstat($0.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
        }
        let dirs = contents.filter(isDir).sorted { $0.lastPathComponent < $1.lastPathComponent }
        let files = contents.filter { !isDir($0) }
            .map { $0.lastPathComponent }.sorted()
        for file in files {
            lines.append(String(repeating: "  ", count: depth + 1) + file)
        }
        for child in dirs {
            let childDepth = depth + 1
            if childDepth > maxDepth { continue }
            lines.append(String(repeating: "  ", count: childDepth) + child.lastPathComponent + "/")
            walkTree(child, depth: childDepth, maxDepth: maxDepth, lines: &lines)
        }
    }

    // The default is the locator every CLIBridge spawn uses, so the canonical binary is
    // found (Homebrew cellar symlinks, custom PATH installs) rather than a hard-coded path.
    static func jamfCLIVersion(
        binary: URL? = ExecutableLocator.locate("jamf-cli")
    ) -> String {
        guard let binary else {
            return "not installed"
        }
        // Apply the codesign gate before running the binary, mirroring
        // JamfCLIInstaller.installedVersion(at:). On gate failure, omit the
        // version — running an untrusted binary for a diagnostic bundle is not
        // worth the security risk.
        if CLIBridge.codesignGate(executable: binary, onLine: CLIBridge.noOpOnLine) != nil {
            return "unavailable (codesign gate rejected binary)"
        }
        guard let result = JamfCLIProbe.run(
            executable: binary, arguments: ["--version"], timeout: 10) else {
            return "unavailable (did not run)"
        }
        guard result.exitCode == 0 else { return "unavailable (exit \(result.exitCode))" }
        let out = String(decoding: result.stdout, as: UTF8.self)
        let text = out.isEmpty ? String(decoding: result.stderr, as: UTF8.self) : out
        if let first = text.split(separator: "\n").first {
            return first.trimmingCharacters(in: .whitespaces)
        }
        return "unavailable"
    }

    private static func appVersion() -> String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown"
    }

    private static func slug(_ profile: String) -> String {
        let lower = profile.lowercased()
        guard !lower.isEmpty else { return "default" }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789._-")
        var result = ""
        var lastDash = false
        for char in lower {
            if allowed.contains(char) {
                result.append(char)
                lastDash = false
            } else if !lastDash {
                result.append("-")
                lastDash = true
            }
        }
        return result.isEmpty ? "default" : result
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        return formatter.string(from: date)
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
