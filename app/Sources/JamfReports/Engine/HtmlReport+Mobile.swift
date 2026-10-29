import Foundation

// MARK: - HtmlReport+Mobile
//
// The "Mobile devices" section (#275): counts by form factor, management and supervision,
// passcode, Activation Lock and jailbreak status, and OS versions, read through `MobileFleetService` so the
// numbers follow the same rules as the Mobile Devices screen and the workbook's mobile
// sheets. No per-device table: an HTML report is forwarded, and the workbook has the rows.

extension HtmlReport {

    /// "42 devices · 30 iPad · 12 iPhone", the group's headline.
    func mobileHeadline(_ mobile: MobileFleetService.Snapshot) -> [String] {
        guard mobile.totalDevices > 0 else { return [] }
        let f = HtmlSectionFormatters.self
        var parts = [f.plural(mobile.totalDevices, "device")]
        if mobile.iPadCount > 0 { parts.append("\(mobile.iPadCount) iPad") }
        if mobile.iPhoneCount > 0 { parts.append("\(mobile.iPhoneCount) iPhone") }
        if mobile.appleTVCount > 0 { parts.append("\(mobile.appleTVCount) Apple TV") }
        return parts
    }

    func buildMobileFleet(_ mobile: MobileFleetService.Snapshot?) -> HtmlBlock {
        let f = HtmlSectionFormatters.self
        guard let mobile, mobile.totalDevices > 0 else {
            return .omitted(mobileAbsenceReason(mobile))
        }
        let total = mobile.totalDevices
        var cards = [f.SectionCard(name: "Mobile devices", value: "\(total)")]
        for (name, count) in [("iPad", mobile.iPadCount), ("iPhone", mobile.iPhoneCount),
                              ("Apple TV", mobile.appleTVCount)] where count > 0 {
            cards.append(.init(name: name, value: "\(count)"))
        }
        let detailed = !mobile.richDevices.isEmpty
        if detailed {
            cards.append(.init(
                name: "Managed", value: "\(mobile.managedCount)", sublabel: "of \(total)"))
            cards.append(.init(
                name: "Supervised", value: "\(mobile.supervisedCount)", sublabel: "of \(total)"))
        }
        let devices = mobile.richDevices
        cards.append(postureCard(
            "Passcode compliant", count: mobile.passcodeCompliantCount,
            reporting: devices.compactMap(MobileFleetService.passcodeCompliant(of:)).count))
        cards.append(postureCard(
            "Activation Lock on", count: mobile.activationLockEnabledCount,
            reporting: devices.compactMap(MobileFleetService.activationLockEnabled(of:)).count))
        cards.append(postureCard(
            "Jailbreak detected", count: mobile.jailbreakDetectedCount,
            reporting: devices.compactMap(MobileFleetService.jailbreakStatus(of:)).count))

        var body = f.renderCardGrid(cards: cards)
        let versions = mobile.osDistribution.map { (label: $0.osVersion, count: $0.count) }
        if !versions.isEmpty {
            body += "\n<p class=\"block-note\">OS versions, iOS and iPadOS together.</p>\n"
                + f.renderBars(versions, expanded: expandAll, colored: .version)
        }
        if !detailed {
            body += "\n<p class=\"block-note\">" + f.escapeHTML(
                "Only the device list was collected, so management, supervision, passcode, "
                + "jailbreak status and OS versions are not known.") + "</p>"
        }
        return .shown(f.block(id: "mobile-fleet", title: "Mobile devices (\(total))", body: body))
    }

    /// A posture count; "Unknown" when no device carries the field, never 0.
    private func postureCard(
        _ name: String, count: Int?, reporting: Int
    ) -> HtmlSectionFormatters.SectionCard {
        guard let count else {
            return .init(name: name, value: "Unknown", sublabel: "no device reports it")
        }
        return .init(name: name, value: "\(count)", sublabel: "of \(reporting) reporting")
    }

    /// Why the report has no mobile section: nothing collected (with the recorded cause of the
    /// last failed attempt, if there is one) or a snapshot that lists no device.
    private func mobileAbsenceReason(_ mobile: MobileFleetService.Snapshot?) -> String {
        let collected = mobile?.sourceDates[MobileFleetService.deviceKind] != nil
            || !(mobile?.richDevices.isEmpty ?? true)
        if collected { return "the mobile device snapshot lists no devices" }
        let state = StateFileStore(directory: dataDir.appendingPathComponent("state"))
        if let cause = state.cause(for: MobileFleetService.deviceKind) {
            return "No mobile device data collected: the last attempt failed (\(cause.label))"
        }
        return "No mobile device data collected"
    }
}
