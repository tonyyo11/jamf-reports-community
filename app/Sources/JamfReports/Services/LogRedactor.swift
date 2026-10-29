import Foundation

/// Redacts credential patterns from free-text log lines before they leave the host
/// (clipboard exports, on-disk exports, UI display).
///
/// `redact` is the secret-only tier used for display — PII patterns (hostnames/serials/emails)
/// are out of scope there because jamf-cli output rarely contains raw PII and the
/// false-positive cost on log noise is high. Text that leaves the host goes through
/// `redactedForSharing`, which adds the diagnostic bundle's PII and scope-ID pass.
///
/// Patterns (always on):
/// - OAuth `client_secret` in YAML or JSON form
/// - OAuth `client_id` (long-form values: UUID or 16+ char opaque)
/// - Bearer tokens in HTTP-like contexts
/// - JWTs (three base64url segments separated by dots, starting with `eyJ`)
/// - `access_token` / `refresh_token` JSON shapes
/// - Generic `password` field values
/// - HTTP Basic auth headers (`Authorization: Basic <base64>`)
/// - Webhook URLs in `webhook_url` config keys (Teams / Slack / generic)
/// - Generic `api_key` / `apikey` field values
///
/// Replacement templates preserve surrounding quotes/markers so the redacted
/// output stays valid YAML/JSON for downstream tooling.
enum LogRedactor {

    // MARK: - Patterns

