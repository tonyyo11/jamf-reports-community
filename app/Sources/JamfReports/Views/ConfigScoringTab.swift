import SwiftUI

// MARK: - Security policy card

/// What counts as a security gap in this workspace: the level of FileVault, SIP, Firewall and
/// Gatekeeper, and of FileVault off on a hardware-encrypted Mac. Every change is written to
/// config.yaml at once, one key at a time, through `WorkspaceStore.saveSecurityLevel` and
/// `saveHardwareLevel`; the pickers read the store's policy, so a failed save leaves them on
/// what is saved. A value or key a hand-typed block carries that the app did not use as
/// written is shown against its row.
struct SecurityPolicyCard: View {
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var saveFailure: SaveFailure?

    /// Each failure is its own value, so a second identical failure still redraws the pickers
    /// back onto the saved policy.
    struct SaveFailure: Equatable {
        let id = UUID()
        let message: String
    }

    var body: some View {
        let issues = workspace.securityPolicyIssues
        let fileVaultIgnored = workspace.securityPolicy.fileVault == .ignore
        return Card(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "Security Policy")
                Text("Decides what counts as a security gap on every screen, report and "
                     + "scheduled run for this workspace. Saved to config.yaml.")
                    .font(.caption)
                    .foregroundStyle(Theme.Text.tertiary(contrast))
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(SecurityControl.allCases, id: \.self) { control in
                        controlRow(control, issue: Self.levelIssue(for: control, in: issues))
                    }
                    hardwareRow(
                        issue: Self.hardwareLevelIssue(in: issues),
                        fileVaultIgnored: fileVaultIgnored)
                    issueNotes(issues)
                }
                .disabled(workspace.demoMode)
                .help(workspace.demoMode ? DemoData.liveOnlyHelp : "")
                if let saveFailure {
                    Text(saveFailure.message)
                        .font(.caption)
                        .foregroundStyle(Theme.Colors.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Security policy configuration")
    }

    private func controlRow(_ control: SecurityControl, issue: SecurityPolicyIssue?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text(control.displayName)
                    .font(.footnote)
                    .foregroundStyle(Theme.Colors.fg)
                Spacer(minLength: 12)
                Picker(control.displayName, selection: Self.levelBinding(
                    control, in: workspace, failure: $saveFailure)
                ) {
                    ForEach(SecurityControlLevel.allCases, id: \.self) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
                .accessibilityLabel("\(control.displayName) level")
            }
            if let issue {
                writeNote(issue, level: workspace.securityPolicy.level(for: control)) {
                    Self.writeAppliedLevel(control, in: workspace, failure: $saveFailure)
                }
            }
        }
    }

    /// Stacked, not beside its label: four segments and the long label do not share a row at
    /// `PageScaffold.minSupportedWidth`.
    private func hardwareRow(issue: SecurityPolicyIssue?, fileVaultIgnored: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("FileVault off on a hardware-encrypted Mac")
                .font(.footnote)
                .foregroundStyle(Theme.Colors.fg)
            Picker("FileVault off on a hardware-encrypted Mac", selection: Self.hardwareBinding(
                in: workspace, failure: $saveFailure)
            ) {
                Text("Same as FileVault").tag(SecurityControlLevel?.none)
                ForEach(SecurityControlLevel.allCases, id: \.self) { level in
                    Text(level.displayName).tag(SecurityControlLevel?.some(level))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 420)
            .disabled(fileVaultIgnored)
            .accessibilityLabel("FileVault off on a hardware-encrypted Mac level")
            Text("Apple silicon Macs and Intel Macs with the T2 chip always encrypt the "
                 + "internal disk; with FileVault off it unlocks without a password.")
                .font(.caption)
                .foregroundStyle(Theme.Text.tertiary(contrast))
                .fixedSize(horizontal: false, vertical: true)
            if let issue {
                writeNote(issue, level: workspace.securityPolicy.fileVaultOffHardwareEncrypted) {
                    Self.writeAppliedHardwareLevel(in: workspace, failure: $saveFailure)
                }
            }
        }
    }

