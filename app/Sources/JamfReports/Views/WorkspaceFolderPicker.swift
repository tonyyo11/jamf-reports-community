import SwiftUI
import AppKit

/// One folder pick and one consent for every place the operator can point the
/// app at a workspace root: Settings, the first-launch setup card, and the
/// Overview "Configuration incomplete" banner.
enum WorkspaceFolderPicker {
    /// nil when the operator cancelled. Opens at the current workspace root and offers New
    /// Folder on every path (#289), so a fresh folder needs no trip to Finder.
    @MainActor
    static func choose() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Choose the folder that holds your Jamf Reports workspaces."
        panel.directoryURL = existingFolder(atOrAbove: ProfileService.workspacesRoot())
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// The panel ignores a folder that does not exist (a first launch has no `~/Jamf-Reports`)
    /// and reopens wherever the last panel was, so start at the nearest folder that does.
    nonisolated static func existingFolder(
        atOrAbove url: URL, fileManager: FileManager = .default
    ) -> URL {
        var candidate = url.standardizedFileURL
        while candidate.path != "/" {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        return candidate
    }

    /// Named for what it actually shares, not for the feature.
    nonisolated static func consentTitle(for url: URL?) -> String {
        guard let url, let provider = CloudStorage.provider(for: url) else {
            return "Use this shared folder?"
        }
        return "Everyone with access to this \(provider.displayName) folder will be able to "
            + "read your fleet's device data"
    }

    nonisolated static let consentMessage: String = """
        Device serials, usernames, real names, email addresses, job titles, phone \
        numbers and rooms are stored in clear text in the raw snapshots and run logs, \
        and any webhook URL you configure is stored in config.yaml. The folder's sharing \
        settings decide who can read all of that — \
        this app cannot restrict it, and the file permissions it sets are not carried \
        across by the sync provider.

        Confirm the folder is shared only with people cleared to see device-level \
        inventory. If a wider audience only needs the reports, cancel and set \
        Output & Branding's output folder to the shared location instead — that \
        publishes finished reports without sharing the raw data.
        """
}

/// Choosing a synced folder widens who can read raw fleet data. That is the
/// operator's call — made knowingly, at the moment they make it. `pending` holds
/// the chosen URL until they confirm or cancel; a local folder never sets it.
struct SharedFolderConsent: ViewModifier {
    @Binding var pending: URL?
    let apply: (URL) -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            WorkspaceFolderPicker.consentTitle(for: pending),
            isPresented: Binding(
                get: { pending != nil },
                set: { if !$0 { pending = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Use this folder") {
                let url = pending
                pending = nil
                if let url { apply(url) }
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            Text(WorkspaceFolderPicker.consentMessage)
        }
    }
}

extension View {
    func sharedFolderConsent(pending: Binding<URL?>, apply: @escaping (URL) -> Void) -> some View {
        modifier(SharedFolderConsent(pending: pending, apply: apply))
    }
}
