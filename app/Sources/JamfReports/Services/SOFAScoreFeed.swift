import Foundation

/// What the score's two currency factors read from the cached macOS SOFA feed
/// (`jamf-cli-data/sofa/macos_data_feed.json`, written by `SOFAFeedService.refresh`): every
/// release of each major version with its date, and the newest XProtect.
struct SOFAScoreFeed: Sendable, Equatable {
    struct Release: Sendable, Equatable {
        let version: String
        let date: Date
    }

    /// Releases by major version, newest version first.
    let releasesByMajor: [Int: [Release]]
    let xprotectVersion: Int?
    let xprotectReleased: Date?

    static func load(dataDir: URL) -> SOFAScoreFeed? {
        let url = dataDir.appendingPathComponent("sofa", isDirectory: true)
            .appendingPathComponent("macos_data_feed.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }

    static func decode(_ data: Data) -> SOFAScoreFeed? {
        guard let feed = try? JSONDecoder().decode(Feed.self, from: data) else { return nil }
        var byMajor: [Int: [Release]] = [:]
        for entry in feed.osVersions {
            let listed = entry.securityReleases + [entry.latest].compactMap { $0 }
            for item in listed {
                guard let version = item.productVersion?.trimmingCharacters(in: .whitespaces),
                      let major = SOFAFeedService.versionTuple(version).first,
                      let date = item.releaseDate.flatMap(Self.date(from:))
                else { continue }
                var releases = byMajor[major] ?? []
                if !releases.contains(where: { $0.version == version }) {
                    releases.append(Release(version: version, date: date))
                }
                byMajor[major] = releases
            }
        }
        for (major, releases) in byMajor {
            byMajor[major] = releases.sorted {
                SOFAFeedService.compareTuples(
                    SOFAFeedService.versionTuple($0.version),
                    SOFAFeedService.versionTuple($1.version)) > 0
            }
        }
        let xprotect = feed.xprotectConfig?.version.flatMap {
            Int($0.trimmingCharacters(in: .whitespaces))
        }
        let released = feed.xprotectConfig?.releaseDate.flatMap(Self.date(from:))
        return SOFAScoreFeed(
            releasesByMajor: byMajor, xprotectVersion: xprotect, xprotectReleased: released)
    }

    /// Whether `version` counts as current with `graceDays`: at least the newest release of
    /// its major that came out `graceDays` or more before `now`. True when every release of
    /// that major is newer than that (nothing is required yet); nil for a major the feed does
    /// not list, a version that does not parse, or a major whose releases are all dated in the
    /// future (a feed cannot be trusted to say nothing is required).
    func isCurrent(_ version: String, graceDays: Int, now: Date) -> Bool? {
        let tuple = SOFAFeedService.versionTuple(version)
        guard let major = tuple.first, let releases = releasesByMajor[major] else { return nil }
        let dated = releases.filter { !Self.isFutureDated($0.date, now: now) }
        guard !dated.isEmpty else { return nil }
        let cutoff = now.addingTimeInterval(-Double(graceDays) * 86_400)
        guard let required = dated.first(where: { $0.date <= cutoff }) else { return true }
        return SOFAFeedService.compareTuples(
            tuple, SOFAFeedService.versionTuple(required.version)) >= 0
    }

    /// Whether an XProtect version counts as current: at least the newest, or the newest came
    /// out less than `graceDays` before `now`. Nil when the feed has no XProtect version.
    func isXProtectCurrent(_ version: Int, graceDays: Int, now: Date) -> Bool? {
        guard let latest = xprotectVersion else { return nil }
        if version >= latest { return true }
        guard let released = xprotectReleased else { return false }
        guard !Self.isFutureDated(released, now: now) else { return false }
        return now.timeIntervalSince(released) < Double(graceDays) * 86_400
    }

    /// The feed is trusted on TLS alone, so a release dated ahead of now would otherwise stretch
    /// the grace period without bound. A day of allowance covers time zones on release day.
    private static func isFutureDated(_ date: Date, now: Date) -> Bool {
        date > now.addingTimeInterval(86_400)
    }

    private static func date(from raw: String) -> Date? {
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: raw) { return date }
        iso.formatOptions = [.withFullDate]
        return iso.date(from: String(raw.prefix(10)))
    }

    /// Every field is read on its own: a value of another type costs that field, a release
    /// that lacks what a factor needs is skipped by `decode`, and the rest of the feed stands.
    private struct Feed: Decodable {
        let osVersions: [Entry]
        let xprotectConfig: XProtectConfig?

        enum CodingKeys: String, CodingKey {
            case osVersions = "OSVersions"
            case xprotectConfig = "XProtectPlistConfigData"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            osVersions = (try? c.decodeIfPresent([Lossy<Entry>].self, forKey: .osVersions))?
                .compactMap(\.value) ?? []
            xprotectConfig = try? c.decodeIfPresent(XProtectConfig.self, forKey: .xprotectConfig)
        }
    }

    /// A list element that fails to decode is nil, not a failure of the whole list.
    private struct Lossy<Value: Decodable>: Decodable {
        let value: Value?

        init(from decoder: Decoder) throws {
            value = try? Value(from: decoder)
        }
    }

    /// A value of another type reads as absent rather than failing the whole feed.
    private struct XProtectConfig: Decodable {
        let version: String?
        let releaseDate: String?

        enum CodingKeys: String, CodingKey {
            case version = "com.apple.XProtect"
            case releaseDate = "ReleaseDate"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try? c.decodeIfPresent(String.self, forKey: .version)
            releaseDate = try? c.decodeIfPresent(String.self, forKey: .releaseDate)
        }
    }

    private struct Entry: Decodable {
        let latest: Item?
        let securityReleases: [Item]

        enum CodingKeys: String, CodingKey {
            case latest = "Latest"
            case securityReleases = "SecurityReleases"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            latest = try? c.decodeIfPresent(Item.self, forKey: .latest)
            securityReleases = (try? c.decodeIfPresent(
                [Lossy<Item>].self, forKey: .securityReleases))?.compactMap(\.value) ?? []
        }
    }

    private struct Item: Decodable {
        let productVersion: String?
        let releaseDate: String?

        enum CodingKeys: String, CodingKey {
            case productVersion = "ProductVersion"
            case releaseDate = "ReleaseDate"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            productVersion = try? c.decodeIfPresent(String.self, forKey: .productVersion)
            releaseDate = try? c.decodeIfPresent(String.self, forKey: .releaseDate)
        }
    }
}
