import SwiftUI

/// The opt-in on-device insight card. A screen passes its own wording and
/// input; the card hides itself off macOS 27, in demo mode and while
/// `ai.enabled` is off. Ungated, through the `FleetInsightGenerator` seam —
/// never imports FoundationModels directly.
struct AIInsightCard: View {
    let title: String
    let idleText: String
    let provenanceText: String
    let input: FleetInsightInput?

    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var model = AIInsightCardModel()

    /// macOS 27 and a live profile. Synchronous, so a screen can leave the
    /// card out of its layout before any config is read.
    static func isOffered(
        demoMode: Bool, platformSupported: Bool = ModelAvailability.platformSupported
    ) -> Bool {
        platformSupported && !demoMode
    }

    var body: some View {
        switch model.presence(profile: workspace.profile, demoMode: workspace.demoMode) {
        case .hidden:
            EmptyView()
        case .loading:
            // A zero-size host: an empty view never runs its task.
            Color.clear.frame(width: 0, height: 0)
                .task(id: workspace.profile) { bind(workspace.profile) }
        case .shown:
            card
                .onChange(of: input, initial: true) { _, new in model.setInput(new) }
                // The generator keeps its prewarmed session for the first request.
                .task(id: workspace.profile) { await model.prepare() }
        }
    }

    private func bind(_ profile: String) {
        let config = AIConfigLoader.load(profile: profile)
        let availability = ModelAvailability.current(for: config)
        model.bind(profile: profile, config: config, availability: availability,
                   generator: makeInsightGenerator(config: config, availability: availability))
    }

    private var card: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionHeader(title: title)
                    Spacer()
                    Kicker(text: "macOS 27", tone: .muted)
                }
                content
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    @ViewBuilder
    private var content: some View {
        if !model.availability.isReady {
            statusText(model.availability.message)
        } else if let insight = model.insight {
            // Before isGenerating so streamed partials render as they arrive;
            // the spinner covers only the wait for the first snapshot.
            resultView(insight)
        } else if model.isGenerating {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Generating insight…")
                    .font(.footnote)
                    .foregroundStyle(Theme.Text.tertiary(contrast))
            }
        } else if let errorMessage = model.errorMessage {
            VStack(alignment: .leading, spacing: 8) {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(Theme.Colors.warn)
                    .fixedSize(horizontal: false, vertical: true)
                generateButton("Try again")
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(idleText)
                    .font(.footnote)
                    .foregroundStyle(Theme.Text.tertiary(contrast))
                    .fixedSize(horizontal: false, vertical: true)
                generateButton("Generate insight")
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
            Text(provenanceText)
                .font(.caption2)
                .foregroundStyle(Theme.Text.tertiary(contrast))
                .fixedSize(horizontal: false, vertical: true)
            generateButton("Regenerate")
        }
    }

    private func generateButton(_ label: String) -> some View {
        PNPButton(title: label, icon: "sparkles", size: .sm) {
            Task { await model.generate() }
        }
        .disabled(model.input == nil)
    }

    private func severityColor(_ severity: InsightBullet.Severity) -> Color {
        switch severity {
        case .info: Theme.Colors.teal
        case .warning: Theme.Colors.warn
        case .critical: Theme.Colors.danger
        }
    }
}

/// What `AIInsightCard` shows, kept out of the view so a test can drive it.
@MainActor @Observable
final class AIInsightCardModel {
    enum Presence: Equatable { case hidden, loading, shown }

    private(set) var availability: ModelAvailability = .requiresMacOS27
    private(set) var input: FleetInsightInput?
    private(set) var insight: FleetInsight?
    private(set) var isGenerating = false
    private(set) var errorMessage: String?
    private var profile: String?
    private var config = AIConfig()
    @ObservationIgnored private var generator: (any FleetInsightGenerator)?
    /// Bumped by every reset, so a stream started before one stops writing.
    @ObservationIgnored private var generation = 0

    /// Hidden where `AIInsightCard.isOffered` is false and while `ai.enabled`
    /// is off; loading until `profile`'s config has been read.
    func presence(
        profile: String, demoMode: Bool,
        platformSupported: Bool = ModelAvailability.platformSupported
    ) -> Presence {
        guard AIInsightCard.isOffered(demoMode: demoMode, platformSupported: platformSupported)
        else { return .hidden }
        guard self.profile == profile else { return .loading }
        return config.isUsable ? .shown : .hidden
    }

    func bind(profile: String, config: AIConfig, availability: ModelAvailability,
              generator: any FleetInsightGenerator) {
        self.profile = profile
        self.config = config
        self.availability = availability
        self.generator = generator
        reset()
    }

    /// A different input clears what the card showed for the old one.
    func setInput(_ input: FleetInsightInput?) {
        guard input != self.input else { return }
        self.input = input
        reset()
    }

    func prepare() async {
        await generator?.prepare()
    }

    func generate() async {
        guard let input, let generator, !isGenerating else { return }
        reset()
        isGenerating = true
        let request = generation
        do {
            for try await partial in generator.generateStream(input) {
                guard request == generation else { return }
                insight = partial
            }
            if request == generation { isGenerating = false }
        } catch {
            guard request == generation else { return }
            // An interrupted insight is not trustworthy, and would hide the error.
            insight = nil
            isGenerating = false
            errorMessage = Self.message(for: error)
        }
    }

    private func reset() {
        generation += 1
        insight = nil
        errorMessage = nil
        isGenerating = false
    }

    private static func message(for error: Error) -> String {
        switch error as? FleetInsightError {
        case .unavailable(let reason)?:
            return reason.message
        case .generationFailed(let message)?:
            return message
        case nil:
            AppLogger.platform.error(
                "AIInsightCard generate failed: \(error.localizedDescription, privacy: .private)")
            return "Insight generation failed."
        }
    }
}
