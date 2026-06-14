import SwiftUI

/// Guided walkthrough that explains which Jamf Pro export-only fields to include
/// for Extension Attribute tracking, detects EA-like columns in the newest inbox
/// CSV, and lets the operator one-click-adopt selected EAs into `config.yaml`.
///
/// Adoption is additive (never deletes config) and explicit (the user selects
/// which EAs to adopt — no silent auto-write).
@MainActor
struct CSVEAWalkthroughSheet: View {
    let profile: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorSchemeContrast) private var contrast

    @State private var proposals: [ScaffoldService.ProposedEA] = []
    @State private var selected: Set<String> = []
    /// Proposal ids the operator chose to adopt as a Security Agent rather than a
    /// Custom EA. Default (absent) is Custom EA.
    @State private var agentTargets: Set<String> = []
    /// Per-proposal connected-value override for Security Agent adoption; absent
    /// falls back to the proposal's sample value.
    @State private var connectedValues: [String: String] = [:]
    @State private var sourceName: String?
    @State private var loaded = false
    @State private var adoptError: String?
    @State private var confirmation: String?

    private enum AdoptTarget: Hashable { case customEA, securityAgent }

    private var selectedProposals: [ScaffoldService.ProposedEA] {
        proposals.filter { selected.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerSection
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    guidanceCard
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
                        confirmationBanner(confirmation)
                    }
                }
            }
            footerButtons
        }
        .padding(20)
        .frame(minWidth: 460, idealWidth: 540, minHeight: 420, idealHeight: 600)
        .background(Theme.Colors.winBG)
        .task { await load() }
    }

    // MARK: - Sections

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Kicker(text: "CSV · Extension Attributes", tone: .teal)
            Text("Set up EA tracking")
                .font(Theme.Fonts.serif(22, weight: .bold))
                .foregroundStyle(Theme.Text.primary)
            if let sourceName {
                Mono(text: sourceName)
            }
        }
    }

    private var guidanceCard: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Before you export")
                Text("When exporting from Jamf Pro, add your Extension Attribute "
                    + "columns to the export. Built-in inventory fields alone won't "
                    + "include EA values — pick the EAs you track (compliance state, "
                    + "agent versions, certificate dates) under \"Export-only fields\".")
                    .font(.footnote)
                    .foregroundStyle(Theme.Text.tertiary(contrast))
                    .fixedSize(horizontal: false, vertical: true)
                Text("The candidates below were detected in your newest inbox CSV. "
                    + "Select the ones to track and adopt them into config.yaml — "
                    + "your existing settings are preserved.")
                    .font(.caption)
                    .foregroundStyle(Theme.Text.tertiary(contrast))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var candidatesCard: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionHeader(title: "Proposed Extension Attributes")
                    Spacer()
                    Pill(text: "\(selected.count)/\(proposals.count) selected", tone: .teal)
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

    private func candidateRow(_ ea: ScaffoldService.ProposedEA) -> some View {
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
                        Mono(text: ea.column, size: 10.5)
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
                        Picker("", selection: targetBinding(ea)) {
                            Text("Custom EA").tag(AdoptTarget.customEA)
                            Text("Security Agent").tag(AdoptTarget.securityAgent)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 220)
                        Spacer()
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
                                    value: connectedBinding(ea), placeholder: "e.g. Installed",
                                    mono: true)
                                    .frame(maxWidth: 220)
                                Spacer()
                            }
                            Text("Value in the column that means the agent is "
                                + "installed/connected (case-insensitive substring match).")
                                .font(.caption2)
                                .foregroundStyle(Theme.Text.tertiary(contrast))
                        }
                    }
                }
                .padding(.leading, 24)
            }
        }
        .padding(.vertical, 8)
    }

    /// Custom EA (default) vs Security Agent for a proposal.
    private func targetBinding(_ ea: ScaffoldService.ProposedEA) -> Binding<AdoptTarget> {
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
    private func connectedBinding(_ ea: ScaffoldService.ProposedEA) -> Binding<String> {
        Binding(
            get: { connectedValues[ea.id] ?? ea.sampleValue },
            set: { connectedValues[ea.id] = $0 }
        )
    }

    private var loadingState: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Scanning the newest inbox CSV…")
                .font(.footnote)
                .foregroundStyle(Theme.Text.tertiary(contrast))
        }
        .padding(.vertical, 12)
    }

    private var noCandidatesState: some View {
        Card(padding: 16) {
            EmptyStateView(
                systemImage: "tablecells.badge.ellipsis",
                title: sourceName == nil
                    ? "No CSV in the inbox yet."
                    : "No EA-like columns detected.",
                message: sourceName == nil
                    ? "Drop a Jamf Pro export into the csv-inbox folder, then reopen "
                        + "this guide to detect Extension Attribute columns."
                    : "This export looks like built-in inventory fields only. Re-export "
                        + "with your Extension Attribute columns added under "
                        + "\"Export-only fields\"."
            )
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.Colors.danger)
            Text(message)
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.Colors.danger)
            Spacer()
        }
        .padding(12)
        .background(Theme.Colors.danger.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func confirmationBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.Colors.tealBright)
            Text(message)
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.Text.primary)
            Spacer()
        }
        .padding(12)
        .background(Theme.Colors.teal.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var footerButtons: some View {
        HStack {
            PNPButton(title: "Close", style: .ghost) { dismiss() }
            Spacer()
            PNPButton(
                title: "Add \(selected.count) to config",
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
        guard let url = newestInboxCSV() else { return }
        sourceName = url.lastPathComponent
        guard let sample = try? ScaffoldService.readSample(from: url) else { return }
        let mapped = mappedHeaders(for: sample.headers)
        let detected = ScaffoldService.proposeEAs(
            headers: sample.headers,
            sampleRows: sample.rows,
            mappedHeaders: mapped
        )
        proposals = detected
        // Default-select clear EA-looking candidates (non-text guesses).
        selected = Set(detected.filter { $0.type != "text" }.map { $0.id })
    }

    private func adopt() {
        adoptError = nil
        let eas = selectedProposals.filter { !agentTargets.contains($0.id) }
        let agents = selectedProposals.filter { agentTargets.contains($0.id) }
        do {
            let result = try ConfigEAAdopter.adopt(
                eaProposals: eas, agentProposals: agents,
                connectedValues: connectedValues, profile: profile)
            if result.eas == 0 && result.agents == 0 {
                confirmation = "Those columns are already in config.yaml."
            } else {
                var parts: [String] = []
                if result.eas > 0 {
                    parts.append("\(result.eas) Extension Attribute\(result.eas == 1 ? "" : "s")")
                }
                if result.agents > 0 {
                    parts.append("\(result.agents) Security Agent\(result.agents == 1 ? "" : "s")")
                }
                confirmation = "Added \(parts.joined(separator: " and ")) to config.yaml for "
                    + "profile \(profile). They appear in the Config tab now and in reports "
                    + "after the next generate."
            }
            // Brief confirmation, then dismiss.
            Task {
                try? await Task.sleep(for: .milliseconds(900))
                dismiss()
            }
        } catch {
            adoptError = "Couldn't write the selections to config.yaml: "
                + "\(error.localizedDescription). Verify the workspace config isn't open "
                + "elsewhere and is writable, then try again."
        }
    }

    // MARK: - Inbox lookup

    /// Resolve the newest non-archived inbox CSV's URL through the same workspace
    /// path guard `CSVInboxService` uses. Returns `nil` when none exists.
    private func newestInboxCSV() -> URL? {
        let files = CSVInboxService().list(profile: profile)
            .filter { $0.status != .archived }
        guard let newest = files.first,
              let root = WorkspacePathGuard.root(for: profile) else {
            return nil
        }
        let inbox = root.appendingPathComponent("csv-inbox", isDirectory: true)
        guard let validatedInbox = WorkspacePathGuard.validate(inbox, under: root) else {
            return nil
        }
        let candidate = validatedInbox.appendingPathComponent(
            newest.name,
            isDirectory: false
        )
        return WorkspacePathGuard.validate(candidate, under: root)
    }

    /// Headers already mapped to logical columns/compliance fields, so they are
    /// excluded from EA proposals.
    private func mappedHeaders(for headers: [String]) -> Set<String> {
        guard let loaded = try? ConfigService.load(profile: profile) else {
            // No config yet — use scaffold's best-guess mapping to avoid proposing
            // obvious column mappings as EAs.
            let mapping = (try? scaffoldResult(headers: headers)) ?? [:]
            return Set(mapping.values)
        }
        var mapped = Set(loaded.state.columns.values.filter { !$0.isEmpty })
        if !loaded.state.failuresCountColumn.isEmpty {
            mapped.insert(loaded.state.failuresCountColumn)
        }
        if !loaded.state.failuresListColumn.isEmpty {
            mapped.insert(loaded.state.failuresListColumn)
        }
        for agent in loaded.state.securityAgents where !agent.column.isEmpty {
            mapped.insert(agent.column)
        }
        // Exclude columns already adopted as custom EAs so a second visit doesn't
        // re-propose them.
        for ea in loaded.state.customEAs where !ea.column.isEmpty {
            mapped.insert(ea.column)
        }
        return mapped
    }

    /// Best-guess header → logical mapping (computer + compliance), used only when
    /// no config.yaml exists yet.
    private func scaffoldResult(headers: [String]) throws -> [String: String] {
        var mapping: [String: String] = [:]
        for logical in ConfigState.columnKeys {
            if let match = ScaffoldService.bestColumnMatch(
                headers: headers, logical: logical, family: nil
            ) {
                mapping[logical] = match.header
            }
        }
        return mapping
    }
}
