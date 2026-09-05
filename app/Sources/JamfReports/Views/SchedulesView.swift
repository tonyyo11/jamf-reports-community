import SwiftUI
import Combine

// Thread-safe accumulator for streaming log lines from CLIBridge callbacks.
private final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [CLIBridge.LogLine] = []
    func append(_ line: CLIBridge.LogLine) { lock.withLock { _lines.append(line) } }
    var lines: [CLIBridge.LogLine] { lock.withLock { _lines } }
}

struct SchedulesView: View {
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var profileFilter: String = "All"
    @State private var isRunning = false
    @State private var lastRunMessage: String? = nil
    @State private var runLogLines: [CLIBridge.LogLine] = []
    @State private var showRunLog = false
    @State private var showNewSchedule = false
    @State private var newScheduleForm = ScheduleFormState()
    @State private var pendingDelete: Schedule? = nil
    @State private var showDeleteConfirm = false
    @State private var writeError: String? = nil
    @State private var showWriteError = false
    @State private var now = Date()
    private let countdownTick = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    // Shared with AutomationView: flipping this on re-routes (via AutomationTab)
    // to the managed-policy editor and reconciles the managed agents.
    @AppStorage(AutomationPolicy.storageKey) private var automationPolicyRaw: String = ""

    @State private var query = ""

