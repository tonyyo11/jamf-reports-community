import SwiftUI

/// The Config screen's read-only "From config.yaml" tab: what the file holds that the other
/// tabs do not edit, so a setting typed by hand is visible in the app. It writes nothing.
struct ConfigFromFileTab: View {
    let reading: ConfigFileReading
    let isDemo: Bool
    /// The file exists, so Finder has something to show; true even when it cannot be read.
    let canReveal: Bool
    let reveal: () -> Void
    let reload: () -> Void

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            introCard
            switch reading {
            case .unavailable(let message):
                messageCard(message)
            case .sections(let sections) where sections.isEmpty:
                messageCard(ConfigFileSections.nothingToShow)
            case .sections(let sections):
                if !sections.fileOnly.isEmpty { settingsCard(sections) }
                if !sections.unknown.isEmpty { unknownCard(sections) }
                if !sections.skipped.isEmpty { skippedCard(sections) }
            }
        }
    }

    // MARK: Cards

    private var introCard: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "From config.yaml")
                Text("Read only. Lists the settings no screen in the app edits. "
                    + "Reload re-reads this list; the other tabs keep what they loaded.")
                    .font(.footnote)
                    .foregroundStyle(Theme.Text.secondary)
                HStack(spacing: 8) {
                    PNPButton(title: "Reveal in Finder", icon: "folder", size: .sm, action: reveal)
                        .disabled(!canReveal)
                        .help(isDemo ? DemoData.liveOnlyHelp : "")
                    PNPButton(
                        title: "Reload", icon: "arrow.clockwise", size: .sm, action: reload)
                }
            }
        }
    }

    private func messageCard(_ message: String) -> some View {
        Card(padding: 16) {
            Text(message)
                .font(.callout)
                .foregroundStyle(Theme.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func settingsCard(_ sections: ConfigFileSections) -> some View {
        let count = sections.fileOnly.reduce(0) { $0 + $1.settings.count }
        return Card(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(
                    title: "Set in the file, not editable here",
                    trailingValue: Self.count(count + sections.omittedSettings, "setting"))
                ForEach(sections.fileOnly, id: \.name) { block in
                    VStack(alignment: .leading, spacing: 6) {
                        Kicker(text: block.name)
                        ForEach(block.settings, id: \.keyPath) { setting in
                            row(setting.keyPath, setting.value)
                        }
                    }
                }
                moreLine(sections.omittedSettings, "setting")
            }
        }
    }

    private func unknownCard(_ sections: ConfigFileSections) -> some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(
                    title: "Not read by the app",
                    trailingValue: Self.count(
                        sections.unknown.count + sections.omittedUnknown, "key"))
                ForEach(Array(sections.unknown.enumerated()), id: \.offset) { _, key in
                    row(key.keyPath, key.suggestion.map { "Did you mean \"\($0)\"?" } ?? "")
                }
                moreLine(sections.omittedUnknown, "key")
            }
        }
    }

    private func skippedCard(_ sections: ConfigFileSections) -> some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(
                    title: "Skipped by the reader",
                    trailingValue: Self.count(
                        sections.skipped.count + sections.omittedSkipped, "line"))
                ForEach(Array(sections.skipped.enumerated()), id: \.offset) { _, note in
                    Text(note)
                        .font(Theme.Fonts.mono(11.5))
                        .foregroundStyle(Theme.Text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                moreLine(sections.omittedSkipped, "line")
            }
        }
    }

    // MARK: Rows

    /// A key and its value on one line when both fit, else the value under the key, so the
    /// row still reads at `PageScaffold.minSupportedWidth`.
    private func row(_ key: String, _ value: String) -> some View {
        let keyText = Text(key).font(Theme.Fonts.mono(11.5)).foregroundStyle(Theme.Text.secondary)
        let valueText = Text(value).font(Theme.Fonts.mono(11.5)).foregroundStyle(Theme.Text.primary)
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                keyText.fixedSize()
                Spacer(minLength: 0)
                valueText.fixedSize()
            }
            VStack(alignment: .leading, spacing: 1) {
                keyText.fixedSize(horizontal: false, vertical: true)
                valueText.fixedSize(horizontal: false, vertical: true)
            }
        }
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func moreLine(_ omitted: Int, _ noun: String) -> some View {
        if omitted > 0 {
            Text("…and \(omitted) more \(noun)\(omitted == 1 ? "" : "s") not listed")
                .font(.caption)
                .foregroundStyle(Theme.Text.tertiary(contrast))
        }
    }

    static func count(_ number: Int, _ noun: String) -> String {
        "\(number) \(noun)\(number == 1 ? "" : "s")"
    }
}
