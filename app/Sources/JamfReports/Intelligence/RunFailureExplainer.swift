import Foundation

// MARK: - Seam (ungated — exists on every OS/toolchain)

/// Turns a redacted failed-run log excerpt into a plain-language explanation.
/// Mirrors the `FleetInsightGenerator` seam idiom; conformers are the gated
/// `FoundationModelsRunFailureExplainer` (on-device model ONLY) and
/// `StubRunFailureExplainer` (deterministic, no model).
protocol RunFailureExplaining: Sendable {
    func explain(_ input: RunFailureInput) async throws -> RunFailureExplanation
}

/// Portable explanation result. Plain `Sendable` value — never carries
/// `@Generable`; the gated companion maps INTO this type across the seam.
struct RunFailureExplanation: Sendable, Equatable {
    var summary: String
    var likelyCause: String
    var firstStep: String
}

// MARK: - Input (redaction enforced at construction)

/// The data the explainer diagnoses from. PRIVACY INVARIANT: the initializer is
/// private and the only way to construct a value is `build(...)`, which applies
/// FULL redaction (LogRedactor credential patterns + DiagnosticRedactor PII
/// pass: hostnames, emails, serials, usernames) and tail-truncates BEFORE
/// storing — an unredacted log excerpt is unconstructable by design.
struct RunFailureInput: Sendable {
    /// Redacted, length-capped run label (free text from a log filename).
    let label: String
    let exitCode: Int32?
    /// Formatted from a `Date` at construction — never free text, so the prompt
    /// can't be injected through it (the T-23 discipline).
    let dateRange: String
    /// Last `maxExcerptLines` lines of the log, fully redacted.
    let redactedLogExcerpt: String

    static let maxExcerptLines = 200

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    private init(label: String, exitCode: Int32?, dateRange: String, redactedLogExcerpt: String) {
        self.label = label
        self.exitCode = exitCode
        self.dateRange = dateRange
        self.redactedLogExcerpt = redactedLogExcerpt
    }

    /// The ONLY constructor. Redacts every free-text field before storing.
    static func build(
        label: String, exitCode: Int32?, runDate: Date, rawLog: String
    ) -> RunFailureInput {
        RunFailureInput(
            label: String(LogRedactor.redact(label).prefix(120)),
            exitCode: exitCode,
            dateRange: dateFormatter.string(from: runDate),
            redactedLogExcerpt: redactedExcerpt(from: rawLog)
        )
    }

    /// Tail-truncate to `maxExcerptLines`, then apply full redaction: the
    /// credential patterns (`LogRedactor`) plus the full-PII text pass
    /// (`DiagnosticRedactor` with every category on — hostnames, emails,
    /// serials, usernames). Logs are the one AI input class with residual PII
    /// risk, so both tiers run unconditionally.
    static func redactedExcerpt(from rawLog: String) -> String {
        let tail = rawLog.components(separatedBy: "\n").suffix(maxExcerptLines)
        return DiagnosticRedactor().redactText(LogRedactor.redact(tail.joined(separator: "\n")))
    }

    /// Prompt context for the model. Budgeting keeps the header and the NEWEST
    /// excerpt lines (the failure evidence is at the tail, unlike the fleet
    /// insight's head-weighted `budget`).
    func promptContext(maxApproxTokens: Int = 1_500) -> String {
        let header = [
            "Scheduled run \"\(label)\" on \(dateRange) failed.",
            "Exit code: \(exitCode.map { String($0) } ?? "unknown").",
            "Redacted log excerpt (newest lines last):",
        ]
        return Self.budgetTail(
            header: header,
            excerpt: redactedLogExcerpt.components(separatedBy: "\n"),
            maxApproxTokens: maxApproxTokens
        )
    }

    /// ~4 chars/token heuristic (same as `FleetInsightInput.budget`), but keeps
    /// trailing excerpt lines and drops from the FRONT; always keeps at least
    /// one excerpt line so the failure line is never budgeted away.
    static func budgetTail(header: [String], excerpt: [String], maxApproxTokens: Int) -> String {
        let maxChars = max(0, maxApproxTokens) * 4
        var used = header.reduce(0) { $0 + $1.count + 1 }
        var kept: [String] = []
        for line in excerpt.reversed() {
            let cost = line.count + 1
            if used + cost > maxChars, !kept.isEmpty { break }
            kept.append(line)
            used += cost
        }
        return (header + kept.reversed()).joined(separator: "\n")
    }
}

// MARK: - On-device pinning (ungated, pure — provable on the default toolchain)

extension AIConfig {
    /// Copy of this config with `lock_on_device` forced on. The run-failure
    /// explainer selects its generator from this copy so log excerpts NEVER
    /// leave the box, regardless of the user's configured tier.
    var lockedOnDeviceCopy: AIConfig {
        var copy = self
        copy.lockOnDevice = true
        return copy
    }
}

/// Pure generator-kind resolution for the explainer: ALWAYS selects on the
/// locked copy, so any tier (pcc, external) resolves to `.onDevice`. Ungated so
/// the guarantee is testable without FoundationModels.
func runFailureGeneratorKind(for config: AIConfig) -> GeneratorKind {
    GeneratorKind.select(config: config.lockedOnDeviceCopy)
}

// MARK: - Stub (ungated — no model, deterministic)

/// Backs the seam when AI is disabled/unavailable or on a toolchain without
/// FoundationModels. Mirrors `StubInsightGenerator`.
struct StubRunFailureExplainer: RunFailureExplaining {
    /// When set, explains WHY the stub is in play. nil = neutral placeholder.
    let availability: ModelAvailability?

    init(availability: ModelAvailability? = nil) {
        self.availability = availability
    }

