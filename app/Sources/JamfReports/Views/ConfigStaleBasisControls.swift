import SwiftUI

/// Config › Thresholds: which dates make a Mac stale (`thresholds.stale_basis`) and how far
/// a Mac's check-in or inventory may lag its last contact (`thresholds.contact_gap_days`).
/// Both save through `ConfigService`: the basis only when it is not the default, the gap only
/// when it is not 14 days.
struct StaleBasisControls: View {
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldLabel(label: "Stale counts", trailing: "stale_basis")
            ForEach(StaleBasis.allCases, id: \.self) { date in
                basisRow(date)
            }
            FieldHelp(text: "A Mac is stale when any date turned on is more than the stale "
                + "threshold ago. Last contact counts MDM and declarative device management "
                + "too; a Mac with none recorded is not judged by it.")
        }
        .padding(.bottom, 12)
        VStack(alignment: .leading, spacing: 4) {
            FieldLabel(label: "Contact gap", trailing: "contact_gap_days")
            EditableNumberStepper(
                value: gapDays, range: ContactGap.dayRange, suffix: "days",
                help: "How far a Mac's check-in or inventory may lag its last contact.")
            FieldHelp(text: "The Health Audit and Devices flag a Mac MDM still reaches when its "
                + "last check-in, or its last inventory, is more than this many days behind its "
                + "last contact.")
        }
        .padding(.bottom, 12)
    }

    private func basisRow(_ date: StaleBasis) -> some View {
        HStack {
            Text(date.label).font(.callout).foregroundStyle(Theme.Text.primary)
            Spacer()
            PNPToggle(isOn: isOn(date), label: date.label)
        }
    }

    private func isOn(_ date: StaleBasis) -> Binding<Bool> {
        Binding(
            get: { workspace.configState.staleBasis.contains(date) },
            set: { workspace.configState.staleBasis = Self.setting(
                date, on: $0, in: workspace.configState.staleBasis) })
    }

    private var gapDays: Binding<Int> {
        Binding(
            get: { workspace.configState.contactGapDaysValue },
            set: { workspace.configState.contactGapDays = String($0) })
    }

    /// `basis` with `date` turned on or off. At least one date stays on: turning off the last
    /// one changes nothing.
    nonisolated static func setting(
        _ date: StaleBasis, on: Bool, in basis: [StaleBasis]
    ) -> [StaleBasis] {
        var updated = Set(basis)
        if on { updated.insert(date) } else if updated.count > 1 { updated.remove(date) }
        return StaleBasis.allCases.filter(updated.contains)
    }
}
