import Foundation

// MARK: - Seam (ungated — exists on every OS/toolchain)

/// Turns exec-summary aggregates into a short report narrative paragraph.
/// Mirrors the `FleetInsightGenerator` seam idiom; conformers are the gated
/// `FoundationModelsReportNarrativeGenerator` and `StubReportNarrativeGenerator`.
protocol ReportNarrativeGenerating: Sendable {
    func narrative(_ input: ReportNarrativeInput) async throws -> String
}

// MARK: - Input (aggregate-only, same source as the Executive Summary sheet)

/// The data the narrative is written from: the SAME `ExecutiveSummaryMetrics`
/// aggregates the Executive Summary sheet renders — counts and percentages
/// only, no device/user identifiers, no free-text fields (T-23: nothing here
/// can carry prompt-injection text; the grade is a fixed enum).
struct ReportNarrativeInput: Sendable {
    let metrics: CoreDashboard.ExecutiveSummaryMetrics

    /// Same "has anything to say" bar as `writeExecutiveSummary`.
    static func hasAnyData(_ m: CoreDashboard.ExecutiveSummaryMetrics) -> Bool {
        m.totalDevices != nil || m.patchFleetCompliancePct != nil || m.recentCount != nil
    }

    /// Plain-language prompt context. Absent metrics are omitted (never a
    /// misleading 0). Reuses `FleetInsightInput.budget` for the token cap.
    func promptContext(maxApproxTokens: Int = 1_000) -> String {
        var lines: [String] = ["Fleet executive summary metrics:"]
        appendInt(&lines, "Total devices", metrics.totalDevices)
        appendInt(&lines, "Managed devices", metrics.managedCount)
        if let score = metrics.securityScore {
            var line = "- Security score: \(String(format: "%.1f", score)) / 100"
            if let grade = metrics.securityGrade { line += " (grade \(grade.rawValue))" }
            lines.append(line)
        }
        appendPct(&lines, "Patch fleet compliance", metrics.patchFleetCompliancePct)
        appendPct(&lines, "FileVault coverage", metrics.fileVaultPct)
        appendPct(&lines, "SIP coverage", metrics.sipPct)
        appendPct(&lines, "Firewall coverage", metrics.firewallPct)
        appendInt(&lines, "Recently seen devices (0-30d)", metrics.recentCount)
        appendInt(&lines, "Stale devices offline (31-90d)", metrics.offlineCount)
        appendInt(&lines, "Stale devices inactive (91-180d)", metrics.inactiveCount)
        appendInt(&lines, "Stale devices dormant (180d+)", metrics.dormantCount)
        appendInt(&lines, "P0 action items (FileVault/SIP/Firewall gaps)", metrics.actionItemsP0)
        appendInt(&lines, "P1 action items (Gatekeeper gaps)", metrics.actionItemsP1)
        return FleetInsightInput.budget(lines, maxApproxTokens: maxApproxTokens)
    }

    private func appendInt(_ lines: inout [String], _ label: String, _ value: Int?) {
        guard let value else { return }
        lines.append("- \(label): \(value)")
    }

    private func appendPct(_ lines: inout [String], _ label: String, _ value: Double?) {
        guard let value else { return }
        lines.append("- \(label): \(String(format: "%.1f%%", value))")
    }
}

// MARK: - Stub (ungated — no model)

/// Backs the seam when AI is disabled/unavailable or on a toolchain without
/// FoundationModels. THROWS instead of returning placeholder text (unlike
/// `StubInsightGenerator`, which feeds a card): stub output must never land
/// inside a generated report — a failed narrative means "omit the section".
struct StubReportNarrativeGenerator: ReportNarrativeGenerating {
    let availability: ModelAvailability?

    init(availability: ModelAvailability? = nil) {
        self.availability = availability
    }

    func narrative(_ input: ReportNarrativeInput) async throws -> String {
        throw FleetInsightError.unavailable(availability ?? .disabledByConfig)
    }
}

// MARK: - Factory (ungated signature; FM branch is gated)

/// Picks the conformer for a config + resolved availability. Same shape as
/// `makeInsightGenerator`. The narrative input is aggregates-only (like the
/// insight card), so it resolves via the normal `GeneratorKind.select`.
@MainActor
func makeReportNarrativeGenerator(
    config: AIConfig,
    availability: ModelAvailability
) -> any ReportNarrativeGenerating {
    guard config.isUsable else {
        return StubReportNarrativeGenerator(availability: .disabledByConfig)
    }
    guard availability.isReady else {
        return StubReportNarrativeGenerator(availability: availability)
    }
    // `external` tier is specced but not built; the stub throws → section omitted.
    if GeneratorKind.select(config: config) == .external {
        return StubReportNarrativeGenerator(availability: .requiresMacOS27)
    }

    #if canImport(FoundationModels) && compiler(>=6.4)
    if #available(macOS 27, *) {
        return FoundationModelsReportNarrativeGenerator(config: config)
    }
    #endif
    return StubReportNarrativeGenerator(availability: .requiresMacOS27)
}

// MARK: - GUI choke point (ungated)

/// HARD POLICY (F3): the model is invoked ONLY from GUI-initiated generate
/// flows (OverviewView.runGenerate, GenerateSheet.runGenerate). Headless paths
/// — `main.swift --scheduled-run`, the included `jamf-reports` CLI, and the
/// Schedules "Run now" dispatcher — never call this; their engine calls leave
/// `aiNarrative` at its `nil` default and the section is omitted.
enum ReportNarrative {
    /// Hard timebox — the report must never block on the model.
    static let defaultTimeout: Duration = .seconds(10)

