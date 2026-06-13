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
    private var seededRegexes: [String: NSRegularExpression] = [:]

    private let secretPatterns: [(NSRegularExpression, String)]
    private let hostnameURLRE: NSRegularExpression
    private let hostnameBareRE: NSRegularExpression
    private let emailRE: NSRegularExpression
    private let serialRE: NSRegularExpression
    private let homePathRE: NSRegularExpression

    private static let maxSeedPerCategory = 5000
    private static let minSeedLen = 4
    private static let seededCategories =
        ["serial", "device", "udid", "host", "ip", "user", "email", "org"]

    /// Exact key match (lowercased) → value replaced with `REDACTED_<UPPER>`.
    static let sensitiveJSONKeys: Set<String> = [
        "client_secret", "client_id", "access_token", "refresh_token",
        "password", "secret", "api_key", "apikey", "authorization",
        "token", "bearer_token", "session_token", "pat", "private_key",
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
        "ipaddress": "ip", "ip_address": "ip",
        "username": "user", "user_name": "user", "user": "user",
        "realname": "user", "real_name": "user",
        // operatorUserHost is "username@hostname-first-label"; the email regex
        // won't match (no TLD) and no other pattern covers name@machine.
        // Redact the full value under the "user" category.
        "operatoruserhost": "user",
        "email": "email", "emailaddress": "email", "email_address": "email",
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
            #"\b([a-z0-9][a-z0-9\-]{0,62}\.(?:jamfcloud\.com|jamfcloud\.io))\b"#,
            [.caseInsensitive])
        self.emailRE = Self.mustCompile(
            #"\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b"#)
        self.serialRE = Self.mustCompile(#"\b[B-DF-HJ-NP-TV-Z0-9]{10,12}\b"#)
        self.homePathRE = Self.mustCompile(#"(/Users/)([A-Za-z0-9._-]+)"#)
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
        ]
    }

    /// Redact free text: credential patterns (always), then enabled PII regexes,
    /// then any literals seeded from `jamf-cli-data/`.
    func redactText(_ text: String) -> String {
        var out = text
        for (re, template) in secretPatterns {
            out = re.stringByReplacingMatches(
                in: out, range: NSRange(location: 0, length: (out as NSString).length),
                withTemplate: template)
        }
        if redactHostnames {
            out = replaceMatches(hostnameURLRE, in: out) { g in
                (g[1] ?? "") + self.placeholder("host", g[2] ?? "")
            }
            out = replaceMatches(hostnameBareRE, in: out) { g in
                self.placeholder("host", g[0] ?? "")
            }
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
            guard piiEnabled(category), let re = seededRegexes[category] else { continue }
            out = replaceMatches(re, in: out) { g in self.placeholder(category, g[0] ?? "") }
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
                if let category = Self.piiJSONKeys[keyLower],
                   piiEnabled(category), let str = val as? String, !str.isEmpty {
                    out[key] = placeholder(category, str)
                    continue
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
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) else { continue }
            harvest(obj, into: &sets)
        }
        let total = sets.values.reduce(0) { $0 + $1.count }
        for (category, values) in sets { compileSeededRegex(category, from: values) }
        return total
    }

    // MARK: - Internals

    /// Compile one category's harvested literals into an alternation regex and
    /// store it. Extracted from `seedFromWorkspace` to keep that method's
    /// complexity within the project ceiling.
    private func compileSeededRegex(_ category: String, from values: Set<String>) {
        let literals = values.filter { $0.count >= Self.minSeedLen }
            .sorted { $0.count > $1.count }
            .prefix(Self.maxSeedPerCategory)
        guard !literals.isEmpty else { return }
        let pattern = literals.map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        do {
            seededRegexes[category] = try NSRegularExpression(pattern: pattern)
        } catch {
            // Seeding only augments free-text redaction; key-based and regex
            // PII/credential redaction are unaffected. Log so the rare
            // (length-limit) gap is observable rather than silent.
            AppLogger.engine.warning(
                "DiagnosticRedactor: seed compile failed for \(category, privacy: .public)")
        }
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

    /// `udid`, `ip`, and `org` have no keep-flag and are always redacted when
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

    private func harvest(_ value: Any, into sets: inout [String: Set<String>]) {
        if let dict = value as? [String: Any] {
            for (key, val) in dict {
                if let category = Self.piiJSONKeys[key.lowercased()], let str = val as? String {
                    let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { sets[category, default: []].insert(trimmed) }
                }
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
        add(#"(client_secret\s*[:=]\s*["']?)([^"'\s,}]{8,})(["']?)"#,
            "$1REDACTED_CLIENT_SECRET$3")
        add(#"(client_id\s*[:=]\s*["']?)([A-Fa-f0-9\-]{20,}|[A-Za-z0-9_\-]{16,64})(["']?)"#,
            "$1REDACTED_CLIENT_ID$3")
        add(#"(Bearer\s+)[A-Za-z0-9._\-+/=]{20,}"#, "$1REDACTED_BEARER")
        add(#"\beyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\b"#,
            "REDACTED_JWT", ci: false)
        add(#"("access_token"\s*:\s*")[^"]+(")"#, "$1REDACTED_ACCESS_TOKEN$2", ci: false)
        add(#"("refresh_token"\s*:\s*")[^"]+(")"#, "$1REDACTED_REFRESH_TOKEN$2", ci: false)
        add(#"(password\s*[:=]\s*["']?)([^"'\s,}]{1,})(["']?)"#, "$1REDACTED_PASSWORD$3")
        add(#"(api_?key\s*[:=]\s*["']?)([^"'\s,}]{8,})(["']?)"#, "$1REDACTED_API_KEY$3")
        // Single regex token; splitting the literal would obscure the pattern.
        // swiftlint:disable:next line_length
        add(#"((?:\w*token\w*|\bpat|\w*private_key\w*)\s*[:=]\s*["']?)(?!REDACTED)([^"'\s,}]{8,})(["']?)"#,
            "$1REDACTED_TOKEN$3")
        add(#"(Authorization:\s*Basic\s+)[A-Za-z0-9+/=]{8,}"#, "$1REDACTED_BASIC_CREDENTIAL")
        add(#"(webhook_url\s*[:=]\s*["']?)(https?://[^\s"',}]+)(["']?)"#,
            "$1REDACTED_WEBHOOK_URL$3")
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

    /// Generate a bundle for `profile`, returning the written `.zip` URL.
    static func generate(
        profile: String, options: DiagnosticBundleOptions = .init(), now: Date = Date()
    ) throws -> URL {
        guard let workspace = ProfileService.workspaceURL(for: profile)?
            .resolvingSymlinksInPath().standardizedFileURL else {
            throw DiagnosticBundleError.invalidProfile(profile)
        }
        let sources = Sources(
            workspaceName: workspace.lastPathComponent,
            workspaceRoot: workspace,
            logsDir: try WorkspacePaths.runHistoryDir(for: profile),
            summariesDir: try WorkspacePaths.summariesDir(for: profile),
            configURL: workspace.appendingPathComponent("config.yaml"),
            dataDir: try WorkspacePaths.dataDir(for: profile),
            cliProfile: profile
        )
        return try buildBundle(
            sources: sources, outputDir: try WorkspacePaths.diagnosticsDir(for: profile),
            profileSlug: slug(profile), options: options, now: now)
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

        let entries = try stageFiles(
            sources: sources, into: staging, redactor: redactor, options: options, now: now)
        let manifest = buildManifest(
            entries: entries, sources: sources, options: options, redactor: redactor, now: now)
        let manifestData = try JSONSerialization.data(
            withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try manifestData.write(to: staging.appendingPathComponent("manifest.json"))

        let zipURL = outputDir.appendingPathComponent(
            "jamf-reports-diagnostic-\(profileSlug)-\(stamp).zip")
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
            AppLogger.engine.warning(
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
        var entries: [ManifestEntry] = []
        entries += collectLogs(
            from: sources.logsDir, into: staging, redactor: redactor,
            days: options.logLookbackDays, now: now)
        entries += collectSummaries(
            from: sources.summariesDir, into: staging, redactor: redactor,
            limit: options.summaryLimit)
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

    private static func collectLogs(
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
            let arcname = "logs/\(relativePath(of: url, under: logsDir))"
            guard let data = try? Data(contentsOf: url) else {
                entries.append(.skipped(path: arcname, reason: "could not read log"))
                continue
            }
            var content = String(decoding: data, as: UTF8.self)
            if let redactor { content = redactor.redactText(content) }
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
            .sorted { lhs, rhs in modified(lhs) > modified(rhs) }
            .prefix(limit)
        var entries: [ManifestEntry] = []
        for url in summaries {
            let arcname = "summaries/\(url.lastPathComponent)"
            if isSymlink(url) {
                entries.append(.skipped(path: arcname, reason: "symlink — skipped"))
                continue
            }
            guard let data = try? Data(contentsOf: url),
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
        guard let data = try? Data(contentsOf: configURL) else {
            return [.skipped(path: "config.yaml", reason: "could not read config")]
        }
        var content = String(decoding: data, as: UTF8.self)
        if let redactor { content = redactor.redactText(content) }
        try writeText(content, to: staging.appendingPathComponent("config.yaml"))
        return [.file(path: "config.yaml", size: content.utf8.count, redacted: redactor != nil)]
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
        cliProfile: String, into staging: URL, redactor: DiagnosticRedactor?
    ) -> [ManifestEntry] {
        guard !cliProfile.isEmpty, ProfileService.isValid(cliProfile) else { return [] }
        guard let binary = ExecutableLocator.locate("jamf-cli") else { return [] }
        if CLIBridge.codesignGate(executable: binary, onLine: CLIBridge.noOpOnLine) != nil {
            return []
        }
        let result = runProcess(
            binary.path, ["-p", cliProfile, "doctor", "--output", "json"], timeout: 15)
        guard result.code == 0, let data = result.stdout.data(using: .utf8) else { return [] }
        return stageDoctorJSON(data, into: staging, redactor: redactor)
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
            "workspace": sources.workspaceName,
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
        let result = runProcess(
            "/usr/bin/ditto",
            ["-c", "-k", "--norsrc", "--noextattr", staging.path, zipURL.path])
        guard result.code == 0 else {
            throw DiagnosticBundleError.archiveFailed(
                result.stderr.isEmpty ? "ditto exit \(result.code)" : result.stderr)
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
        let isDir: (URL) -> Bool = {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
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

    private static func jamfCLIVersion() -> String {
        // Use the same locator every CLIBridge spawn uses so we get the canonical
        // binary (handles Homebrew cellar symlinks, custom PATH installs, etc.)
        // rather than hard-coded paths that may miss the actual installation.
        guard let binary = ExecutableLocator.locate("jamf-cli") else {
            return "not installed"
        }
        // Apply the codesign gate before running the binary, mirroring
        // JamfCLIInstaller.installedVersion(at:). On gate failure, omit the
        // version — running an untrusted binary for a diagnostic bundle is not
        // worth the security risk.
        if CLIBridge.codesignGate(executable: binary, onLine: CLIBridge.noOpOnLine) != nil {
            return "unavailable (codesign gate rejected binary)"
        }
        let result = runProcess(binary.path, ["--version"], timeout: 10)
        guard result.code == 0 else { return "unavailable (exit \(result.code))" }
        let text = result.stdout.isEmpty ? result.stderr : result.stdout
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

    private static func runProcess(
        _ executable: String, _ arguments: [String], timeout: TimeInterval = 30
    ) -> (code: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            return (-1, "", error.localizedDescription)
        }
        // Watchdog: terminate a wedged child so the bundle can't hang the UI
        // indefinitely (the pipe read below blocks until the process exits).
        let box = ProcessBox(process)
        let watchdog = DispatchWorkItem { if box.process.isRunning { box.process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        return (
            process.terminationStatus,
            String(decoding: outData, as: UTF8.self),
            String(decoding: errData, as: UTF8.self))
    }
}

/// Carries a `Process` into the timeout watchdog closure. `Process.terminate()`
/// and `isRunning` are documented thread-safe, so unchecked-Sendable is sound —
/// mirrors the `TextLineBuffer` pattern used elsewhere in the app.
private final class ProcessBox: @unchecked Sendable {
    let process: Process
    init(_ process: Process) { self.process = process }
}
