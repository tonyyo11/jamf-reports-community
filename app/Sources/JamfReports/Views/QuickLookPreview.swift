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
        // Validate URL against the canonical SystemActions allow-list before previewing.
        guard let url = url,
              SystemActions.isURLAllowed(url) else {
            nsView.previewItem = nil
            return
        }

        nsView.previewItem = url as NSURL
    }
}