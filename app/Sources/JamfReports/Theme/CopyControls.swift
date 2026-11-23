import SwiftUI

/// A small button that copies `text` and shows a check for a moment.
struct CopyButton: View {
    let text: String
    /// What is copied, for the tooltip and VoiceOver: "serial number", "command".
    var what: String = L("text")
    var title: String? = nil

    @State private var copied = false

    var body: some View {
        Button {
            SystemActions.copyToClipboard(text)
            copied = true
        } label: {
            Label(title ?? L("Copy"), systemImage: copied ? "checkmark" : "doc.on.doc")
                .labelStyle(CopyLabelStyle(showsTitle: title != nil))
                .font(.caption.weight(.medium))
                .foregroundStyle(copied ? Theme.Colors.ok : Theme.Colors.fgMuted)
        }
        .buttonStyle(.borderless)
        .help(L("Copy the \(what)"))
        .accessibilityLabel(L("Copy the \(what)"))
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

private struct CopyLabelStyle: LabelStyle {
    let showsTitle: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
            if showsTitle { configuration.title }
        }
    }
}

/// A command we ask someone to run: monospaced, selectable, with a Copy button. Build any
/// profile name into `command` with `ProfileName.shellWord`, never by interpolation.
struct CommandText: View {
    let command: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(command)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            CopyButton(text: command, what: L("command"), title: L("Copy"))
        }
        .padding(8)
        .background(Theme.Colors.winBG2, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
