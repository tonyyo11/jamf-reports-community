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
    /// What a save did not keep (a backup was made), shown while its profile is live.
    @State private var saveNote: ProfileSaveNote?

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
                statusLines
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Security policy configuration")
    }

    @ViewBuilder
    private var statusLines: some View {
        if let saveFailure {
            Text(saveFailure.message)
                .font(.caption)
                .foregroundStyle(Theme.Colors.danger)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let line = saveNote?.line(for: workspace.profile) { warnNote(line) }
    }

    private func controlRow(_ control: SecurityControl, issue: SecurityPolicyIssue?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text(control.displayName)
                    .font(.footnote)
                    .foregroundStyle(Theme.Colors.fg)
                Spacer(minLength: 12)
                Picker(control.displayName, selection: Self.levelBinding(
                    control, in: workspace, failure: $saveFailure, note: $saveNote)
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
                writeNote(issue, level: workspace.securityPolicy.level(for: control),
                          for: control.displayName) {
                    Self.writeAppliedLevel(control, in: workspace,
                        failure: $saveFailure, note: $saveNote)
                }
            }
        }
    }

    /// Beside its label like the control rows when the card is wide enough, under it when not
    /// (the long label and five segments do not share a row at `PageScaffold.minSupportedWidth`).
    /// Either way the picker ends on the trailing edge, where the control rows' pickers end.
    private func hardwareRow(issue: SecurityPolicyIssue?, fileVaultIgnored: Bool) -> some View {
        let label = Text("FileVault off on a hardware-encrypted Mac")
            .font(.footnote)
            .foregroundStyle(Theme.Colors.fg)
        return VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    label
                    Spacer(minLength: 12)
                    hardwarePicker(fileVaultIgnored: fileVaultIgnored)
                }
                VStack(alignment: .leading, spacing: 6) {
                    label
                    hardwarePicker(fileVaultIgnored: fileVaultIgnored)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            Text("Apple silicon Macs and Intel Macs with the T2 chip always encrypt the "
                 + "internal disk; with FileVault off it unlocks without a password.")
                .font(.caption)
                .foregroundStyle(Theme.Text.tertiary(contrast))
                .fixedSize(horizontal: false, vertical: true)
            if let issue {
                writeNote(issue, level: workspace.securityPolicy.fileVaultOffHardwareEncrypted,
                          for: "FileVault off on a hardware-encrypted Mac") {
                    Self.writeAppliedHardwareLevel(in: workspace,
                        failure: $saveFailure, note: $saveNote)
                }
            }
        }
    }

    private func hardwarePicker(fileVaultIgnored: Bool) -> some View {
        Picker("FileVault off on a hardware-encrypted Mac", selection: Self.hardwareBinding(
            in: workspace, failure: $saveFailure, note: $saveNote)
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
    }

    @ViewBuilder
    private func issueNotes(_ issues: [SecurityPolicyIssue]) -> some View {
        ForEach(Self.shapeIssues(in: issues), id: \.keyPath) { issue in
            warnNote(Self.shapeCaption(issue))
        }
        ForEach(Self.factorIssues(in: issues), id: \.keyPath) { issue in
            warnNote(Self.factorCaption(issue))
        }
        if let unknown = Self.unknownKeysCaption(issues) { warnNote(unknown) }
    }

    /// The note for a typed level the app did not accept, with a button that writes the level
    /// it applied. Choosing the shown level in the picker fires nothing, so without the
    /// button a typo that reads as that level could not be cleared from here.
    private func writeNote(
        _ issue: SecurityPolicyIssue, level: SecurityControlLevel?, for setting: String,
        write: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            warnNote(Self.levelCaption(issue))
            Spacer(minLength: 8)
            PNPButton(title: Self.writeTitle(for: level), size: .sm, action: write)
                .accessibilityLabel("\(Self.writeTitle(for: level)) for \(setting)")
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
        failure: Binding<SaveFailure?>, note: Binding<ProfileSaveNote?>
    ) -> Binding<SecurityControlLevel> {
        Binding(
            get: { workspace.securityPolicy.level(for: control) },
            set: { level in
                persist(failure, note: note, profile: workspace.profile) {
                    try workspace.saveSecurityLevel(level, for: control)
                }
            })
    }

    static func hardwareBinding(
        in workspace: WorkspaceStore, failure: Binding<SaveFailure?>,
        note: Binding<ProfileSaveNote?>
    ) -> Binding<SecurityControlLevel?> {
        Binding(
            get: { workspace.securityPolicy.fileVaultOffHardwareEncrypted },
            set: { level in
                persist(failure, note: note, profile: workspace.profile) {
                    try workspace.saveHardwareLevel(level)
                }
            })
    }

    /// The "Write fail" button: writes the level the app applied for this control over what
    /// the file holds, so the typed value that did not read as a level goes.
    static func writeAppliedLevel(
        _ control: SecurityControl, in workspace: WorkspaceStore,
        failure: Binding<SaveFailure?>, note: Binding<ProfileSaveNote?>
    ) {
        let level = workspace.securityPolicy.level(for: control)
        persist(failure, note: note, profile: workspace.profile) {
            try workspace.saveSecurityLevel(level, for: control)
        }
    }

    /// Applied nil (FileVault's own level) removes the entry.
    static func writeAppliedHardwareLevel(
        in workspace: WorkspaceStore, failure: Binding<SaveFailure?>,
        note: Binding<ProfileSaveNote?>
    ) {
        let level = workspace.securityPolicy.fileVaultOffHardwareEncrypted
        persist(failure, note: note, profile: workspace.profile) {
            try workspace.saveHardwareLevel(level)
        }
    }

    static func writeTitle(for level: SecurityControlLevel?) -> String {
        level.map { "Write \($0.rawValue)" } ?? "Remove the entry"
    }

    /// A successful write clears the failure and keeps what it did not keep as the card's note
    /// (a later write with nothing to say leaves it); a failed one becomes the card's message.
    static func persist(
        _ failure: Binding<SaveFailure?>, note: Binding<ProfileSaveNote?>, profile: String,
        _ write: () throws -> ConfigSaveReport
    ) {
        do {
            let report = try write()
            failure.wrappedValue = nil
            if let saved = report.note(for: profile) { note.wrappedValue = saved }
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

    /// The block or `controls` holding something other than settings.
    static func shapeIssues(in issues: [SecurityPolicyIssue]) -> [SecurityPolicyIssue] {
        issues.filter { SecurityPolicyConfigLoader.blockKeyPaths.contains($0.keyPath) }
    }

    /// A `score_factors` entry the app skipped or read other than as typed. The factors card
    /// edits the list, so these are noted here with the other hand-typed values.
    static func factorIssues(in issues: [SecurityPolicyIssue]) -> [SecurityPolicyIssue] {
        issues.filter { SecurityPolicyConfigLoader.isFactorPath($0.keyPath) && !$0.used.isEmpty }
    }

    static func levelCaption(_ issue: SecurityPolicyIssue) -> String {
        "config.yaml says \"\(shown(issue.value))\", which is not fail, warning or ignore — "
            + "using \(shown(issue.used))."
    }

    /// Names the entry as `score_factors[N]`, with what the app did with it.
    static func factorCaption(_ issue: SecurityPolicyIssue) -> String {
        let path = issue.keyPath.replacingOccurrences(of: "security_policy.", with: "")
        let typed = issue.value.isEmpty ? "" : " (\"\(shown(issue.value))\")"
        return "config.yaml's \(shownPath(path))\(typed): \(issue.used)."
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

/// The workspace's security policy and the factors the Security Score counts.
struct ScoringTab: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SecurityPolicyCard()
            ScoreFactorsCard()
        }
    }
}
