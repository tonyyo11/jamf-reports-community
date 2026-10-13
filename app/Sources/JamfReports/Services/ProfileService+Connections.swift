import Foundation

/// Profiles arranged by connection, for the sidebar menu and Fleet Overview.
struct ConnectionGrouping: Sendable {
    struct Section: Identifiable, Sendable {
        struct Entry: Identifiable, Sendable {
            let profile: JamfCLIProfile
            /// The member's label, which defaults to the profile name.
            let label: String
            var id: String { profile.name }
        }

        let connection: Connection
        let entries: [Entry]
        var id: UUID { connection.id }
    }

    let sections: [Section]
    /// Profiles in no connection, in discovery order.
    let ungrouped: [JamfCLIProfile]

    var hasConnections: Bool { !sections.isEmpty }
}

extension ProfileService {
    /// Which discovered profiles sit under which connection. A member whose profile is no longer
    /// discovered is left out of the result (the store keeps it, since a profile can reappear),
    /// and a connection with no discovered member shows no section. A profile named by two
    /// connections lands under the older one. Sections follow `createdAt`; entries keep the
    /// connection's member order.
    static func connectionGrouping(
        profiles: [JamfCLIProfile], connections: [Connection]
    ) -> ConnectionGrouping {
        let byName = Dictionary(
            profiles.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var placed = Set<String>()
        typealias Entry = ConnectionGrouping.Section.Entry
        var sections: [ConnectionGrouping.Section] = []
        let ordered = connections.sorted {
            ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString)
        }
        for connection in ordered {
            let entries = connection.members.compactMap { member -> Entry? in
                guard let profile = byName[member.profile],
                      placed.insert(member.profile).inserted else { return nil }
                return .init(profile: profile, label: member.label)
            }
            if !entries.isEmpty { sections.append(.init(connection: connection, entries: entries)) }
        }
        return ConnectionGrouping(
            sections: sections, ungrouped: profiles.filter { !placed.contains($0.name) })
    }
}
