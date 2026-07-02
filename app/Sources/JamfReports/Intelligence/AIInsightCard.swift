import SwiftUI

/// Card rendering the macOS-27 opt-in fleet insight. Ungated — compiles and
/// renders on every OS version: below macOS 27 (or off the beta toolchain) it
/// resolves to `.requiresMacOS27` and shows the same messaging a disabled/
/// unavailable model would, all through the `ModelAvailability`/
/// `FleetInsightGenerator` seam. Never imports FoundationModels directly.
///
/// DRAFT — needs visual verification at PageScaffold.minSupportedWidth.
struct AIInsightCard: View {
    let profile: String
    let current: DailySummary?
    let previous: DailySummary?

    @Environment(\.colorSchemeContrast) private var contrast
    @State private var config: AIConfig = AIConfig()
    @State private var availability: ModelAvailability = .requiresMacOS27
    @State private var generator: (any FleetInsightGenerator)?
    @State private var insight: FleetInsight?
    @State private var isGenerating = false
    @State private var errorMessage: String?

    var body: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionHeader(title: "AI Fleet Insight")
                    Spacer()
                    Kicker(text: "macOS 27", tone: .muted)
                }
                content
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("AI Fleet Insight")
        .task(id: profile) {
            config = AIConfigLoader.load(profile: profile)
            availability = ModelAvailability.current(for: config)
            insight = nil
            errorMessage = nil
            // Hold the generator so its prewarmed session survives to the first
            // request; prepare() is a no-op for the stub.
            let prepared = makeInsightGenerator(config: config, availability: availability)
            generator = prepared
            await prepared.prepare()
        }
    }

    @ViewBuilder
    private var content: some View {
        if !config.isUsable {
            statusText(ModelAvailability.disabledByConfig.message)
        } else if !availability.isReady {
            statusText(availability.message)
        } else if let insight {
            // Before isGenerating so streamed partials render as they arrive;
            // the spinner covers only the wait for the first snapshot.
            resultView(insight)
        } else if isGenerating {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Generating insight…")
                    .font(.footnote)
                    .foregroundStyle(Theme.Text.tertiary(contrast))
            }
        } else if let errorMessage {
            VStack(alignment: .leading, spacing: 8) {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(Theme.Colors.warn)
                    .fixedSize(horizontal: false, vertical: true)
                generateButton(title: "Try again")
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Turn today's fleet data into a plain-language summary using \(tierLabel).")
                    .font(.footnote)
                    .foregroundStyle(Theme.Text.tertiary(contrast))
                    .fixedSize(horizontal: false, vertical: true)
                generateButton(title: "Generate insight")
            }
        }
    }

    private func statusText(_ message: String) -> some View {
        Text(message)
            .font(.footnote)
            .foregroundStyle(Theme.Text.tertiary(contrast))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func resultView(_ insight: FleetInsight) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(insight.headline)
                .font(.callout.weight(.semibold))
                .foregroundStyle(Theme.Colors.fg)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(insight.bullets.enumerated()), id: \.offset) { _, bullet in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle()
                        .fill(severityColor(bullet.severity))
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                    Text(bullet.text)
                        .font(.footnote)
                        .foregroundStyle(Theme.Colors.fg2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // T-25: the insight reads as authoritative without a provenance cue;
            // keep the "verify against the real tiles" property explicit.
            Text("AI-generated from the daily digest — verify against the tiles below.")
                .font(.caption2)
                .foregroundStyle(Theme.Text.tertiary(contrast))
                .fixedSize(horizontal: false, vertical: true)
            generateButton(title: "Regenerate")
        }
    }

    private func generateButton(title: String) -> some View {
        PNPButton(title: title, icon: "sparkles", size: .sm) {
            guard current != nil else { return }
            generate()
        }
        .disabled(current == nil)
    }

    private func severityColor(_ severity: InsightBullet.Severity) -> Color {
        switch severity {
        case .info: Theme.Colors.teal
        case .warning: Theme.Colors.warn
        case .critical: Theme.Colors.danger
        }
    }

    private var tierLabel: String {
        config.resolvedTier == .pcc ? "Private Cloud Compute" : "on-device intelligence"
    }

    private func generate() {
        guard let current, !isGenerating else { return }
        isGenerating = true
        insight = nil
        errorMessage = nil
        let generatorConfig = config
        let generatorAvailability = availability
        let heldGenerator = generator
        let input = FleetInsightInput.build(current: current, previous: previous)
        Task { @MainActor in
            // Prefer the held (prewarmed) generator; fall back for the first
            // click racing the .task that creates it.
            let generator = heldGenerator
                ?? makeInsightGenerator(config: generatorConfig, availability: generatorAvailability)
            defer { isGenerating = false }
            do {
                for try await partial in generator.generateStream(input) {
                    insight = partial
                }
            } catch let error as FleetInsightError {
                // Drop any mid-stream partial: it would mask the error branch
                // and an interrupted insight isn't trustworthy anyway.
                insight = nil
                switch error {
                case .unavailable(let reason):
                    errorMessage = reason.message
                case .generationFailed(let message):
                    errorMessage = message
                }
            } catch {
                insight = nil
                AppLogger.platform.error("AIInsightCard generate failed: \(error.localizedDescription, privacy: .private)")
                errorMessage = "Insight generation failed."
            }
        }
    }
}
