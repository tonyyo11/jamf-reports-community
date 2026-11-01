import SwiftUI
import TipKit

/// Guided walkthrough that lists the Extension Attributes jamf-cli already collected and
/// lets the operator adopt selected ones into `config.yaml`. A CSV export the operator
/// picks can be imported once instead; it only proposes, and is not read again.
///
/// Adoption is additive (never deletes config) and explicit (the user selects
/// which EAs to adopt — no silent auto-write).
@MainActor
struct CSVEAWalkthroughSheet: View {
    let profile: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorSchemeContrast) private var contrast

    @State private var proposals: [ProposedEA] = []
    /// Proposal id → values for the dry-run parse check (a CSV column, or collected values).
    @State private var valueSamples: [String: [String]] = [:]
    /// Proposal id → caption for a collected EA that has no values yet.
    @State private var rowNotes: [String: String] = [:]
    /// Collected EAs left out because `config.yaml` already tracks them.
    @State private var alreadyTrackedCount = 0
    @State private var selected: Set<String> = []
    /// Proposal ids the operator chose to adopt as a Security Agent rather than a
    /// Custom EA. Default (absent) is Custom EA.
    @State private var agentTargets: Set<String> = []
    /// Per-proposal connected-value override for Security Agent adoption; absent
    /// falls back to the proposal's sample value.
    @State private var connectedValues: [String: String] = [:]
    /// Per-proposal type override, defaulting to the detected guess. Drives both
    /// adoption and the dry-run parse-health verdict.
    @State private var typeOverrides: [String: CustomEAConfig.EAType] = [:]
    /// The CSV the operator imported; nil while showing the collected EAs.
    @State private var importedCSVName: String?
    @State private var loaded = false
    @State private var adoptError: String?
    @State private var confirmation: String?
    /// The save left notes (a block left as typed, a copy made), so the banner warns.
    @State private var confirmationHasNotes = false
    private enum AdoptTarget: Hashable { case customEA, securityAgent }

    private var selectedProposals: [ProposedEA] {
        proposals.filter { selected.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerSection
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    guidanceCard
                    TipView(WalkthroughTips.adoptTarget)
                    if !loaded {
                        loadingState
                    } else if proposals.isEmpty {
                        noCandidatesState
                    } else {
                        candidatesCard
                    }
                    if let adoptError {
                        errorBanner(adoptError)
                    }
                    if let confirmation {
                        confirmationBanner(confirmation, warns: confirmationHasNotes)
                    }
                }
            }
            footerButtons
        }
        .padding(20)
        .frame(minWidth: 460, idealWidth: 540, minHeight: 420, idealHeight: 600)
        .background(Theme.Colors.winBG)
        .task { await load() }
        // A banner appears mid-screen with no focus change, so VoiceOver would not say it.
        .onChange(of: adoptError) { _, text in announce(text) }
        .onChange(of: confirmation) { _, text in announce(text) }
        // Esc dismisses. Hidden zero-size button with .cancelAction is the
        // canonical SwiftUI pattern (see OverviewView's drill-down dismissal).
        .background {
            Button("", action: { dismiss() })
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Kicker(
                text: importedCSVName == nil
                    ? L("Collected data · Extension Attributes") : L("CSV import · Extension Attributes"),
                tone: .teal)
            Text(importedCSVName == nil ? "Adopt EAs" : "Set up EA tracking")
                .font(Theme.Fonts.serif(22, weight: .bold))
                .foregroundStyle(Theme.Text.primary)
                .accessibilityAddTraits(.isHeader)
            if let importedCSVName {
                Mono(text: importedCSVName)
            }
        }
    }

    private var guidanceCard: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(
                    title: importedCSVName == nil ? L("From Collected Data") : L("Before You Export"))
                Text(importedCSVName == nil
                    ? "These are the Extension Attributes jamf-cli collected on its last refresh. Select the ones to track and adopt them into config.yaml — your existing settings are preserved."
                    : "The candidates below were detected in the CSV you picked. Add your Extension Attribute columns to the Jamf Pro export under \"Export-only fields\", then select the ones to track. The file is read once; config.yaml is all that is kept.")
                    .font(.footnote)
                    .foregroundStyle(Theme.Text.tertiary(contrast))
                    .fixedSize(horizontal: false, vertical: true)
                if importedCSVName == nil {
                    PNPButton(
                        title: L("Import from a CSV export (one time)"),
                        icon: "tablecells.badge.ellipsis", style: .ghost, size: .sm
                    ) { pickCSV() }
                }
            }
        }
    }

    private var candidatesCard: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionHeader(title: L("Proposed Extension Attributes"))
                    Spacer()
                    Pill(text: L("\(selected.count)/\(proposals.count) selected"), tone: .teal)
                }
                VStack(spacing: 0) {
                    ForEach(Array(proposals.enumerated()), id: \.element.id) { idx, ea in
                        candidateRow(ea)
                        if idx < proposals.count - 1 {
                            Divider().background(Theme.Hairline.standard)
                        }
                    }
                }
            }
        }
    }

    private func candidateRow(_ ea: ProposedEA) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                toggle(ea.id)
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: selected.contains(ea.id)
                            ? "checkmark.square.fill" : "square")
                        .foregroundStyle(selected.contains(ea.id)
                                            ? Theme.Colors.gold : Theme.Text.tertiary(contrast))
                        .font(.system(size: 14))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ea.name)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(Theme.Text.primary)
                        if importedCSVName != nil { Mono(text: ea.column, size: 10.5) }
                        if let note = rowNotes[ea.id] {
                            Text(note)
                                .font(.caption2)
                                .foregroundStyle(Theme.Text.tertiary(contrast))
                        }
                        if !ea.sampleValue.isEmpty {
                            Text("e.g. \(ea.sampleValue)")
                                .font(.caption2)
                                .foregroundStyle(Theme.Text.tertiary(contrast))
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    Pill(text: ea.type, tone: .muted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(ea.name), \(ea.type)")
            .accessibilityValue(selected.contains(ea.id) ? "Selected" : "Not selected")
            .accessibilityAddTraits(.isButton)

            if selected.contains(ea.id) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("Adopt as")
                            .font(.caption2)
                            .foregroundStyle(Theme.Text.tertiary(contrast))
                        Picker("Adopt as", selection: targetBinding(ea)) {
                            Text("Custom EA").tag(AdoptTarget.customEA)
                            Text("Security Agent").tag(AdoptTarget.securityAgent)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 220)
                        Spacer()
                    }
                    if !agentTargets.contains(ea.id) {
                        HStack(spacing: 8) {
                            Text("Type")
                                .font(.caption2)
                                .foregroundStyle(Theme.Text.tertiary(contrast))
                            Picker("Type", selection: typeBinding(ea)) {
                                ForEach(CustomEAConfig.EAType.allCases) { type in
                                    Text(type.rawValue.capitalized).tag(type)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .frame(width: 160)
                            Spacer()
                        }
                        parseHealthVerdict(for: ea)
                    }
                    if agentTargets.contains(ea.id) {
                        // Own line so it never reads as a third picker segment or
                        // overflows the sheet at minWidth.
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Text("Connected value")
                                    .font(.caption2)
                                    .foregroundStyle(Theme.Text.tertiary(contrast))
                                PNPTextField(
                                    value: connectedBinding(ea), placeholder: L("e.g. Installed"),
                                    mono: true)
                                    .accessibilityLabel("Connected value")
                                    .frame(maxWidth: 220)
                                Spacer()
                            }
                            TipView(WalkthroughTips.connectedValue)
                                .frame(maxWidth: 360, alignment: .leading)
                            Text("Pre-filled from a sample value. Set it to what this column shows when the agent is installed/connected — matched as a case-insensitive substring (e.g. Installed, Running, or a version). A device counts as connected when its value contains this text.")
                                .font(.caption2)
                                .foregroundStyle(Theme.Text.tertiary(contrast))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.leading, 24)
            }
        }
        .padding(.vertical, 8)
    }

    /// Custom EA (default) vs Security Agent for a proposal.
    private func targetBinding(_ ea: ProposedEA) -> Binding<AdoptTarget> {
        Binding(
            get: { agentTargets.contains(ea.id) ? .securityAgent : .customEA },
            set: { newValue in
                if newValue == .securityAgent { agentTargets.insert(ea.id) }
                else { agentTargets.remove(ea.id) }
                confirmation = nil
            }
        )
    }

    /// Connected value for a Security Agent adoption; defaults to the sample value.
    private func connectedBinding(_ ea: ProposedEA) -> Binding<String> {
        Binding(
            get: { connectedValues[ea.id] ?? ea.sampleValue },
            set: { connectedValues[ea.id] = $0 }
        )
    }

    /// EA type for a proposal; defaults to `ScaffoldService`'s detected guess.
    private func typeBinding(_ ea: ProposedEA) -> Binding<CustomEAConfig.EAType> {
        Binding(
            get: { typeOverrides[ea.id] ?? Self.eaType(from: ea.type) },
            set: { typeOverrides[ea.id] = $0 }
        )
    }

    /// Map `ScaffoldService`'s detected type string to the Models.swift twin.
    /// `ScaffoldService.guessEAType` only ever returns these five strings; an
    /// unrecognized value (future scaffold change) falls back to `.text`.
    private static func eaType(from raw: String) -> CustomEAConfig.EAType {
        CustomEAConfig.EAType(rawValue: raw) ?? .text
    }

    /// In-memory dry-run parse verdict for a proposal's chosen type, computed
    /// from the values already loaded for the walkthrough (cheap — capped at 50 per EA).
    private func parseHealth(
        for ea: ProposedEA
    ) -> EAParseHealthService.ColumnHealth? {
        guard let values = valueSamples[ea.id] else { return nil }
        let type = typeOverrides[ea.id] ?? Self.eaType(from: ea.type)
        return EAParseHealthService.assess(column: ea.column, values: values, type: type)
    }

    @ViewBuilder
    private func parseHealthVerdict(for ea: ProposedEA) -> some View {
        if let health = parseHealth(for: ea), let rate = health.parseRate {
            let type = typeOverrides[ea.id] ?? Self.eaType(from: ea.type)
            let pct = Int((rate * 100).rounded())
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: verdictIcon(rate))
                        .foregroundStyle(verdictColor(rate))
                        .font(.caption2)
                    Text(health.nonEmpty == 1 ? "Parses as \(type.rawValue) for \(pct)% of \(health.nonEmpty) non-empty row" : "Parses as \(type.rawValue) for \(pct)% of \(health.nonEmpty) non-empty rows")
                        .font(.caption2)
                        .foregroundStyle(verdictColor(rate))
                }
                if rate < 0.9, let top = health.topUnparseable.first {
                    Text("Most common unparsed shape: \(top.skeleton) (×\(top.count))")
                        .font(.caption2)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                }
            }
        }
    }

    private func verdictIcon(_ rate: Double) -> String {
        rate >= 0.9 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private func verdictColor(_ rate: Double) -> Color {
        if rate >= 0.9 { return Theme.Colors.ok }
        if rate >= 0.5 { return Theme.Colors.warn }
        return Theme.Colors.danger
    }

    private var loadingState: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
                .accessibilityLabel("Reading the collected Extension Attributes")
            Text("Reading the collected Extension Attributes…")
                .font(.footnote)
                .foregroundStyle(Theme.Text.tertiary(contrast))
        }
        .padding(.vertical, 12)
    }

    private var noCandidatesState: some View {
        Card(padding: 16) {
            if importedCSVName != nil {
                EmptyStateView(
                    systemImage: "tablecells.badge.ellipsis",
                    title: L("No EA-like columns detected."),
                    message: L("This export looks like built-in inventory fields only. Re-export with your Extension Attribute columns added under \"Export-only fields\".")
                )
            } else {
                EmptyStateView(
                    systemImage: "tablecells.badge.ellipsis",
                    title: alreadyTrackedCount > 0
                        ? L("Every collected EA is already tracked.")
                        : L("No Extension Attributes collected yet."),
                    message: alreadyTrackedCount > 0
                        ? L("All \(alreadyTrackedCount) are in config.yaml.")
                        : L("Refresh from the Overview to collect them, or import a CSV export once.")
                )
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.Colors.danger)
            Text(message)
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.Colors.dangerSoft)
            Spacer()
        }
        .padding(12)
        .background(Theme.Colors.danger.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func confirmationBanner(_ message: String, warns: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: warns ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(warns ? Theme.Colors.warn : Theme.Colors.tealBright)
            Text(message)
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.Text.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(12)
        .background((warns ? Theme.Colors.warn : Theme.Colors.teal).opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var footerButtons: some View {
        HStack {
            PNPButton(title: L("Close"), style: .ghost) { dismiss() }
            Spacer()
            PNPButton(
                title: L("Add \(selected.count) to config"),
                icon: "plus.circle",
                style: .gold
            ) {
                adopt()
            }
            .disabled(selected.isEmpty)
            .opacity(selected.isEmpty ? 0.5 : 1)
        }
    }

    // MARK: - Actions

    private func toggle(_ id: String) {
        if selected.contains(id) {
            selected.remove(id)
        } else {
            selected.insert(id)
        }
        confirmation = nil
    }

    private func load() async {
        defer { loaded = true }
        guard let dir = try? WorkspacePaths.dataDir(for: profile) else { return }
        let tracked = trackedColumns()
        let found = await Task.detached(priority: .utility) {
            CollectedEACandidates.load(dataDir: dir, tracked: tracked)
        }.value
        let open = found.filter { !$0.alreadyTracked }
        alreadyTrackedCount = found.count - open.count
        proposals = open.map(\.proposal)
        valueSamples = Dictionary(uniqueKeysWithValues: open.map { ($0.id, $0.sampleValues) })
        rowNotes = Dictionary(uniqueKeysWithValues: open.filter(\.hasNoValues).map {
            ($0.id, L("Defined in Jamf Pro; no values collected yet"))
        })
        selected = Set(open.filter { !$0.hasNoValues && $0.type != "text" }.map(\.id))
    }

    /// One-time import: the operator picks a CSV export; it proposes columns and is not kept.
    private func pickCSV() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.prompt = L("Import")
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in importCSV(url) }
        }
    }

    private func importCSV(_ url: URL) {
        importedCSVName = url.lastPathComponent
        adoptError = nil
        confirmation = nil
        proposals = []
        valueSamples = [:]
        rowNotes = [:]
        selected = []
        agentTargets = []
        typeOverrides = [:]
        let mapped = mappedHeaders()
        Task {
            // The read caps at 256 MB, so it stays off the main actor.
            let result = await Task.detached { Result { try ScaffoldService.readSample(from: url) } }
                .value
            finishImport(result, url: url, mapped: mapped)
        }
    }

    /// Why a CSV could not be read, in words for the banner.
    static func importFailureText(_ error: Error, fileName: String) -> String {
        L("Couldn't read \(fileName) as a CSV export: \(error.localizedDescription)")
    }

    private func finishImport(
        _ result: Result<ScaffoldService.CSVSample, Error>, url: URL, mapped: Set<String>
    ) {
        // A newer pick replaced this one while it was reading.
        guard importedCSVName == url.lastPathComponent else { return }
        let sample: ScaffoldService.CSVSample
        switch result {
        case .success(let read): sample = read
        case .failure(let error):
            adoptError = Self.importFailureText(error, fileName: url.lastPathComponent)
            return
        }
        let detected = ScaffoldService.proposeEAs(
            headers: sample.headers,
            sampleRows: sample.rows,
            mappedHeaders: mapped
        )
        proposals = detected
        for ea in detected {
            guard let col = sample.headers.firstIndex(of: ea.column) else { continue }
            valueSamples[ea.id] = sample.rows.compactMap { $0.count > col ? $0[col] : nil }
        }
        // Default-select clear EA-looking candidates (non-text guesses).
        selected = Set(detected.filter { $0.type != "text" }.map { $0.id })
    }

    /// Columns `config.yaml` already tracks as custom EAs or security agents.
    private func trackedColumns() -> Set<String> {
        guard let state = try? ConfigService.load(profile: profile).state else { return [] }
        return Set(state.customEAs.map(\.column) + state.securityAgents.map(\.column))
    }

    /// The operator's type pick is what gets adopted — rebuild the proposal
    /// when it differs from the scaffold's guess.
    private func applyingTypeOverride(
        _ ea: ProposedEA
    ) -> ProposedEA {
        guard let override = typeOverrides[ea.id], override.rawValue != ea.type else { return ea }
        return ProposedEA(
            name: ea.name, column: ea.column,
            type: override.rawValue, sampleValue: ea.sampleValue)
    }

    /// What an adoption wrote, then the notes its save left (a block left as typed, a copy).
    static func adoptionMessage(eas: Int, agents: Int, notes: [String], profile: String) -> String {
        var parts: [String] = []
        if eas > 0 { parts.append((eas == 1 ? L("\(eas) Extension Attribute") : L("\(eas) Extension Attributes"))) }
        if agents > 0 { parts.append((agents == 1 ? L("\(agents) Security Agent") : L("\(agents) Security Agents"))) }
        let head: String?
        if !parts.isEmpty {
            head = L("Added \(parts.joined(separator: " and ")) to config.yaml for profile \(profile). They appear in the Config tab now and in reports after the next generate.")
        } else {
            head = notes.isEmpty ? L("Those columns are already in config.yaml.") : nil
        }
        return ([head].compactMap { $0 } + notes).joined(separator: " ")
    }

    private func announce(_ text: String?) {
        if let text { AccessibilityNotification.Announcement(text).post() }
    }

    private func adopt() {
        adoptError = nil
        let eas = selectedProposals.filter { !agentTargets.contains($0.id) }
            .map { applyingTypeOverride($0) }
        let agents = selectedProposals.filter { agentTargets.contains($0.id) }
        do {
            let result = try ConfigEAAdopter.adopt(
                eaProposals: eas, agentProposals: agents,
                connectedValues: connectedValues, profile: profile)
            let notes = result.report.notes
            confirmationHasNotes = !notes.isEmpty
            confirmation = Self.adoptionMessage(
                eas: result.eas, agents: result.agents, notes: notes, profile: profile)
        } catch {
            adoptError = L("Couldn't write the selections to config.yaml: \(error.localizedDescription). Verify the workspace config isn't open elsewhere and is writable, then try again.")
        }
    }

    // MARK: - CSV import

    /// Headers config.yaml already tracks (compliance, agents, custom EAs), so a second visit
    /// does not re-propose them.
    private func mappedHeaders() -> Set<String> {
        guard let loaded = try? ConfigService.load(profile: profile) else { return [] }
        let state = loaded.state
        let columns = [state.failuresCountColumn, state.failuresListColumn]
            + state.securityAgents.map(\.column) + state.customEAs.map(\.column)
        return Set(columns.filter { !$0.isEmpty })
    }
}
