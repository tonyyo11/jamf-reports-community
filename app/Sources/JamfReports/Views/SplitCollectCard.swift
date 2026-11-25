import SwiftUI

/// One schedule whose collect stopped at its budget today and is being continued.
struct SplitCollectRow: Identifiable, Equatable, Sendable {
    var id: String { label }
    let label: String
    let name: String
    /// Sources landed so far and the day's plan; nil when the names stopped lining up (sources
    /// came due again after 12 hours), so the row says how many are left instead.
    let done: Int?
    let of: Int?
    let left: Int
    /// A failure stands: the 1, 2, 4 h retries run before the next continuation.
    let retrying: Bool

    /// The active workspace's open split days, in schedule order.
    static func rows(
        state: TickState, schedules: [Schedule], workspace: String, now: Date
    ) -> [SplitCollectRow] {
        schedules.compactMap { schedule in
            guard let label = schedule.launchAgentLabel, let split = state.splitDay[label],
                  split.isOpen(on: now),
                  let progress = split.profiles[schedule.isMulti ? workspace : ""] else { return nil }
            let agree = Set(progress.left).isSubset(of: progress.planned)
            return SplitCollectRow(
                label: label, name: schedule.name,
                done: agree ? progress.planned.count - progress.left.count : nil,
                of: agree ? progress.planned.count : nil, left: progress.left.count,
                retrying: split.failed
                    && (state.retryCount[label] ?? 0) < TickScheduler.retryBackoffs.count)
        }
    }

    var progressText: String {
        if let done, let of { return L("\(done) of \(of) sources collected today") }
        return left == 1 ? L("1 source left today") : L("\(left) sources left today")
    }

    var pickupText: String {
        retrying ? L("A source failed: the retry runs first, then the rest of today's collect.")
            : L("Next pickup within about five minutes, once the lock is free.")
    }
}

/// "Continue today's collect": the schedules whose collect stopped at its budget, what is left,
/// and Continue now. Shared by `AutomationView` and `SchedulesView`; hidden with nothing open.
struct SplitCollectCard: View {
    @Environment(WorkspaceStore.self) private var workspace
    @State private var starting: Set<String> = []

    var body: some View {
        if !workspace.splitCollectRows.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Continuing today's collect").font(.headline)
                    Text("These collects stopped at the run budget and are being picked up through the day.")
                        .font(.footnote).foregroundStyle(Theme.Colors.fgMuted)
                    ForEach(workspace.splitCollectRows) { row in
                        rowView(row)
                    }
                }
            }
        }
    }

    private func rowView(_ row: SplitCollectRow) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).font(.callout.weight(.semibold))
                Text(row.progressText).font(.callout)
                Text(row.pickupText).font(.footnote).foregroundStyle(Theme.Colors.fgMuted)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            Button(L("Continue now")) {
                starting.insert(row.label)
                Task {
                    _ = await workspace.runNowFromHealthRow(label: row.label)
                    await workspace.refreshAutomationHealth()
                    starting.remove(row.label)
                }
            }
            .disabled(workspace.demoMode || starting.contains(row.label)
                      || workspace.isAnyCollectInFlight || CLIBridge.tickLockHeldRecently())
            .help(workspace.demoMode ? DemoData.liveOnlyHelp : "")
        }
    }
}

#if DEBUG
#Preview {
    let workspace = WorkspaceStore(demoMode: false)
    workspace.splitCollectRows = [
        SplitCollectRow(label: "a", name: "Managed freshness", done: 19, of: 31, left: 12,
                        retrying: false),
        SplitCollectRow(label: "b", name: "Nightly full collect", done: nil, of: nil, left: 4,
                        retrying: false),
        SplitCollectRow(label: "c", name: "School collect", done: 7, of: 12, left: 5,
                        retrying: true),
    ]
    return SplitCollectCard()
        .environment(workspace)
        .padding()
        .preferredColorScheme(.dark)
        .frame(width: PageScaffold<EmptyView>.minSupportedWidth)
}
#endif
