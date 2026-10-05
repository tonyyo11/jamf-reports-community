import SwiftUI

/// What the Scoring tab shows beside each factor: the agents and baselines the workspace
/// configures, and what every factor the tab can list measured in the newest snapshots, so a
/// factor shows its share as soon as it is added.
struct ScoreFactorsSnapshot: Sendable, Equatable {
    var agents: [String] = []
    var baselines: [String] = []
    var staleDays = 30
    var measures: [String: SecurityScoreMeasure] = [:]

    /// Off the main actor: it reads config.yaml and the snapshots.
    static func load(profile: String) -> ScoreFactorsSnapshot {
        guard let workspace = ProfileService.workspaceURL(for: profile),
              let config = try? ConfigLoader.load(
                  from: workspace.appendingPathComponent("config.yaml")),
              let dataDir = try? WorkspacePaths.dataDir(for: profile)
        else { return ScoreFactorsSnapshot() }
        var snapshot = ScoreFactorsSnapshot()
        snapshot.agents = SecurityScoreInputs.namedAgents(in: config).map(\.name)
        snapshot.baselines = (config.compliance?.resolvedBaselines ?? []).map(\.name)
        snapshot.staleDays = config.thresholds?.resolvedStaleDays ?? 30
        var candidates: [SecurityScoreFactor] = config.resolvedSecurityPolicy.scoreFactors ?? []
        candidates += SecurityScoreFactor.nativeDefaults
        candidates += snapshot.agents.map { SecurityScoreFactor(.agent, weight: 1, target: $0) }
        candidates.append(SecurityScoreFactor(.mscp, weight: 1))
        candidates += snapshot.baselines.map {
            SecurityScoreFactor(.mscp, weight: 1, target: $0)
        }
        let posture = SecurityPostureService.load(profile: profile)
        snapshot.measures = SecurityScoreInputs.measures(
            for: candidates, fleet: posture.totalDevices > 0 ? posture.fleetCounts : nil,
            sources: SecurityScoreInputs.load(dataDir: dataDir, factors: candidates),
            config: config)
        return snapshot
    }
}

/// Config › Scoring: the factors the Security Score counts, each with its weight, today's share
/// and its part of the score, saved to `security_policy.score_factors` through
/// `WorkspaceStore.saveScoreFactors`, so the summary, the workbook and the Security Posture
/// screen score the same list. A workspace with no list shows the defaults; the first edit
/// writes the whole list.
struct ScoreFactorsCard: View {
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var snapshot = ScoreFactorsSnapshot()
    @State private var saveFailure: String?
    /// What a save did not keep (a backup was made), shown while its profile is live.
    @State private var saveNote: ProfileSaveNote?

    private var agentNames: [String] {
        workspace.configState.securityAgents.map(\.name)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private var listed: [SecurityScoreFactor] {
        workspace.securityPolicy.scoreFactors ?? SecurityScoreFactor.defaults(
            agents: agentNames, hasBaseline: !snapshot.baselines.isEmpty)
    }

    var body: some View {
        let factors = listed
        return Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                ScoreFactorsHeader(
                    count: factors.count, isDefault: workspace.securityPolicy.scoreFactors == nil,
                    demo: workspace.demoMode, onDefaults: { save(nil) })
                Text(Self.intro)
                    .font(.caption)
                    .foregroundStyle(Theme.Text.tertiary(contrast))
                    .fixedSize(horizontal: false, vertical: true)
                statusLines
                rows(factors)
                ScoreFactorAddMenu(
                    options: addOptions(factors), onAdd: { save(factors + [$0]) })
                EDRAgentPickerRow(names: agentNames, onFailure: { saveFailure = $0 },
                                  onSaved: noting)
            }
            .disabled(workspace.demoMode)
            .help(workspace.demoMode ? DemoData.liveOnlyHelp : "")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Security score factors")
        .task(id: reloadKey(factors)) { await reload() }
    }

    private func rows(_ factors: [SecurityScoreFactor]) -> some View {
        let scoring = Self.scoringWeight(
            factors, snapshot: snapshot, policy: workspace.securityPolicy)
        return VStack(spacing: 6) {
            ForEach(factors, id: \.key) { factor in
                ScoreFactorRow(
                    label: factor.label(staleDays: snapshot.staleDays),
                    status: Self.status(of: factor, snapshot: snapshot,
                                        policy: workspace.securityPolicy),
                    part: Self.part(factor, of: scoring),
                    weight: Binding(
                        get: { Int(factor.weight) },
                        set: { save(Self.replacing(factor, weight: $0, in: factors)) }),
                    onRemove: { save(factors.filter { $0.key != factor.key }) })
            }
        }
    }

