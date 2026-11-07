import Foundation

/// The products an environment (workspace) holds, and the device types in it. Screens, tabs and
/// Config tabs read this instead of asking each profile's auth method or product separately.
struct EnvironmentProducts: Equatable, Sendable {
    enum Product: String, CaseIterable, Sendable {
        case jamfPro, jamfSchool, platform, protect, securityCloud
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
}