    private var filteredSchedules: [Schedule] {
        let scoped = profileFilter == "All"
            ? workspace.schedules
            : workspace.schedules.filter { $0.profile == profileFilter }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return scoped }
        return scoped.filter { schedule in
            schedule.name.lowercased().contains(trimmed)
                || schedule.profile.lowercased().contains(trimmed)
                || schedule.schedule.lowercased().contains(trimmed)
                || schedule.cadence.lowercased().contains(trimmed)
                || schedule.mode.rawValue.lowercased().contains(trimmed)
        }
    }

    private var profileCount: Int {
        Set(workspace.schedules.map(\.profile)).count
    }

    var body: some View {
        PageScaffold(spacing: 14) {
            header
            managedModeCard
            profileFilterStrip
            nextUpCallout
            schedulesTable
            // Notifications apply to any scheduled run — hand-built or managed —
            // so unmanaged-mode operators get the same panel AutomationView shows,
            // rather than having to hand-edit config.yaml's `notify:` block.
            // Gated on !demoMode: unlike AutomationView (whose demo branch never
            // constructs this card at all), SchedulesView has no outer demo
            // wrapper, and the demo profile name is a syntactically valid
            // profile — an ungated card would write a real config.yaml to
            // ~/Jamf-Reports/<demo profile>/ on every toggle/keystroke.
            if !workspace.demoMode {
                NotificationsCard(profile: workspace.profile)
            }
            runModesExplainer
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Filter by name, profile, cadence, or mode")
        .sheet(isPresented: $showNewSchedule) {
            NewScheduleSheet(
                form: $newScheduleForm,
                profiles: workspace.profiles.map(\.name)
            ) { form in
                showNewSchedule = false
                Task { await saveSchedule(form) }
            } onCancel: {
                showNewSchedule = false
            }
        }
        .confirmationDialog(
            "Delete \"\(pendingDelete?.name ?? "")\"?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete LaunchAgent", role: .destructive) {
                if let s = pendingDelete { deleteSchedule(s) }
            }
        }
        .alert("Write Error", isPresented: $showWriteError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(writeError ?? "Unknown error")
        }
        .onReceive(countdownTick) { now = $0 }
    }

    // MARK: - Managed-mode switch

    /// The master "Manage automation" toggle, mirrored from AutomationView so the
    /// operator can switch from hand-built schedules to the managed policy without
    /// losing access to the switch. Flipping it on re-routes (AutomationTab) and
    /// the policy editor's reconcile installs the managed agents.
    private var managedModeCard: some View {
        Card {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Managed automation").font(.headline)
                    Text("Off — you manage these schedules yourself. Turn on to let the app keep "
                        + "every profile fresh and generate reports automatically, on one policy.")
                        .font(.footnote).foregroundStyle(Theme.Colors.fgMuted)
                }
                Spacer()
                Toggle("", isOn: managedModeBinding)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(workspace.demoMode)
            }
        }
    }

    // Re-parses AutomationPolicy per access; only read once (managedModeCard's
    // single Toggle) per body evaluation, so a @State hoist isn't warranted here.
    private var managedModeBinding: Binding<Bool> {
        Binding(
            get: { AutomationPolicy.parse(automationPolicyRaw).isManaged },
            set: { isOn in
                var policy = AutomationPolicy.parse(automationPolicyRaw)
                policy.isManaged = isOn
                automationPolicyRaw = policy.serialize()
            }
        )
    }

    // MARK: - Header

    private var header: some View {
        PageHeader(
            kicker: "macOS LaunchAgent · UserAgent",
            title: "Scheduled Runs",
            subtitle: "\(workspace.schedules.count) schedule\(workspace.schedules.count == 1 ? "" : "s") · \(workspace.schedules.filter(\.enabled).count) enabled · across \(profileCount) jamf-cli profile\(profileCount == 1 ? "" : "s")"
        ) {
            AnyView(
                HStack(spacing: 8) {
                    PNPButton(title: "Refresh", icon: "arrow.clockwise") {
                        workspace.reloadFromDisk()
                    }
                    .help("Re-scan ~/Library/LaunchAgents for jamfreports schedules.")
                    PNPButton(title: "New schedule", icon: "plus", style: .gold) {
                        newScheduleForm = ScheduleFormState(defaultProfile: workspace.profile)
                        showNewSchedule = true
                    }
                    .disabled(workspace.demoMode)
                    .help(workspace.demoMode
                          ? "Available in live mode only"
                          : "Create a new LaunchAgent that runs jamf-cli on a cron-style schedule.")
                }
            )
        }
    }

    // MARK: - Profile filter strip

    private var profileFilterStrip: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Kicker(text: "JAMF-CLI PROFILE").padding(.trailing, 4)
                    Button {
                        profileFilter = "All"
                    } label: {
                        Pill(text: "All · \(workspace.schedules.count)", tone: profileFilter == "All" ? .gold : .muted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show all profiles, \(workspace.schedules.count) schedule\(workspace.schedules.count == 1 ? "" : "s")")
                    ForEach(workspace.profiles) { p in
                        let count = workspace.schedules.filter { $0.profile == p.name }.count
                        Button {
                            profileFilter = p.name
                        } label: {
                            Pill(text: "\(p.name) · \(count)", tone: profileFilter == p.name ? .gold : .muted)
                                .opacity(count > 0 ? 1 : 0.5)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Filter by \(p.name), \(count) schedule\(count == 1 ? "" : "s")")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            PNPButton(title: "Add profile", icon: "plus", size: .sm) {
                NotificationCenter.default.post(
                    name: .navigateToTab,
                    object: nil,
                    userInfo: ["tab": Tab.settings.rawValue]
                )
            }
            .help("Add connections in Settings · Connections")
        }
    }

    // MARK: - Next-up callout

    private var nextUpCallout: some View {
        let next = filteredSchedules.first(where: \.enabled) ?? filteredSchedules.first
        let nextDate = next.flatMap { Self.parseScheduleDate($0.next, reference: now) }
        let lastDate = next.flatMap { Self.parseScheduleDate($0.last, reference: now) }
        let progress = Self.intervalProgress(now: now, next: nextDate, last: lastDate)
        return GlassPane(borderColor: Theme.Colors.gold.opacity(0.4)) {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    Circle()
                        .stroke(Theme.Colors.hairlineStrong, lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: CGFloat(progress))
                        .stroke(
                            LinearGradient(
                                colors: [Theme.Colors.gold, Theme.Colors.goldBright],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            ),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "clock")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Theme.Colors.goldBright)
                }
                .frame(width: 56, height: 56)

                VStack(alignment: .leading, spacing: 2) {
                    Kicker(text: "Next up", tone: .gold)
                    Text(next?.name ?? "No schedules enabled")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Theme.Colors.fg)
                    HStack(spacing: 4) {
                        if let s = next {
                            Mono(text: "\(s.schedule) · \(s.mode.rawValue) · ", size: 11.5)
                            Text(s.profile).font(Theme.Fonts.mono(11.5)).foregroundStyle(Theme.Colors.goldBright)
                        }
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Kicker(text: nextDate == nil ? "Awaiting schedule" : "Runs in", tone: .gold)
                    Text(Self.countdownString(now: now, next: nextDate))
                        .font(Theme.Fonts.mono(28, weight: .bold))
                        .foregroundStyle(Theme.Colors.goldBright)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }

                VStack(spacing: 6) {
                    PNPButton(
                        title: isRunning ? "Running…" : "Run now",
                        icon: isRunning ? "hourglass" : "play.fill"
                    ) {
                        guard !isRunning else { return }
                        showRunLog = true
                        Task { await runNextScheduledNow() }
                    }
                    .disabled(workspace.demoMode || isRunning)
                    .help(workspace.demoMode ? "Available in live mode only" : "")
                    if let msg = lastRunMessage {
                        Mono(text: msg, size: 10, color: Theme.Text.tertiary(contrast))
                            .accessibilityAddTraits(.updatesFrequently)
                    }
                }
            }
        }
        .sheet(isPresented: $showRunLog) {
            runLogSheet
        }
    }

    /// Parses schedule strings such as "Apr 27, 07:00" into the next future `Date`.
    /// Falls back to nil if the format is unrecognized (e.g. "—").
    private static func parseScheduleDate(_ raw: String, reference: Date) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != "—" else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let calendar = Calendar.current
        let year = calendar.component(.year, from: reference)
        for fmt in ["MMM d, HH:mm", "MMM d yyyy, HH:mm", "MMM d, h:mm a"] {
            formatter.dateFormat = fmt
            if let parsed = formatter.date(from: trimmed) {
                var comps = calendar.dateComponents([.month, .day, .hour, .minute], from: parsed)
                comps.year = year
                if let candidate = calendar.date(from: comps) {
                    if candidate < reference.addingTimeInterval(-86_400 * 7) {
                        comps.year = year + 1
                        return calendar.date(from: comps)
                    }
                    return candidate
                }
            }
        }
        return nil
    }

    private static func countdownString(now: Date, next: Date?) -> String {
        guard let next, next > now else { return "—" }
        let total = Int(next.timeIntervalSince(now))
        let days = total / 86_400
        let hours = (total % 86_400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 { return String(format: "%dd %02dh %02dm", days, hours, minutes) }
        return String(format: "%02dh %02dm", hours, minutes)
    }

    private static func intervalProgress(now: Date, next: Date?, last: Date?) -> Double {
        guard let next else { return 0 }
        let start = last ?? next.addingTimeInterval(-86_400)
        let total = next.timeIntervalSince(start)
        guard total > 0 else { return 0 }
        let elapsed = now.timeIntervalSince(start)
        return min(max(elapsed / total, 0), 1)
    }

    /// Live run-output console. Presented as a window-modal sheet (not a
    /// popover) so it does not light-dismiss on a stray click mid-run —
    /// `showRunLog` has no re-open path while `isRunning`, and the run is a
    /// detached task that keeps going regardless. Closed only via the ✕.
    private var runLogSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Mono(text: "Live output", size: 12, color: Theme.Colors.fg2)
                Spacer()
                if isRunning {
                    ProgressView().scaleEffect(0.6)
                } else if let msg = lastRunMessage, let exitCode = Self.extractExitCode(from: msg) {
                    Pill(
                        text: "EXIT \(exitCode)",
                        tone: exitCode == 0 ? .teal : .danger,
                        icon: exitCode == 0 ? "checkmark" : "xmark"
                    )
                }
                Button {
                    let joined = runLogLines.map(\.text).joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(joined, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 11))
                        .foregroundStyle(Theme.Colors.fgMuted)
                }
                .buttonStyle(.plain)
                .disabled(runLogLines.isEmpty)
                .accessibilityLabel("Copy all output")
                .help("Copy entire log to clipboard")
                Button { showRunLog = false } label: {
                    Image(systemName: "xmark").font(.system(size: 11))
                        .foregroundStyle(Theme.Colors.fgMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close run log")
                .help("Close live output")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            RunLogConsole(lines: runLogLines, isRunning: isRunning)
                .frame(minWidth: 520, idealWidth: 520, maxWidth: 520, minHeight: 200, maxHeight: 320)
        }
        .background(Theme.Colors.winBG2)
    }

    // MARK: - Schedules table

    private var schedulesTable: some View {
        Card(padding: 0) {
            Table(filteredSchedules) {
                TableColumn("") { s in
                    Button { Task { await toggleSchedule(s) } } label: {
                        PNPToggle(isOn: .constant(s.enabled)).allowsHitTesting(false)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(s.enabled ? "Disable \(s.name)" : "Enable \(s.name)")
                }
                .width(48)

                TableColumn("Schedule") { s in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.name).font(.callout.weight(.semibold))
                        Text(s.plainLanguageSummary)
                            .font(.caption)
                            .foregroundStyle(Theme.Text.secondary)
                        if s.needsMigrationNudge {
                            HStack(spacing: 4) {
                                Image(systemName: "info.circle")
                                    .font(.caption2)
                                    .foregroundStyle(Theme.Colors.info)
                                Text("Re-save to migrate")
                                    .font(.caption2)
                                    .foregroundStyle(Theme.Colors.info)
                            }
                        }
                        Mono(text: labelText(for: s), size: 10.5)
                    }
                }

                TableColumn("Profile") { s in
                    Pill(text: s.profileDisplayLabel, tone: s.isMulti ? .teal : .gold)
                }.width(140)
                TableColumn("Cadence") { s in Mono(text: s.schedule) }
                TableColumn("Mode")    { s in Pill(text: s.mode.rawValue, tone: .muted) }
                TableColumn("Next Run") { s in
                    Mono(text: s.next, color: s.enabled ? Theme.Colors.goldBright : Theme.Text.tertiary(contrast))
                }
                TableColumn("Last Run") { s in Mono(text: s.last) }
                TableColumn("Status")   { s in statusPill(for: s.lastStatus) }.width(80)
                TableColumn("Outputs") { s in
                    HStack(spacing: 4) {
                        if s.artifacts.isEmpty {
                            Text("—").foregroundStyle(Theme.Text.tertiary(contrast))
                        } else {
                            ForEach(s.artifacts, id: \.self) { Pill(text: $0, tone: .muted) }
                        }
                    }
                }
                TableColumn("") { s in
                    Menu {
                        Button {
                            guard !isRunning, !workspace.demoMode else { return }
                            showRunLog = true
                            Task { await runScheduleNow(s) }
                        } label: {
                            Label("Run now", systemImage: "play.fill")
                        }
                        .disabled(isRunning || workspace.demoMode)
                        Divider()
                        Button(role: .destructive) {
                            guard !workspace.demoMode else { return }
                            pendingDelete = s
                            showDeleteConfirm = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .disabled(workspace.demoMode)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundStyle(Theme.Colors.fgMuted)
                            .font(.system(size: 14))
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .accessibilityLabel("Actions for \(s.name)")
                    .help("Run now or delete \(s.name)")
                }
                .width(28)
            }
            .frame(minHeight: 280)
            .scrollContentBackground(.hidden)
        }
    }

    // MARK: - Run modes explainer

    private var runModesExplainer: some View {
        let iconMap: [Schedule.RunMode: (String, Color)] = [
            .snapshotOnly: ("icloud.and.arrow.up", Theme.Colors.info),
            .jamfCLIOnly: ("bolt.fill", Theme.Colors.gold),
            .jamfCLIFull: ("shield.lefthalf.filled", Theme.Colors.ok),
            .csvAssisted: ("folder.fill", Theme.Colors.purple),
        ]
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Kicker(text: "RUN MODES")
                Spacer()
                Menu {
                    ForEach(Schedule.RunMode.allCases, id: \.id) { mode in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(mode.displayTitle)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Theme.Colors.fg)
                            Text(mode.displayDescription)
                                .font(.caption)
                                .foregroundStyle(Theme.Text.tertiary(contrast))
                                .lineLimit(3)
                        }
                    }
                } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.Colors.fgMuted)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .help("Run mode explanations")
            }
            HStack(spacing: 10) {
                ForEach(Schedule.RunMode.allCases, id: \.id) { mode in
                    let (icon, color) = iconMap[mode] ?? ("questionmark.circle", Theme.Colors.fgMuted)
                    Card(padding: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Image(systemName: icon)
                                    .font(.system(size: 14))
                                    .foregroundStyle(color)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(mode.displayTitle)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(Theme.Colors.fg)
                                    Mono(text: mode.rawValue, size: 9, color: Theme.Text.tertiary(contrast))
                                }
                            }
                            Divider().background(Theme.Colors.hairline)
                            Text(mode.displayDescription)
                                .font(.caption)
                                .foregroundStyle(Theme.Text.tertiary(contrast))
                                .lineLimit(4)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func runNextScheduledNow() async {
        let target = filteredSchedules.first(where: \.enabled) ?? filteredSchedules.first
        guard let target else { return }
        await runScheduleNow(target)
    }

    private func runScheduleNow(_ schedule: Schedule) async {
        guard !workspace.demoMode,
              let label = LaunchAgentWriter.label(for: schedule) else { return }
        isRunning = true
        runLogLines = []
        let buf = LineBuffer()
        let exit = await TickRunner.spawnNow(label: label, wait: true) { line in
            buf.append(line)
            Task { @MainActor in runLogLines = buf.lines }
        }
        runLogLines = buf.lines
        isRunning = false
        lastRunMessage = "\(schedule.name) · exit \(exit)"
        workspace.reloadFromDisk()
    }

    private func toggleSchedule(_ schedule: Schedule) async {
        guard var record = ScheduleRecord(schedule: schedule) else {
            writeError = "This schedule cannot be edited here."; showWriteError = true; return
        }
        record.enabled.toggle()
        do { try ScheduleStore().upsert(record) } catch {
            writeError = error.localizedDescription; showWriteError = true; return
        }
        workspace.reloadFromDisk()
    }

    private func deleteSchedule(_ schedule: Schedule) {
        guard !workspace.demoMode,
              let label = LaunchAgentWriter.label(for: schedule) else { return }
        guard !ManagedAutomation.owns(label) else {
            writeError = "\(schedule.name) is a managed automation agent — "
                + "turn off Manage automation to remove it."
            showWriteError = true
            return
        }
        do { try ScheduleStore().remove(label: label) } catch {
            writeError = error.localizedDescription; showWriteError = true; return
        }
        Task { await workspace.applyAutomationPolicy() }
    }

    private func saveSchedule(_ form: ScheduleFormState) async {
        guard let record = ScheduleRecord(schedule: form.toSchedule()) else {
            writeError = "Schedule name or profile produces an invalid label."
            showWriteError = true
            return
        }
        do { try ScheduleStore().upsert(record) } catch {
            writeError = "Could not save schedule · \(error.localizedDescription)"
            showWriteError = true
            return
        }
        await workspace.applyAutomationPolicy()
    }

    // MARK: - Helpers

    private func statusPill(for s: Schedule.LastStatus) -> some View {
        let pill: Pill
        switch s {
        case .ok:      pill = Pill(text: "OK",      tone: .teal,   icon: "checkmark")
        case .warn:    pill = Pill(text: "WARN",    tone: .warn,   icon: "exclamationmark")
        case .fail:    pill = Pill(text: "FAIL",    tone: .danger, icon: "xmark")
        case .partial: pill = Pill(text: "PARTIAL", tone: .warn,   icon: "exclamationmark.triangle.fill")
        }
        return pill.accessibilityLabel(s.accessibilityLabel)
    }

    private func labelText(for schedule: Schedule) -> String {
        LaunchAgentWriter.label(for: schedule) ?? "(invalid label)"
    }

    /// Extracts the exit code from a run-completion message. The producer is
    /// `runSchedule` which emits `"\(name) · exit \(code)"`. Older log
    /// formats may omit the leading separator. Returns nil when the message
    /// does not carry a parseable exit code — callers should suppress the
    /// EXIT pill rather than rendering a bogus "EXIT -1" sentinel.
    /// `nonisolated` so unit tests can call it without inheriting the
    /// implicit `@MainActor` View isolation under Swift 6 strict concurrency.
    nonisolated static func extractExitCode(from message: String) -> Int? {
        // Anchor on the literal " exit " (or "exit " at start of string)
        // followed by an optional sign and digits to end-of-string. The
        // trailing-only match avoids picking up "Exit Code in" or similar
        // mid-sentence occurrences if the format ever changes.
        guard let range = message.range(
            of: #"(?:^|\s)exit\s+(-?\d+)\s*$"#,
            options: .regularExpression
        ) else {
            return nil
        }
        // Extract the captured digit run from the matched substring.
        let matched = message[range]
        guard let digits = matched.range(of: #"-?\d+"#, options: .regularExpression) else {
            return nil
        }
        return Int(matched[digits])
    }
}

