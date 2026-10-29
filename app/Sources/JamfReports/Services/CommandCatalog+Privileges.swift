import Foundation

extension CommandCatalog {

    /// One Jamf Pro API role privilege for the setup text, with where the name came from.
    struct Privilege: Sendable, Equatable, Hashable {
        enum Source: String, Sendable {
            case jamfCLI = "jamf-cli"
            case jamfReports = "Jamf Reports"
        }

        let name: String
        let source: Source

        /// Both lists as one, sorted by name; a name jamf-cli lists is jamf-cli's.
        static func merged(listed: [String], supplemental: [String]) -> [Privilege] {
            let fromCLI = Set(listed)
            let all = fromCLI.map { Privilege(name: $0, source: .jamfCLI) }
                + Set(supplemental).subtracting(fromCLI)
                    .map { Privilege(name: $0, source: .jamfReports) }
            return all.sorted { $0.name < $1.name }
        }
    }

    /// Privileges for the commands whose catalog row lists none: every `pro report` row and the
    /// `pro classic-*` list rows (1.31.1). Hand-kept from the by-report table in
    /// `docs/wiki/13-Permissions-and-Access.md`, which uses the names the API role editor shows
    /// in Jamf Pro 11.32. `CommandCatalog.collectPrivileges` applies an entry only while the
    /// catalog still lists none for that command, and `CommandCatalogTests` fails when a key's
    /// row gains a list, so a name jamf-cli takes over stops being ours.
    ///
    /// Not mapped, by design: `pro overview` (the table does not name its need) and the Platform
    /// API reports `compliance-devices`, `compliance-rules`, `ddm-status` and
    /// `blueprint-status`, which need a Jamf Account permission, not an API role.
    static let supplementalPrivileges: [String: [String]] = [
        "pro report security": computers,
        "pro report inventory-summary": computers,
        "pro report device-compliance": computers,
        "pro report software-installs": computers,
        "pro report duplicate-serials": computers,
        "pro report patch-status": [
            "Read Patch Management Software Titles", "Read Patch Policies", "Read Computers",
            "Read Mobile Devices",
        ],
        "pro report update-status": [
            "Read Managed Software Updates", "Read Computers", "Read Mobile Devices",
        ],
        "pro report policy-status": ["Read Policies"],
        "pro classic-policies list": ["Read Policies"],
        "pro report profile-status": profilesAndApps,
        "pro report app-status": profilesAndApps,
        "pro classic-macos-config-profiles list": ["Read macOS Configuration Profiles"],
        "pro classic-mobile-config-profiles list": ["Read iOS Configuration Profiles"],
        "pro report ea-results": ["Read Computer Extension Attributes", "Read Computers"],
        "pro groups list": computerGroups,
        "pro classic-computer-groups list": computerGroups,
        "pro classic-mobile-device-groups list": [
            "Read Smart Mobile Device Groups", "Read Static Mobile Device Groups",
        ],
        "pro audit": [
            "Read Policies", "Read Categories", "Read Self Service", "Read Smart Computer Groups",
            "Read Static Computer Groups", "Read Device Enrollment Program Instances",
            "Read Computer PreStage Enrollments", "View MDM command information in Jamf Pro API",
            "Read Computers",
        ],
        // Its only caller is the weekly scan behind `mdm-command-health`.
        "pro classic-computer-history get": ["Read Computers", "Read Mobile Devices"],
    ]

    private static let computers = ["Read Computers"]

    private static let computerGroups = ["Read Smart Computer Groups", "Read Static Computer Groups"]

    private static let profilesAndApps = [
        "Read macOS Configuration Profiles", "Read iOS Configuration Profiles",
        "Read Mac Applications", "Read Mobile Device Applications",
        "View MDM command information in Jamf Pro API", "Read Computers", "Read Mobile Devices",
    ]
}
