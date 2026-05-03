import SwiftUI

// Thread-safe accumulator for streaming log lines from CLIBridge callbacks.
private final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [CLIBridge.LogLine] = []
    func append(_ line: CLIBridge.LogLine) { lock.withLock { _lines.append(line) } }
    var lines: [CLIBridge.LogLine] { lock.withLock { _lines } }
}

struct SchedulesView: View {
    @Environment(WorkspaceStore.self) private var workspace
    @State private var profileFilter: String = "All"
    @State private var bridge = CLIBridge()
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

    private var filteredSchedules: [Schedule] {
        if profileFilter == "All" { return workspace.schedules }
        return workspace.schedules.filter { $0.profile == profileFilter }
    }

    private var profileCount: Int {
        Set(workspace.schedules.map(\.profile)).count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if let message = workspace.launchAgentCleanupMessage {
                    legacyCleanupBanner(message)
                }
                profileFilterStrip
                nextUpCallout
                schedulesTable
                runModesExplainer
            }
            .padding(EdgeInsets(top: Theme.Metrics.pagePadTop,
                                leading: Theme.Metrics.pagePadH,
                                bottom: Theme.Metrics.pagePadBottom,
                                trailing: Theme.Metrics.pagePadH))
        }
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
    }

    // MARK: - Header

    private var header: some View {
        PageHeader(
            kicker: "macOS LaunchAgent · UserAgent",
            title: "Scheduled Runs",
            subtitle: "\(workspace.schedules.count) schedules · \(workspace.schedules.filter(\.enabled).count) enabled · across \(profileCount) jamf-cli profiles"
        ) {
            AnyView(
                HStack(spacing: 8) {
                    PNPButton(title: "Refresh", icon: "arrow.clockwise") {
                        workspace.reloadFromDisk()
                    }
                    PNPButton(title: "New schedule", icon: "plus", style: .gold) {
                        newScheduleForm = ScheduleFormState(defaultProfile: workspace.profile)
                        showNewSchedule = true
                    }
                }
            )
        }
    }

    private func legacyCleanupBanner(_ message: String) -> some View {
        GlassPane(borderColor: Theme.Colors.warn.opacity(0.35)) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.Colors.warn)
                Text(message)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.Colors.fg2)
                Spacer()
            }
        }
    }

    // MARK: - Profile filter strip

    private var profileFilterStrip: some View {
        HStack(spacing: 8) {
            Kicker(text: "JAMF-CLI PROFILE").padding(.trailing, 4)
            Button {
                profileFilter = "All"
            } label: {
                Pill(text: "All · \(workspace.schedules.count)", tone: profileFilter == "All" ? .gold : .muted)
            }
            .buttonStyle(.plain)
            ForEach(workspace.profiles) { p in
                let count = workspace.schedules.filter { $0.profile == p.name }.count
                Button {
                    profileFilter = p.name
                } label: {
                    Pill(text: "\(p.name) · \(count)", tone: profileFilter == p.name ? .gold : .muted)
                        .opacity(count > 0 ? 1 : 0.5)
                }
                .buttonStyle(.plain)
            }
            Spacer()
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
        return GlassPane(borderColor: Theme.Colors.gold.opacity(0.4)) {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LinearGradient(
                            colors: [Theme.Colors.gold, Theme.Colors.goldDim],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ))
                    Image(systemName: "clock")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Color(hex: 0x1A1408))
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 2) {
                    Kicker(text: "Next up", tone: .gold)
                    Text(next?.name ?? "No schedules enabled")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.Colors.fg)
                    HStack(spacing: 4) {
                        if let s = next {
                            Mono(text: "\(s.schedule) · \(s.mode.rawValue) · ", size: 11.5)
                            Text(s.profile).font(Theme.Fonts.mono(11.5)).foregroundStyle(Theme.Colors.goldBright)
                        }
                    }
                }
                Spacer()

                VStack(spacing: 6) {
                    PNPButton(
                        title: isRunning ? "Running…" : "Run now",
                        icon: isRunning ? "hourglass" : "play.fill"
                    ) {
                        guard !isRunning else { return }
                        showRunLog = true
                        Task { await runNextScheduledNow() }
                    }
                    if let msg = lastRunMessage {
                        Mono(text: msg, size: 10, color: Theme.Colors.fgMuted)
                    }
                }
            }
        }
        .popover(isPresented: $showRunLog) {
            runLogPopover
        }
    }

    private var runLogPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Mono(text: "Live output", size: 12, color: Theme.Colors.fg2)
                Spacer()
                if isRunning {
                    ProgressView().scaleEffect(0.6)
                } else if let msg = lastRunMessage {
                    Pill(text: msg.contains("exit 0") ? "EXIT 0" : "DONE",
                         tone: msg.contains("exit 0") ? .teal : .warn)
                }
                Button { showRunLog = false } label: {
                    Image(systemName: "xmark").font(.system(size: 11))
                        .foregroundStyle(Theme.Colors.fgMuted)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    if runLogLines.isEmpty {
                        Mono(text: isRunning ? "Starting…" : "No output", size: 11.5)
                            .padding(14)
                    } else {
                        ForEach(runLogLines) { line in
                            Text(line.text)
                                .font(Theme.Fonts.mono(11))
                                .foregroundStyle(logColor(for: line.level))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(14)
                    }
                }
            }
            .frame(width: 520, height: 260)
            .background(Theme.Colors.codeBG)
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
                }
                .width(48)

                TableColumn("Schedule") { s in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.name).font(.system(size: 13, weight: .semibold))
                        Mono(text: labelText(for: s), size: 10.5)
                    }
                }

                TableColumn("Profile") { s in
                    Pill(text: s.profileDisplayLabel, tone: s.isMulti ? .teal : .gold)
                }.width(140)
                TableColumn("Cadence") { s in Mono(text: s.schedule) }
                TableColumn("Mode")    { s in Pill(text: s.mode.rawValue, tone: .muted) }
                TableColumn("Next Run") { s in
                    Mono(text: s.next, color: s.enabled ? Theme.Colors.goldBright : Theme.Colors.fgMuted)
                }
                TableColumn("Last Run") { s in Mono(text: s.last) }
                TableColumn("Status")   { s in statusPill(for: s.lastStatus) }.width(80)
                TableColumn("Outputs") { s in
                    HStack(spacing: 4) {
                        if s.artifacts.isEmpty {
                            Text("—").foregroundStyle(Theme.Colors.fgMuted)
                        } else {
                            ForEach(s.artifacts, id: \.self) { Pill(text: $0, tone: .muted) }
                        }
                    }
                }
                TableColumn("") { s in
                    Menu {
                        Button {
                            guard !isRunning else { return }
                            showRunLog = true
                            Task { await runScheduleNow(s) }
                        } label: {
                            Label("Run now", systemImage: "play.fill")
                        }
                        .disabled(isRunning)
                        Divider()
                        Button(role: .destructive) {
                            pendingDelete = s
                            showDeleteConfirm = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundStyle(Theme.Colors.fgMuted)
                            .font(.system(size: 14))
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                }
                .width(28)
            }
            .frame(minHeight: 280)
            .scrollContentBackground(.hidden)
        }
    }

    // MARK: - Run modes explainer

    private var runModesExplainer: some View {
        let modes: [(String, String, String, Color)] = [
            ("snapshot-only", "Refresh jamf-cli JSON · archive CSVs",     "icloud.and.arrow.up",   Theme.Colors.info),
            ("jamf-cli-only", "Live or cached jamf-cli sheets",           "bolt.fill",             Theme.Colors.gold),
            ("jamf-cli-full", "Baseline CSV + snapshots + report",        "shield.lefthalf.filled", Theme.Colors.ok),
            ("csv-assisted",  "CSV inbox + jamf-cli",                     "folder.fill",           Theme.Colors.purple),
        ]
        return HStack(spacing: 10) {
            ForEach(modes, id: \.0) { mode in
                Card(padding: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Image(systemName: mode.2).font(.system(size: 14)).foregroundStyle(mode.3)
                            Text(mode.0).font(Theme.Fonts.mono(12, weight: .semibold)).foregroundStyle(Theme.Colors.fg)
                        }
                        Text(mode.1).font(.system(size: 11)).foregroundStyle(Theme.Colors.fgMuted)
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
        isRunning = true
        runLogLines = []
        let buf = LineBuffer()

        guard let agentLabel = LaunchAgentWriter.label(for: schedule),
              schedule.isMulti || ProfileService.isValid(schedule.profile)
        else {
            lastRunMessage = "invalid schedule label"
            isRunning = false
            return
        }

        let exit = await LaunchAgentWriter.runNow(agentLabel) { line in
            buf.append(line)
            Task { @MainActor in runLogLines = buf.lines }
        }

        runLogLines = buf.lines
        isRunning = false
        lastRunMessage = "\(schedule.name) · exit \(exit)"
        workspace.reloadFromDisk()
    }

    private func toggleSchedule(_ schedule: Schedule) async {
        guard let idx = workspace.schedules.firstIndex(where: { $0.id == schedule.id }) else { return }

        let original = workspace.schedules[idx].enabled
        guard let agentLabel = LaunchAgentWriter.label(for: workspace.schedules[idx]) else {
            writeError = "Schedule name or profile produces an invalid LaunchAgent label."
            showWriteError = true
            return
        }
        workspace.schedules[idx].enabled.toggle()
        let nowEnabled = workspace.schedules[idx].enabled

        let exitCode = await bridge.setupLaunchAgent(
            workspace.schedules[idx],
            load: nowEnabled
        ) { _ in }

        if exitCode != 0 {
            workspace.schedules[idx].enabled = original
            writeError = "Could not update LaunchAgent \(agentLabel) · exit \(exitCode)"
            showWriteError = true
        } else {
            workspace.reloadFromDisk()
        }
    }

    private func deleteSchedule(_ schedule: Schedule) {
        guard let label = LaunchAgentWriter.label(for: schedule) else {
            writeError = "Schedule name or profile produces an invalid LaunchAgent label."
            showWriteError = true
            return
        }
        Task {
            _ = await LaunchAgentWriter.unload(label)
            do {
                try LaunchAgentWriter.delete(label)
                workspace.schedules.removeAll { $0.id == schedule.id }
            } catch {
                writeError = error.localizedDescription; showWriteError = true
            }
        }
    }

    private func saveSchedule(_ form: ScheduleFormState) async {
        let schedule = form.toSchedule()
        let exitCode = await bridge.setupLaunchAgent(schedule, load: schedule.enabled) { _ in }
        if exitCode == 0 {
            workspace.reloadFromDisk()
        } else {
            writeError = "Could not create LaunchAgent · exit \(exitCode)"
            showWriteError = true
        }
    }

    // MARK: - Helpers

    private func statusPill(for s: Schedule.LastStatus) -> some View {
        switch s {
        case .ok:   Pill(text: "OK",   tone: .teal,   icon: "checkmark")
        case .warn: Pill(text: "WARN", tone: .warn,   icon: "exclamationmark")
        case .fail: Pill(text: "FAIL", tone: .danger, icon: "xmark")
        }
    }

    private func labelText(for schedule: Schedule) -> String {
        LaunchAgentWriter.label(for: schedule) ?? "(invalid label)"
    }

    private func logColor(for level: CLIBridge.LogLevel) -> Color {
        switch level {
        case .info: Theme.Colors.fg2
        case .ok:   Theme.Colors.ok
        case .warn: Theme.Colors.warn
        case .fail: Theme.Colors.danger
        }
    }
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

    // Multi-profile targeting
    enum ProfileMode: String, CaseIterable, Identifiable {
        case single = "Single profile"
        case all = "All profiles"
        case filter = "Profile filter (glob)"
        case list = "Specific profiles"
        var id: String { rawValue }
    }
    var profileMode: ProfileMode = .single
    var multiFilter = ""          // for .filter
    var multiList = ""            // for .list, comma-separated
    var multiSequential = false

    var resolvedMultiTarget: MultiTarget? {
        switch profileMode {
        case .single: return nil
        case .all:    return MultiTarget(scope: .all, sequential: multiSequential)
        case .filter:
            let g = multiFilter.trimmingCharacters(in: .whitespaces)
            guard !g.isEmpty else { return MultiTarget(scope: .all, sequential: multiSequential) }
            return MultiTarget(scope: .filter(g), sequential: multiSequential)
        case .list:
            let ps = multiList.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !ps.isEmpty else { return MultiTarget(scope: .all, sequential: multiSequential) }
            return MultiTarget(scope: .list(ps), sequential: multiSequential)
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
        case .filter:  return !multiFilter.trimmingCharacters(in: .whitespaces).isEmpty
        case .list:    return !multiList.trimmingCharacters(in: .whitespaces).isEmpty
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
            multiTarget: target
        )
    }
}

// MARK: - New schedule sheet

private struct NewScheduleSheet: View {
    @Binding var form: ScheduleFormState
    let profiles: [String]
    let onSave: (ScheduleFormState) -> Void
    let onCancel: () -> Void

    private let weekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title bar
            HStack {
                Text("New Schedule")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.Colors.fg)
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.Colors.fgMuted)
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
            }
            .padding(18)
            Divider()

            // Form body
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    formRow(label: "Name") {
                        PNPTextField(value: $form.name, placeholder: "e.g. Daily Snapshot Collection")
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
                    } else if form.profileMode == .filter {
                        formRow(label: "Glob pattern") {
                            PNPTextField(value: $form.multiFilter, placeholder: "e.g. prod-*", mono: true)
                        }
                    } else if form.profileMode == .list {
                        formRow(label: "Profiles") {
                            PNPTextField(value: $form.multiList,
                                         placeholder: "production,staging", mono: true)
                        }
                    }

                    if form.profileMode != .single {
                        formRow(label: "Sequential") {
                            Toggle("Run profiles one at a time", isOn: $form.multiSequential)
                                .labelsHidden()
                            Text("Run profiles one at a time")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.Colors.fgMuted)
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
}
