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
                SectionHeader(title: L("From config.yaml"))
                Text("Read only. Lists the settings no screen in the app edits. Reload re-reads this list; the other tabs keep what they loaded.")
                    .font(.footnote)
                    .foregroundStyle(Theme.Text.secondary)
                HStack(spacing: 8) {
                    PNPButton(title: L("Reveal in Finder"), icon: "folder", size: .sm, action: reveal)
                        .disabled(!canReveal)
                        .help(isDemo ? DemoData.liveOnlyHelp : "")
                    PNPButton(
                        title: L("Reload"), icon: "arrow.clockwise", size: .sm, action: reload)
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
                    title: L("Set in the file, not editable here"),
                    trailingValue: Self.settingCount(count + sections.omittedSettings))
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
                    title: L("Not read by the app"),
                    trailingValue: Self.keyCount(
                        sections.unknown.count + sections.omittedUnknown))
                ForEach(Array(sections.unknown.enumerated()), id: \.offset) { _, key in
                    row(key.keyPath, key.note ?? "")
                }
                moreLine(sections.omittedUnknown, "key")
            }
        }
    }

    private func skippedCard(_ sections: ConfigFileSections) -> some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(
                    title: L("Skipped by the reader"),
                    trailingValue: Self.lineCount(
                        sections.skipped.count + sections.omittedSkipped))
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
            Text(omitted == 1 ? "…and \(omitted) more \(noun) not listed" : "…and \(omitted) more \(noun)s not listed")
                .font(.caption)
                .foregroundStyle(Theme.Text.tertiary(contrast))
        }
    }

    static func settingCount(_ number: Int) -> String {
        number == 1 ? L("\(number) setting") : L("\(number) settings")
    }

    static func keyCount(_ number: Int) -> String {
        number == 1 ? L("\(number) key") : L("\(number) keys")
    }

    static func lineCount(_ number: Int) -> String {
        number == 1 ? L("\(number) line") : L("\(number) lines")
    }
}
