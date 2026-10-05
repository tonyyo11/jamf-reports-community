import Foundation

/// A Mac that MDM still reaches while its Jamf binary or its inventory has fallen behind.
///
/// Last Contact moves for any channel (the Jamf binary, MDM, declarative device management),
/// Last Check-in only for the Jamf binary and Last Inventory Update only for a recon. Contact
/// current with a check-in far behind it is a Mac the binary no longer reaches Jamf Pro from:
/// broken, removed or blocked. The lag is measured from Last Contact, not from today, so a Mac
/// that is silent on every channel is stale (`StaleRule`), not a gap.
enum ContactGap: String, CaseIterable, Sendable, Equatable {
    /// Last Check-in is more than the gap before Last Contact.
    case binarySilent
    /// The check-in keeps up with Last Contact; Last Inventory Update does not.
    case inventoryStale

    /// `thresholds.contact_gap_days`: whole days from 1 to 365.
    static let defaultDays = 14
    static let dayRange = 1...365

    /// The gap a Mac shows, nil when none. A Mac without a Last Contact, or whose Last Contact
    /// is itself more than `staleDays` old, has none. A missing check-in or inventory date is
    /// older than any gap.
    static func of(
        checkIn: Date?, inventory: Date?, contact: Date?,
        staleDays: Int, gapDays: Int, now: Date = Date()
    ) -> ContactGap? {
        guard let contact,
              StaleRule.wholeDays(from: contact, to: now) <= staleDays else { return nil }
        func lags(_ date: Date?) -> Bool {
            guard let date else { return true }
            return StaleRule.wholeDays(from: date, to: contact) > gapDays
        }
        if lags(checkIn) { return .binarySilent }
        if lags(inventory) { return .inventoryStale }
        return nil
    }

    /// The finding's name in the Health Audit.
    var findingName: String {
        switch self {
        case .binarySilent: "Jamf binary not checking in while MDM reaches the Mac"
        case .inventoryStale: "Inventory not updating while the Mac checks in"
        }
    }

    /// The short label for a table cell.
    var label: String {
        switch self {
        case .binarySilent: "Jamf binary silent"
        case .inventoryStale: "Inventory not updating"
        }
    }

    func recommendation(gapDays: Int) -> String {
        switch self {
        case .binarySilent:
            "Last Contact is current but Last Check-in is more than \(gapDays) days behind it: "
                + "MDM reaches these Macs and the Jamf binary does not. Check that the Jamf "
                + "binary is installed and its launch daemons are loaded, run "
                + "sudo jamf policy on the Mac, and check the network path to Jamf Pro."
        case .inventoryStale:
            "These Macs check in, but Last Inventory Update is more than \(gapDays) days behind "
                + "Last Contact. Run sudo jamf recon on the Mac, and check the scope of the "
                + "policy that submits inventory."
        }
    }
}