    func explain(_ input: RunFailureInput) async throws -> RunFailureExplanation {
        RunFailureExplanation(
            summary: availability?.message ?? "AI insights are not enabled for this profile.",
            likelyCause: "",
            firstStep: ""
        )
    }
}

// MARK: - Factory (ungated signature; FM branch is gated)

/// Picks the conformer for a config + resolved availability. PRIVACY: logs are
/// the one input class with residual PII risk, so the real explainer is handed
/// `config.lockedOnDeviceCopy` — `GeneratorKind.select` on a locked config can
/// never resolve to PCC/external, so no off-box model type is ever constructed
/// for a log excerpt, regardless of the user's tier. Callers should probe
/// `ModelAvailability.current(for: config.lockedOnDeviceCopy)` for the same
/// reason (a pcc tier without the entitlement must not mask on-device readiness).
@MainActor
func makeRunFailureExplainer(
    config: AIConfig,
    availability: ModelAvailability
) -> any RunFailureExplaining {
    guard config.isUsable else { return StubRunFailureExplainer(availability: .disabledByConfig) }
    guard availability.isReady else { return StubRunFailureExplainer(availability: availability) }

    #if canImport(FoundationModels) && compiler(>=6.4)
    if #available(macOS 27, *) {
        return FoundationModelsRunFailureExplainer(config: config.lockedOnDeviceCopy)
    }
    #endif
    return StubRunFailureExplainer(availability: .requiresMacOS27)
}

// MARK: - Gated FoundationModels implementation (macOS 27 only)

// Same gate discipline as FoundationModelsInsightGenerator: `compiler(>=6.4)`
// is the real discriminator (Xcode 27 only); on the default toolchain this
// whole block elides and the seam is served by StubRunFailureExplainer.
#if canImport(FoundationModels) && compiler(>=6.4)
import FoundationModels

/// On-device-ONLY explainer. The factory pins the config via
/// `lockedOnDeviceCopy`; `explain` additionally refuses any non-on-device kind
/// (defense in depth) — a log excerpt is never sent to PCC or an external model.
@available(macOS 27, *)
struct FoundationModelsRunFailureExplainer: RunFailureExplaining {
    let config: AIConfig

    private static let instructions = """
    You are diagnosing a failed scheduled run of a Mac fleet-reporting tool.
    Diagnose ONLY from the provided log excerpt; never invent commands, file
    paths, or facts that are not present in the log. Produce a one-sentence
    plain-language summary of the failure, the single most likely cause, and
    exactly one concrete first troubleshooting step for the admin.
    """

    func explain(_ input: RunFailureInput) async throws -> RunFailureExplanation {
        let kind = GeneratorKind.select(config: config)
        AppLogger.platform.notice(
            "Run failure explanation requested via \(String(describing: kind), privacy: .public)")

        // The factory's locked copy makes this unreachable — refuse (never
        // construct an off-box model) if a future caller bypasses the factory.
        guard kind == .onDevice else {
            throw FleetInsightError.unavailable(.unknown("Run logs are analyzed on-device only."))
        }

        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            throw FleetInsightError.unavailable(ModelAvailability.map(model.availability))
        }
        let prompt = input.promptContext(maxApproxTokens: model.contextSize / 4)

        do {
            return try await respond(model: model, prompt: prompt)
        } catch let error as FleetInsightError {
            throw error
        } catch {
            AppLogger.platform.error(
                "Run failure explanation failed: \(error.localizedDescription, privacy: .private)")
            throw FleetInsightError.generationFailed(
                FoundationModelsInsightGenerator.userMessage(for: error))
        }
    }

    /// Same capability probes as `FoundationModelsInsightGenerator.respond`:
    /// plain text when guided generation is unsupported (whole response into
    /// `summary`), reasoning options only when advertised.
    private func respond(
        model: SystemLanguageModel, prompt: String
    ) async throws -> RunFailureExplanation {
        let caps = model.capabilities
        let session = LanguageModelSession(model: model, instructions: Self.instructions)

        guard caps.contains(.guidedGeneration) else {
            let response = try await session.respond(to: prompt)
            return RunFailureExplanation(summary: response.content, likelyCause: "", firstStep: "")
        }

        if caps.contains(.reasoning) {
            let options = ContextOptions(
                reasoningLevel: config.resolvedReasoningLevel.asContextReasoningLevel
            )
            let response = try await session.respond(
                to: prompt,
                generating: FleetIntelligence.GeneratedRunFailureExplanation.self,
                contextOptions: options
            )
            return FleetIntelligence.map(response.content)
        }

        let response = try await session.respond(
            to: prompt,
            generating: FleetIntelligence.GeneratedRunFailureExplanation.self
        )
        return FleetIntelligence.map(response.content)
    }
}

// MARK: - Gated @Generable companion

@available(macOS 27, *)
extension FleetIntelligence {
    /// Structured-output companion for guided generation. Lives inside the gate
    /// (`@Generable`/`@Guide` are macOS-27-only macros); maps 1:1 to the
    /// portable `RunFailureExplanation`.
    @Generable
    struct GeneratedRunFailureExplanation {
        @Guide(description: "One-sentence plain-language summary of why the run failed.")
        var summary: String
        @Guide(description: "The single most likely cause, based only on the log excerpt.")
        var likelyCause: String
        @Guide(description: "One concrete first troubleshooting step for the admin.")
        var firstStep: String
    }

    /// Map the guided-generation value into the portable seam model.
    static func map(_ generated: GeneratedRunFailureExplanation) -> RunFailureExplanation {
        RunFailureExplanation(
            summary: generated.summary,
            likelyCause: generated.likelyCause,
            firstStep: generated.firstStep
        )
    }
}
#endif
