import SwiftUI

/// The "Server and admin health" card on the Audit screen: the Jamf Pro server's own
/// credentials with days left, or why one could not be read. Draws nothing until a source has
/// been attempted. Copy is a DRAFT for the visual pass.
struct ServerHealthSection: View {
    let health: ServerHealth?

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        if let health, health.hasAttempt {
            Card(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader(title: L("Server and admin health")).padding(16)
                    Divider().background(Theme.Colors.hairline)
                    ForEach(health.credentials.filter { $0.fact != .notCollected }, id: \.key) {
                        rowView(title: Self.title($0), fact: $0.fact)
                    }
                    if health.notifications != .notCollected {
                        rowView(title: L("Jamf Pro notifications"), fact: health.notifications)
                    }
                    let hygiene = health.adminHygiene.filter { $0.fact != .notCollected }
                    if !hygiene.isEmpty {
                        Text(L("Admin hygiene")).font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.Colors.fg2)
                            .padding(.horizontal, 16).padding(.top, 8)
                        ForEach(hygiene, id: \.kind) { rowView(title: $0.label, fact: $0.fact) }
                    }
                    Text(L("ADE tokens: see Management health"))
                        .font(.footnote)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                        .padding(.horizontal, 16).padding(.vertical, 8)
                }
            }
        }
    }

    private func rowView(title: String, fact: ServerHealth.FactState) -> some View {
        HStack(spacing: 10) {
            if Self.pillText(fact).isEmpty {
                Color.clear.frame(width: 86, height: 1)
            } else {
                Pill(text: Self.pillText(fact), tone: Self.pillTone(fact))
                    .frame(width: 86, alignment: .leading)
            }
            Text(title).font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.Colors.fg)
            Spacer()
            Text(ServerHealth.text(for: fact)).font(.footnote.monospacedDigit())
                .foregroundStyle(Theme.Colors.fg2)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    static func title(_ row: ServerHealth.CredentialRow) -> String {
        row.key == "ca" ? L("Built-in CA") : row.label
    }

    private static func state(_ fact: ServerHealth.FactState) -> CredentialExpiry.State? {
        if case .value(.credential(let credential), _) = fact { return credential.state }
        return nil
    }

    static func pillText(_ fact: ServerHealth.FactState) -> String {
        switch state(fact) {
        case .expired?: L("EXPIRED")
        case .expiring?: L("EXPIRING")
        default: ""
        }
    }

    static func pillTone(_ fact: ServerHealth.FactState) -> Pill.Tone {
        switch state(fact) {
        case .expired?: .danger
        case .expiring?: .warn
        default: .muted
        }
    }
}
