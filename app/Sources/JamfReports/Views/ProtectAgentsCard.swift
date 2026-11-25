import SwiftUI

/// The Protect screen's "Protect agents" card: signatures behind, agent behind and disconnected
/// over a day, each with the baseline it was measured against, or why it was not evaluated.
struct ProtectAgentsCard: View {
    let health: ProtectAgentHealth
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: L("Protect agents"))
                row(L("Signatures behind"), health.signaturesBehind)
                row(L("Agent behind the installer"), health.agentBehind)
                row(L("Disconnected for more than a day"), health.disconnected)
                reasons
                Text(L("Agents on a plan with automatic updates off can be held back on purpose."))
                    .font(.caption)
                    .foregroundStyle(Theme.Text.tertiary(contrast))
            }
        }
    }

    private func row(_ title: String, _ finding: ProtectAgentHealth.Finding) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.Colors.fg)
                Spacer()
                Text(Self.value(finding))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(Theme.Colors.fg)
            }
            if let caption = Self.caption(finding) {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(Theme.Text.tertiary(contrast))
            }
        }
    }

    @ViewBuilder
    private var reasons: some View {
        let shown = health.disconnectedReasons
        if !shown.isEmpty || health.disconnectedTimeUnknown > 0 {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, entry in
                    // Protect's reason is shown as it gives it; only the fallback is translated.
                    let reason = entry.reason ?? L("No reason reported")
                    Text(verbatim: "\(entry.count) · \(reason)")
                        .font(.caption.monospaced())
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                }
                if health.distinctReasons > shown.count {
                    Text(L("\(shown.count) of \(health.distinctReasons) reasons shown"))
                        .font(.caption)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                }
                let unknown = health.disconnectedTimeUnknown
                if unknown > 0 {
                    Text(L("\(unknown) not connected, time of disconnection unknown"))
                        .font(.caption)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                }
            }
        }
    }

    /// "N of M", or a dash while the finding is not evaluated.
    static func value(_ finding: ProtectAgentHealth.Finding) -> String {
        guard let share = finding.share else { return "—" }
        return L("\(share.met) of \(share.of)")
    }

    /// The baseline, or why the finding is not evaluated.
    static func caption(_ finding: ProtectAgentHealth.Finding) -> String? {
        if let reason = finding.notEvaluated { return L("Not evaluated: \(text(reason))") }
        switch finding.baseline {
        case .published(let id, let created):
            return L("Compared with version \(id), published \(day(created))")
        case .installer(let version, let firstSeen):
            let shown = ConfigSchema.displayText(version)
            return L("Compared with installer \(shown), first seen \(day(firstSeen))")
        case nil:
            return nil
        }
    }

    private static func day(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    static func text(_ reason: ProtectAgentHealth.Unavailable) -> String {
        switch reason {
        case .notCollected(let kind): return L("\(kind) not collected yet")
        case .unreadable(let kind): return L("\(kind) could not be read")
        case .noPublishedVersions: return L("Protect published no signature versions")
        case .noVersionOldEnough: return L("no published signature version is a day old yet")
        case .noInstallerVersion: return L("Protect gave no installer version")
        case .installerNotAVersion(let v):
            return L("installer version \(ConfigSchema.displayText(v)) is not a version number")
        case .installerTooNew(let v, let firstSeen):
            return L("installer \(ConfigSchema.displayText(v)) first seen \(day(firstSeen))")
        case .firstSeenUnknown(let v):
            return L("no dated snapshot holds installer \(ConfigSchema.displayText(v))")
        case .noCollectionTime: return L("the Protect computers snapshot has no collection time")
        }
    }
}
