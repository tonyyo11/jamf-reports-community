import Foundation

/// Wraps the destructive `pro sg apply` operation (jamf-cli v1.17+, PR #205).
///
/// **First write surface in the app.** Every existing flow is read-only; this
/// service is the only path that creates or updates state in a Jamf Pro tenant.
/// The trust-boundary expansion is narrow on purpose: the GUI collects explicit
/// user consent via `SmartGroupApplySheet` before constructing the CLICommand,
/// and the executor's `--yes` flag is intentional (the GUI has no TTY for an
/// interactive confirmation prompt — consent is collected at the SwiftUI layer).

// MARK: - Result model

/// The structured result of a successful `pro sg apply` invocation.
///
/// PR #205 emits a result envelope with the smart-group ID Jamf Pro assigned
/// (or matched, for idempotent updates), the name as stored, and a post-apply
/// membership count from the immediate API call the CLI performs after the
/// create/update.
struct SmartGroupApplyResult: Sendable, Equatable {
    /// Smart-group ID assigned by Jamf Pro. Drives the "Reveal in Jamf Pro" link.
    let smartGroupID: Int

    /// Group name as stored in Jamf Pro. May differ from the requested name only
    /// if Jamf Pro normalized it (whitespace, etc.); usually identical.
    let name: String

    /// Devices that match the group's criteria right after apply. The CLI fetches
    /// this via `/v2/computer-groups/smart-groups/<id>/membership` after the create
    /// or update. `nil` only if the membership call itself failed (group was still
    /// created — surface as a "created, count unavailable" message).
    let memberCount: Int?

    /// Whether the apply created a new group (true) or updated an existing one
    /// by name (false). Matters for the success-card copy.
    let created: Bool
}

// MARK: - Errors

enum SmartGroupApplyError: Error, Equatable {
    /// jamf-cli's `pro sg` namespace is missing — the binary is older than v1.17.
    /// Callers should feature-detect upstream and not reach this.
    case featureNotAvailable
    /// Jamf API rejected the request — 401 (auth), 403 (permission), 429 (rate
    /// limit), etc. Surfaced to the user with the original code.
    case apiError(httpStatus: Int, message: String)
    /// Network failure or non-HTTP error reported by jamf-cli.
    case networkFailure(String)
    /// The CLI returned non-JSON or unexpected JSON. The string is the raw stderr.
    case unexpectedOutput(String)
    /// Generic non-zero exit not otherwise classified.
    case executionFailed(code: Int32, stderr: String)
}

// MARK: - Service

/// `@MainActor` because results bind directly into SwiftUI view-models.
@MainActor
final class SmartGroupApplyService {
    private let executor: CLIExecutor

    init(executor: CLIExecutor) {
        self.executor = executor
    }

    /// Applies a template to create or update a smart group by name.
    ///
    /// `dryRun: true` exercises the same code path but tells jamf-cli to validate
    /// without writing. Useful for a "dry-run first" preview workflow even though
    /// `preview` already shows the criteria — `apply --dry-run` additionally
    /// confirms the request would be accepted by Jamf Pro (e.g. catches name
    /// collisions before the real apply lands).
    func apply(
        profile: String,
        templateSlug: String,
        smartGroupName: String,
        params: [String: String] = [:],
        recalculate: Bool = false,
        dryRun: Bool = false
    ) async throws -> SmartGroupApplyResult {
        let command = CLICommand.proSmartGroupApply(
            profile: profile,
            templateSlug: templateSlug,
            smartGroupName: smartGroupName,
            params: params,
            recalculate: recalculate,
            dryRun: dryRun
        )
        let data: Data
        do {
            data = try await executor.execute(command)
        } catch let CLIExecutorError.nonZeroExit(code, stderr) {
            throw Self.classifyError(code: code, stderr: stderr)
        } catch CLIExecutorError.binaryNotFound {
            throw SmartGroupApplyError.featureNotAvailable
        } catch {
            throw SmartGroupApplyError.executionFailed(code: -1, stderr: String(describing: error))
        }
        return try Self.decodeResult(data)
    }

    // MARK: - Internal helpers (exposed for tests)

    /// Translates jamf-cli stderr / exit-code patterns into the typed error space.
    /// The dispatch is text-pattern-based because jamf-cli doesn't emit a stable
    /// error-classification field; PR #205's apply path forwards Jamf Pro API
    /// errors as `"Error: HTTP <code>: <message>"` (see the upstream
    /// `cliCtx.Client.Do` wrapper).
    static func classifyError(code: Int32, stderr: String) -> SmartGroupApplyError {
        let lower = stderr.lowercased()
        if lower.contains("unknown command") || lower.contains("unknown subcommand") {
            return .featureNotAvailable
        }
        // HTTP <code>: <message> — common case from cliCtx.Client.Do.
        if let httpInfo = Self.extractHTTPError(from: stderr) {
            return .apiError(httpStatus: httpInfo.code, message: httpInfo.message)
        }
        // Network errors usually surface as "Get/Post <url>: connection refused",
        // "i/o timeout", "no such host", etc. Detect a few stable substrings.
        let networkPatterns = ["connection refused", "i/o timeout", "no such host",
                               "tls handshake", "context deadline exceeded"]
        if networkPatterns.contains(where: lower.contains) {
            return .networkFailure(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return .executionFailed(code: code, stderr: stderr)
    }

    /// Pulls `(code, message)` out of strings shaped like
    /// `"Error: HTTP 401: Unauthorized"` or `"HTTP 429 Too Many Requests"`.
    /// Returns nil when no HTTP-status pattern is present.
    static func extractHTTPError(from stderr: String) -> (code: Int, message: String)? {
        // Anchor on " HTTP " followed by 3-digit code; capture the trailing message.
        let pattern = #"HTTP\s+(\d{3})[:\s]+([^\n]+)"#
        guard let range = stderr.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        let matched = String(stderr[range])
        guard let codeRange = matched.range(of: #"\d{3}"#, options: .regularExpression),
              let code = Int(matched[codeRange]) else {
            return nil
        }
        // Everything after the code, trimming the separator characters.
        let afterCode = matched[codeRange.upperBound...]
        let message = afterCode
            .drop(while: { $0 == ":" || $0 == " " })
            .trimmingCharacters(in: .whitespaces)
        return (code, message)
    }

    /// Decodes the apply result envelope. PR #205's apply emits an object like:
    /// `{"id": 42, "name": "Stale 90d", "member_count": 17, "created": true}`.
    /// The decoder tolerates camelCase or snake_case keys since the upstream
    /// JSON serializer convention isn't fully locked in the PR.
    static func decodeResult(_ data: Data) throws -> SmartGroupApplyResult {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SmartGroupApplyError.unexpectedOutput(
                String(data: data, encoding: .utf8) ?? ""
            )
        }
        guard let id = json["id"] as? Int ?? json["smartGroupId"] as? Int ?? json["smart_group_id"] as? Int else {
            throw SmartGroupApplyError.unexpectedOutput(
                "apply result missing 'id' field: " + (String(data: data, encoding: .utf8) ?? "")
            )
        }
        let name = json["name"] as? String ?? ""
        let memberCount = json["member_count"] as? Int
            ?? json["memberCount"] as? Int
            ?? json["matched_count"] as? Int
            ?? json["matchedCount"] as? Int
        let created = json["created"] as? Bool ?? true
        return SmartGroupApplyResult(
            smartGroupID: id,
            name: name,
            memberCount: memberCount,
            created: created
        )
    }
}