// MARK: - Run log console (terminal-styled live output)

/// Terminal-styled console for streaming `CLIBridge.LogLine` output. Color-codes lines by
/// keyword (error/warn/success), shows a blinking cursor on the trailing line, and
/// auto-scrolls to the bottom only while the user has not manually scrolled up.
private struct RunLogConsole: View {
    let lines: [CLIBridge.LogLine]
    let isRunning: Bool
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var isScrolledToBottom = true
    @State private var cursorVisible = true
    private let cursorTick = Timer.publish(every: 0.55, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    if lines.isEmpty {
                        HStack(spacing: 0) {
                            Text(isRunning ? "Starting" : "No output")
                                .font(Theme.Fonts.mono(12))
                                .foregroundStyle(Theme.Text.tertiary(contrast))
                            cursor
                        }
                    } else {
                        ForEach(Array(lines.enumerated()), id: \.element.id) { idx, line in
                            HStack(spacing: 0) {
                                Text(line.text)
                                    .font(Theme.Fonts.mono(12))
                                    .foregroundStyle(color(for: line))
                                    .textSelection(.enabled)
                                if idx == lines.count - 1 { cursor }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                        }
                    }
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                .padding(14)
                .background(scrollOffsetReader)
            }
            .coordinateSpace(name: Self.coordSpace)
            .background(Theme.Colors.codeBG)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Metrics.buttonRadius, style: .continuous)
                    .strokeBorder(Theme.Colors.hairlineStrong, lineWidth: 1)
            )
            .onChange(of: lines.count) { _, _ in
                guard isScrolledToBottom else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
            .onPreferenceChange(BottomVisibilityKey.self) { reachedBottom in
                isScrolledToBottom = reachedBottom
            }
        }
        .onReceive(cursorTick) { _ in cursorVisible.toggle() }
    }

    private var cursor: some View {
        Rectangle()
            .fill(Theme.Colors.goldBright)
            .frame(width: 7, height: 13)
            .opacity(cursorVisible && isRunning ? 1 : 0)
            .padding(.leading, 2)
    }

    private var scrollOffsetReader: some View {
        GeometryReader { geo in
            // True when the bottom of the content is within ~24pt of the viewport bottom.
            let frame = geo.frame(in: .named(Self.coordSpace))
            let nearBottom = frame.maxY <= geo.size.height + 32
            Color.clear.preference(key: BottomVisibilityKey.self, value: nearBottom)
        }
    }

    private func color(for line: CLIBridge.LogLine) -> Color {
        let lower = line.text.lowercased()
        if lower.contains("error") || lower.contains("fail") || line.level == .fail {
            return Theme.Colors.dangerSoft
        }
        if lower.contains("warn") || line.level == .warn {
            return Theme.Colors.warnSoft
        }
        if line.text.contains("✓") || lower.contains("success") || lower.contains("done") || line.level == .ok {
            return Theme.Colors.ok
        }
        return Theme.Colors.fg2
    }

    private static let bottomAnchor = "run-log-bottom"
    private static let coordSpace = "run-log-scroll"
}

