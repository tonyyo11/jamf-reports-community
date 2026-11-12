import Foundation

/// A Mac that enrolled through Automated Device Enrollment but never received the Jamf binary
/// (the "DEP - <serial>" records of #274): Jamf Pro lists it as not managed, or as managed
/// with no inventory ever (MDM reaches it, the binary never ran), and it has never
/// checked in. It is neither stale nor a contact gap, because nothing is broken that a wait or
/// a `jamf recon` would fix; it needs a person.
///
/// Detected from data, never from the name, which admins rename.
enum BinaryMissing {
    /// What the app calls the state.
    static var title: String { L("Jamf binary missing") }
    /// The cell value in a table.
    static var shortLabel: String { L("Jamf binary missing") }

    /// The three ways to get the binary onto the Mac, in the order to try them.
    static var remediation: [String] {
        [
            L("Mark the computer as managed in Jamf Pro, so it tries to push the binary again."),
            L("Deploy the Jamf binary through the API or another tool."),
            L("Run sudo profiles renew -type enrollment on the Mac to restart enrollment."),
        ]
    }

    /// The one rule: the Mac has never checked in and Jamf either reports it unmanaged or has
    /// never had an inventory from it (`NeverInventoried`: MDM reaches it, so it can read as
    /// managed, but the binary never ran). An unknown managed state with an inventory is not
    /// flagged, so a source that does not carry the field flags nothing.
    static func isMissing(
        managedState: String, neverCheckedIn: Bool, neverInventoried: Bool = false
    ) -> Bool {
        neverCheckedIn && (isUnmanaged(managedState) || neverInventoried)
    }

    /// The one reader of a managed-state text: true for `true`, `yes`, `1`, `Managed`, false for
    /// `false`, `no`, `0`, `Unmanaged`, nil for anything else (blank, unknown).
    static func managed(_ managedState: String) -> Bool? {
        let text = managedState.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["true", "yes", "1", "managed"].contains(text) { return true }
        if ["false", "no", "0", "unmanaged"].contains(text) { return false }
        return nil
    }

    /// True only for a value that says unmanaged (`false`, `no`, `0`, `Unmanaged`).
    static func isUnmanaged(_ managedState: String) -> Bool {
        managed(managedState) == false
    }

    /// The "Needs attention" line, "3 Macs enrolled but never received the Jamf binary."
    static func attentionSentence(count: Int) -> String {
        let macs = count == 1 ? L("1 Mac") : L("\(count) Macs")
        return L("\(macs) enrolled but never received the Jamf binary: never checked in, and not managed or never inventoried. Mark each computer as managed in Jamf Pro, deploy the binary another way, or run sudo profiles renew -type enrollment on the Mac.")
    }
}

extension DeviceInventoryRecord {
    /// The Mac has never checked in and is unmanaged or never inventoried. Needs a source that
    /// dates every Mac (the `computers` snapshot): a blank check-in elsewhere means other things.
    var isBinaryMissing: Bool {
        BinaryMissing.isMissing(
            managedState: managedState,
            neverCheckedIn: carriesDates && checkInDate == nil && daysSinceContact == nil
                && lastContact.isEmpty,
            neverInventoried: neverInventoried)
    }
}
