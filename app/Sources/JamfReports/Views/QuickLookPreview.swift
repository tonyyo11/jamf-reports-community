import SwiftUI
import Quartz

/// QuickLook preview component that wraps QLPreviewView for displaying reports.
/// Triggers on Space key press and validates URLs against SystemActions allow-list.
struct QuickLookPreview: NSViewRepresentable {
    let url: URL?

    func makeNSView(context: Context) -> QLPreviewView {
        let preview = QLPreviewView()
        preview.autostarts = true
        return preview
    }

    func updateNSView(_ nsView: QLPreviewView, context: Context) {
        // Validate URL against SystemActions allow-list before previewing
        guard let url = url,
              SystemActions.isURLAllowed(url) else {
            nsView.previewItem = nil
            return
        }

        nsView.previewItem = url as NSURL
    }
}

extension SystemActions {
    /// Check if a URL is within the allowed path bounds for file operations.
    /// Reuses the same validation logic as open/reveal operations.
    static func isURLAllowed(_ url: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let allowedPaths = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Jamf-Reports").path + "/",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents").path + "/",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents").path + "/",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path + "/",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop").path + "/"
        ]

        return allowedPaths.contains { resolved.path.hasPrefix($0) }
    }
}