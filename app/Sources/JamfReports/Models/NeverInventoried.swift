import Foundation

/// A Mac that has never sent Jamf Pro an inventory: MDM-enrolled (it can even read as managed)
/// but with no OS version and no inventory date, because the Jamf binary never ran. Jamf still
/// returns its security fields (`firewallEnabled: false`, a blank FileVault state), which read as
/// "off" when they mean "never reported". Such a Mac counts as a Mac and reports no control.
enum NeverInventoried {
    /// A `pro report security` device row. Only an `os_version` present and blank counts: a row
    /// without the key (an older jamf-cli) is no evidence.
    static func isNeverInventoried(osVersion: String?) -> Bool {
        osVersion?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true
    }

    /// A `computers` snapshot item whose `general.reportDate` and `operatingSystem.version` are
    /// both present and null or blank. A key that is missing is no evidence.
    static func isNeverInventoried(computer item: [String: Any]) -> Bool {
        presentAndBlank("reportDate", in: item["general"])
            && presentAndBlank("version", in: item["operatingSystem"])
    }

    private static func presentAndBlank(_ key: String, in section: Any?) -> Bool {
        guard let section = section as? [String: Any], let value = section[key] else {
            return false
        }
        if value is NSNull { return true }
        return (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true
    }
}
