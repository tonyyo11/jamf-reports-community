import SwiftUI

/// The Jamf Protect row of Data Sources > Additional Products: Add, or CONNECTED / not found
/// with Reconnect and Disconnect. Disconnect writes config.yaml for `workspace` only.
struct ProtectProductControl: View {
    let workspace: String
    let state: ProtectConnection.State
    let demoMode: Bool
    let onConnect: () -> Void
    /// Called after config.yaml was rewritten, so the card reloads.
    let onDisconnected: () -> Void

    @Environment(\.colorSchemeContrast) private var contrast
    @State private var confirmDisconnect = false
    @State private var note: String?
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            row
            caption(ProtectConnection.credentialsNote)
            if let note { caption(note).textSelection(.enabled) }
            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .confirmationDialog(
            "Disconnect Jamf Protect?", isPresented: $confirmDisconnect, titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive, action: disconnect)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This turns off protect in this workspace's config.yaml and removes the profile name from it. The jamf-cli profile is not removed.")
        }
    }

    @ViewBuilder
    private var row: some View {
        switch state {
        case .notConnected:
            PNPButton(title: L("Add Jamf Protect"), icon: "shield.lefthalf.filled", size: .sm,
                      action: onConnect)
                .disabled(demoMode)
                .help(demoMode ? DemoData.liveOnlyHelp : "")
        case .connected(let profile):
            HStack(spacing: 8) {
                Pill(text: L("CONNECTED"), tone: .teal, icon: "checkmark")
                profileText(L("Jamf Protect · \(profile)"))
                actions
            }
        case .profileMissing(let profile):
            HStack(spacing: 8) {
                Pill(text: L("NOT FOUND"), tone: .warn, icon: "exclamationmark.triangle")
                profileText(L("Profile \(profile) not found in jamf-cli"))
                actions
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        PNPButton(title: L("Reconnect"), icon: "arrow.triangle.2.circlepath", size: .sm,
                  action: onConnect)
            .disabled(demoMode)
            .help(demoMode ? DemoData.liveOnlyHelp : "")
        PNPButton(title: L("Disconnect"), icon: "xmark.circle", style: .ghost, size: .sm) {
            guard !demoMode else { return }
            confirmDisconnect = true
        }
        .disabled(demoMode)
        .help(demoMode ? DemoData.liveOnlyHelp : "")
    }

    private func profileText(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Theme.Text.tertiary(contrast))
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Theme.Text.tertiary(contrast))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func disconnect() {
        guard !demoMode else { return }
        let missing: Bool
        let profile: String
        switch state {
        case .connected(let name): (missing, profile) = (false, name)
        case .profileMissing(let name): (missing, profile) = (true, name)
        case .notConnected: return
        }
        do {
            let report = try ProtectConnection.disconnect(workspace: workspace)
            errorText = nil
            note = ProtectConnection.disconnectedNote(profile: profile, profileMissing: missing)
                + (report.backupName.map { L(" A copy of config.yaml is in \($0).") } ?? "")
            onDisconnected()
        } catch {
            errorText = L("Couldn't disconnect Jamf Protect: \(error.localizedDescription)")
        }
    }
}