private struct BottomVisibilityKey: PreferenceKey {
    static let defaultValue = true
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = nextValue() }
}

// MARK: - New schedule form state

struct ScheduleFormState {
    var name = ""
    var profile = ""
    var cadenceType = CadenceType.daily
    var weekday = 1     // 1 = Monday
    var monthDay = 1
    var scheduledTime = Calendar.current.date(from: DateComponents(hour: 6, minute: 0)) ?? Date()
    var mode = Schedule.RunMode.snapshotOnly
    var enabled = true

    /// Which `CollectionTier`s the collect step fetches (PR-23 T-17).
    /// Initialized to the default mode's tier set; kept in sync with the
    /// mode picker until the user manually edits it (`userTouchedTiers`).
    var tiers: Set<CollectionTier> = Schedule.RunMode.snapshotOnly.defaultTiers

    /// True once the user manually toggled a tier checkbox. Once set, a
    /// mode change no longer overwrites `tiers` with the new mode's
    /// default — the operator's explicit choice wins.
    var userTouchedTiers = false

    /// Re-sync `tiers` to `mode`'s default unless the user has overridden.
    /// Called from the form's mode-picker `.onChange`.
    mutating func syncTiersToMode() {
        guard !userTouchedTiers else { return }
        tiers = mode.defaultTiers
    }

