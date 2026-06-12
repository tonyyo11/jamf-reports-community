import SwiftUI

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
/// `.neverFetchedLive`. Callers without a collect context omit it and keep
/// the informational banner unchanged.
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
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "clock.badge.exclamationmark")
                    .foregroundStyle(Theme.Colors.warn)
                    .accessibilityHidden(true)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Theme.Colors.warn)
                Spacer(minLength: showsCollectButton ? 8 : 0)
                if showsCollectButton {
                    PNPButton(
                        title: isCollecting ? "Collecting…" : "Collect now",
                        icon: isCollecting ? "hourglass" : "arrow.down.circle",
                        size: .sm
                    ) {
                        guard !isCollecting else { return }
                        onCollect?()
                    }
                    .disabled(isCollecting)
                    .help("Fetch live jamf-cli data for this profile now.")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.Colors.warn.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Theme.Colors.warn.opacity(0.35), lineWidth: 0.5)
                    )
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel(message)
        }
    }

    /// The Collect button renders only for `.neverFetchedLive` with a handler:
    /// a stale-but-present cache still drives every dashboard, so the steady
    /// `.stale` state stays informational. Public for tests.
    var showsCollectButton: Bool {
        source == .neverFetchedLive && onCollect != nil
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
struct CollectNowBanner: View {
    @Environment(WorkspaceStore.self) private var workspace
    let source: CacheSource
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
            await workspace.runFirstCollect()
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
