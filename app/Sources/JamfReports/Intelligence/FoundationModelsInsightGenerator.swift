// The entire file is gated: it references macOS-27-only FoundationModels types
// (LanguageModel, SystemLanguageModel, PrivateCloudComputeLanguageModel,
// LanguageModelSession, ContextOptions, LanguageModelError, Prompt). `compiler(>=6.4)`
// is the real discriminator — Xcode 27 is the only toolchain shipping Swift 6.4;
// on the default toolchain (Swift 6.3) this whole block elides and the seam is
// served by StubInsightGenerator. NOT compile-checked by the default toolchain;
// verify with the beta toolchain (DEVELOPER_DIR=/Applications/Xcode-beta.app).
#if canImport(FoundationModels) && compiler(>=6.4)
import Foundation
import FoundationModels

/// Gated namespace for the macOS-27 intelligence layer. The `@Generable`
/// companion (`FleetInsight.swift`) extends this same enum.
@available(macOS 27, *)
enum FleetIntelligence {}

// A class (not a struct) so `prepare()` can retain the prewarmed session for
// the first request. @unchecked Sendable: `config` is immutable Sendable state;
// the only mutable state is the prewarmed-session handoff, guarded by
// `sessionLock` — and LanguageModelSession itself is `@unchecked Sendable`
// per the SDK (swiftinterface :1995).
@available(macOS 27, *)
final class FoundationModelsInsightGenerator: FleetInsightGenerator, @unchecked Sendable {
    let config: AIConfig
    private let sessionLock = NSLock()
    private var prewarmedSession: LanguageModelSession?

    init(config: AIConfig) {
        self.config = config
    }

    private static let instructions = """
    You are a Mac fleet-operations analyst. Given a set of already-collected
    fleet metrics, produce a concise plain-language insight for an IT admin.
    Lead with a one-sentence headline on overall fleet health, then 3 to 6
    prioritized findings. Base every statement only on the provided numbers;
    never invent metrics. Use severity "critical" for security regressions or
    failing controls, "warning" for downward trends or gaps, "info" otherwise.
    """

    // MARK: - Prewarm (session ownership)

    /// Construct and prewarm the session ahead of the first request. Same
    /// selection/guard chain as `generate` — a locked config never constructs
    /// PCC, and a missing entitlement/unavailable model no-ops here (the error
    /// surfaces on `generate`, not on this best-effort warm-up).
    func prepare() async {
        switch GeneratorKind.select(config: config) {
        case .onDevice:
            let model = SystemLanguageModel.default
            guard case .available = model.availability else { return }
            storePrewarmedSession(model: model)
        case .privateCloudCompute:
            guard PCCEntitlement.isPresent else { return }
            let model = PrivateCloudComputeLanguageModel()
            guard case .available = model.availability else { return }
            storePrewarmedSession(model: model)
        case .external:
            return
        }
    }

    private func storePrewarmedSession(model: some LanguageModel) {
        let session = LanguageModelSession(model: model, instructions: Self.instructions)
        session.prewarm(promptPrefix: Prompt(Self.instructions))
        sessionLock.lock()
        prewarmedSession = session
        sessionLock.unlock()
    }

    /// Take-once: the prewarmed session serves the FIRST request only; later
    /// requests get a fresh session so transcripts never accumulate across runs.
    private func takePrewarmedSession() -> LanguageModelSession? {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        let session = prewarmedSession
        prewarmedSession = nil
        return session
    }

    private func makeSession(for model: some LanguageModel) -> LanguageModelSession {
        takePrewarmedSession() ?? LanguageModelSession(model: model, instructions: Self.instructions)
    }

    // MARK: - Prompt budgeting

    /// First pass is the char/4 heuristic; then verify with the model's real
    /// tokenizer (`tokenCount(for:)` is SystemLanguageModel-only) and re-render
    /// at half the budget if the rendered context exceeds the context window.
    /// Best-effort: a tokenCount failure keeps the heuristic result.
    private static func verifiedPrompt(
        for input: FleetInsightInput, model: SystemLanguageModel
    ) async -> String {
        let budget = model.contextSize / 4
        let prompt = input.promptContext(maxApproxTokens: budget)
        guard let tokens = try? await model.tokenCount(for: prompt),
              tokens > model.contextSize else {
            return prompt
        }
        return input.promptContext(maxApproxTokens: budget / 2)
    }

