import SwiftUI

/// Shared recipe behind every hand-copied "warn/danger/info strip" banner in
/// the app (StaleDataBanner, heavyTierStalePrompt, automationHealthBanner,
/// authWarningBanner, error banners). One canonical visual: HStack, 10h/6v
/// padding, 6pt-radius rounded rect, tone-tinted 0.08 fill / 0.35 stroke.
///
/// `content` carries the label (and any trailing controls); `action` adds an
/// optional trailing button. Kept dumb — no environment reads — so every
/// call site stays a drop-in replacement for its hand-rolled HStack.
struct InlineBannerAction {
    let label: String
    let icon: String?
    let isDisabled: Bool
    let help: String?
    let handler: () -> Void

    init(label: String, icon: String? = nil, isDisabled: Bool = false, help: String? = nil, handler: @escaping () -> Void) {
        self.label = label
        self.icon = icon
        self.isDisabled = isDisabled
        self.help = help
        self.handler = handler
    }
}

enum InlineBannerTone {
    case warn, danger, info

    var color: Color {
        switch self {
        case .warn: Theme.Colors.warn
        case .danger: Theme.Colors.danger
        case .info: Theme.Colors.goldBright
        }
    }
}

struct InlineBanner<Content: View>: View {
    typealias Action = InlineBannerAction
    typealias Tone = InlineBannerTone

    let icon: String
    let tone: Tone
    var action: Action?
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tone.color)
                .accessibilityHidden(true)
            content()
            if let action {
                Spacer(minLength: 8)
                PNPButton(title: action.label, icon: action.icon, size: .sm, action: action.handler)
                    .disabled(action.isDisabled)
                    .help(action.help ?? "")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(tone.color.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(tone.color.opacity(0.35), lineWidth: 0.5)
                )
        )
    }
}

/// Inline freshness banner — surfaces when cached snapshot data is stale or
/// when no live fetch has ever occurred. Renders nothing when the source is
/// `.fresh`, so it is safe to drop unconditionally above any chart or KPI
/// grid backed by cached data.
///
/// Visual contract matches the original `DeviceLookupView.staleBanner` (PR-7):
/// `clock.badge.exclamationmark` icon + warn-toned text on a warn-tinted
/// rounded rect (0.08 fill / 0.35 stroke / 6pt radius). No animation —
/// staleness is a steady-state signal, not an event, so `accessibilityReduceMotion`
/// handling is not required.
///
/// Three states (`CacheSource` enum):
///   - `.fresh` — empty view
///   - `.stale(at:)` — "Stale data — last fetched X ago" (RelativeDateTimeFormatter)
///   - `.neverFetchedLive` — "No live data fetched yet — run Collect to populate"
///
/// The `.neverFetchedLive` case closes the PR-7 BACKLOG CONSIDER about the
/// banner always firing on first install.
///
/// Issue #181: the never-fetched copy says "run Collect" but nothing in the
/// GUI was labeled Collect. Callers that can run a collect pass `onCollect`;
/// the banner then renders a "Collect now" button alongside the message for
/// `.neverFetchedLive` and `.stale(at:)`. Callers without a collect context
/// omit it and keep the informational banner unchanged.
struct StaleDataBanner: View {
    let source: CacheSource
    var onCollect: (() -> Void)?
    var isCollecting: Bool

    init(source: CacheSource, onCollect: (() -> Void)? = nil, isCollecting: Bool = false) {
        self.source = source
        self.onCollect = onCollect
        self.isCollecting = isCollecting
    }

    var body: some View {
        if source.shouldDisplayBanner {
            InlineBanner(
                icon: "clock.badge.exclamationmark",
                tone: .warn,
                action: showsCollectButton ? InlineBannerAction(
                    label: isCollecting ? "Collecting…" : "Collect now",
                    icon: isCollecting ? "hourglass" : "arrow.down.circle",
                    isDisabled: isCollecting,
                    help: "Fetch live jamf-cli data for this profile now."
                ) {
                    guard !isCollecting else { return }
                    onCollect?()
                } : nil
            ) {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Theme.Colors.warn)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(message)
        }
    }

    /// The Collect button renders for any banner-visible state (`.neverFetchedLive`
    /// or `.stale(at:)`) when a handler is provided. Public for tests.
    var showsCollectButton: Bool {
        source.shouldDisplayBanner && onCollect != nil
    }

    /// Public for tests — lets us assert the rendered copy without standing
    /// up a SwiftUI snapshot harness.
    var message: String {
        switch source {
        case .fresh:
            return ""
        case .stale(let date):
            let formatter = RelativeDateTimeFormatter()
            formatter.dateTimeStyle = .named
            let relative = formatter.localizedString(for: date, relativeTo: Date())
            return "Stale data — last fetched \(relative)"
        case .neverFetchedLive:
            return "No live data fetched yet — run Collect to populate"
        }
    }
}

#Preview("Fresh (no banner)") {
    VStack(alignment: .leading, spacing: 8) {
        StaleDataBanner(source: .fresh)
        Text("Fresh state renders nothing")
            .font(.footnote)
            .foregroundStyle(Theme.Colors.fgMuted)
    }
    .padding()
    .frame(width: 400)
    .background(Theme.Colors.winBG)
}

#Preview("Stale (2 days ago)") {
    let past = Calendar.current.date(byAdding: .day, value: -2, to: Date())!
    return StaleDataBanner(source: .stale(at: past))
        .padding()
        .frame(width: 400)
        .background(Theme.Colors.winBG)
}

#Preview("Never fetched live") {
    StaleDataBanner(source: .neverFetchedLive)
        .padding()
        .frame(width: 400)
        .background(Theme.Colors.winBG)
}

/// `StaleDataBanner` with the "Collect now" action wired to the active
/// workspace. Adopt on screens fed by `pro` collect snapshots — NOT on
/// audit-driven screens (Run Audit is their fetch) or Protect (separate
/// collect path). Posts `.refreshActiveTab` when the collect finishes so
/// the hosting screen reloads its snapshot.
///
/// Pass `tiers` to scope the refresh to the data this screen cares about.
/// Defaults to all tiers so callers that don't specify get the same
/// full-collect behaviour as the original first-run path.
struct CollectNowBanner: View {
    @Environment(WorkspaceStore.self) private var workspace
    let source: CacheSource
    var tiers: Set<CollectionTier> = Set(CollectionTier.allCases)
    @State private var isCollecting = false

    var body: some View {
        StaleDataBanner(
            source: source,
            onCollect: { runCollect() },
            isCollecting: isCollecting
        )
    }

    private func runCollect() {
        guard !isCollecting else { return }
        isCollecting = true
        Task {
            await workspace.runTierRefresh(tiers)
            isCollecting = false
            NotificationCenter.default.post(name: .refreshActiveTab, object: nil)
        }
    }
}

#Preview("Never fetched live — Collect action") {
    StaleDataBanner(source: .neverFetchedLive, onCollect: {})
        .padding()
        .frame(width: 400)
        .background(Theme.Colors.winBG)
}

#Preview("Never fetched live — collecting") {
    StaleDataBanner(source: .neverFetchedLive, onCollect: {}, isCollecting: true)
        .padding()
        .frame(width: 400)
        .background(Theme.Colors.winBG)
}