    @ViewBuilder
    private var statusLines: some View {
        if let saveFailure {
            Text(saveFailure)
                .font(.caption)
                .foregroundStyle(Theme.Colors.danger)
        }
        if let line = saveNote?.line(for: workspace.profile) {
            Text(line)
                .font(.caption)
                .foregroundStyle(Theme.Colors.warn)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Actions

    /// Nil removes the list, so the workspace scores the defaults again.
    private func save(_ factors: [SecurityScoreFactor]?) {
        guard !workspace.demoMode else { return }
        do {
            noting(try workspace.saveScoreFactors(factors))
        } catch {
            saveFailure = "Couldn't save the score factors: \(error.localizedDescription)"
        }
    }

    /// A successful save clears the failure and keeps what it did not keep as the note.
    private func noting(_ report: ConfigSaveReport) {
        saveFailure = nil
        if let saved = report.note(for: workspace.profile) { saveNote = saved }
    }

    private func reload() async {
        guard !workspace.demoMode else { return }
        let profile = workspace.profile
        let loaded = await Task.detached(priority: .utility) {
            ScoreFactorsSnapshot.load(profile: profile)
        }.value
        guard profile == workspace.profile else { return }
        snapshot = loaded
    }

    /// Shares do not depend on weights, so only a changed list or profile reloads them.
    private func reloadKey(_ factors: [SecurityScoreFactor]) -> String {
        ([workspace.profile] + factors.map(\.key)).joined(separator: "\u{1F}")
    }

    // MARK: Pure helpers

    static let intro = "The Security Score is the weighted share of Macs that pass each factor, "
        + "on Security Posture, the Overview, Trends, alerts and reports. Weights need not add "
        + "up to 100: a factor with no data drops out and the rest are rescaled. The list is "
        + "saved to this workspace's config.yaml (security_policy.score_factors)."

    /// The factors that score today: counted, with data and a weight above 0.
    static func scoringWeight(
        _ factors: [SecurityScoreFactor], snapshot: ScoreFactorsSnapshot,
        policy: SecurityControlPolicy
    ) -> [String: Double] {
        let counted = Set(policy.resolvedScoreFactors(
            agents: snapshot.agents, baselines: snapshot.baselines).map(\.key))
        var weights: [String: Double] = [:]
        for factor in factors where counted.contains(factor.key) && factor.weight > 0
            && snapshot.measures[factor.key]?.share != nil {
            weights[factor.key] = factor.weight
        }
        return weights
    }

    /// The factor's part of the score in percent; nil when it does not score today.
    static func part(_ factor: SecurityScoreFactor, of scoring: [String: Double]) -> Double? {
        let total = scoring.values.reduce(0, +)
        guard total > 0, let weight = scoring[factor.key] else { return nil }
        return weight / total * 100
    }

    /// Today's share, or why the factor does not score.
    static func status(
        of factor: SecurityScoreFactor, snapshot: ScoreFactorsSnapshot,
        policy: SecurityControlPolicy
    ) -> String {
        if let control = factor.kind.control, policy.level(for: control) == .ignore {
            return "Not counted: \(control.displayName) is set to Ignore above"
        }
        switch factor.kind {
        case .agent where SecurityControlPolicy.configuredName(
            factor.target, in: snapshot.agents) == nil:
            return "Not counted: no security agent has this name"
        case .mscp where snapshot.baselines.isEmpty:
            return "Not counted: no mSCP baseline is configured"
        case .mscp where factor.target != nil && SecurityControlPolicy.configuredName(
            factor.target, in: snapshot.baselines) == nil:
            return "Not counted: no mSCP baseline has this name"
        default:
            break
        }
        guard let share = snapshot.measures[factor.key]?.share else { return "No data yet" }
        return String(format: "%.1f%% of Macs pass", share)
    }

    static func replacing(
        _ factor: SecurityScoreFactor, weight: Int, in factors: [SecurityScoreFactor]
    ) -> [SecurityScoreFactor] {
        factors.map { listed in
            guard listed.key == factor.key else { return listed }
            var changed = listed
            changed.weight = Double(min(max(weight, 0), 100))
            return changed
        }
    }

    /// Factors the list does not hold yet, in the tab's order: the native ones, the first
    /// baseline (when one is configured and no mSCP factor is listed), each named baseline and
    /// each agent.
    func addOptions(_ factors: [SecurityScoreFactor]) -> [SecurityScoreFactor] {
        Self.addOptions(factors, agents: agentNames, baselines: snapshot.baselines)
    }

    static func addOptions(
        _ factors: [SecurityScoreFactor], agents: [String], baselines: [String]
    ) -> [SecurityScoreFactor] {
        let listed = Set(factors.map(\.key))
        var options = SecurityScoreFactor.nativeDefaults.filter { !listed.contains($0.key) }
        let anyMSCP = factors.contains { $0.kind == .mscp }
        if !baselines.isEmpty, !anyMSCP {
            options.append(.init(.mscp, weight: SecurityScoreFactor.defaultMSCPWeight))
        }
        if baselines.count > 1 {
            let weight = SecurityScoreFactor.defaultMSCPWeight
            options += baselines.map { SecurityScoreFactor(.mscp, weight: weight, target: $0) }
                .filter { !listed.contains($0.key) }
        }
        options += agents.map {
            SecurityScoreFactor(.agent, weight: SecurityScoreFactor.defaultAgentWeight, target: $0)
        }.filter { $0.target != nil && !listed.contains($0.key) }
        return options
    }
}

private struct ScoreFactorsHeader: View {
    let count: Int
    let isDefault: Bool
    let demo: Bool
    let onDefaults: () -> Void

    var body: some View {
        HStack {
            SectionHeader(title: "Security Score Factors")
            Spacer()
            Pill(text: isDefault ? "Defaults" : "\(count) factors", tone: .teal,
                 icon: isDefault ? "checkmark" : "slider.horizontal.3")
            PNPButton(title: "Use defaults", size: .sm, action: onDefaults)
                .disabled(demo || isDefault)
                .help(demo ? DemoData.liveOnlyHelp
                      : "Remove the list from config.yaml and score the default factors.")
        }
    }
}

private struct ScoreFactorRow: View {
    let label: String
    let status: String
    let part: Double?
    @Binding var weight: Int
    let onRemove: () -> Void

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.footnote)
                    .foregroundStyle(Theme.Colors.fg)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(Theme.Text.tertiary(contrast))
            }
            Spacer(minLength: 8)
            Text(part.map { String(format: "%.0f%% of score", $0) } ?? "—")
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.Text.secondary)
                .frame(minWidth: 84, alignment: .trailing)
            EditableNumberStepper(value: $weight, range: 0...100, suffix: "pts")
                .accessibilityLabel("\(label) weight")
            Button(action: onRemove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove \(label) from the score")
            .accessibilityLabel("Remove \(label)")
        }
    }
}

