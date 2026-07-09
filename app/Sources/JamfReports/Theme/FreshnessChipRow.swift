import SwiftUI

/// Compact per-kind freshness chips for operational screens (Patch, Updates,
/// Security Posture, Devices). Unlike `ProvenanceBadge` — which reports the
/// digest-level `collectionSources` for summary-driven screens — this row shows
/// the newest on-disk file date for each raw jamf-cli kind the screen reads, so
/// a screen that merges kinds surfaces per-kind staleness honestly instead of
/// collapsing to one date.
///
/// Coloring reuses `CacheSource.from` (the 36h freshness convention) so the
/// fresh/stale decision stays single-sourced: muted when fresh, warn-colored
/// when older than the window. A kind named in `expectedKinds` but absent from
/// `sourceDates` renders a danger-toned "never" chip instead of silently
/// vanishing — a kind that stops being collected is worse than a stale one.
struct FreshnessChipRow: View {
    /// Kind name → newest snapshot date. A kind absent from disk is absent here.
    let sourceDates: [String: Date]
    /// Kind names the calling screen reads. A kind listed here but missing from
    /// `sourceDates` gets an explicit "never" chip. Defaults to `[]`, which
    /// reproduces the pre-2.6 behavior of only ever showing present kinds.
    var expectedKinds: [String] = []
    /// Injected for deterministic tests; defaults to now.
    var now: Date = Date()
    /// Freshness window in hours — matches the per-service 36h convention.
    var withinHours: Double = 36

    var body: some View {
        // The Settings "Skip expensive collections" toggle makes the four
        // per-device kinds intentionally absent — a "never" chip there would be
        // a false alarm, so skipped kinds are not "expected".
        let skipExpensive = UserDefaults.standard.bool(forKey: "skipExpensiveCollections")
        let effectiveExpected = skipExpensive
            ? expectedKinds.filter { !ReportEngine.expensivePerDeviceKinds.contains($0) }
            : expectedKinds
        let models = Self.chipModels(sourceDates: sourceDates, expectedKinds: effectiveExpected, now: now)
        if !models.isEmpty {
            // FlowLayout (shared with TrendsView's metric pills row) wraps to a
            // new line instead of overflowing when an absent-kind chip pushes
            // the row past the available width.
            FlowLayout(spacing: 6) {
                ForEach(models, id: \.kind) { model in
                    chip(for: model)
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    private func chip(for model: ChipModel) -> some View {
        let display = Self.displayInfo(for: model, now: now, withinHours: withinHours)
        return HStack(spacing: 4) {
            Image(systemName: display.icon)
                .font(.system(size: 9, weight: .semibold))
                .accessibilityHidden(true)
            Text(display.label)
                .font(.caption)
        }
        .foregroundStyle(display.tone)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.white.opacity(0.06)))
        .help(display.help)
        .accessibilityLabel(display.accessibilityLabel)
    }

    /// One chip per kind: `.present` for every entry in `sourceDates`, `.absent`
    /// for every `expectedKinds` entry missing from it. Sorted by kind name for
    /// stable, deterministic layout.
    struct ChipModel: Equatable {
        let kind: String
        let state: State

        enum State: Equatable {
            case present(Date)
            case absent
        }
    }

    /// Pure chip-model derivation — `nonisolated` because `View` conformance
    /// MainActor-isolates statics on Swift 6.1, which would break nonisolated
    /// test callers (6.3 relaxes this; see `relativeLabel` below).
    nonisolated static func chipModels(
        sourceDates: [String: Date],
        expectedKinds: [String] = [],
        now: Date = Date()
    ) -> [ChipModel] {
        var models = sourceDates.map { ChipModel(kind: $0.key, state: .present($0.value)) }
        let present = Set(sourceDates.keys)
        for kind in expectedKinds where !present.contains(kind) {
            models.append(ChipModel(kind: kind, state: .absent))
        }
        return models.sorted { $0.kind < $1.kind }
    }

    private struct ChipDisplay {
        let icon: String
        let label: String
        let tone: Color
        let help: String
        let accessibilityLabel: String
    }

    /// Pure per-chip presentation, `nonisolated` for the same reason as
    /// `chipModels`.
    nonisolated private static func displayInfo(
        for model: ChipModel, now: Date, withinHours: Double
    ) -> ChipDisplay {
        switch model.state {
        case .present(let date):
            let stale = CacheSource
                .from(snapshotDate: date, withinHours: withinHours, now: now)
                .shouldDisplayBanner
            let relative = relativeLabel(for: date, now: now)
            return ChipDisplay(
                icon: "clock",
                label: "\(model.kind) · \(relative)",
                tone: stale ? Theme.Colors.warn : Theme.Colors.fgMuted,
                help: "\(model.kind): last collected \(absoluteLabel(for: date))",
                accessibilityLabel: "\(model.kind), \(relative)"
            )
        case .absent:
            return ChipDisplay(
                icon: "exclamationmark.triangle",
                label: "\(model.kind) · never",
                tone: Theme.Colors.danger,
                help: "\(model.kind): never collected",
                accessibilityLabel: "\(model.kind), never collected"
            )
        }
    }

    // MARK: - Pure formatting (testable)

    /// Coarse relative label: "just now" / "Nh ago" / "Nd ago". Deterministic
    /// (no locale-relative formatter) so it is unit-testable and stable across
    /// machines. `nonisolated`: View conformance MainActor-isolates statics on
    /// Swift 6.1, which breaks nonisolated test callers (6.3 relaxes this).
    nonisolated static func relativeLabel(for date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        let hours = Int(seconds / 3600)
        if hours < 1 { return "just now" }
        if hours < 24 { return "\(hours)h ago" }
        let days = hours / 24
        return "\(days)d ago"
    }

    /// Absolute timestamp for the `.help` tooltip.
    nonisolated static func absoluteLabel(for date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}