    func generate(_ input: FleetInsightInput) async throws -> FleetInsight {
        // Model selection honoring lock_on_device. Two branches because the
        // concrete model TYPES differ (and only PCC needs async contextSize).
        // lock_on_device (or tier==on_device) constructs ONLY SystemLanguageModel;
        // PrivateCloudComputeLanguageModel() is never reached under a lock.
        let kind = GeneratorKind.select(config: config)
        // Audit trail: successes were previously silent, so a tier flipped by an
        // out-of-band config edit would generate via PCC with no log evidence.
        // Logging the configured tier and lock flag alongside the resolved kind
        // lets an auditor tell "user chose on-device" from "lock overrode pcc".
        AppLogger.platform.notice("""
            Fleet insight requested via \(String(describing: kind), privacy: .public) \
            (tier=\(self.config.resolvedTier.rawValue, privacy: .public), \
            locked=\(self.config.isLockedOnDevice, privacy: .public))
            """)

        do {
            switch kind {
            case .onDevice:
                let model = SystemLanguageModel.default
                guard case .available = model.availability else {
                    throw FleetInsightError.unavailable(ModelAvailability.map(model.availability))
                }
                let prompt = await Self.verifiedPrompt(for: input, model: model)
                return try await respond(model: model, prompt: prompt)

            case .privateCloudCompute:
                // Unreachable when config.isLockedOnDevice (GeneratorKind.select
                // returns .onDevice under a lock) — belt and suspenders.
                // Constructing the PCC model without the entitlement is a
                // fatalError, so refuse (throw, never construct) when it's absent.
                guard PCCEntitlement.isPresent else {
                    throw FleetInsightError.unavailable(.pccEntitlementMissing)
                }
                let model = PrivateCloudComputeLanguageModel()
                guard case .available = model.availability else {
                    throw FleetInsightError.unavailable(ModelAvailability.mapPCC(model.availability))
                }
                let budget = (try? await model.contextSize) ?? 4_096
                let prompt = input.promptContext(maxApproxTokens: budget / 4)
                return try await respond(model: model, prompt: prompt)

            case .external:
                // The factory never routes here (external falls back to the stub
                // until P5). Guard anyway rather than construct anything.
                throw FleetInsightError.unavailable(.requiresMacOS27)
            }
        } catch let error as FleetInsightError {
            throw error
        } catch {
            AppLogger.platform.error("Fleet insight generation failed: \(error.localizedDescription, privacy: .private)")
            throw FleetInsightError.generationFailed(Self.userMessage(for: error))
        }
    }

    /// Run the request using ONLY capabilities the model advertises. The base
    /// on-device model does not support `.reasoning`, so passing a reasoning
    /// level unconditionally makes it reject the request ("doesn't have the
    /// capabilities needed for this operation") — and `PrivateCloudCompute`
    /// *traps* on the same unsupported option instead of throwing. Probe first:
    /// apply a reasoning level only when supported, and fall back to plain text
    /// when the model can't do guided (structured) generation at all.
    private func respond<M: LanguageModel>(model: M, prompt: String) async throws -> FleetInsight {
        let caps = model.capabilities
        let session = makeSession(for: model)

        guard caps.contains(.guidedGeneration) else {
            let response = try await session.respond(to: prompt)
            return FleetInsight(headline: response.content, bullets: [])
        }

        if caps.contains(.reasoning) {
            let options = ContextOptions(
                reasoningLevel: config.resolvedReasoningLevel.asContextReasoningLevel
            )
            let response = try await session.respond(
                to: prompt,
                generating: FleetIntelligence.GeneratedFleetInsight.self,
                contextOptions: options
            )
            return FleetIntelligence.map(response.content)
        }

        let response = try await session.respond(
            to: prompt,
            generating: FleetIntelligence.GeneratedFleetInsight.self
        )
        return FleetIntelligence.map(response.content)
    }

    // MARK: - Streaming

