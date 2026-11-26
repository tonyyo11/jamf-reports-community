import SwiftUI

/// The Overview's "Since last collect" section. Counts only: opening the Macs behind one is
/// a later stage (B2c).
struct OverviewChangesCard: View {
    let changes: OverviewChanges
    /// Today's date as the summaries write it; the card names the day when it differs.
    let today: String
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    SectionHeader(title: OverviewSection.changes.title)
                    if changes.day != today {
                        Text(L("From the summary of \(FleetInsightInput.safeDate(changes.day))"))
                            .font(.caption)
                            .foregroundStyle(Theme.Text.tertiary(contrast))
                    }
                }
                if let note = changes.computerNote {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(Theme.Text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                rows(changes.computerRows + [changes.benchmarkRow].compactMap { $0 })
                if !changes.patchRows.isEmpty {
                    Text(changes.patchScanDay.map {
                        L("Since the last patch scan (\(FleetInsightInput.safeDate($0)))")
                    } ?? L("Since the last patch scan"))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.Colors.fg)
                    rows(changes.patchRows)
                }
                if !changes.agents.isEmpty {
                    Text(L("Agent coverage"))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.Colors.fg)
                    rows(changes.agents)
                }
            }
        }
    }

    private func rows(_ rows: [OverviewChanges.Row]) -> some View {
        EqualHeightTileGrid(minTileWidth: 180, spacing: 8) {
            ForEach(rows) { row in
                HStack {
                    Text(row.label)
                        .font(.footnote)
                        .foregroundStyle(Theme.Text.secondary)
                    Spacer(minLength: 8)
                    Text(row.value)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.Colors.fg)
                        .monospacedDigit()
                }
            }
        }
    }
}
