import Foundation

extension ConfigDoctorService {

    /// One `.warn` row when a shared workspace's config.yaml differs from the values this Mac
    /// pinned (`SharedConfigPin`), with a Confirm button per changed key. Never `.fail`: the
    /// run it describes already used the safe values, and a scheduled run must not turn red
    /// for it. A pin that cannot be read has no per-key answer, so it gets one Confirm all.
    static func sharedConfigRows(
        profile: String, appSupport: URL = AppSupport.directory()
    ) -> [DoctorRow] {
        let check = SharedConfigPin.check(profile: profile, appSupport: appSupport)
        guard !check.drifts.isEmpty else { return [] }
        let unreadable = check.pinned == nil
        let items = check.drifts.map { drift in
            // Hidden characters make the shown value differ from what Confirm would pin.
            let hidden = ConfigSchema.hasHiddenCharacters(drift.current)
            return DoctorRowItem(
                id: drift.key.rawValue,
                text: sharedConfigText(drift, workspace: check.workspace)
                    + (hidden ? L("\n  contains hidden characters: fix it in config.yaml; it cannot be confirmed here") : ""),
                action: unreadable || hidden ? nil : .confirmSharedConfig([drift]))
        }
        return [DoctorRow(
            id: "shared_config.drift",
            severity: .warn,
            title: L("Shared config changed since this Mac pinned it"),
            detail: items.map(\.text).joined(separator: "\n\n"),
            hint: L("A Mac sharing this workspace edited config.yaml, or it was edited here. Until you confirm, every screen, report and run on this Mac uses the safe value for each key (workspace Generated Reports folder, archive instead of delete, no webhook send, no Protect collection, no logo, the history file beside the report, no report timestamp)."),
            action: unreadable ? .confirmSharedConfig(check.drifts) : nil,
            items: items
        )]
    }

    /// The key, the value pinned and the value now, each as typed (control characters removed,
    /// nothing cut short before the 1024-character limit), and for a folder where it lands.
    /// The webhook and the timestamp authority show their host and a short fingerprint, never
    /// the URL.
    private static func sharedConfigText(
        _ drift: SharedConfigPin.Drift, workspace: URL?
    ) -> String {
        let key = drift.key == .notifyURL ? "notify.url" : drift.key.rawValue
        var lines = [
            key,
            L("  pinned: ") + (drift.pinnedIsNote ? drift.pinned : sharedConfigValue(drift.pinned)),
            L("  now:    ") + sharedConfigValue(drift.current),
        ]
        if drift.key.isFolder, let workspace, !drift.current.isEmpty {
            let destination = WorkspacePaths.destination(of: drift.current, workspace: workspace)
            let place = destination.insideWorkspace ? "inside" : "outside"
            let path = ConfigSchema.fullDisplayText(destination.path)
            lines.append((path.truncated ? L("  lands:  \(path.text) (truncated) (\(place) this workspace)") : L("  lands:  \(path.text) (\(place) this workspace)")))
        }
        return lines.joined(separator: "\n")
    }

    private static func sharedConfigValue(_ value: String) -> String {
        guard !value.isEmpty else { return L("(not set)") }
        let shown = ConfigSchema.fullDisplayText(value)
        return "\"\(shown.text)\"" + (shown.truncated ? L(" (truncated)") : "")
    }
}
