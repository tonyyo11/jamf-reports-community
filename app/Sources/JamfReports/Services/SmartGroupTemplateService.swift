import Foundation

/// Data models and read-only service for jamf-cli's smart-group template namespace
/// (`pro sg`, introduced upstream in jamf-cli PR #205 — landing in v1.17+).
///
/// **Scope of this file (Stage 1):** read-only operations — `templates` and `preview`.
/// The destructive `apply` operation lives in a sibling service so the trust-boundary
/// surface (first time the app writes to a Jamf tenant) stays narrowly scoped and
/// easy to audit.
///
/// The models mirror PR #205's published contract. If the PR changes shape before
/// merge, only the decoder structs here need to update.

// MARK: - Models

/// One curated smart-group template as returned by `pro sg templates --output json`.
///
/// Templates encode operational knowledge (criterion names verified byte-for-byte
/// against JSS server source). The library covers 5 categories: encryption (6),
/// updates (4), mdm (5), compliance (4), lifecycle (4) = 23 total at PR #205.
struct SmartGroupTemplate: Codable, Sendable, Equatable, Identifiable {
    /// URL-safe slug — the value passed to `--template`.
    /// Example: `"not-encrypted"`, `"stale-checkin"`, `"os-version-below"`.
    let slug: String

    /// Operational category. Stable values: `"encryption"`, `"updates"`, `"mdm"`,
    /// `"compliance"`, `"lifecycle"`. Future categories may be added — UI should
    /// treat the value as opaque, not a closed enum, so an unknown category
    /// surfaces as "Other" rather than crashing the decoder.
    let category: String

    /// Short admin-facing description.
    let description: String

    /// Required and optional parameters the template accepts. Empty for templates
    /// that take no parameters (e.g. `stale-checkin` is fully parameterless).
    let params: [SmartGroupTemplateParam]

    var id: String { slug }
}

/// Parameter accepted by a template. Mirrors `internal/smartgroup.ParamSpec` upstream.
struct SmartGroupTemplateParam: Codable, Sendable, Equatable {
    /// Flag name passed via `--<name>=<value>` to `pro sg preview`/`apply`.
    let name: String

    /// Whether this parameter must be supplied. Optional parameters have defaults
    /// encoded in the template itself.
    let required: Bool

    /// Human-readable description (used in tooltips / form labels).
    let description: String

    /// Optional default value to pre-populate UI inputs. `nil` when the template
    /// requires the operator to specify a value (e.g. an OS version threshold).
    let `default`: String?
}

/// The criteria JSON body that `apply` would POST. Returned by `pro sg preview` and
/// by `apply --dry-run`. The shape is the Jamf Pro `/v2/computer-groups/smart-groups`
/// payload, which is opaque to us — the GUI surfaces it as pretty-printed JSON for
/// user review before consenting to the live apply.
struct SmartGroupPreview: Sendable, Equatable {
    /// Pretty-printed JSON. Stored as a string so the GUI can render it in a code
    /// block without needing to re-encode.
    let bodyJSON: String

    /// Estimated match count when the preview can compute one. `nil` when the
    /// template requires a live API call to evaluate criteria.
    let estimatedMatchCount: Int?
}

// MARK: - Errors

enum SmartGroupTemplateServiceError: Error, Equatable {
    /// `pro sg` was rejected by jamf-cli — feature-detect failed (binary too old).
    case featureNotAvailable
    /// Decoder could not parse the JSON returned by jamf-cli. Wrap the underlying
    /// error description so the GUI can show a meaningful message.
    case decodeFailed(String)
    /// Underlying execution failed (HTTP 401/403/network/etc.). Forwarded from
    /// `CLIExecutorError.nonZeroExit`.
    case executionFailed(code: Int32, stderr: String)
    /// Template slug not recognized by jamf-cli (mistyped or removed upstream).
    case unknownTemplate(String)
}

// MARK: - Service

/// Read-only operations against `pro sg templates` and `pro sg preview`.
///
/// `@MainActor` because the service is consumed by views; the executor itself is
/// `Sendable` and runs the subprocess off the main thread via `CLIBridge`.
@MainActor
final class SmartGroupTemplateService {
    private let executor: CLIExecutor

    init(executor: CLIExecutor) {
        self.executor = executor
    }

    /// Fetches the curated template library. Sorted by category then slug so the
    /// UI gets a deterministic order without having to sort again.
    func listTemplates(profile: String) async throws -> [SmartGroupTemplate] {
        let data = try await runOrTranslate {
            try await executor.execute(.proSmartGroupTemplates(profile: profile))
        }
        do {
            let templates = try JSONDecoder().decode([SmartGroupTemplate].self, from: data)
            return templates.sorted { lhs, rhs in
                if lhs.category != rhs.category { return lhs.category < rhs.category }
                return lhs.slug < rhs.slug
            }
        } catch {
            throw SmartGroupTemplateServiceError.decodeFailed(String(describing: error))
        }
    }

