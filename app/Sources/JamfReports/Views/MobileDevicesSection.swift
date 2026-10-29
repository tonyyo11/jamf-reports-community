import SwiftUI

/// The Health Audit's "Mobile Devices" findings (mobile spec 5), computed from the newest
/// `mobile-devices-list` snapshot through `MobileFinding`, the rules `MobileSummary` counts
/// with, so each count equals the Mobile Devices filter it opens. A finding no device reports
/// the field for is left out (never "0 affected"), and the list is empty when the snapshot has
/// no mobile devices. OK when no device shows the condition. `previous` is the newest daily
/// summary before the snapshot's day that carries mobile figures; its count gives the change.
/// Internal for tests.
func mobileDevicesFindings(
    _ snapshot: MobileFleetService.Snapshot, context: MobileFinding.Context,
    previous: (date: String, mobile: MobileSummary)? = nil
) -> [AuditFinding] {
    guard snapshot.totalDevices > 0 else { return [] }
    let counts = snapshot.findingCounts(context)
    return MobileFinding.allCases.compactMap { finding -> AuditFinding? in
        guard let count = counts[finding] else { return nil }
        let names = count == 0 ? [] : deviceNames(snapshot, affectedBy: finding, context: context)
        let shown = Array(names.prefix(mobileFindingDeviceCap))
        let more = names.count - shown.count
        return AuditFinding(
            name: finding.name(staleDays: context.staleDays),
            affected: count,
            category: MobileFinding.category,
            recommendation: finding.recommendation(staleDays: context.staleDays),
            severity: count == 0 ? "OK" : finding.severity,
            devices: shown + (more > 0 ? ["and \(more) more, in Mobile Devices"] : []),
            deviceNoun: "Devices",
            mobileFilter: finding.rawValue,
            change: previous.flatMap { earlier in
                finding.count(in: earlier.mobile).map {
                    MobileFinding.changeText(current: count, previous: $0, since: earlier.date)
                }
            })
    }
}

/// "Name (serial)" of each device showing `finding`, sorted by name.
private func deviceNames(
    _ snapshot: MobileFleetService.Snapshot, affectedBy finding: MobileFinding,
    context: MobileFinding.Context
) -> [String] {
    let listRows = snapshot.lightDevicesByID
    let affected = snapshot.devices(snapshot.richDevices, affectedBy: finding, context: context)
    let names: [String] = affected.map { device in
        let serial = MobileFleetService.serialNumber(
            of: device, listRow: device.mobileDeviceId.flatMap { listRows[$0] })
        return "\(device.general?.displayName ?? "Untitled Device") (\(serial ?? "no serial"))"
    }
    return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
}

/// Devices a finding's popover lists before it says how many more the Mobile Devices list holds.
private let mobileFindingDeviceCap = 200

extension MobileFinding {
    /// The newest summary dated before `day` (yyyy-MM-dd) that carries mobile figures, from
    /// summaries in date order.
    static func previous(
        in summaries: [DailySummary], before day: String
    ) -> (date: String, mobile: MobileSummary)? {
        summaries.last { $0.date < day && $0.mobile != nil }
            .flatMap { summary in summary.mobile.map { (summary.date, $0) } }
    }
}

/// The findings for `profile`, read off the main actor.
func mobileDevicesFindings(
    profile: String, staleDays: Int, now: Date
) -> [AuditFinding] {
    let snapshot = MobileFleetService.load(profile: profile)
    guard snapshot.totalDevices > 0 else { return [] }
    let day = SummaryJSONParser.dateFormatter.string(from: snapshot.snapshotDate ?? now)
    return mobileDevicesFindings(
        snapshot, context: snapshot.findingContext(staleDays: staleDays, now: now),
        previous: MobileFinding.previous(
            in: TrendStore.readSummaries(profile: profile), before: day))
}

/// The "Mobile Devices" card on the Audit screen: one row per finding with its device count
/// (a button that opens Mobile Devices filtered to those devices), the change since the
/// previous summary, and a popover with the recommendation and the devices. Draws nothing
/// without findings.
struct MobileDevicesSection: View {
    let findings: [AuditFinding]

    @Environment(\.colorSchemeContrast) private var contrast
    @State private var selected: AuditFinding?

    var body: some View {
        if !findings.isEmpty {
            Card(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader(title: "Mobile Devices").padding(16)
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
            VStack(alignment: .leading, spacing: 2) {
                Text(finding.name)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.Colors.fg)
                if let change = finding.change {
                    Text(change)
                        .font(.caption)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                }
            }
            Spacer()
            countView(finding)
            Button { selected = finding } label: { Image(systemName: "info.circle") }
                .buttonStyle(.plain)
                .accessibilityLabel("Details for \(finding.name)")
                .help("Recommendation and the devices behind this finding.")
                .popover(isPresented: Binding(
                    get: { selected?.id == finding.id },
                    set: { if !$0 { selected = nil } }
                )) {
                    FindingDetailPopover(finding: finding, tone: tone(finding.severity))
                }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    @ViewBuilder
    private func countView(_ finding: AuditFinding) -> some View {
        if finding.affected > 0, let filter = finding.mobileFilter {
            Button {
                NotificationCenter.default.post(
                    name: .navigateToTab, object: nil,
                    userInfo: ["tab": Tab.mobileFleet.rawValue, MobileFinding.userInfoKey: filter])
            } label: {
                Text(finding.affectedDisplay).font(.footnote.monospacedDigit()).underline()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                "\(finding.affectedDisplay) devices: \(finding.name). Open Mobile Devices.")
            .help("Open Mobile Devices filtered to these devices.")
        } else {
            Text(finding.affectedDisplay).font(.footnote.monospacedDigit())
        }
    }

    private func tone(_ severity: String) -> Pill.Tone {
        switch severity.uppercased() {
        case "CRITICAL": .danger
        case "WARNING": .warn
        default: .teal
        }
    }
}
