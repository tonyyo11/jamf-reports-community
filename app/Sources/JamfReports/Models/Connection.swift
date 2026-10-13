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
            guard let host = URL(string: url)?.host?.lowercased(),
                  let first = host.split(separator: ".").first else { return .other }
            return Region(rawValue: String(first)) ?? .other
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

        init(profile: String, scopeID: String, label: String? = nil, product: Product = .unknown) {
            self.profile = profile
            self.scopeID = scopeID
            self.label = label ?? profile
            self.product = product
        }

        enum CodingKeys: String, CodingKey { case profile, scopeID, label, product }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            profile = try c.decode(String.self, forKey: .profile)
            scopeID = try c.decodeIfPresent(String.self, forKey: .scopeID) ?? ""
            label = try c.decodeIfPresent(String.self, forKey: .label) ?? profile
            product = (try? c.decodeIfPresent(Product.self, forKey: .product)) ?? .unknown
        }
    }

    var id: UUID
    var name: String
    var region: Region
    var level: Level
    var members: [Member]
    var createdAt: Date

    init(
        id: UUID = UUID(), name: String, region: Region, level: Level,
        members: [Member], createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.region = region
        self.level = level
        self.members = members
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey { case id, name, region, level, members, createdAt }

    /// Unknown future values for `region` and `level` and a bad date decode to a default, so
    /// one newer record cannot make the whole file unreadable.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        members = try c.decodeIfPresent([Member].self, forKey: .members) ?? []
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? members.first?.profile ?? ""
        region = (try? c.decodeIfPresent(Region.self, forKey: .region)) ?? .other
        level = (try? c.decodeIfPresent(Level.self, forKey: .level)) ?? .environment
        createdAt = (try? c.decodeIfPresent(Date.self, forKey: .createdAt))
            ?? Date(timeIntervalSince1970: 0)
    }
}