    @ViewBuilder
    private func issueNotes(_ issues: [SecurityPolicyIssue]) -> some View {
        ForEach(Self.shapeIssues(in: issues), id: \.keyPath) { issue in
            warnNote(Self.shapeCaption(issue))
        }
        ForEach(Self.weightIssues(in: issues), id: \.keyPath) { issue in
            warnNote(Self.weightCaption(issue))
        }
        if let unknown = Self.unknownKeysCaption(issues) { warnNote(unknown) }
    }

    /// The note for a typed level the app did not accept, with a button that writes the level
    /// it applied. Choosing the shown level in the picker fires nothing, so without the
    /// button a typo that reads as that level could not be cleared from here.
    private func writeNote(
        _ issue: SecurityPolicyIssue, level: SecurityControlLevel?,
        write: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            warnNote(Self.levelCaption(issue))
            Spacer(minLength: 8)
            PNPButton(title: Self.writeTitle(for: level), size: .sm, action: write)
        }
    }

    private func warnNote(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Theme.Colors.warn)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Saving

    /// The binding a control's picker uses: it reads the store's policy and a change writes
    /// that one key.
    static func levelBinding(
        _ control: SecurityControl, in workspace: WorkspaceStore,
        failure: Binding<SaveFailure?>
    ) -> Binding<SecurityControlLevel> {
        Binding(
            get: { workspace.securityPolicy.level(for: control) },
            set: { level in
                persist(failure) { try workspace.saveSecurityLevel(level, for: control) }
            })
    }

    static func hardwareBinding(
        in workspace: WorkspaceStore, failure: Binding<SaveFailure?>
    ) -> Binding<SecurityControlLevel?> {
        Binding(
            get: { workspace.securityPolicy.fileVaultOffHardwareEncrypted },
            set: { level in persist(failure) { try workspace.saveHardwareLevel(level) } })
    }

    /// The "Write fail" button: writes the level the app applied for this control over what
    /// the file holds, so the typed value that did not read as a level goes.
    static func writeAppliedLevel(
        _ control: SecurityControl, in workspace: WorkspaceStore,
        failure: Binding<SaveFailure?>
    ) {
        let level = workspace.securityPolicy.level(for: control)
        persist(failure) { try workspace.saveSecurityLevel(level, for: control) }
    }

    /// Applied nil (FileVault's own level) removes the entry.
    static func writeAppliedHardwareLevel(
        in workspace: WorkspaceStore, failure: Binding<SaveFailure?>
    ) {
        let level = workspace.securityPolicy.fileVaultOffHardwareEncrypted
        persist(failure) { try workspace.saveHardwareLevel(level) }
    }

    static func writeTitle(for level: SecurityControlLevel?) -> String {
        level.map { "Write \($0.rawValue)" } ?? "Remove the entry"
    }

    /// A successful write clears the failure, a failed one becomes the card's message.
    static func persist(_ failure: Binding<SaveFailure?>, _ write: () throws -> Void) {
        do {
            try write()
            failure.wrappedValue = nil
        } catch {
            failure.wrappedValue = SaveFailure(
                message: "Couldn't save the security policy: \(error.localizedDescription)")
        }
    }

    // MARK: Wording

    private static func level(
        _ keyPath: String, in issues: [SecurityPolicyIssue]
    ) -> SecurityPolicyIssue? {
        issues.first { $0.keyPath == keyPath && !$0.used.isEmpty }
    }

    static func levelIssue(
        for control: SecurityControl, in issues: [SecurityPolicyIssue]
    ) -> SecurityPolicyIssue? {
        level("\(SecurityPolicyConfigLoader.controlsPath).\(control.rawValue)", in: issues)
    }

    static func hardwareLevelIssue(in issues: [SecurityPolicyIssue]) -> SecurityPolicyIssue? {
        level(SecurityPolicyConfigLoader.hardwarePath, in: issues)
    }

    /// The block, `controls` or `score_weights` holding something other than settings.
    static func shapeIssues(in issues: [SecurityPolicyIssue]) -> [SecurityPolicyIssue] {
        issues.filter { SecurityPolicyConfigLoader.blockKeyPaths.contains($0.keyPath) }
    }

    /// A `score_weights` value the app did not read as a weight. The weights card has its own
    /// steppers, so these are noted here with the other hand-typed values.
    static func weightIssues(in issues: [SecurityPolicyIssue]) -> [SecurityPolicyIssue] {
        issues.filter { SecurityPolicyConfigLoader.isWeightPath($0.keyPath) && !$0.used.isEmpty }
    }

    static func levelCaption(_ issue: SecurityPolicyIssue) -> String {
        "config.yaml says \"\(shown(issue.value))\", which is not fail, warning or ignore — "
            + "using \(shown(issue.used))."
    }

    /// Names the key as `score_weights.<key>`: the whole key path of the longest key is past
    /// what `shown` allows.
    static func weightCaption(_ issue: SecurityPolicyIssue) -> String {
        let key = issue.keyPath.split(separator: ".").last.map(String.init) ?? issue.keyPath
        return "config.yaml's score_weights.\(shown(key)) is \"\(shown(issue.value))\", which "
            + "is not a number from 0 to 100 — using \(shown(issue.used))."
    }

    static func shapeCaption(_ issue: SecurityPolicyIssue) -> String {
        "config.yaml's \(shownPath(issue.keyPath)) is \"\(shown(issue.value))\", which is not "
            + "a set of settings — using \(shown(issue.used))."
    }

    /// Nil when every key in the block is one the app reads.
    static func unknownKeysCaption(_ issues: [SecurityPolicyIssue]) -> String? {
        let paths = issues.filter { $0.used.isEmpty }.map { shownPath($0.keyPath) }
        guard !paths.isEmpty else { return nil }
        let noun = paths.count == 1 ? "setting" : "settings"
        return "config.yaml has \(paths.count) security_policy \(noun) the app does not read: "
            + paths.joined(separator: ", ") + "."
    }

    /// Text taken from the user's file: control characters removed, length capped.
    private static func shown(_ raw: String) -> String {
        SecurityPolicyConfigLoader.displayText(raw)
    }

    /// A key path in an issue: the loader capped the typed key it ends in, so only control
    /// characters are removed again, or a long key such as `controls.screen_saver_lock` is cut.
    private static func shownPath(_ raw: String) -> String {
        SecurityPolicyConfigLoader.stripped(raw)
    }
}

