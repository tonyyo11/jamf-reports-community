import SwiftUI

/// Provenance chip for digest-driven screens (Overview, Trends, Fleet
/// Overview): the numbers come from the once-a-day summary digest, not live
/// inventory. When the digest recorded its input sources (R4) and any were
/// cached or missing, the chip says so instead of letting stale data wear a
/// fresh date.
struct ProvenanceBadge: View {
    /// Digest date (`DailySummary.date`); nil when no summary exists yet.
    let asOf: String?
    /// `DailySummary.collectionSources` — kind → "live" | "cache" | "absent".
    var sources: [String: String]? = nil

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 9, weight: .semibold))
                .accessibilityHidden(true)
            Text(label)
                .font(.caption)
        }
        .foregroundStyle(degradedNote == nil ? Theme.Colors.fgMuted : Theme.Colors.warn)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.white.opacity(0.06)))
        .help(helpText)
        .accessibilityLabel(label)
    }

    /// Public for tests.
    var label: String {
        let base = asOf.map { "Daily summary digest · \($0)" }
            ?? "Daily summary digest · none yet"
        guard let degradedNote else { return base }
        return "\(base) · \(degradedNote)"
    }

    /// "N cached, M missing" when the digest's recorded inputs were not all
    /// live; nil when all live or unrecorded. Public for tests.
    var degradedNote: String? {
        guard let sources, !sources.isEmpty else { return nil }
        let cached = sources.values.filter { $0 == "cache" }.count
        let absent = sources.values.filter { $0 == "absent" }.count
        guard cached > 0 || absent > 0 else { return nil }
        var parts: [String] = []
        if cached > 0 { parts.append("\(cached) cached") }
        if absent > 0 { parts.append("\(absent) missing") }
        return "sources: \(parts.joined(separator: ", "))"
    }

    private var helpText: String {
        var text = "This screen renders the once-a-day summary digest, not live inventory. "
            + "Per-device truth lives on the Devices, Patch, Updates, and posture screens."
        if let sources, !sources.isEmpty {
            let detail = sources.sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value)" }
                .joined(separator: ", ")
            text += "\nDigest inputs — \(detail)."
        }
        return text
    }
}
