import SwiftUI

/// Renames a Connection and relabels its members. Display only: the jamf-cli profiles and
/// workspaces keep their names.
struct ConnectionRenameSheet: View {
    let connection: Connection
    let store: ConnectionStore
    var onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var name: String
    @State private var labels: [String: String]
    @State private var saveError: String?

    init(connection: Connection, store: ConnectionStore, onSaved: @escaping () -> Void) {
        self.connection = connection
        self.store = store
        self.onSaved = onSaved
        _name = State(initialValue: connection.name)
        _labels = State(initialValue: Dictionary(
            connection.members.map { ($0.profile, $0.label) },
            uniquingKeysWith: { first, _ in first }))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename connection")
                .font(Theme.Fonts.serif(22, weight: .bold))
                .foregroundStyle(Theme.Colors.fg)
            Text("Names and labels are shown in the sidebar and Fleet Overview. The jamf-cli "
                + "profiles and workspaces keep their names.")
                .font(.callout)
                .foregroundStyle(Theme.Text.tertiary(contrast))
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 5) {
                FieldLabel(label: "Connection name")
                PNPTextField(value: $name)
            }
            ForEach(connection.members, id: \.profile) { member in
                VStack(alignment: .leading, spacing: 5) {
                    FieldLabel(label: "Label for \(member.profile)")
                    PNPTextField(value: labelBinding(member.profile))
                }
            }
            if let saveError {
                Text(saveError).font(.footnote).foregroundStyle(Theme.Colors.danger)
            }
            HStack {
                PNPButton(title: "Cancel", style: .neutral, size: .md) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                PNPButton(title: "Save", icon: "checkmark", style: .gold, size: .md, action: save)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 460)
        .background(Theme.Colors.winBG)
    }

    private func labelBinding(_ profile: String) -> Binding<String> {
        Binding(get: { labels[profile] ?? "" }, set: { labels[profile] = $0 })
    }

    private func save() {
        do {
            try store.rename(id: connection.id, name: name, labels: labels)
            onSaved()
            dismiss()
        } catch {
            saveError = "Could not save: \(error.localizedDescription)"
        }
    }
}
