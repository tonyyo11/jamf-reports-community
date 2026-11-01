import SwiftUI

/// The "Keep data fresh automatically" controls both setup screens show: the switch, its
/// explanation and, when on, the deep-scan day, report cadence and run time.
struct AutomationChoiceFields: View {
    @Binding var choice: AutomationSetupChoice
    var isLocked = false

    private static let weekdays = [L("Sun"), L("Mon"), L("Tue"), L("Wed"), L("Thu"), L("Fri"), L("Sat")]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $choice.enabled) {
                Text("Keep data fresh automatically").font(.callout.weight(.semibold))
            }
            .toggleStyle(.switch)
            .disabled(isLocked)
            Text("A daily collect keeps dashboards and Trends current; a weekly deep scan runs the two per-device queries. Adjust anytime from the Automation tab.")
                .font(.footnote)
                .foregroundStyle(Theme.Colors.fgMuted)
            if choice.enabled {
                Divider().background(Theme.Colors.hairline)
                Picker("Deep scan & report day", selection: $choice.scanWeekday) {
                    ForEach(0..<7, id: \.self) { index in
                        Text(Self.weekdays[index]).tag(index)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 260, alignment: .leading)
                .disabled(isLocked)
                Picker("Generate reports", selection: $choice.reportsCadence) {
                    Text("Off").tag(AutomationPolicy.ReportsCadence.off)
                    Text("Daily").tag(AutomationPolicy.ReportsCadence.daily)
                    Text("Weekly").tag(AutomationPolicy.ReportsCadence.weekly)
                    Text("Monthly").tag(AutomationPolicy.ReportsCadence.monthly)
                }
                .pickerStyle(.segmented)
                .disabled(isLocked)
                HStack {
                    Text("Run automation at")
                    TextField("Run automation at", text: $choice.runTime, prompt: Text("06:00"))
                        .labelsHidden()
                        .frame(width: 80)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isLocked)
                }
                .font(.callout)
            }
        }
    }
}
