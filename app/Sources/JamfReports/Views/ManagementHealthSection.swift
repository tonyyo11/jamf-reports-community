import SwiftUI

/// The "Management health" card on the Audit screen (`ManagementCard`): one row per finding
/// with its Mac count and denominator, grouped Gaps, Warnings and Counts, then the neutral
/// on/off settings and the Automated Device Enrollment token. A gap or warning row opens
/// Computers on the Management filter. Draws nothing without a card.
struct ManagementHealthSection: View {
    let card: ManagementCard?

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        if let card, !card.isEmpty {
            Card(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader(title: L("Management health")).padding(16)
                    if let note = card.inventoryNote { noteText(note) }
                    group(L("Gaps"), card.gaps)
                    group(L("Warnings"), card.warnings)
                    group(L("Counts"), card.counts)
                    group(L("Settings"), card.settings)
                    tokenGroup(card)
                }
            }
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ rows: [ManagementCard.Row]) -> some View {
        if !rows.isEmpty {
            caption(title)
            ForEach(rows) { row in rowView(row) }
        }
    }

    @ViewBuilder
    private func tokenGroup(_ card: ManagementCard) -> some View {
        if !card.tokens.isEmpty || card.tokenNote != nil {
            caption(L("Automated Device Enrollment token"))
            ForEach(card.tokens) { row in rowView(row) }
            if let note = card.tokenNote { noteText(note) }
        }
    }

    private func noteText(_ note: String) -> some View {
        Text(note)
            .font(.footnote)
            .foregroundStyle(Theme.Text.tertiary(contrast))
            .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private func caption(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().background(Theme.Colors.hairline)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.Text.tertiary(contrast))
                .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 2)
                .accessibilityAddTraits(.isHeader)
        }
    }

    @ViewBuilder
    private func rowView(_ row: ManagementCard.Row) -> some View {
        if row.opensComputers {
            Button(action: openComputers) { rowContent(row) }
                .buttonStyle(.plain)
                .help(L("Open Computers on the Management filter."))
                .accessibilityHint(L("Opens Computers on the Management filter."))
        } else {
            rowContent(row)
        }
    }

    private func rowContent(_ row: ManagementCard.Row) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                if row.tone == .neutral {
                    Color.clear.frame(width: 86, height: 1)
                } else {
                    Pill(text: Self.pillText(row.tone), tone: Self.pillTone(row.tone))
                        .frame(width: 86, alignment: .leading)
                }
                Text(row.title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.Colors.fg)
                Spacer()
                Text(row.value).font(.footnote.monospacedDigit())
                    .foregroundStyle(Theme.Colors.fg2)
                if row.opensComputers {
                    Image(systemName: "chevron.right")
                        .font(.caption2).foregroundStyle(Theme.Text.tertiary(contrast))
                        .accessibilityHidden(true)
                }
            }
            if let breakdown = row.breakdown {
                Text(breakdown)
                    .font(.caption)
                    .foregroundStyle(Theme.Text.tertiary(contrast))
                    .padding(.leading, 96)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func openComputers() {
        NotificationCenter.default.post(
            name: .navigateToTab, object: nil,
            userInfo: DevicesView.DeviceFilter.management.navigationUserInfo())
    }

    static func pillText(_ tone: ManagementCard.Tone) -> String {
        switch tone {
        case .gap: L("GAP")
        case .warning: L("WARNING")
        case .neutral: ""
        }
    }

    static func pillTone(_ tone: ManagementCard.Tone) -> Pill.Tone {
        switch tone {
        case .gap: .danger
        case .warning: .warn
        case .neutral: .muted
        }
    }
}