    /// Build the narrative for a GUI generate run, or nil (section omitted)
    /// when AI is disabled, the model isn't ready, there's no aggregate data,
    /// generation errors, or the timebox expires.
    @MainActor
    static func makeForGUIGenerate(
        profile: String, timeout: Duration = defaultTimeout
    ) async -> String? {
        guard ProfileService.isValid(profile) else { return nil }
        let ai = AIConfigLoader.load(profile: profile)
        guard ai.isUsable else { return nil }
        let availability = ModelAvailability.current(for: ai)
        guard availability.isReady else { return nil }
        guard let workspace = ProfileService.workspaceURL(for: profile),
              let dataDir = try? WorkspacePaths.dataDir(for: profile) else { return nil }
        let configURL = workspace.appendingPathComponent("config.yaml")

        // Aggregate build reads cached snapshots — keep the file I/O off-main.
        let input = await Task.detached(priority: .userInitiated) { () -> ReportNarrativeInput? in
            let config = (try? ConfigLoader.load(from: configURL)) ?? ReportConfig()
            let metrics = CoreDashboard.executiveMetrics(config: config, dataDir: dataDir)
            guard ReportNarrativeInput.hasAnyData(metrics) else { return nil }
            return ReportNarrativeInput(metrics: metrics)
        }.value
        guard let input else { return nil }

        let generator = makeReportNarrativeGenerator(config: ai, availability: availability)
        return await generate(generator: generator, input: input, timeout: timeout)
    }

    /// Race generation against the timebox; nil on timeout or any error so the
    /// report proceeds without the section. Internal (not private) for tests.
    static func generate(
        generator: any ReportNarrativeGenerating,
        input: ReportNarrativeInput,
        timeout: Duration = defaultTimeout
    ) async -> String? {
        let result = await withTaskGroup(of: String?.self) { group in
            group.addTask { try? await generator.narrative(input) }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        let trimmed = result?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            AppLogger.platform.notice("Report narrative skipped (timeout, error, or empty output)")
            return nil
        }
        return trimmed
    }
}

// MARK: - Gated FoundationModels implementation (macOS 27 only)

// Same gate discipline as FoundationModelsInsightGenerator: `compiler(>=6.4)`
// is the real discriminator (Xcode 27 only); on the default toolchain this
// whole block elides and the seam is served by StubReportNarrativeGenerator.
#if canImport(FoundationModels) && compiler(>=6.4)
import FoundationModels

/// Narrative generator: aggregates-only input, resolved through the normal
/// `GeneratorKind.select` (same guards as `FoundationModelsInsightGenerator`).
@available(macOS 27, *)
struct FoundationModelsReportNarrativeGenerator: ReportNarrativeGenerating {
    let config: AIConfig

    private static let instructions = """
    You are writing the executive-summary narrative for a Mac fleet report.
    Produce ONE short paragraph (3 to 5 sentences) summarizing overall fleet
    health for a director-level reader. Base every statement only on the
    provided numbers; never invent metrics, and never name devices or people.
    """

    /// Low temperature: the narrative restates the metrics, it doesn't create.
    /// GenerationOptions init verified against the 27 SDK swiftinterface :3157
    /// (`temperature` property :3147).
    private static let options = GenerationOptions(temperature: 0.1)

    func narrative(_ input: ReportNarrativeInput) async throws -> String {
        let kind = GeneratorKind.select(config: config)
        AppLogger.platform.notice("""
            Report narrative requested via \(String(describing: kind), privacy: .public) \
            (tier=\(config.resolvedTier.rawValue, privacy: .public))
            """)

        do {
            switch kind {
            case .onDevice:
                let model = SystemLanguageModel.default
                guard case .available = model.availability else {
                    throw FleetInsightError.unavailable(ModelAvailability.map(model.availability))
                }
                let prompt = input.promptContext(maxApproxTokens: model.contextSize / 4)
                return try await respond(model: model, prompt: prompt)

            case .external:
                // The factory never routes here — guard, never construct.
                throw FleetInsightError.unavailable(.requiresMacOS27)
            }
        } catch let error as FleetInsightError {
            throw error
        } catch {
            AppLogger.platform.error(
                "Report narrative generation failed: \(error.localizedDescription, privacy: .private)")
            throw FleetInsightError.generationFailed(
                FoundationModelsInsightGenerator.userMessage(for: error))
        }
    }

    /// Same capability probes as `FoundationModelsInsightGenerator.respond`:
    /// plain text when guided generation is unsupported, reasoning options
    /// only when advertised.
    private func respond<M: LanguageModel>(model: M, prompt: String) async throws -> String {
        let caps = model.capabilities
        let session = LanguageModelSession(model: model, instructions: Self.instructions)

        guard caps.contains(.guidedGeneration) else {
            let response = try await session.respond(to: prompt, options: Self.options)
            return response.content
        }

        if caps.contains(.reasoning) {
            let contextOptions = ContextOptions(
                reasoningLevel: config.resolvedReasoningLevel.asContextReasoningLevel
            )
            let response = try await session.respond(
                to: prompt,
                generating: FleetIntelligence.GeneratedReportNarrative.self,
                options: Self.options,
                contextOptions: contextOptions
            )
            return response.content.narrative
        }

        let response = try await session.respond(
            to: prompt,
            generating: FleetIntelligence.GeneratedReportNarrative.self,
            options: Self.options
        )
        return response.content.narrative
    }
}

// MARK: - Gated @Generable companion

@available(macOS 27, *)
extension FleetIntelligence {
    /// Single-field structured output keeps the shape constrained; maps to a
    /// plain String across the seam.
    @Generable
    struct GeneratedReportNarrative {
        @Guide(description: "One short paragraph (3-5 sentences) summarizing overall fleet health.")
        var narrative: String
    }
}
#endif
