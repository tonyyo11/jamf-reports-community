import SwiftUI

/// What the "Deployments and patch policies" Audit card shows: each source's state and the
/// levels it was judged at, read off the main actor.
struct DeploymentHealthCard: Equatable, Sendable {
    var states: [DeploymentHealth.Source: DeploymentHealth.SourceState]
    var levels: DeploymentHealth.Levels
    /// True when config.yaml did not load, so the defaults stand in for the configured levels.
    var levelsAreDefaults = false

    /// Nothing attempted for either source: the card draws nothing.
    var isEmpty: Bool { states.values.allSatisfy { $0 == .notCollected } }

    static func load(profile: String, now: Date = Date()) -> DeploymentHealthCard? {
        guard let dataDir = try? WorkspacePaths.dataDir(for: profile) else { return nil }
        let config = ProfileService.workspaceURL(for: profile).flatMap {
            try? ConfigLoader.load(from: $0.appendingPathComponent("config.yaml"))
        }
        return DeploymentHealthCard(
            states: DeploymentHealth.load(
                dataDir: dataDir, now: now,
                maxAgeHours: config?.jamfCli?.resolvedMaxCacheAgeHours),
            levels: config?.thresholds?.resolvedDeploymentLevels ?? .defaults,
            levelsAreDefaults: config == nil)
    }
}

/// The "Deployments and patch policies" card on the Audit screen. Copy is a DRAFT for the visual
/// pass.
struct DeploymentHealthSection: View {
    let card: DeploymentHealthCard?

    /// Rows at a level shown per source before "N of M shown".
    static let shownRows = 10

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.percentFormat) private var percentFormat

    var body: some View {
        if let card, !card.isEmpty {
            Card(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader(title: L("Deployments and patch policies")).padding(16)
                    Divider().background(Theme.Colors.hairline)
                    ForEach(DeploymentHealth.Source.allCases, id: \.self) { source in
                        sourceView(source, card.states[source] ?? .notCollected, card: card)
                    }
                    Text(Self.levelsLine(card))
                        .font(.footnote)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                        .padding(.horizontal, 16).padding(.vertical, 8)
                }
            }
        }
    }

    @ViewBuilder
    private func sourceView(
        _ source: DeploymentHealth.Source, _ state: DeploymentHealth.SourceState,
        card: DeploymentHealthCard
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(source.displayName).font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.Colors.fg)
            if let text = DeploymentHealth.stateText(state) {
                line(text)
            } else {
                let atLevel = DeploymentHealth.atLevel(state.rows, levels: card.levels)
                ForEach(Array(atLevel.prefix(Self.shownRows).enumerated()), id: \.offset) { _, entry in
                    HStack(spacing: 10) {
                        Pill(text: entry.judgement == .critical ? L("CRITICAL") : L("WARNING"),
                             tone: entry.judgement == .critical ? .danger : .warn)
                            .frame(width: 86, alignment: .leading)
                        Text(Self.rowText(entry.row, failed: entry.failed,
                                          inScope: entry.inScope, levels: card.levels,
                                          percentFormat: percentFormat))
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(Theme.Colors.fg2)
                            .textSelection(.enabled)
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                }
                if atLevel.count > Self.shownRows {
                    line(L("\(Self.shownRows) of \(atLevel.count) shown"))
                }
                ForEach(Self.summaryLines(state, levels: card.levels), id: \.self) { line($0) }
            }
            if source == .patchPolicy {
                line(L("Devices failing per patch title are on the Patch screen."))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private func line(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundStyle(Theme.Colors.fg2)
    }

    /// "name: 48 of 400 Macs failed (12%)".
    static func rowText(
        _ row: DeploymentHealth.Row, failed: Int, inScope: Int, levels: DeploymentHealth.Levels,
        percentFormat: PercentFormat
    ) -> String {
        let share = DeploymentHealth.shareText(row, levels: levels, format: percentFormat)
        return L("\(row.displayName): \(failed) of \(inScope) Macs failed (\(share))")
    }

    /// The judged line, the not-judged line, the "as of" and left-out notes; parts that are 0
    /// are left out.
    static func summaryLines(
        _ state: DeploymentHealth.SourceState, levels: DeploymentHealth.Levels
    ) -> [String] {
        guard case .rows(let rows, let asOf, let leftOut) = state else { return [] }
        var lines: [String] = []
        if let asOf {
            lines.append(L("As of \(asOf.formatted(date: .abbreviated, time: .omitted)), no longer current"))
        }
        let figures = DeploymentHealth.figures(rows, levels: levels)
        let below = figures.judged - figures.atWarning - figures.atCritical
        if below > 0 { lines.append(L("\(below) judged, below the levels")) }
        let counts = DeploymentHealth.notJudgedCounts(rows, levels: levels)
        let parts: [String] = [
            counts[.notJudged].map { L("\($0) not enabled") },
            counts[.nothingInScope].map { L("\($0) nothing in scope") },
            counts[.belowMinimumScope].map { L("\($0) under \(DeploymentHealth.minimumInScope) Macs") },
            counts[.unmeasured].map { L("\($0) unmeasured") },
        ].compactMap { $0 }
        if !parts.isEmpty {
            lines.append(L("Not judged: \(parts.joined(separator: ", "))"))
        }
        if leftOut == 1 {
            lines.append(L("1 row with no ID left out"))
        } else if leftOut > 1 {
            lines.append(L("\(leftOut) rows with no ID left out"))
        }
        return lines
    }

    static func levelsLine(_ card: DeploymentHealthCard) -> String {
        let text = L("Levels: warning \(card.levels.warning)%, critical \(card.levels.critical)% of a deployment's or policy's Macs")
        return card.levelsAreDefaults ? L("\(text) (defaults; config.yaml could not be read)") : text
    }
}

#if DEBUG
#Preview("Deployments and patch policies") {
    DeploymentHealthSection(card: DemoData.deploymentHealth)
        .frame(width: PageScaffold<EmptyView>.minSupportedWidth)
        .padding()
        .preferredColorScheme(.dark)
}
#endif
