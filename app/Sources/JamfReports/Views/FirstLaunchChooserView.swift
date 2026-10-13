import SwiftUI

/// First-launch decision screen.
///
/// Replaces the previous behaviour where `WorkspaceStore.init` silently flipped
/// into demo mode whenever no real `jamf-cli` profiles existed. The chooser is
/// only shown when both `workspace.profiles.isEmpty` and `workspace.demoMode`
/// is false — i.e. a fresh install where the user has not yet picked a path.
///
/// Four cards:
/// - "Connect with Jamf Account" (Platform API, recommended for Jamf Cloud) hands off to
///   `OnboardingView` the same way, first setting `OnboardingFlow.pendingProConnectionType` so
///   the Authenticate step opens on the Platform gateway form.
/// - "Connect a Jamf Pro server" (OAuth2) hands off to `OnboardingView` via the existing
///   `.navigateToTab(.onboarding)` notification path.
/// - "Connect Jamf School" hands off to the SAME `OnboardingView`, but first
///   sets `OnboardingFlow.pendingProductPath = .school` so the flow runs the
///   School-only step sequence (no Jamf Pro auth/validate/add-products steps).
/// - "Try the demo first" flips `WorkspaceStore.demoMode` to true (which
///   persists `forceDemoModeKey` so subsequent launches skip the chooser).
///
/// Layout sized to breathe at `JamfReportsApp.minSupportedWidth` (960pt).
/// The card grid uses `LazyVGrid` with two flexible columns so the cards
/// collapse to a stack if the user shrinks the window below the card pair's
/// natural minimum.
struct FirstLaunchChooserView: View {
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.colorSchemeContrast) private var contrast

    /// Called when the user picks "Connect Jamf Pro". The parent
    /// (`ContentView`) flips a `@State` flag so the next render swaps
    /// in `OnboardingView`. Lives on the parent rather than the
    /// workspace store because it is a transient UI choice, not state
    /// the rest of the app needs to observe.
    let onStartOnboarding: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                cardGrid
                productsFootnote
                footnote
            }
            .padding(EdgeInsets(top: 56, leading: 60, bottom: 40, trailing: 60))
            .frame(maxWidth: 920)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.Colors.winBG)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Kicker(text: "First launch", tone: .gold)
            Text("Welcome to Jamf Reports.")
                .font(Theme.Fonts.serif(36, weight: .bold))
                .foregroundStyle(Theme.Colors.fg)
            Text("Connect Jamf Cloud, a Jamf Pro server or Jamf School to build your first workspace, or open the app with demo data to see every screen first.")
                .font(.body)
                .foregroundStyle(Theme.Text.tertiary(contrast))
                .frame(maxWidth: 700, alignment: .leading)
        }
    }

    /// Sets the one-shot handoffs the onboarding flow built next consumes. Each card sets both, so
    /// a card that builds no flow cannot leave another card's choice queued.
    static func queueOnboarding(
        _ path: OnboardingFlow.ProductPath, connection: OnboardingFlow.ProConnectionType?
    ) {
        OnboardingFlow.pendingProductPath = path
        OnboardingFlow.pendingProConnectionType = connection
    }

    private func startOnboarding(
        _ path: OnboardingFlow.ProductPath, connection: OnboardingFlow.ProConnectionType?
    ) {
        Self.queueOnboarding(path, connection: connection)
        onStartOnboarding()
    }

    private var cardGrid: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(minimum: 320), spacing: 18, alignment: .top),
                GridItem(.flexible(minimum: 320), spacing: 18, alignment: .top),
            ],
            spacing: 18
        ) {
            chooserCard(
                icon: "person.badge.key.fill",
                title: "Connect with Jamf Account",
                body: "The recommended way to connect Jamf Cloud: a Jamf Account integration scoped to your environment, through the Jamf Platform API. Reaches Jamf Pro, Compliance Benchmarks and Blueprints.",
                pills: [
                    ("Platform API", "key.fill", Pill.Tone.teal),
                    ("Recommended", "star.fill", Pill.Tone.muted),
                ],
                cta: "Connect with Jamf Account",
                ctaIcon: "arrow.right",
                ctaStyle: .gold,
                action: { startOnboarding(.pro, connection: .platformGateway) }
            )

            chooserCard(
                icon: "network.badge.shield.half.filled",
                title: "Connect a Jamf Pro server",
                body: "For on-prem, GovCloud or any Jamf Pro instance, with an API client (OAuth2). Walks you through jamf-cli auth, workspace setup and an optional CSV mapping.",
                pills: [
                    ("OAuth2", "key.fill", Pill.Tone.teal),
                    ("Local workspace", "folder", Pill.Tone.muted),
                ],
                cta: "Get started",
                ctaIcon: "arrow.right",
                ctaStyle: .neutral,
                action: { startOnboarding(.pro, connection: nil) }
            )

            chooserCard(
                icon: "graduationcap.fill",
                title: "Connect Jamf School",
                body: "Sets up a Jamf School-only workspace — jamf-cli auth with your Network ID and API key, then reports from Jamf School data. Ships community-validated.",
                pills: [
                    ("API key", "key.fill", Pill.Tone.teal),
                    ("K-12 / EDU", "building.columns", Pill.Tone.muted),
                ],
                cta: "Set up School",
                ctaIcon: "arrow.right",
                ctaStyle: .neutral,
                action: { startOnboarding(.school, connection: nil) }
            )

            chooserCard(
                icon: "sparkles",
                title: "Try the demo first",
                body: "Loads synthetic fleet data so you can explore every screen without hitting a Jamf Pro API.",
                pills: [
                    ("No API calls", "wifi.slash", Pill.Tone.muted),
                    ("Read-only", "eye", Pill.Tone.teal),
                ],
                cta: "Use demo data",
                ctaIcon: "play.fill",
                ctaStyle: .neutral,
                action: { workspace.setDemoMode(true) }
            )
        }
    }

    private func chooserCard(
        icon: String,
        title: String,
        body: String,
        pills: [(String, String, Pill.Tone)],
        cta: String,
        ctaIcon: String,
        ctaStyle: PNPButton.Style,
        action: @escaping () -> Void
    ) -> some View {
        Card(padding: 26) {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Theme.Colors.goldBright)
                    .frame(width: 56, height: 56)
                    .background(Theme.Colors.gold.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Theme.Colors.fg)
                    Text(body)
                        .font(.body)
                        .foregroundStyle(Theme.Colors.fg2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 6) {
                    ForEach(Array(pills.enumerated()), id: \.offset) { _, pill in
                        Pill(text: pill.0, tone: pill.2, icon: pill.1)
                    }
                }

                Spacer(minLength: 0)

                PNPButton(title: cta, icon: ctaIcon, style: ctaStyle, size: .lg, action: action)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// What the cards cannot set up, said before someone picks the closest one.
    private var productsFootnote: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "questionmark.circle")
                .foregroundStyle(Theme.Colors.fgMuted)
            Text("Only Jamf Protect or Jamf Security Cloud? Jamf Reports reports on a Jamf Pro or "
                + "Jamf School fleet. Jamf Protect is added to a Jamf Pro workspace, and Jamf "
                + "Security Cloud is not supported yet.")
                .font(.footnote)
                .foregroundStyle(Theme.Text.tertiary(contrast))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footnote: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .foregroundStyle(Theme.Colors.fgMuted)
            Text("You can switch between demo data and a real connection anytime from Settings → jamf-cli → Demo mode.")
                .font(.footnote)
                .foregroundStyle(Theme.Text.tertiary(contrast))
        }
        .padding(.top, 4)
    }
}

#Preview {
    FirstLaunchChooserView(onStartOnboarding: {})
        .environment(WorkspaceStore(demoMode: false))
        .frame(width: 960, height: 760)
}
