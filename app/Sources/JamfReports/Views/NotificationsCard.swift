import SwiftUI
import TipKit

/// Configures the active profile's `notify:` webhook. Scheduled runs already
/// read this block at run time, so the panel only WRITES it; each control
/// persists immediately (write-on-change), matching the Settings AI panel.
/// The URL TextField is the exception: its binding fires per KEYSTROKE, and each
/// save is a full config.yaml read/decode/re-encode/atomic-rename — so URL edits
/// are debounced (600ms) instead of written per character.
///
/// Shared between `AutomationView` (managed mode) and `SchedulesView` (unmanaged
/// mode, the per-schedule builder) — notifications apply to any scheduled run,
/// hand-built or managed, so both screens render the same card rather than
/// forcing unmanaged-mode operators to hand-edit `config.yaml`.
struct NotificationsCard: View {
    let profile: String

    @State private var notifyEnabled = false
    @State private var notifyProvider: NotifyConfig.Provider = .teams
    @State private var notifyURL = ""
    @State private var notifyDetail: NotifyConfig.Detail = .full
    @State private var notifySaveMessage: String?
    @State private var notifyTestResult: String?
    @State private var notifyTesting = false
    @State private var notifyURLSaveTask: Task<Void, Never>?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Notifications").font(.headline)
                Text("Webhook for profile \"\(profile)\".")
                    .font(.callout.weight(.semibold))
                Text("Scheduled runs post digests, failure alerts, metric alerts, and overdue "
                    + "notices to this webhook.")
                    .font(.footnote).foregroundStyle(Theme.Colors.fgMuted)

                Toggle("Enable notifications", isOn: Binding(
                    get: { notifyEnabled },
                    set: { notifyEnabled = $0; saveNotifyConfig() }))
                    .toggleStyle(.switch)
                TipView(AutomationTips.notifications)
                    .frame(maxWidth: 420, alignment: .leading)

                if notifyEnabled {
                    Picker("Service", selection: Binding(
                        get: { notifyProvider },
                        set: { notifyProvider = $0; saveNotifyConfig() })) {
                        ForEach(NotifyConfig.Provider.allCases, id: \.self) { provider in
                            Text(provider == .teams ? "Microsoft Teams" : "Slack").tag(provider)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 260, alignment: .leading)

                    TextField("https://...", text: Binding(
                        get: { notifyURL },
                        set: { notifyURL = $0; scheduleDebouncedNotifySave() }))
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                        .frame(maxWidth: 420, alignment: .leading)
                        .onSubmit { flushNotifySave() }

                    if NotifyConfigWriter.showsInsecureURLWarning(enabled: notifyEnabled, url: notifyURL) {
                        Text("URL must start with https:// — notifications will not send.")
                            .font(.footnote).foregroundStyle(Theme.Colors.warn)
                    }

                    Picker("Detail", selection: Binding(
                        get: { notifyDetail },
                        set: { notifyDetail = $0; saveNotifyConfig() })) {
                        Text("Full").tag(NotifyConfig.Detail.full)
                        Text("Minimal").tag(NotifyConfig.Detail.minimal)
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 260, alignment: .leading)
                    Text("Minimal sends event counts only — no metric values, error text, or "
                        + "schedule names.")
                        .font(.footnote).foregroundStyle(Theme.Colors.fgMuted)

                    HStack(spacing: 8) {
                        PNPButton(title: "Send test notification", icon: "paperplane", size: .sm) {
                            Task { await sendTestNotification() }
                        }
                        .disabled(notifyTesting || !currentNotifyConfig.isUsable)
                        if notifyTesting { ProgressView().controlSize(.small) }
                    }

                    if let notifyTestResult {
                        Text(notifyTestResult)
                            .font(.caption).foregroundStyle(Theme.Colors.fgMuted)
                    }
                }

                if let notifySaveMessage {
                    Text(notifySaveMessage)
                        .font(.caption).foregroundStyle(Theme.Colors.warn)
                }
            }
        }
        // Load the active profile's `notify:` block into the form (and reset on a
        // profile switch), mirroring the Settings AI panel's `.task(id: profile)`.
        .task(id: profile) { loadNotifyConfig() }
        // A pending debounced save (in-flight keystroke, not yet flushed) must
        // not be lost if the operator navigates away before it fires.
        .onDisappear { flushNotifySave() }
    }

    /// A `NotifyConfig` built from the CURRENT form values, so the test-send uses
    /// the in-progress URL even before it round-trips to disk.
    private var currentNotifyConfig: NotifyConfig {
        NotifyConfig(
            enabled: notifyEnabled,
            provider: notifyProvider.rawValue,
            url: notifyURL,
            detail: notifyDetail.rawValue
        )
    }

    private func loadNotifyConfig() {
        let config = NotifyConfigLoader.load(profile: profile)
        notifyEnabled = config.isEnabled
        notifyProvider = config.resolvedProvider
        notifyURL = config.resolvedURL
        notifyDetail = config.resolvedDetail
        notifySaveMessage = nil
        notifyTestResult = nil
    }

    private func saveNotifyConfig() {
        do {
            try NotifyConfigWriter.save(
                enabled: notifyEnabled,
                provider: notifyProvider.rawValue,
                url: notifyURL,
                detail: notifyDetail.rawValue,
                profile: profile
            )
            notifySaveMessage = nil
        } catch {
            notifySaveMessage = "Couldn't save notification settings: \(error.localizedDescription)"
        }
    }

    /// Debounce URL-keystroke saves: each save is a full config.yaml
    /// read/decode/re-encode/rename, so coalesce rapid typing into one write.
    private func scheduleDebouncedNotifySave() {
        notifyURLSaveTask?.cancel()
        notifyURLSaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            saveNotifyConfig()
        }
    }

    /// Write immediately (Return pressed) — cancel any pending debounce first.
    private func flushNotifySave() {
        notifyURLSaveTask?.cancel()
        notifyURLSaveTask = nil
        saveNotifyConfig()
    }

    private func sendTestNotification() async {
        notifyTesting = true
        notifyTestResult = nil
        let delivered = await WebhookNotifier.send(
            config: currentNotifyConfig,
            title: "Test notification — Jamf Reports",
            facts: [
                .init(label: "Profile", value: profile),
                .init(label: "Status", value: "Test"),
            ]
        )
        notifyTesting = false
        notifyTestResult = delivered ? "Delivered" : "Send failed — check the URL"
    }
}
