import Foundation

/// An actionable warning a run logged that an admin has to fix (2.11). Informational warnings
/// stay in the log only. The raw value is persisted in status files: never rename a case.
enum AttentionCode: String, Codable, Sendable, CaseIterable {
    case webhookRejected
    case schoolZeroDevices
    case eaSnapshotUnreadable
    case fleetDriftLargeChange
    case protectBackupSkipped
    case protectBackupPartial
    case lostModeStripFailed
    case jamfCLIProfileMissing
    case proBackupChoiceNeeded

    /// The screen where the fix, or the run that saw it, is.
    enum Destination: Sendable, Equatable {
        case automation, backups, runHistory
    }

    var destination: Destination {
        switch self {
        case .webhookRejected, .jamfCLIProfileMissing: .automation
        case .protectBackupSkipped, .protectBackupPartial, .proBackupChoiceNeeded: .backups
        case .schoolZeroDevices, .eaSnapshotUnreadable, .fleetDriftLargeChange,
             .lostModeStripFailed: .runHistory
        }
    }
}

/// What one run did about a code: saw it again, or ran the check and it passed.
enum AttentionChange: Sendable, Equatable {
    case raised(String)
    case cleared
}

/// One open attention item, as the `attention` array of a status file holds it.
struct AttentionItem: Codable, Sendable, Equatable {
    let code: AttentionCode
    /// Short, redacted: no device data, URLs or secrets (`sanitized`).
    var message: String
    var firstSeen: Date
    var lastSeen: Date
    var count: Int
    let profile: String
    /// The Run History log name of the run that last saw it, when that run kept one.
    var runLog: String?

    enum CodingKeys: String, CodingKey {
        case code, message, count, profile
        case firstSeen = "first_seen"
        case lastSeen = "last_seen"
        case runLog = "run_log"
    }

    static let maxMessageLength = 160
    /// The most sightings counted. Status files sit in a folder a peer can write, so a stored
    /// count is held to this range and adding one never overflows.
    static let maxCount = 1_000_000

    /// `count` held to 1...`maxCount`.
    func clampingCount() -> AttentionItem {
        var item = self
        item.count = min(max(count, 1), Self.maxCount)
        return item
    }

    /// Redacted as Run History's shared text is, with any URL removed and the length capped.
    static func sanitized(_ text: String, profile: String) -> String {
        let shared = LogRedactor.redactedForSharing(text, profile: profile)
        let flat = shared
            .replacingOccurrences(
                of: #"[A-Za-z][A-Za-z0-9+.-]*://\S+"#, with: "<url>", options: .regularExpression)
            .replacingOccurrences(of: #"\p{Cc}"#, with: " ", options: .regularExpression)
        return String(flat.prefix(maxMessageLength))
    }

    /// `open` with one run's `changes` applied: a code seen again keeps its first sighting and
    /// counts up, a cleared code is removed. Items of other profiles are left as they are.
    static func merging(
        _ open: [AttentionItem], _ changes: [AttentionCode: AttentionChange],
        profile: String, runLog: String?, now: Date
    ) -> [AttentionItem] {
        var items = open
        for (code, change) in changes.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let index = items.firstIndex { $0.code == code && $0.profile == profile }
            switch (change, index) {
            case (.cleared, let index?):
                items.remove(at: index)
            case (.cleared, nil):
                break
            case (.raised(let message), let index?):
                items[index].message = message
                items[index].lastSeen = now
                items[index].count = min(max(items[index].count, 0), Self.maxCount - 1) + 1
                items[index].runLog = runLog
            case (.raised(let message), nil):
                items.append(AttentionItem(
                    code: code, message: message, firstSeen: now, lastSeen: now, count: 1,
                    profile: profile, runLog: runLog))
            }
        }
        return items
    }

    /// Newest sighting first: the banner's button follows the first.
    static func ordered(_ items: [AttentionItem]) -> [AttentionItem] {
        items.sorted { ($0.lastSeen, $1.code.rawValue) > ($1.lastSeen, $0.code.rawValue) }
    }
}

/// Items the admin dismissed on this Mac, each until it clears and opens again (a new
/// `firstSeen`); a repeat of the same open item stays hidden. Per Mac in UserDefaults, never in
/// the workspace.
enum AttentionDismissals {
    static let key = "dismissedAttentionItems"

    static func isDismissed(_ item: AttentionItem, in defaults: UserDefaults = .standard) -> Bool {
        (defaults.dictionary(forKey: key)?[id(item)] as? Double)
            == item.firstSeen.timeIntervalSince1970
    }

    static func dismiss(_ items: [AttentionItem], in defaults: UserDefaults = .standard) {
        var stored = defaults.dictionary(forKey: key) ?? [:]
        for item in items { stored[id(item)] = item.firstSeen.timeIntervalSince1970 }
        defaults.set(stored, forKey: key)
    }

    private static func id(_ item: AttentionItem) -> String {
        "\(item.profile)|\(item.code.rawValue)"
    }
}
