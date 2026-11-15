import SwiftUI

/// The School Overview's "Device health" card: neutral "N of M" counts from
/// `SchoolDeviceHealth`, never graded or coloured. A figure whose snapshot could not be read
/// says so instead of disappearing.
struct SchoolDeviceHealthCard: View {
    let health: SchoolDeviceHealth

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: L("Device health"))
                ForEach(health.items, id: \.self) { item in
                    SchoolDeviceHealthRow(health: health, item: item)
                }
                if let line = SchoolDeviceHealth.line(health.depStatuses) {
                    Text(L("Automated Device Enrollment status: \(line)"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(health.detailLines, id: \.self) { line in
                    Text(line).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct SchoolDeviceHealthRow: View {
    let health: SchoolDeviceHealth
    let item: SchoolDeviceHealth.Item

    private var value: String {
        guard let figure = health.figures[item] else { return L("could not be read") }
        return L("\(figure.count) of \(figure.of) \(item.unit)")
    }

    private var breakdown: String? {
        guard item == .adeNotEnrolled, health.figures[item] != nil,
              let line = SchoolDeviceHealth.line(health.notEnrolledProfiles) else { return nil }
        return L("By enrollment profile: \(line)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.title)
                Spacer(minLength: 12)
                Text(value).monospacedDigit().foregroundStyle(.secondary)
            }
            if let breakdown {
                Text(breakdown).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
