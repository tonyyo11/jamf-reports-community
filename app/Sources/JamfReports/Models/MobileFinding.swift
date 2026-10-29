import Foundation

/// The seven mobile conditions the Health Audit's "Mobile Devices" card counts (mobile spec 5):
/// the Mobile Devices screen filters to the devices behind each one, and the HTML report's
/// "Needs attention" states each from the daily summary's `MobileSummary`. Every reading goes
/// through `MobileSummary.device` and `MobileSummary.isStale`, the rules the summary counts
/// with, so a card, a filter and a sentence cannot disagree. A device that does not report the
/// field a rule judges is not counted either way (`isAffected` is nil).
enum MobileFinding: String, CaseIterable, Sendable, Identifiable {
    case jailbreak, unmanaged, passcode, dataProtection, osBehind, updateErrors, stale

    var id: String { rawValue }

    /// The Health Audit category all seven share.
    static let category = "Mobile devices"

    /// What the rules judge devices against.
    struct Context: Sendable, Equatable {
        /// The iOS / iPadOS feed's newest release per major; empty leaves `osBehind` unjudged.
        var latestByMajor: [Int: String] = [:]
        var staleDays: Int
        var now: Date
        /// Identifiers of the devices in the update scan's non-computer error rows; nil when no
        /// scan has run, which leaves `updateErrors` unjudged.
        var updateErrorKeys: Set<String>?
    }

    // MARK: - Wording

    func name(staleDays: Int) -> String {
        switch self {
        case .jailbreak: "Jailbreak detected"
        case .unmanaged: "Not managed"
        case .passcode: "Passcode not compliant"
        case .dataProtection: "Data protection off"
        case .osBehind: "OS behind the current release"
        case .updateErrors: "Software update errors"
        case .stale: "No inventory update in more than \(staleDays) days"
        }
    }

    /// The filter chip's and menu's label.
    var filterLabel: String {
        switch self {
        case .jailbreak: "Jailbreak detected"
        case .unmanaged: "Not managed"
        case .passcode: "Passcode not compliant"
        case .dataProtection: "Data protection off"
        case .osBehind: "OS behind"
        case .updateErrors: "Update errors"
        case .stale: "Stale inventory"
        }
    }

    /// The Health Audit severity word: high, medium and low in the spec.
    var severity: String {
        switch self {
        case .jailbreak: "CRITICAL"
        case .stale: "INFO"
        default: "WARNING"
        }
    }

    func recommendation(staleDays: Int) -> String {
        switch self {
        case .jailbreak:
            "A jailbroken device can bypass the protections MDM relies on. Take it out of "
                + "use, investigate it, and re-enroll it only after it is restored."
        case .unmanaged:
            "Jamf Pro lists these devices as unmanaged: no profile or restriction is "
                + "enforced on them. Re-enroll them, or retire the records."
        case .passcode:
            "These devices do not meet the passcode requirement. Check that a passcode "
                + "configuration profile is scoped to them."
        case .dataProtection:
            "Data protection is off on these devices, usually because no passcode is set. "
                + "Require a passcode with a configuration profile."
        case .osBehind:
            "These devices run an older iOS or iPadOS than the newest release of their "
                + "major version. Push the update, or check that nothing defers it."
        case .updateErrors:
            "The software update scan found errors on these devices. Open OS Updates for "
                + "the products and status, and check that the device can reach Apple."
        case .stale:
            "These devices have not submitted inventory for more than \(staleDays) days "
                + "(last inventory update). Check that they are on, enrolled and reach Jamf Pro."
        }
    }

    /// The HTML report's "Needs attention" line for `count` devices (above zero).
    func sentence(count: Int, staleDays: Int) -> String {
        let one = count == 1
        let devices = one ? "1 mobile device" : "\(count) mobile devices"
        switch self {
        case .jailbreak: return "\(devices) \(one ? "has" : "have") a jailbreak detected."
        case .unmanaged: return "\(devices) \(one ? "is" : "are") not managed."
        case .passcode:
            return "\(devices) \(one ? "does" : "do") not meet the passcode requirement."
        case .dataProtection: return "\(devices) \(one ? "has" : "have") data protection off."
        case .osBehind:
            return "\(devices) \(one ? "is" : "are") behind the current iOS or iPadOS release."
        case .updateErrors:
            return "\(devices) \(one ? "has" : "have") software update errors."
        case .stale:
            return "\(devices) \(one ? "has" : "have") not updated inventory for more than "
                + "\(staleDays) days."
        }
    }

