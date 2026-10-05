import SwiftUI

/// The Health Audit's two "Contact gap" findings: Macs that MDM reaches while their Jamf
/// binary is silent, and Macs that check in while their inventory does not update
/// (`ContactGap`). Computed from the Devices inventory rather than `pro audit`, like Command
/// health, so they appear without an audit run. OK when no Mac shows the gap, WARNING for a
/// silent Jamf binary and INFO for stale inventory otherwise. Empty when no Mac carries a
/// Last Contact (Jamf Pro before 11.30), so nothing says "no gap" about data that is absent.
/// Internal for tests.
func contactGapFindings(
    _ snapshot: DeviceInventorySnapshot, now: Date = Date()
) -> [AuditFinding] {
    guard snapshot.devices.contains(where: { $0.contactDate != nil }) else { return [] }
    let groups = snapshot.contactGaps(staleDays: snapshot.staleDays, now: now)
    return ContactGap.allCases.map { gap in
        let macs = groups[gap] ?? []
        return AuditFinding(
            name: gap.findingName,
            affected: macs.count,
            category: "Contact gap",
            recommendation: gap.recommendation(gapDays: snapshot.contactGapDays),
            severity: macs.isEmpty ? "OK" : (gap == .binarySilent ? "WARNING" : "INFO"),
            devices: macs.map { "\($0.displayName) (\($0.displaySerial))" }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }
}

/// The "Contact gap" card on the Audit screen: one row per finding, each with its Mac count and
/// a popover with the recommendation and the Macs. Draws nothing without findings.
struct ContactGapSection: View {
    let findings: [AuditFinding]

    @Environment(\.colorSchemeContrast) private var contrast
    @State private var selected: AuditFinding?

    var body: some View {
        if !findings.isEmpty {
            Card(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader(title: "Contact gap").padding(16)
                    Divider().background(Theme.Colors.hairline)
                    ForEach(findings) { finding in row(finding) }
                }
            }
        }
    }

    private func row(_ finding: AuditFinding) -> some View {
        HStack(spacing: 10) {
            Pill(text: finding.severity, tone: tone(finding.severity))
                .frame(width: 86, alignment: .leading)
            Text(finding.name)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.Colors.fg)
            Spacer()
            Text(finding.affectedDisplay).font(.footnote.monospacedDigit())
            Button { selected = finding } label: { Image(systemName: "info.circle") }
                .buttonStyle(.plain)
                .help("Recommendation and the Macs behind this finding.")
                .popover(isPresented: Binding(
                    get: { selected?.id == finding.id },
                    set: { if !$0 { selected = nil } }
                )) {
                    FindingDetailPopover(finding: finding, tone: tone(finding.severity))
                }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private func tone(_ severity: String) -> Pill.Tone {
        severity.uppercased() == "WARNING" ? .warn : .teal
    }
}