    // Multi-profile targeting. The native runner only ever honours
    // `--all-profiles` + exclusions (`ScheduleRecord.allProfiles` is a Bool),
    // so this stays a two-way choice rather than modeling scopes the store
    // cannot persist.
    enum ProfileMode: String, CaseIterable, Identifiable {
        case single = "Single profile"
        case all = "All profiles"
        var id: String { rawValue }
    }
    var profileMode: ProfileMode = .single
    var multiSequential = false

    var resolvedMultiTarget: MultiTarget? {
        switch profileMode {
        case .single: return nil
        case .all:    return MultiTarget(scope: .all, sequential: multiSequential)
        }
    }

    init(defaultProfile: String = "") { profile = defaultProfile }

    enum CadenceType: String, CaseIterable, Identifiable {
        case daily = "Daily"
        case weekly = "Weekly"
        case weekdays = "Weekdays"
        case monthly = "Monthly"
        var id: String { rawValue }
    }

    var scheduleString: String {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: scheduledTime)
        let h = comps.hour ?? 6
        let m = comps.minute ?? 0
        let t = String(format: "%02d:%02d", h, m)
        switch cadenceType {
        case .daily:    return "Daily \(t)"
        case .weekly:
            let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
            return "\(names[min(weekday, 6)]) \(t)"
        case .weekdays: return "Weekdays \(t)"
        case .monthly:
            let suffixes = ["th", "st", "nd", "rd"]
            let s = monthDay <= 3 ? suffixes[monthDay] : "th"
            return "\(monthDay)\(s) \(t)"
        }
    }

    var isValid: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch profileMode {
        case .single:  return !profile.isEmpty
        case .all:     return true
        }
    }

    func toSchedule() -> Schedule {
        let target = resolvedMultiTarget
        return Schedule(
            name: name.trimmingCharacters(in: .whitespaces),
            profile: profile,
            schedule: scheduleString,
            cadence: cadenceType.rawValue.lowercased(),
            mode: mode,
            next: "—",
            last: "—",
            lastStatus: .ok,
            artifacts: [],
            enabled: enabled,
            multiTarget: target,
            tiers: tiers
        )
    }
}