    /// Hosts a Teams, Power Automate or Slack incoming webhook is served from, as host regexes
    /// (no scheme, port or path), paired with the path the secret follows. One list: the
    /// redaction patterns below and Config Doctor's known-host check both read it.
    static let notifyWebhookHosts: [(host: String, path: String)] = [
        (#"hooks\.slack\.com"#, "/services"),
        (#"[A-Za-z0-9.\-]+\.webhook\.office\.com"#, "/"),
        (#"[A-Za-z0-9.\-]+\.logic\.azure\.(?:com|us)"#, "/"),
        // Power Platform trigger hosts: commercial, GCC (`api.gov.powerplatform.microsoft.us`),
        // GCC High (`api.high.…`) and DoD (`api.appsplatform.us`).
        (#"[A-Za-z0-9.\-]+\.api\.powerplatform\.(?:com|us)"#, "/"),
        (#"[A-Za-z0-9.\-]+\.api\.(?:gov|high)\.powerplatform\.microsoft\.us"#, "/"),
        (#"[A-Za-z0-9.\-]+\.api\.appsplatform\.us"#, "/"),
    ]

    /// True when `host` (no port) is one of `notifyWebhookHosts`.
    static func isKnownNotifyWebhookHost(_ host: String) -> Bool {
        notifyWebhookHosts.contains {
            host.range(of: "^" + $0.host + "$", options: [.regularExpression, .caseInsensitive])
                != nil
        }
    }

    /// Incoming-webhook endpoints, as `https?://` URL patterns: `notifyWebhookHosts` and Discord.
    /// Shared with `DiagnosticRedactor`; a host added there reaches both, so the two cannot drift.
    static let webhookURLPatterns: [String] = (
        notifyWebhookHosts.map { $0.host + #"(?::\d+)?"# + $0.path }
            + [#"(?:ptb\.|canary\.)?discord(?:app)?\.com/api/webhooks"#]
    ).map { #"https?://"# + $0 + #"[^\s"',}]*"# }

    /// A `sig=` query value: the signature a Workflows trigger or an Azure SAS URL is signed with.
    static let signatureQueryPattern = #"([?&]sig=)[^\s&"',}]+"#
    static let signatureQueryTemplate = "$1REDACTED_SIG"

    private struct Pattern {
        let regex: NSRegularExpression
        let template: String
    }

    /// Build the compiled pattern table once at first use. Crashes on regex syntax
    /// error are caught up-front during XCTest and surfaced as test failures.
    private static let patterns: [Pattern] = {
        var built: [Pattern] = []

        // OAuth client_secret in YAML or JSON form. The optional `["']?` after the
        // key name catches the JSON shape `"client_secret": "value"`. Min 8 chars
        // on the value to avoid matching example placeholders like `client_secret: x`.
        built.append(Pattern(
            regex: try! NSRegularExpression(
                pattern: #"(client_secret["']?\s*[:=]\s*["']?)([^"'\s,\}]{8,})(["']?)"#,
                options: [.caseInsensitive]
            ),
            template: "$1REDACTED_CLIENT_SECRET$3"
        ))

        // OAuth client_id — UUID (36 chars) or 16+ char opaque token. Shorter
        // values are not redacted to avoid eating example values like `client_id: dev`.
        built.append(Pattern(
            regex: try! NSRegularExpression(
                pattern: #"(client_id["']?\s*[:=]\s*["']?)([A-Fa-f0-9\-]{20,}|[A-Za-z0-9_\-]{16,64})(["']?)"#,
                options: [.caseInsensitive]
            ),
            template: "$1REDACTED_CLIENT_ID$3"
        ))

        // Bearer tokens in HTTP-like contexts (Authorization headers, log echoes).
        // 20-char floor mirrors the Python pattern.
        built.append(Pattern(
            regex: try! NSRegularExpression(
                pattern: #"(Bearer\s+)[A-Za-z0-9._\-+/=]{20,}"#,
                options: [.caseInsensitive]
            ),
            template: "$1REDACTED_BEARER"
        ))

        // JWTs — three base64url segments separated by dots, starting with `eyJ`.
        built.append(Pattern(
            regex: try! NSRegularExpression(
                pattern: #"\beyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\b"#,
                options: []
            ),
            template: "REDACTED_JWT"
        ))

        // OAuth token-response JSON shapes.
        // YAML form intentionally excluded — jamf-cli emits tokens only in JSON
        // API responses, not in YAML config echoes.
        built.append(Pattern(
            regex: try! NSRegularExpression(
                pattern: #"("access_token"\s*:\s*")[^"]+(")"#,
                options: []
            ),
            template: "$1REDACTED_ACCESS_TOKEN$2"
        ))
        built.append(Pattern(
            regex: try! NSRegularExpression(
                pattern: #"("refresh_token"\s*:\s*")[^"]+(")"#,
                options: []
            ),
            template: "$1REDACTED_REFRESH_TOKEN$2"
        ))

        // HTTP Basic auth headers (mirrors Python LogRedactor S-1 pattern).
        // 16-char floor on the base64 payload guards against eating
        // example values like `Authorization: Basic short`.
        built.append(Pattern(
            regex: try! NSRegularExpression(
                pattern: #"(Authorization:\s+Basic\s+)[A-Za-z0-9+/=]{16,}"#,
                options: [.caseInsensitive]
            ),
            template: "$1REDACTED_BASIC"
        ))

        // Webhook URLs in YAML/JSON — Microsoft Teams / Slack / generic
        // webhook_url config keys. Tenant identifiers travel in the path.
        built.append(Pattern(
            regex: try! NSRegularExpression(
                pattern: #"(webhook_url\s*[:=]\s*["']?)(https?://[^\s"',}]+)(["']?)"#,
                options: [.caseInsensitive]
            ),
            template: "$1REDACTED_WEBHOOK_URL$3"
        ))

        // The key-based rule above misses this app's own webhook: NotifyConfig
        // stores it at `notify.url`, i.e. a bare `url:`, not `webhook_url:`. An
        // incoming-webhook URL is a posting credential whose SECRET IS THE PATH,
        // so match the endpoint shape and drop the whole value.
        for pattern in webhookURLPatterns {
            built.append(Pattern(
                regex: try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                template: "REDACTED_WEBHOOK_URL"
            ))
        }

        // A signature query value survives where the host is not a known webhook host, such
        // as a URL cut short or echoed by a proxy.
        built.append(Pattern(
            regex: try! NSRegularExpression(
                pattern: signatureQueryPattern, options: [.caseInsensitive]),
            template: signatureQueryTemplate
        ))

        // Password fields (generic; redact the value, keep the key). The optional
        // `["']?` after the key name catches the JSON shape `"password": "value"`.
        // One-char floor catches "password: x" as well as long values.
        built.append(Pattern(
            regex: try! NSRegularExpression(
                pattern: #"(password["']?\s*[:=]\s*["']?)([^"'\s,\}]{1,})(["']?)"#,
                options: [.caseInsensitive]
            ),
            template: "$1REDACTED_PASSWORD$3"
        ))

        // Generic API keys — covers both `api_key` and `apikey` spellings.
        // The Python `_SENSITIVE_JSON_KEYS` set already redacts these in JSON
        // walks; this pattern catches free-text occurrences in log lines that
        // echo a YAML config or HTTP header. 8-char floor mirrors client_secret.
        built.append(Pattern(
            regex: try! NSRegularExpression(
                pattern: #"(api_?key["']?\s*[:=]\s*["']?)([^"'\s,\}]{8,})(["']?)"#,
                options: [.caseInsensitive]
            ),
            template: "$1REDACTED_API_KEY$3"
        ))

        return built
    }()

    // MARK: - Public API

    /// The text for a clipboard copy or a saved export: `redact`, then the diagnostic bundle's
    /// `DiagnosticRedactor` seeded with `profile`'s tenant and environment IDs and its
    /// configured server, so the Jamf host (an on-prem one too) and the IDs jamf-cli echoes in
    /// its error lines ("Environment '<uuid>' not found") leave as placeholders. A nil `profile`
    /// seeds nothing (demo mode never reads a real config).
    static func redactedForSharing(
        _ text: String,
        profile: String?,
        scopeIDs: (String) -> [String] = { DiagnosticBundleService.scopeIDs(profile: $0) },
        serverHosts: (String) -> [String] = { DiagnosticBundleService.serverHosts(profile: $0) }
    ) -> String {
        redactedForSharing(
            text, profiles: profile.map { [$0] } ?? [],
            scopeIDs: scopeIDs, serverHosts: serverHosts)
    }

    /// As above for a log that mixes several profiles' lines (the in-app buffer): every
    /// profile's IDs and server are seeded.
    static func redactedForSharing(
        _ text: String,
        profiles: [String],
        scopeIDs: (String) -> [String] = { DiagnosticBundleService.scopeIDs(profile: $0) },
        serverHosts: (String) -> [String] = { DiagnosticBundleService.serverHosts(profile: $0) }
    ) -> String {
        let redactor = DiagnosticRedactor()
        // Each seed call replaces the last, so hand over every profile's values at once.
        redactor.seedScopeIDs(profiles.flatMap(scopeIDs))
        redactor.seedServerHosts(profiles.flatMap(serverHosts))
        // The profile is often the organisation's name; the bundle seeds the same forms.
        redactor.seedWorkspaceNames(profiles.flatMap { profile in
            [profile] + [ProfileName.pathComponent, ProfileName.labelComponent].map { $0(profile) }
        })
        return redactor.redactText(redact(text))
    }

    /// Apply all credential patterns to a single line of text. Returns the
    /// redacted line; preserves input if no pattern matches.
    static func redact(_ text: String) -> String {
        var out = text
        for pattern in patterns {
            let range = NSRange(out.startIndex..<out.endIndex, in: out)
            out = pattern.regex.stringByReplacingMatches(
                in: out,
                options: [],
                range: range,
                withTemplate: pattern.template
            )
        }
        return out
    }
}
