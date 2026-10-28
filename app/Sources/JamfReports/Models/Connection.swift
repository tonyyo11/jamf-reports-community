import Foundation

/// One Jamf Platform API credential and the jamf-cli profiles registered from it.
///
/// jamf-cli holds a single environment (or tenant) per profile, so reaching several
/// environments with one Jamf Account integration means one profile per ID, all sharing the
/// client ID and secret. `config list` shows neither the client ID nor which profiles share it,
/// so the app records the grouping itself, per Mac, in `ConnectionStore`. Collect, pins,
/// schedules and Run History stay keyed by profile name; a connection only groups profiles for
/// display and, later, for credential updates. It holds no secret and no client ID.
struct Connection: Codable, Sendable, Equatable, Identifiable {
    enum Region: String, Codable, Sendable, Equatable {
        case us, eu, apac
        /// A gateway host this build does not recognise.
        case other

        /// The region named by a gateway URL's host (`https://eu.api.jamfcloud.com`).
        static func region(forGatewayURL url: String) -> Region {
            GatewayRegion.region(forURL: url).flatMap { Region(rawValue: $0.rawValue) } ?? .other
        }
    }

    enum Level: String, Codable, Sendable, Equatable {
        case environment, tenant
    }

    /// One registered profile. `scopeID` is the environment or tenant ID: sensitive like any
    /// tenant ID, so it is never logged and the diagnostic bundle redacts it.
    struct Member: Codable, Sendable, Equatable {
        enum Product: String, Codable, Sendable, Equatable { case pro, school, unknown }

        var profile: String
        var scopeID: String
        var label: String
        var product: Product
        /// The Jamf Pro server this profile reaches through the gateway, once learned
        /// (`pro jamf-pro-server-url get`). A platform profile's own URL is the gateway, so this
        /// is what links it to an oauth2 profile for the same instance. Nil until learned.
        var jamfProURL: String?

        init(
            profile: String, scopeID: String, label: String? = nil, product: Product = .unknown,
            jamfProURL: String? = nil
        ) {
            self.profile = profile
            self.scopeID = scopeID
            self.label = label ?? profile
            self.product = product
            self.jamfProURL = jamfProURL
        }

        enum CodingKeys: String, CodingKey { case profile, scopeID, label, product, jamfProURL }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            profile = try c.decode(String.self, forKey: .profile)
            scopeID = try c.decodeIfPresent(String.self, forKey: .scopeID) ?? ""
            label = try c.decodeIfPresent(String.self, forKey: .label) ?? profile
            product = (try? c.decodeIfPresent(Product.self, forKey: .product)) ?? .unknown
            jamfProURL = (try? c.decodeIfPresent(String.self, forKey: .jamfProURL)) ?? nil
        }
    }

    var id: UUID
    var name: String
    var region: Region
    /// The gateway URL of an `other` region, so Add environments and Update credentials for all
    /// can reach it; nil for the three Jamf Cloud regions, whose host the region names.
    var gatewayURL: String?
    var level: Level
    var members: [Member]
    var createdAt: Date
    /// jamf-cli profiles this app registered in Add environments that the check did not confirm,
    /// so they are in no connection yet. Only these may be registered again with the same label:
    /// a profile of the same shape made in Terminal is not in this list. Names, not secrets.
    var unconfirmedProfiles: [String]

    init(
        id: UUID = UUID(), name: String, region: Region, level: Level,
        members: [Member], createdAt: Date = Date(), unconfirmedProfiles: [String] = [],
        gatewayURL: String? = nil
    ) {
        self.gatewayURL = gatewayURL
        self.id = id
        self.name = name
        self.region = region
        self.level = level
        self.members = members
        self.createdAt = createdAt
        self.unconfirmedProfiles = unconfirmedProfiles
    }

    enum CodingKeys: String, CodingKey {
        case id, name, region, level, members, createdAt, unconfirmedProfiles, gatewayURL
    }

    /// Unknown future values for `region` and `level` and a bad date decode to a default, so
    /// one newer record cannot make the whole file unreadable.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        members = try c.decodeIfPresent([Member].self, forKey: .members) ?? []
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? members.first?.profile ?? ""
        region = (try? c.decodeIfPresent(Region.self, forKey: .region)) ?? .other
        gatewayURL = (try? c.decodeIfPresent(String.self, forKey: .gatewayURL)) ?? nil
        level = (try? c.decodeIfPresent(Level.self, forKey: .level)) ?? .environment
        createdAt = (try? c.decodeIfPresent(Date.self, forKey: .createdAt))
            ?? Date(timeIntervalSince1970: 0)
        unconfirmedProfiles = (try? c.decodeIfPresent([String].self, forKey: .unconfirmedProfiles))
            ?? []
    }
}