// MARK: - New schedule sheet

private struct NewScheduleSheet: View {
    @Binding var form: ScheduleFormState
    let profiles: [String]
    let onSave: (ScheduleFormState) -> Void
    let onCancel: () -> Void
    @Environment(\.colorSchemeContrast) private var contrast

    @FocusState private var nameFieldFocused: Bool
    @State private var nameWasTouched = false

    private let weekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title bar
            HStack {
                Text("New Schedule")
                    .font(.headline)
                    .foregroundStyle(Theme.Colors.fg)
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.Colors.fgMuted)
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close new schedule")
                .help("Close new schedule")
            }
            .padding(18)
            Divider()

            // Form body
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    formRow(label: "Name") {
                        VStack(alignment: .leading, spacing: 4) {
                            PNPTextField(value: $form.name, placeholder: "e.g. Daily Snapshot Collection")
                                .focused($nameFieldFocused)
                                .onChange(of: nameFieldFocused) { _, focused in
                                    if !focused { nameWasTouched = true }
                                }
                            if nameWasTouched && form.name.trimmingCharacters(in: .whitespaces).isEmpty {
                                Text("Schedule name is required")
                                    .font(.caption)
                                    .foregroundStyle(Theme.Colors.warn)
                            }
                        }
                    }

                    formRow(label: "Profile target") {
                        Picker("", selection: $form.profileMode) {
                            ForEach(ScheduleFormState.ProfileMode.allCases) {
                                Text($0.rawValue).tag($0)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                    }

                    if form.profileMode == .single {
                        formRow(label: "Profile") {
                            Picker("", selection: $form.profile) {
                                ForEach(profiles, id: \.self) { Text($0).tag($0) }
                            }
                            .labelsHidden()
                            .frame(maxWidth: .infinity)
                        }
                    }

                    if form.profileMode != .single {
                        formRow(label: "Sequential") {
                            Toggle("Run profiles one at a time", isOn: $form.multiSequential)
                                .labelsHidden()
                            Text("Run profiles one at a time")
                                .font(.caption)
                                .foregroundStyle(Theme.Text.tertiary(contrast))
                        }
                    }

                    formRow(label: "Cadence") {
                        Picker("", selection: $form.cadenceType) {
                            ForEach(ScheduleFormState.CadenceType.allCases) {
                                Text($0.rawValue).tag($0)
                            }
                        }
                        .labelsHidden()

                        if form.cadenceType == .weekly {
                            Picker("Day", selection: $form.weekday) {
                                ForEach(0..<7) { Text(weekdayNames[$0]).tag($0) }
                            }
                            .labelsHidden()
                        }

                        if form.cadenceType == .monthly {
                            Picker("Day", selection: $form.monthDay) {
                                ForEach(1...28, id: \.self) { Text("Day \($0)").tag($0) }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 120)
                        }
                    }

                    formRow(label: "Time") {
                        DatePicker("", selection: $form.scheduledTime,
                                   displayedComponents: [.hourAndMinute])
                            .labelsHidden()
                            .datePickerStyle(.compact)
                    }

                    formRow(label: "Mode") {
                        Picker("", selection: $form.mode) {
                            ForEach(Schedule.RunMode.allCases) {
                                Text($0.rawValue).tag($0)
                            }
                        }
                        .labelsHidden()
                        .onChange(of: form.mode) { _, _ in
                            // Re-sync the tier default to the new mode unless
                            // the operator has already picked tiers manually.
                            form.syncTiersToMode()
                        }
                    }

                    // jamf-cli-only never collects — the tier set is moot,
                    // so the picker is hidden for that mode.
                    if form.mode != .jamfCLIOnly {
                        formRow(label: "Tiers") {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 14) {
                                    ForEach(CollectionTier.allCases, id: \.self) { tier in
                                        Toggle(tier.displayName, isOn: tierBinding(tier))
                                            .toggleStyle(.checkbox)
                                    }
                                }
                                Text("Which collection tiers this schedule fetches.")
                                    .font(.caption)
                                    .foregroundStyle(Theme.Text.tertiary(contrast))
                            }
                        }
                    }

                    formRow(label: "Enabled") {
                        Toggle("", isOn: $form.enabled).labelsHidden()
                    }

                    FieldHelp(text: "Cadence preview: \(form.scheduleString)")
                }
                .padding(18)
            }

            Divider()
            HStack {
                Spacer()
                PNPButton(title: "Cancel", action: onCancel)
                PNPButton(title: "Add Schedule", icon: "checkmark", style: .gold) {
                    onSave(form)
                }
                .disabled(!form.isValid)
            }
            .padding(14)
        }
        .frame(width: 420)
        .background(Theme.Colors.winBG2)
    }

    @ViewBuilder
    private func formRow<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel(label: label)
            HStack(spacing: 8) { content() }
        }
    }

    /// Two-way binding for one tier's checkbox. Editing any tier marks
    /// `userTouchedTiers` so a later mode change won't clobber the choice.
    private func tierBinding(_ tier: CollectionTier) -> Binding<Bool> {
        Binding(
            get: { form.tiers.contains(tier) },
            set: { isOn in
                if isOn {
                    form.tiers.insert(tier)
                } else {
                    form.tiers.remove(tier)
                }
                form.userTouchedTiers = true
            }
        )
    }
}