    /// Real streaming: same selection/guard/error chain as `generate`, yielding
    /// a progressively richer `FleetInsight` per response snapshot.
    func generateStream(_ input: FleetInsightInput) -> AsyncThrowingStream<FleetInsight, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.streamInsight(input, into: continuation)
                    continuation.finish()
                } catch let error as FleetInsightError {
                    continuation.finish(throwing: error)
                } catch {
                    AppLogger.platform.error("Fleet insight stream failed: \(error.localizedDescription, privacy: .private)")
                    continuation.finish(
                        throwing: FleetInsightError.generationFailed(Self.userMessage(for: error))
                    )
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func streamInsight(
        _ input: FleetInsightInput,
        into continuation: AsyncThrowingStream<FleetInsight, Error>.Continuation
    ) async throws {
        // Mirrors `generate` exactly: kind selection, tier audit log, PCC
        // entitlement refusal, availability guards.
        let kind = GeneratorKind.select(config: config)
        AppLogger.platform.notice("""
            Fleet insight stream requested via \(String(describing: kind), privacy: .public) \
            (tier=\(self.config.resolvedTier.rawValue, privacy: .public), \
            locked=\(self.config.isLockedOnDevice, privacy: .public))
            """)

        switch kind {
        case .onDevice:
            let model = SystemLanguageModel.default
            guard case .available = model.availability else {
                throw FleetInsightError.unavailable(ModelAvailability.map(model.availability))
            }
            let prompt = await Self.verifiedPrompt(for: input, model: model)
            try await stream(model: model, prompt: prompt, into: continuation)

        case .privateCloudCompute:
            guard PCCEntitlement.isPresent else {
                throw FleetInsightError.unavailable(.pccEntitlementMissing)
            }
            let model = PrivateCloudComputeLanguageModel()
            guard case .available = model.availability else {
                throw FleetInsightError.unavailable(ModelAvailability.mapPCC(model.availability))
            }
            let budget = (try? await model.contextSize) ?? 4_096
            let prompt = input.promptContext(maxApproxTokens: budget / 4)
            try await stream(model: model, prompt: prompt, into: continuation)

        case .external:
            throw FleetInsightError.unavailable(.requiresMacOS27)
        }
    }

    /// Streaming twin of `respond`, with the same capability probes: plain-text
    /// stream when guided generation is unsupported, reasoning options only when
    /// advertised. Snapshots carry all-optional `PartiallyGenerated` content;
    /// `mapPartial` fills the gaps leniently.
    private func stream<M: LanguageModel>(
        model: M, prompt: String,
        into continuation: AsyncThrowingStream<FleetInsight, Error>.Continuation
    ) async throws {
        let caps = model.capabilities
        let session = makeSession(for: model)

        guard caps.contains(.guidedGeneration) else {
            for try await snapshot in session.streamResponse(to: prompt) {
                continuation.yield(FleetInsight(headline: snapshot.content, bullets: []))
            }
            return
        }

        if caps.contains(.reasoning) {
            let options = ContextOptions(
                reasoningLevel: config.resolvedReasoningLevel.asContextReasoningLevel
            )
            for try await snapshot in session.streamResponse(
                to: prompt,
                generating: FleetIntelligence.GeneratedFleetInsight.self,
                contextOptions: options
            ) {
                continuation.yield(FleetIntelligence.mapPartial(snapshot.content))
            }
            return
        }

        for try await snapshot in session.streamResponse(
            to: prompt,
            generating: FleetIntelligence.GeneratedFleetInsight.self
        ) {
            continuation.yield(FleetIntelligence.mapPartial(snapshot.content))
        }
    }

    // MARK: - Error mapping (LanguageModelError + PrivateCloudComputeLanguageModel.Error)

    /// Friendly message for a model error. Covers both the on-device
    /// `LanguageModelError` and the PCC-only `PrivateCloudComputeLanguageModel.Error`
    /// (quota/network) the on-device path never surfaces.
    static func userMessage(for error: Error) -> String {
        if let e = error as? LanguageModelError {
            switch e {
            case .contextSizeExceeded(let c):
                return "Too much fleet data for one insight (\(c.tokenCount)/\(c.contextSize) tokens). Narrow the date range."
            case .rateLimited(let r):
                if let reset = r.resetDate {
                    return "The model is busy; try again after \(reset.formatted())."
                }
                return "The model is rate-limited; try again shortly."
            case .guardrailViolation:
                return "The model declined to summarize this data (safety guardrail)."
            case .refusal:
                return "The model declined to answer."
            case .timeout:
                return "Insight generation timed out. Try again."
            case .unsupportedCapability, .unsupportedGenerationGuide,
                 .unsupportedTranscriptContent, .unsupportedLanguageOrLocale:
                return "The model couldn't produce a structured insight from this data."
            @unknown default:
                return "Insight generation failed."
            }
        }
        if let p = error as? PrivateCloudComputeLanguageModel.Error {
            switch p {
            case .quotaLimitReached(let q):
                if let reset = q.resetDate {
                    return "Private Cloud Compute quota reached; resets \(reset.formatted())."
                }
                return "Private Cloud Compute quota reached."
            case .networkFailure:
                return "Couldn't reach Private Cloud Compute. Check the network."
            case .serviceUnavailable:
                return "Private Cloud Compute is temporarily unavailable."
            @unknown default:
                return "Private Cloud Compute request failed."
            }
        }
        return "Insight generation failed."
    }
}

// MARK: - Partial mapping (streaming)

@available(macOS 27, *)
extension FleetIntelligence {
    /// Map a streaming snapshot's all-optional `PartiallyGenerated` content into
    /// the portable seam model: nil headline renders empty, bullets without text
    /// are skipped, unknown severity falls back to `.info`.
    static func mapPartial(
        _ partial: GeneratedFleetInsight.PartiallyGenerated
    ) -> FleetInsight {
        FleetInsight(
            headline: partial.headline ?? "",
            bullets: (partial.bullets ?? []).compactMap { bullet in
                guard let text = bullet.text, !text.isEmpty else { return nil }
                return InsightBullet(
                    text: text,
                    severity: InsightBullet.Severity(
                        rawValue: (bullet.severity ?? "").lowercased()
                    ) ?? .info
                )
            }
        )
    }
}

// MARK: - Reasoning-level bridge

@available(macOS 27, *)
extension AIConfig.ReasoningLevel {
    /// Bridge the config enum to FoundationModels' `ContextOptions.ReasoningLevel`.
    var asContextReasoningLevel: ContextOptions.ReasoningLevel {
        switch self {
        case .light: return .light
        case .moderate: return .moderate
        case .deep: return .deep
        }
    }
}
#endif