private struct ScoreFactorAddMenu: View {
    let options: [SecurityScoreFactor]
    let onAdd: (SecurityScoreFactor) -> Void

    var body: some View {
        Menu {
            ForEach(options, id: \.key) { option in
                Button(option.label()) { onAdd(option) }
            }
        } label: {
            Label("Add factor", systemImage: "plus.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(options.isEmpty)
        .help(options.isEmpty ? "Every factor is already listed." : "Add a factor to the score.")
    }
}

/// Which `security_agents` entry the Overview's EDR card, its trend and `crowdstrikePct`
/// describe. Offered with two or more agents; the score counts agents through the factors.
private struct EDRAgentPickerRow: View {
    let names: [String]
    let onFailure: (String) -> Void
    let onSaved: (ConfigSaveReport) -> Void

    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        if names.count > 1 {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Agent the EDR card shows")
                        .font(.footnote)
                        .foregroundStyle(Theme.Colors.fg)
                    Text("The Overview's EDR card and trend. The score counts agents above.")
                        .font(.caption)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                }
                Spacer()
                Picker("Agent the EDR card shows", selection: binding) {
                    ForEach(names, id: \.self) { Text($0).tag(Optional($0)) }
                }
                .labelsHidden()
                .frame(width: 260)
            }
            .padding(.top, 6)
        }
    }

    /// The picker shows the agent the card follows, so the default reads as the first agent's
    /// name and choosing it writes that name.
    private var binding: Binding<String?> {
        Binding(
            get: { workspace.edrAgentName },
            set: { name in
                do {
                    onSaved(try workspace.saveEDRAgent(name))
                } catch {
                    onFailure("Couldn't save the EDR agent: \(error.localizedDescription)")
                }
            })
    }
}