    /// "3 fewer than on 2026-10-18", for the card's change against the previous summary.
    static func changeText(current: Int, previous: Int, since date: String) -> String {
        let difference = current - previous
        if difference == 0 { return "No change since \(date)" }
        return "\(abs(difference)) \(difference < 0 ? "fewer" : "more") than on \(date)"
    }

    // MARK: - The rule

    /// True when `device` shows the condition, false when it reports the field and does not,
    /// nil when it does not report the field (or, for `osBehind`, runs a major the feed does
    /// not track; for `updateErrors`, when no scan has run). `updateErrorKey` is
    /// `updateErrorKey(serial:name:)` of the device.
    func isAffected(
        _ device: MobileSummary.Device, updateErrorKey: String?, context: Context
    ) -> Bool? {
        switch self {
        case .jailbreak: return device.jailbroken
        case .unmanaged: return device.managed.map { !$0 }
        case .passcode: return device.passcodeCompliant.map { !$0 }
        case .dataProtection: return device.dataProtected.map { !$0 }
        case .osBehind:
            return device.iOSVersion
                .flatMap { SOFAFeedService.isCurrent($0, latestByMajor: context.latestByMajor) }
                .map { !$0 }
        case .updateErrors:
            return context.updateErrorKeys.map { keys in
                updateErrorKey.map(keys.contains) ?? false
            }
        case .stale:
            return device.lastSeen.map {
                MobileSummary.isStale(
                    lastSeen: $0, staleDays: context.staleDays, now: context.now)
            }
        }
    }

    /// The finding's count in a daily summary; nil when the summary does not carry it.
    func count(in summary: MobileSummary) -> Int? {
        switch self {
        case .jailbreak: summary.jailbroken
        case .unmanaged: summary.unmanaged
        case .passcode: summary.passcode.map { $0.of - $0.met }
        case .dataProtection: summary.dataProtection.map { $0.of - $0.met }
        case .osBehind: summary.osCurrent.map { $0.of - $0.met }
        case .updateErrors: summary.updateErrors
        case .stale: summary.stale
        }
    }

    // MARK: - Update scan rows

    /// How an error row of the update scan names a device: its serial, else its name. A row
    /// naming neither matches no device.
    static func updateErrorKey(serial: String?, name: String?) -> String? {
        MobileFleetService.firstNonBlank(serial, name)?.uppercased()
    }

    /// The devices the update scan lists with errors, other than computers; nil when the data
    /// is not a `--scan-failures` snapshot (a summary-only snapshot's empty list says nothing).
    /// One device with an error for each of two products is one device.
    static func updateErrorKeys(in scanData: Data) -> Set<String>? {
        guard let scan = try? JSONDecoder().decode([UpdateFailuresReport].self, from: scanData)
            .first else { return nil }
        return Set(scan.errorDevices
            .filter { $0.deviceType.uppercased() != "COMPUTER" }
            .compactMap { updateErrorKey(serial: $0.serial, name: $0.name) })
    }

    // MARK: - Navigation

    /// The `.navigateToTab` userInfo key that carries a filter's raw value.
    static let userInfoKey = "mobileFilter"

    /// The post that opens Mobile Devices with this filter applied.
    func navigationUserInfo() -> [String: String] {
        ["tab": Tab.mobileFleet.rawValue, Self.userInfoKey: rawValue]
    }

    /// The filter a navigation asks Mobile Devices to open with: only a post to that tab
    /// carries one, so a request meant for another tab cannot wait for a later visit.
    static func pending(from userInfo: [AnyHashable: Any]?, destination: Tab) -> String? {
        guard destination == .mobileFleet else { return nil }
        return userInfo?[userInfoKey] as? String
    }
}
