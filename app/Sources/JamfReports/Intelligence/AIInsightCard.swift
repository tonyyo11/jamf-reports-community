import SwiftUI

/// The opt-in on-device insight card. A screen passes its own wording and
/// input; the card hides itself off macOS 27, in demo mode and while
/// `ai.enabled` is off. Ungated, through the `FleetInsightGenerator` seam —
/// never imports FoundationModels directly.
struct AIInsightCard: View {
    let title: String
    let idleText: String
    let provenanceText: String
    /// Called only while the card shows (`AIInsightCardModel.shown`).
    let makeInput: @MainActor () -> FleetInsightInput?

    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var model = AIInsightCardModel()

    init(title: String, idleText: String, provenanceText: String, input: FleetInsightInput?) {
        self.init(title: title, idleText: idleText, provenanceText: provenanceText) { input }
    }

    init(
        title: String, idleText: String, provenanceText: String,
        makeInput: @escaping @MainActor () -> FleetInsightInput?
    ) {
        self.title = title
        self.idleText = idleText
        self.provenanceText = provenanceText
        self.makeInput = makeInput
    }

    /// The card's corner label: the short form of `providerName`, which fits one line beside the
    /// title. Not a `Kicker`, which upper-cases its text.
    static let badgeText = "On-Device · Apple Intelligence"
    /// The name Settings and VoiceOver use for Apple's model.
    static let providerName = "On-Device Foundation Model (Apple Intelligence)"

    /// macOS 27 and a live profile. Synchronous, so a screen can leave the
    /// card out of its layout before any config is read.
    static func isOffered(
        demoMode: Bool, platformSupported: Bool = ModelAvailability.platformSupported
    ) -> Bool {
        platformSupported && !demoMode
    }

    /// Decided synchronously, so an absent card adds nothing to its stack, not even spacing.
    var body: some View {
        let shown = model.shown(
            profile: workspace.profile, demoMode: workspace.demoMode, input: makeInput)
        if shown.isPresent {
            card
                .onChange(of: shown.input, initial: true) { _, new in model.setInput(new) }
                // The generator keeps its prewarmed session for the first request.
                .task(id: workspace.profile) {
                    model.select(workspace.profile)
                    await model.prepare()
                }
        }
    }

    /// True until the task has selected the current profile: nothing shown belongs to it yet.
    private var isStale: Bool { model.profile != workspace.profile }

    private var card: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionHeader(title: title)
                    Spacer()
                    Text(Self.badgeText)
                        .font(Theme.Fonts.mono(10.5, weight: .semibold))
                        .tracking(1)
                        .foregroundStyle(Theme.Colors.fgMuted)
                        .lineLimit(1)
                        .accessibilityLabel(Self.providerName)
                }
                content
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    @ViewBuilder
    private var content: some View {
        let availability = model.setup(for: workspace.profile).availability
        if !availability.isReady {
            statusText(availability.message)
        } else if isStale {
            idle
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
            idle
        }
    }

    private var idle: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(idleText)
                .font(.footnote)
                .foregroundStyle(Theme.Text.tertiary(contrast))
                .fixedSize(horizontal: false, vertical: true)
            generateButton("Generate insight")
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
        .disabled(model.input == nil || isStale)
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
    /// A profile's config, model availability and generator, read once per profile.
    struct Setup {
        let config: AIConfig
        let availability: ModelAvailability
        let generator: any FleetInsightGenerator
    }

    /// The profile that the input, insight, spinner and error belong to.
    private(set) var profile: String?
    private(set) var input: FleetInsightInput?
    private(set) var insight: FleetInsight?
    private(set) var isGenerating = false
    private(set) var errorMessage: String?
    /// Filled while the view body runs, so it must not be observed.
    @ObservationIgnored private var setups: [String: Setup] = [:]
    @ObservationIgnored private let makeSetup: @MainActor (String) -> Setup
    /// Bumped by every reset, so a stream started before one stops writing.
    @ObservationIgnored private var generation = 0

    init(makeSetup: @escaping @MainActor (String) -> Setup = AIInsightCardModel.liveSetup) {
        self.makeSetup = makeSetup
    }

    /// A synchronous read of the profile's `ai:` block.
    static func liveSetup(_ profile: String) -> Setup {
        let config = AIConfigLoader.load(profile: profile)
        let availability = ModelAvailability.current(for: config)
        return Setup(config: config, availability: availability,
                     generator: makeInsightGenerator(config: config, availability: availability))
    }

    func setup(for profile: String) -> Setup {
        if let setup = setups[profile] { return setup }
        let setup = makeSetup(profile)
        setups[profile] = setup
        return setup
    }

    /// False where `AIInsightCard.isOffered` is, without reading a config, and
    /// while the profile's `ai.enabled` is off.
    func isPresent(
        profile: String, demoMode: Bool,
        platformSupported: Bool = ModelAvailability.platformSupported
    ) -> Bool {
        AIInsightCard.isOffered(demoMode: demoMode, platformSupported: platformSupported)
            && setup(for: profile).config.isUsable
    }

    /// Whether the card shows and, when it does, its input from `make`. `make` is not called
    /// for a card that does not show, so a screen that redraws often builds nothing while
    /// `ai.enabled` is off.
    func shown(
        profile: String, demoMode: Bool,
        platformSupported: Bool = ModelAvailability.platformSupported,
        input make: () -> FleetInsightInput?
    ) -> (isPresent: Bool, input: FleetInsightInput?) {
        guard isPresent(profile: profile, demoMode: demoMode,
                        platformSupported: platformSupported) else { return (false, nil) }
        return (true, make())
    }

    /// Switches to `profile`, clearing what was shown for another one.
    func select(_ profile: String) {
        guard profile != self.profile else { return }
        self.profile = profile
        reset()
    }

    /// A different input clears what the card showed for the old one.
    func setInput(_ input: FleetInsightInput?) {
        guard input != self.input else { return }
        self.input = input
        reset()
    }

    func prepare() async {
        guard let profile else { return }
        await setup(for: profile).generator.prepare()
    }

    func generate() async {
        guard let profile, let input, !isGenerating else { return }
        let generator = setup(for: profile).generator
        reset()
        isGenerating = true
        let request = generation
        do {
            for try await partial in generator.generateStream(input) {
                guard request == generation else { return }
                insight = partial
            }
            if request == generation {
                isGenerating = false
                insight = insight?.endingOnSentence()
            }
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
