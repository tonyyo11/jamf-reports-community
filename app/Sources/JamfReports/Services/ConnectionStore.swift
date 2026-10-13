import Foundation

/// JSON file of `Connection`s at `AppSupport.directory()/connections.json`: per Mac, never in a
/// workspace (which may be a shared folder), and never read in demo mode. Missing or corrupt
/// gives an empty list; writes are atomic and 0o600. Every method re-reads the file, so the GUI
/// and the tick process never overwrite each other's edits with a stale copy.
///
/// The records hold scope IDs. Nothing here logs them, and the diagnostic bundle never reads
/// this file (it seeds its redactor from `scopeIDs(sharingConnectionWith:)`).
struct ConnectionStore: Sendable {
    static var defaultURL: URL { AppSupport.directory().appendingPathComponent("connections.json") }
    let url: URL

    init(url: URL = ConnectionStore.defaultURL) { self.url = url }

    func load() -> [Connection] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        do {
            return try Self.decoder.decode([Connection].self, from: data)
        } catch {
            // The decode error is left out of the log: a type mismatch can quote the value.
            let aside = setAsideCorruptFile()
            AppLogger.auth.error(
                """
                connections.json could not be decoded — moved to \
                \(aside?.lastPathComponent ?? "(move failed)", privacy: .public)
                """
            )
            return []
        }
    }

    /// The next write replaces the whole file, so a corrupt one is moved to
    /// `connections.json.broken-<stamp>` first rather than overwritten.
    private func setAsideCorruptFile() -> URL? {
        let stamp = ScheduledRunRecorder.timestamp(from: Date())
        let aside = url.appendingPathExtension("broken-\(stamp)")
        do {
            try FileManager.default.moveItem(at: url, to: aside)
            return aside
        } catch {
            return nil
        }
    }

    func save(_ connections: [Connection]) throws {
        let data = try Self.encoder.encode(connections)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func upsert(_ connection: Connection) throws {
        var all = load().filter { $0.id != connection.id }
        // A profile belongs to one connection.
        let taken = Set(connection.members.map(\.profile))
        all = all.map { other in
            var copy = other
            copy.members.removeAll { taken.contains($0.profile) }
            return copy
        }.filter { !$0.members.isEmpty }
        all.append(connection)
        try save(all.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) })
    }

    func remove(id: UUID) throws {
        try save(load().filter { $0.id != id })
    }

    /// Drops one profile from its connection; a connection left with no member is removed.
    func removeMember(profile: String) throws {
        let all = load()
        guard all.contains(where: { $0.members.contains { $0.profile == profile } }) else { return }
        try save(all.compactMap { connection in
            var copy = connection
            copy.members.removeAll { $0.profile == profile }
            return copy.members.isEmpty ? nil : copy
        })
    }

    /// Records a profile that registered and validated. A profile already in a connection keeps
    /// it and its label, with its scope ID and product refreshed; any other starts a connection
    /// named after the profile.
    @discardableResult
    func recordMember(
        profile: String, scopeID: String, product: Connection.Member.Product,
        region: Connection.Region, level: Connection.Level, now: Date = Date()
    ) throws -> Connection {
        var all = load()
        if let index = all.firstIndex(where: { $0.members.contains { $0.profile == profile } }),
           let slot = all[index].members.firstIndex(where: { $0.profile == profile }) {
            all[index].members[slot].scopeID = scopeID
            all[index].members[slot].product = product
            try save(all)
            return all[index]
        }
        let connection = Connection(
            name: profile, region: region, level: level,
            members: [.init(profile: profile, scopeID: scopeID, product: product)],
            createdAt: now)
        all.append(connection)
        try save(all)
        return connection
    }

    /// The scope IDs of every profile in the same connection as `profile`, `profile` included,
    /// for seeding a redactor. Empty when the profile is in no connection.
    func scopeIDs(sharingConnectionWith profile: String) -> [String] {
        let found = load().first { $0.members.contains { $0.profile == profile } }
        guard let connection = found else { return [] }
        return connection.members.map(\.scopeID).filter { !$0.isEmpty }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