// MARK: - Scoring tab

/// Lets the user set the weighted Security Score formula lifted from v3.5. The weights are
/// saved to the workspace's `security_policy.score_weights` through
/// `WorkspaceStore.saveScoreWeights`, so the summary, the workbook and the Security Posture
/// screen score with the same set. A workspace with none saved shows this Mac's earlier
/// preference (`ScoringConfig.storageKey`), which is only read. Tenants without certain agent
/// stacks (e.g. no CrowdStrike) can zero out the matching weight to drop that metric from the
/// score entirely.
///
/// The weights card is built in small functions: Swift 6.1 could not type-check it as one
/// expression in reasonable time.
struct ScoringTab: View {
    @AppStorage(ScoringConfig.storageKey) private var legacyRaw: String = ""
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(WorkspaceStore.self) private var workspace
    @State private var saveFailure: String?

    /// Demo mode shows the defaults the demo's own score uses, not this Mac's preference.
    private var displayed: (weights: SecurityScoreWeights, fromLegacyPreference: Bool) {
        ScoringConfig.displayedWeights(
            config: workspace.securityPolicy.scoreWeights,
            legacyRaw: workspace.demoMode ? "" : legacyRaw)
    }

    /// Saves the whole set with one weight changed.
    private func update(_ mutate: (inout SecurityScoreWeights) -> Void) {
        guard !workspace.demoMode else { return }
        var weights = displayed.weights
        mutate(&weights)
        save(weights)
    }

    /// Nil removes the block, so the workspace scores with the defaults again.
    private func save(_ weights: SecurityScoreWeights?) {
        guard !workspace.demoMode else { return }
        do {
            try workspace.saveScoreWeights(weights)
            saveFailure = nil
        } catch {
            saveFailure = "Couldn't save the score weights: \(error.localizedDescription)"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SecurityPolicyCard()
            // Read once per body evaluation: the 8 weight rows and the total share it.
            weightsCard(displayed)
        }
    }

