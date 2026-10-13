import Foundation

/// The Jamf product a jamf-cli profile logs in to. `config list -o json` does not say, so
/// `ProfileService.derivedProduct` works it out from the profile's `product:` key in jamf-cli's
/// own config file, then its auth method, then its host.
enum JamfCLIProduct: String, Sendable, Equatable {
    case pro, protect, school, securityCloud
    /// Nothing says which: treated like Jamf Pro, as before product detection existed.
    case unknown

    /// A Protect or Security Cloud login: never a workspace or run target, even with a folder.
    var isNeverAWorkspace: Bool { self == .protect || self == .securityCloud }

    /// Whether the profile can be a Jamf Pro workspace. Protect and Security Cloud logins hold
    /// no Jamf Pro data; a Jamf School login is a Jamf School workspace, not a Pro one.
    var canBeProWorkspace: Bool { self == .pro || self == .unknown }

    var displayName: String {
        switch self {
        case .pro, .unknown: "Jamf Pro"
        case .protect: "Jamf Protect"
        case .school: "Jamf School"
        case .securityCloud: "Jamf Security Cloud"
        }
    }
}

/// The level a Jamf Platform API integration was created at in Jamf Account. A profile names
/// one environment ID, one tenant ID, or neither.
enum PlatformScopeLevel: String, Sendable, Equatable {
    case environment, tenant
    /// Neither ID: the integration reaches Jamf Account only, so no Jamf Pro command works.
    case organization

    /// Environment wins when both are set (jamf-cli's `config validate` calls that a fault).
    static func level(environmentID: String?, tenantID: String?) -> PlatformScopeLevel {
        func present(_ value: String?) -> Bool {
            !(value?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
        }
        if present(environmentID) { return .environment }
        return present(tenantID) ? .tenant : .organization
    }
}

extension PlatformScopeLevel {
    /// Why an organization-level profile cannot be a workspace, in the words every screen, log
    /// line and Config Doctor row uses.
    static let organizationLevelReason = "An organization-level integration reaches only Jamf "
        + "Account. Create an environment-level integration in Jamf Account and add that "
        + "profile instead."
}
