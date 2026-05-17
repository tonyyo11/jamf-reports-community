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
struct StaleDataBanner: View {
    let source: CacheSource

    init(source: CacheSource) {
        self.source = source
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
                Spacer(minLength: 0)
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