    private func weightsCard(
        _ shown: (weights: SecurityScoreWeights, fromLegacyPreference: Bool)
    ) -> some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                weightsHeader(totalWeight: Self.totalWeight(shown.weights))
                Text(Self.intro(fromLegacyPreference: shown.fromLegacyPreference))
                    .font(.caption)
                    .foregroundStyle(Theme.Text.tertiary(contrast))
                if let saveFailure {
                    Text(saveFailure)
                        .font(.caption)
                        .foregroundStyle(Theme.Colors.danger)
                }
                weightRows(shown.weights)
                    .disabled(workspace.demoMode)
                    .help(workspace.demoMode ? DemoData.liveOnlyHelp : "")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Security score weight configuration")
    }

    private func weightsHeader(totalWeight: Double) -> some View {
        HStack {
            SectionHeader(title: "Security Score Weights")
            Spacer()
            Pill(
                text: "Sum: \(Int(totalWeight))",
                tone: totalWeight == 100 ? .teal : .gold,
                icon: totalWeight == 100 ? "checkmark" : "scalemass"
            )
            PNPButton(title: "Reset to v3.5 defaults", size: .sm) {
                save(ScoringConfig.resetWeights(legacyRaw: legacyRaw))
            }
            .disabled(workspace.demoMode)
            .help(workspace.demoMode ? DemoData.liveOnlyHelp : Self.resetHelp)
        }
    }

    private func weightRows(_ weights: SecurityScoreWeights) -> some View {
        VStack(spacing: 6) {
            weightRow("FileVault Encryption", value: binding(\.fileVault, weights))
            weightRow("System Integrity Protection", value: binding(\.sip, weights))
            weightRow("Firewall Enabled", value: binding(\.firewall, weights))
            weightRow(edrLabel, value: binding(\.edrAgent, weights))
            weightRow("mSCP Compliance", value: binding(\.mscp, weights))
            weightRow("XProtect Current", value: binding(\.xprotect, weights))
            weightRow("CVE Clean", value: binding(\.cve, weights))
            weightRow("Secure Boot (Full)", value: binding(\.secureBoot, weights))
        }
    }

    private var edrLabel: String {
        "\(workspace.edrAgentName ?? "EDR Agent") Connected"
    }

    /// Reads the weight from the set this body evaluation shows; a change saves that set with
    /// the one weight replaced.
    private func binding(
        _ keyPath: WritableKeyPath<SecurityScoreWeights, Double>,
        _ weights: SecurityScoreWeights
    ) -> Binding<Int> {
        Binding(
            get: { Int(weights[keyPath: keyPath]) },
            set: { value in update { $0[keyPath: keyPath] = Double(value) } })
    }

    private static let resetHelp =
        "Restore the eight default weights from the v3.5 production script."

    private static func intro(fromLegacyPreference: Bool) -> String {
        let base: String = "These weights drive the Security Score everywhere: Security Posture, "
            + "the Overview, Trends, alerts and reports. They are saved to this "
            + "workspace's config.yaml. Set a weight to 0 to drop that metric "
            + "entirely. Missing metrics in your data are auto-renormalized so the "
            + "score still scales to 100."
        guard fromLegacyPreference else { return base }
        return base + " These are this Mac's earlier weights; they apply once you change "
            + "one, which saves them to this workspace."
    }

    private static func totalWeight(_ w: SecurityScoreWeights) -> Double {
        w.fileVault + w.sip + w.firewall + w.edrAgent + w.mscp + w.xprotect + w.cve + w.secureBoot
    }

    @ViewBuilder
    private func weightRow(_ label: String, value: Binding<Int>) -> some View {
        HStack {
            Text(label)
                .font(.footnote)
                .foregroundStyle(Theme.Colors.fg)
            Spacer()
            EditableNumberStepper(value: value, range: 0...100, suffix: "pts")
                .accessibilityLabel("\(label) weight")
                .accessibilityValue("\(value.wrappedValue) points out of 100")
        }
    }
}
