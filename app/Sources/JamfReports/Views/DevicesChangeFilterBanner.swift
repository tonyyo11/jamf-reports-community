import SwiftUI

/// Above the Computers table while a "Since last collect" count is open: what the list is,
/// and every way it can differ from the count (decision 2 of the B2c checklist).
struct DevicesChangeFilterBanner: View {
    let filter: ChangeFilter
    /// Nil while the snapshots are compared.
    let result: ChangeFilterResult?
    /// Macs from that comparison not in today's list; nil until the inventory has loaded.
    let notInList: Int?
    let onClear: () -> Void

    static let leftListLimit = 50

    var body: some View {
        InlineBanner(
            icon: "arrow.left.arrow.right", tone: .info,
            action: .init(label: L("Show all computers"), icon: "xmark", handler: onClear)
        ) {
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.title(filter))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.Colors.fg)
                ForEach(Self.lines(result: result, notInList: notInList), id: \.self) { line in
                    Text(line)
                        .font(.footnote)
                        .foregroundStyle(Theme.Text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if case .left(let macs)? = result?.outcome {
                    leftList(macs)
                }
            }
        }
    }

    static func title(_ filter: ChangeFilter) -> String {
        guard let date = filter.baselineDate else { return filter.kind.label }
        let day = date.formatted(date: .abbreviated, time: .omitted)
        return L("\(filter.kind.label) since \(day)")
    }

    /// The banner's notes, in order; each is decided here so tests read the same text.
    static func lines(result: ChangeFilterResult?, notInList: Int?) -> [String] {
        guard let result else { return [L("Comparing snapshots…")] }
        var lines: [String] = []
        switch result.outcome {
        case .macs(let keys):
            if let failures = result.failures {
                lines.append(keys.count == 1
                    ? L("1 Mac (\(failures) policy failures)")
                    : L("\(keys.count) Macs (\(failures) policy failures)"))
            } else {
                lines.append(keys.count == 1 ? L("1 Mac") : L("\(keys.count) Macs"))
            }
            if let notInList, notInList > 0 {
                lines.append(notInList == 1
                    ? L("1 Mac from that comparison is not in the current list")
                    : L("\(notInList) Macs from that comparison are not in the current list"))
            }
        case .left(let macs):
            lines.append(macs.count == 1
                ? L("1 Mac left since then; it is not in the current list")
                : L("\(macs.count) Macs left since then; they are not in the current list"))
        case .fileGone:
            lines.append(L("Snapshot no longer on disk"))
        case .unreadable(let reason):
            lines.append(reason == .tooLarge
                ? L("A snapshot could not be read: over the read limit")
                : L("A snapshot could not be read: it did not decode"))
        case .cancelled:
            lines.append(L("Comparing snapshots…"))
        }
        if result.ruleChanged { lines.append(L("The rule changed since these counts")) }
        return lines
    }

    private func leftList(_ macs: [ComputerDates]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(macs.prefix(Self.leftListLimit).enumerated()), id: \.offset) { _, mac in
                Text([
                    ConfigSchema.displayText(mac.name ?? ""),
                    ConfigSchema.displayText(mac.serial ?? ""),
                    mac.jamfID.map { L("Jamf ID \($0)") } ?? "",
                ].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.footnote.monospaced())
                    .foregroundStyle(Theme.Colors.fg)
                    .textSelection(.enabled)
            }
            if macs.count > Self.leftListLimit {
                Text(L("and \(macs.count - Self.leftListLimit) more"))
                    .font(.footnote)
                    .foregroundStyle(Theme.Text.secondary)
            }
        }
        .padding(.top, 2)
    }
}