    /// Renders the JSON body that `apply` would POST. No write side-effect.
    /// Used by the GUI to populate the consent screen before an apply.
    func preview(
        profile: String,
        templateSlug: String,
        params: [String: String]
    ) async throws -> SmartGroupPreview {
        let data = try await runOrTranslate {
            try await executor.execute(
                .proSmartGroupPreview(
                    profile: profile,
                    templateSlug: templateSlug,
                    params: params
                )
            )
        }
        return Self.decodePreview(data)
    }

    // MARK: - Internal helpers

    /// Wraps an executor call to translate `CLIExecutorError` into the service's
    /// typed error space. Feature-detect: a `nonZeroExit` with stderr containing
    /// "unknown command" almost certainly means `pro sg` isn't available on the
    /// installed jamf-cli — surface that as `featureNotAvailable` rather than a
    /// generic execution error so the UI can hide buttons gracefully.
    private func runOrTranslate(
        _ work: () async throws -> Data
    ) async throws -> Data {
        do {
            return try await work()
        } catch let CLIExecutorError.nonZeroExit(code, stderr) {
            if Self.stderrIndicatesUnknownCommand(stderr) {
                throw SmartGroupTemplateServiceError.featureNotAvailable
            }
            if Self.stderrIndicatesUnknownTemplate(stderr) {
                throw SmartGroupTemplateServiceError.unknownTemplate(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            // Rewrite the stderr for documented API-error exit codes so the log
            // line at the caller carries a recognisable HTTP-shape signal even
            // when jamf-cli's raw stderr is empty or terse.
            throw SmartGroupTemplateServiceError.executionFailed(
                code: code,
                stderr: Self.annotate(stderr: stderr, withExitCode: code)
            )
        } catch CLIExecutorError.binaryNotFound {
            // jamf-cli not installed at all is "feature not available" from the
            // GUI's perspective — same outcome (hide buttons).
            throw SmartGroupTemplateServiceError.featureNotAvailable
        } catch {
            throw SmartGroupTemplateServiceError.executionFailed(code: -1, stderr: String(describing: error))
        }
    }

    /// Prefixes a documented HTTP-shape annotation onto stderr so executionFailed
    /// log lines distinguish auth/permission/rate-limit failures from generic
    /// errors, even when jamf-cli emits no stderr for the failing call.
    static func annotate(stderr: String, withExitCode code: Int32) -> String {
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix: String?
        switch code {
        case CLIBridge.exitCodeUnauthorized:    prefix = "HTTP 401 Unauthorized"
        case CLIBridge.exitCodePermissionDenied: prefix = "HTTP 403 Forbidden"
        case CLIBridge.exitCodeNotFound:        prefix = "HTTP 404 Not Found"
        case CLIBridge.exitCodeRateLimited:     prefix = "HTTP 429 Too Many Requests"
        default:                                prefix = nil
        }
        guard let prefix else { return stderr }
        return trimmed.isEmpty ? prefix : "\(prefix): \(trimmed)"
    }

    /// jamf-cli's cobra-generated unknown-command error string starts with
    /// "Error: unknown command" or "Error: unknown subcommand". Matched
    /// case-insensitively so a future capitalization change doesn't break detection.
    static func stderrIndicatesUnknownCommand(_ stderr: String) -> Bool {
        let lower = stderr.lowercased()
        return lower.contains("unknown command") || lower.contains("unknown subcommand")
    }

    /// Template-not-found error from PR #205's library lookup path. Matched the
    /// same way as the unknown-command shape.
    static func stderrIndicatesUnknownTemplate(_ stderr: String) -> Bool {
        let lower = stderr.lowercased()
        return lower.contains("unknown template") || lower.contains("template not found")
    }

    /// Decodes preview output. Made internal-static so unit tests can exercise it
    /// against fixture JSON without needing a real `CLIExecutor`.
    static func decodePreview(_ data: Data) -> SmartGroupPreview {
        // The preview command outputs either a JSON object with `body` +
        // `estimated_match_count` fields, or — if PR #205 ships a simpler shape —
        // the raw body JSON. Tolerate both. Match-count is purely advisory; absence
        // is not a decode failure.
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let body = json["body"], JSONSerialization.isValidJSONObject(body) {
                let bodyData = (try? JSONSerialization.data(
                    withJSONObject: body,
                    options: [.prettyPrinted, .sortedKeys]
                )) ?? Data()
                let estimated = json["estimated_match_count"] as? Int
                return SmartGroupPreview(
                    bodyJSON: String(data: bodyData, encoding: .utf8) ?? "",
                    estimatedMatchCount: estimated
                )
            }
        }
        // Fallback: the raw response is itself the body.
        let prettyData = (try? JSONSerialization.jsonObject(with: data))
            .flatMap { try? JSONSerialization.data(
                withJSONObject: $0,
                options: [.prettyPrinted, .sortedKeys]
            ) }
        let pretty = prettyData.flatMap { String(data: $0, encoding: .utf8) }
        return SmartGroupPreview(
            bodyJSON: pretty ?? (String(data: data, encoding: .utf8) ?? ""),
            estimatedMatchCount: nil
        )
    }
}
