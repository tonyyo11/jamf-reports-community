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
/// when older than the window.
struct FreshnessChipRow: View {
    /// Kind name → newest snapshot date. A kind absent from disk is absent here.
    let sourceDates: [String: Date]
    /// Injected for deterministic tests; defaults to now.
    var now: Date = Date()
    /// Freshness window in hours — matches the per-service 36h convention.
    var withinHours: Double = 36

    var body: some View {
        if !entries.isEmpty {
            HStack(spacing: 6) {
                ForEach(entries, id: \.kind) { entry in
                    chip(for: entry)
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    private func chip(for entry: Entry) -> some View {
        let stale = CacheSource
            .from(snapshotDate: entry.date, withinHours: withinHours, now: now)
            .shouldDisplayBanner
        let label = "\(entry.kind) · \(Self.relativeLabel(for: entry.date, now: now))"
        return HStack(spacing: 4) {
            Image(systemName: "clock")
                .font(.system(size: 9, weight: .semibold))
                .accessibilityHidden(true)
            Text(label)
                .font(.caption)
        }
        .foregroundStyle(stale ? Theme.Colors.warn : Theme.Colors.fgMuted)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.white.opacity(0.06)))
        .help("\(entry.kind): last collected \(Self.absoluteLabel(for: entry.date))")
        .accessibilityLabel("\(entry.kind), \(Self.relativeLabel(for: entry.date, now: now))")
    }

    /// Sorted, kind-keyed entries (deterministic order for stable layout).
    private var entries: [Entry] {
        sourceDates
            .map { Entry(kind: $0.key, date: $0.value) }
            .sorted { $0.kind < $1.kind }
    }

    private struct Entry {
        let kind: String
        let date: Date
    }

    // MARK: - Pure formatting (testable)

    /// Coarse relative label: "just now" / "Nh ago" / "Nd ago". Deterministic
    /// (no locale-relative formatter) so it is unit-testable and stable across
    /// machines.
    static func relativeLabel(for date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        let hours = Int(seconds / 3600)
        if hours < 1 { return "just now" }
        if hours < 24 { return "\(hours)h ago" }
        let days = hours / 24
        return "\(days)d ago"
    }

    /// Absolute timestamp for the `.help` tooltip.
    static func absoluteLabel(for date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}
