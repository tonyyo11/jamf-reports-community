import Foundation

/// The products an environment (workspace) holds, and the device types in it. Screens, tabs and
/// Config tabs read this instead of asking each profile's auth method or product separately.
struct EnvironmentProducts: Equatable, Sendable {
    enum Product: String, CaseIterable, Sendable {
        case jamfPro, jamfSchool, platform, protect, securityCloud

        /// English, for reports and webhook cards (never localized).
        var displayName: String {
            switch self {
            case .jamfPro: return "Jamf Pro"
            case .jamfSchool: return "Jamf School"
            case .platform: return "Platform API"
            case .protect: return "Jamf Protect"
            case .securityCloud: return "Security Cloud"
            }
        }
    }

    var products: Set<Product>
    var composition: EnvironmentComposition

    /// A slot that is set is a product. A file without `profiles:` derives no Platform slot, so
    /// `legacyPlatformAuth` (the workspace's own profile logs in with the Platform API) adds it.
    static func from(
        _ environment: EnvironmentProfiles, composition: EnvironmentComposition,
        legacyPlatformAuth: Bool
    ) -> EnvironmentProducts {
        var set = Set<Product>()
        if environment.jamfPro != nil { set.insert(.jamfPro) }
        if environment.jamfSchool != nil { set.insert(.jamfSchool) }
        if environment.platform != nil
            || (environment.source == .legacyKeys && legacyPlatformAuth) {
            set.insert(.platform)
        }
        if environment.protect != nil { set.insert(.protect) }
        if environment.securityCloud != nil { set.insert(.securityCloud) }
        return EnvironmentProducts(products: set, composition: composition)
    }

    /// Every tab the demo shows today.
    static let demo = EnvironmentProducts(
        products: [.jamfPro, .platform, .protect], composition: .mixed)

    /// Jamf School is the MDM.
    var isSchool: Bool { has(.jamfSchool) && !has(.jamfPro) }
    /// Jamf Protect with no MDM.
    var isProtectOnly: Bool { has(.protect) && !has(.jamfPro) && !has(.jamfSchool) }

    func has(_ product: Product) -> Bool { products.contains(product) }

    /// Product names in display order, no profile names: safe for a webhook card.
    var orderedNames: [String] {
        Product.allCases.filter(has).map(\.displayName)
    }

    /// "Jamf Pro (Example), Jamf Protect (Example-Protect)" in display order; a name goes through
    /// `ConfigSchema.displayText`. Nil when the environment holds no product.
    static func headerLine(_ environment: EnvironmentProfiles) -> String? {
        let slots: [(Product, String?)] = [
            (.jamfPro, environment.jamfPro), (.jamfSchool, environment.jamfSchool),
            (.platform, environment.platform), (.protect, environment.protect),
            (.securityCloud, environment.securityCloud),
        ]
        let parts = slots.compactMap { product, name in
            name.map { "\(product.displayName) (\(ConfigSchema.displayText($0)))" }
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// The webhook `Products` value for a workspace, from its config.yaml; nil with no products.
    static func webhookValue(workspace: String) -> String? {
        let names = from(
            EnvironmentProfiles.read(workspace: workspace), composition: .unknown,
            legacyPlatformAuth: false
        ).orderedNames
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }
}
