import Foundation

/// Redacts credential patterns from free-text log lines before they leave the host
/// (clipboard exports, on-disk exports, UI display).
///
/// Secret-only redaction tier — PII patterns (hostnames/serials/emails) are
/// out of scope for run-log redaction because jamf-cli output rarely contains
/// raw PII and the false-positive cost on log noise is high.
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
