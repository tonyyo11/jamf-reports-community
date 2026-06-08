import Foundation

// MARK: - SOFAFeedService

/// Reads and refreshes the macadmins SOFA OS-version feeds.
///
/// **Read path:** loads each platform feed from the shared cache at
/// `<workspace>/jamf-cli-data/sofa/<platform>_data_feed.json`. Python's
/// `SOFAFeedClient` writes to the same location, so both engines share a
/// single cached copy per workspace.
///
/// **Refresh path:** downloads all 4 platform feeds from SOFA v2 via
/// URLSession (TLS — no curl needed in Swift) and atomically replaces each
/// cached file on success. Failures preserve the existing cache and surface
/// a warning string rather than throwing, so callers can render partial data.
///
/// Inject `referenceDate` in tests to pin "today" for deterministic
/// `daysSinceRelease` computation (mirrors Python's `reference_date` param).
struct SOFAFeedService: Sendable {

    // MARK: - Platform constants

    /// SOFA v2 base URL — one feed per platform slug.
    static let feedBaseURL = "https://sofafeed.macadmins.io/v2"

    /// All four platform slugs.
    static let allPlatforms: [String] = ["macos", "ios", "tvos", "watchos"]

    /// Platform slug → human-readable report label.
    /// Must match Python's `SOFA_PLATFORM_LABELS` exactly — fleet currency join
    /// uses string equality on these labels.
    static let platformLabels: [String: String] = [
        "macos":   "macOS",
        "ios":     "iOS / iPadOS",
        "tvos":    "tvOS",
        "watchos": "watchOS",
    ]

    // MARK: - Model

    /// One normalized OS-family row, ready for the "OS Currency" sheet and view.
    struct OSFamilyRow: Sendable, Equatable {
        let platform: String         // e.g. "macOS"
        let osFamily: String         // e.g. "Tahoe 26"
        let productVersion: String   // e.g. "26.5.1"
        let build: String            // e.g. "25F80"
        let releaseDate: String      // ISO date only, e.g. "2026-06-01" (empty when missing)
        let daysSinceRelease: Int?   // nil when releaseDate is absent
        let activelyExploitedCVEs: Int
        let securityInfoURL: String
    }

    /// Full SOFA snapshot ready for rendering.
    struct Snapshot: Sendable {
        let rows: [OSFamilyRow]
        let loadedAt: Date
        /// Warning messages from individual platform loads (non-fatal).
        let warnings: [String]

        static let empty = Snapshot(rows: [], loadedAt: .distantPast, warnings: [])
    }

    // MARK: - Read path

    /// Load cached SOFA feeds from `dataDir/sofa/` for all platforms.
    ///
    /// - Parameters:
    ///   - dataDir: The workspace's `jamf-cli-data` directory URL.
    ///   - referenceDate: "Today" for daysSinceRelease. Defaults to `Date()`.
    /// - Returns: A `Snapshot` with one row per OS family across all platforms.
    ///            Empty when no cache files exist.
    static func load(dataDir: URL, referenceDate: Date = Date()) -> Snapshot {
        let sofaDir = dataDir.appendingPathComponent("sofa", isDirectory: true)
        var rows: [OSFamilyRow] = []
        var warnings: [String] = []
        for platform in allPlatforms {
            let cacheURL = sofaDir.appendingPathComponent("\(platform)_data_feed.json")
            guard FileManager.default.fileExists(atPath: cacheURL.path) else { continue }
            guard let data = try? Data(contentsOf: cacheURL),
                  let feed = try? JSONDecoder().decode(SOFAFeed.self, from: data)
            else {
                warnings.append("Could not decode SOFA cache for \(platform)")
                continue
            }
            rows.append(contentsOf: normalizeFeed(platform: platform, feed: feed,
                                                  referenceDate: referenceDate))
        }
        return Snapshot(rows: rows, loadedAt: Date(), warnings: warnings)
    }

    /// Load from a single fixture file for tests.
    static func load(from url: URL, platform: String, referenceDate: Date = Date()) -> [OSFamilyRow] {
        guard let data = try? Data(contentsOf: url),
              let feed = try? JSONDecoder().decode(SOFAFeed.self, from: data)
        else { return [] }
        return normalizeFeed(platform: platform, feed: feed, referenceDate: referenceDate)
    }

    // MARK: - Refresh path

    /// Download all platform feeds, write atomically to `dataDir/sofa/`, and
    /// return a fresh `Snapshot`. On per-platform failure, keeps the existing
    /// cache and adds a warning — never throws.
    ///
    /// - Parameters:
    ///   - dataDir: The workspace's `jamf-cli-data` directory URL.
    ///   - timeout: Per-feed download timeout. Defaults to 30 seconds.
    ///   - referenceDate: "Today" for daysSinceRelease.
    /// - Returns: A `Snapshot` from the post-refresh state (mix of fresh and cached).
    static func refresh(
        dataDir: URL,
        timeout: TimeInterval = 30,
        referenceDate: Date = Date()
    ) async -> (Snapshot, [String]) {
        let sofaDir = dataDir.appendingPathComponent("sofa", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: sofaDir, withIntermediateDirectories: true)
        } catch {
            let msg = "SOFA: could not create cache dir — \(error.localizedDescription)"
            return (.empty, [msg])
        }

        var rows: [OSFamilyRow] = []
        var warnings: [String] = []

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout + 5
        let session = URLSession(configuration: config)

        for platform in allPlatforms {
            let urlString = "\(feedBaseURL)/\(platform)_data_feed.json"
            guard let url = URL(string: urlString) else {
                warnings.append("SOFA: invalid URL for \(platform)")
                continue
            }
            do {
                let (data, response) = try await session.data(from: url)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    throw URLError(.badServerResponse)
                }
                // Validate the shape before caching.
                let feed = try JSONDecoder().decode(SOFAFeed.self, from: data)
                writeCacheAtomic(data: data, to: sofaDir
                    .appendingPathComponent("\(platform)_data_feed.json"))
                rows.append(contentsOf: normalizeFeed(platform: platform, feed: feed,
                                                      referenceDate: referenceDate))
            } catch {
                let msg = "SOFA \(platform): fetch failed (\(error.localizedDescription)); using cached feed"
                warnings.append(msg)
                // Fall back to existing cache.
                let cacheURL = sofaDir.appendingPathComponent("\(platform)_data_feed.json")
                if let data = try? Data(contentsOf: cacheURL),
                   let feed = try? JSONDecoder().decode(SOFAFeed.self, from: data) {
                    rows.append(contentsOf: normalizeFeed(platform: platform, feed: feed,
                                                          referenceDate: referenceDate))
                }
            }
        }
        return (Snapshot(rows: rows, loadedAt: Date(), warnings: warnings), warnings)
    }

    // MARK: - Internal helpers

    /// Parse a SOFA date string into a `Date`.
    ///
    /// Handles both ISO timestamp format (`2026-06-01T00:00:00Z`, used by macOS/iOS)
    /// and date-only format (`2026-05-11`, used by tvOS/watchOS).
    static func parseSOFADate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Try full ISO 8601 first.
        let isoFull = ISO8601DateFormatter()
        isoFull.formatOptions = [.withInternetDateTime]
        if let d = isoFull.date(from: trimmed) { return d }
        // Alternate: no fractional seconds.
        let isoAlt = ISO8601DateFormatter()
        isoAlt.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withTimeZone]
        if let d = isoAlt.date(from: trimmed) { return d }
        // Date-only ("2026-05-11").
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = TimeZone(identifier: "UTC")
        return df.date(from: String(trimmed.prefix(10)))
    }

    /// Parse a dotted version string into an array of Int components for comparison.
    /// "15.7.10" → [15, 7, 10]. Non-numeric leading chars become 0.
    static func versionTuple(_ version: String) -> [Int] {
        version.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ".")
            .map { component -> Int in
                let s = String(component)
                // Take the leading digits only ("0-rc1" → 0).
                let digits = s.prefix(while: { $0.isNumber })
                return Int(digits) ?? 0
            }
    }

    /// Returns (onLatest, behind) counts for one OS family against its SOFA latest.
    ///
    /// Only devices whose major version matches the family's major are counted.
    /// A device is "on latest" when its full version tuple >= familyLatest tuple.
    static func fleetCurrency(latestVersion: String, osCounts: [String: Int]) -> (Int, Int) {
        let latestTuple = versionTuple(latestVersion)
        guard !latestTuple.isEmpty else { return (0, 0) }
        let major = latestTuple[0]
        var onLatest = 0
        var behind = 0
        for (version, count) in osCounts {
            let devTuple = versionTuple(version)
            guard !devTuple.isEmpty, devTuple[0] == major else { continue }
            if compareTuples(devTuple, latestTuple) >= 0 {
                onLatest += count
            } else {
                behind += count
            }
        }
        return (onLatest, behind)
    }

    /// Returns (eolDevices, eolVersionCount) for devices older than every tracked family.
    ///
    /// Devices whose major < min(familyMajors) have no supported OS — EOL row.
    static func fleetEOLCount(familyMajors: Set<Int>, osCounts: [String: Int]) -> (Int, Int) {
        guard !familyMajors.isEmpty else { return (0, 0) }
        let oldestSupported = familyMajors.min()!
        var devices = 0
        var versions = 0
        for (version, count) in osCounts {
            let devTuple = versionTuple(version)
            guard !devTuple.isEmpty, devTuple[0] < oldestSupported else { continue }
            devices += count
            versions += 1
        }
        return (devices, versions)
    }

    // MARK: - Private

    private static func normalizeFeed(
        platform: String,
        feed: SOFAFeed,
        referenceDate: Date
    ) -> [OSFamilyRow] {
        let label = platformLabels[platform] ?? platform
        var result: [OSFamilyRow] = []
        for entry in feed.osVersions {
            guard let latest = entry.latest else { continue }
            let product = latest.productVersion.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !product.isEmpty else { continue }
            let parsedDate = parseSOFADate(latest.releaseDate ?? "")
            let daysAgo: Int?
            if let pd = parsedDate {
                let diff = Calendar.current.dateComponents([.day], from: pd, to: referenceDate)
                daysAgo = max(0, diff.day ?? 0)
            } else {
                daysAgo = nil
            }
            let relStr: String
            if let pd = parsedDate {
                let df = DateFormatter()
                df.locale = Locale(identifier: "en_US_POSIX")
                df.dateFormat = "yyyy-MM-dd"
                relStr = df.string(from: pd)
            } else {
                relStr = ""
            }
            let cveCount = latest.activelyExploitedCVEs?.count ?? 0
            result.append(OSFamilyRow(
                platform: label,
                osFamily: entry.osVersion,
                productVersion: product,
                build: latest.build ?? "",
                releaseDate: relStr,
                daysSinceRelease: daysAgo,
                activelyExploitedCVEs: cveCount,
                securityInfoURL: latest.securityInfo ?? ""
            ))
        }
        return result
    }

    private static func writeCacheAtomic(data: Data, to url: URL) {
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).partial")
        do {
            try data.write(to: tmp)
            // replaceItem requires the destination to exist; use move when it doesn't.
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            let msg = "SOFAFeedService: could not write cache \(url.lastPathComponent): " +
                      error.localizedDescription
            AppLogger.engine.warning("\(msg, privacy: .private)")
        }
    }

    /// Lexicographic compare on Int arrays.  Returns 0 if equal, >0 if a > b, <0 if a < b.
    private static func compareTuples(_ a: [Int], _ b: [Int]) -> Int {
        let len = max(a.count, b.count)
        for i in 0..<len {
            let av = i < a.count ? a[i] : 0
            let bv = i < b.count ? b[i] : 0
            if av != bv { return av - bv }
        }
        return 0
    }
}

// MARK: - SOFAFeed Codable

/// Decodable shape for the SOFA v2 feed JSON.
struct SOFAFeed: Decodable, Sendable {
    let osVersions: [SOFAOSEntry]

    private enum CodingKeys: String, CodingKey {
        case osVersions = "OSVersions"
    }
}

struct SOFAOSEntry: Decodable, Sendable {
    let osVersion: String
    let latest: SOFALatest?

    private enum CodingKeys: String, CodingKey {
        case osVersion = "OSVersion"
        case latest = "Latest"
    }
}

struct SOFALatest: Decodable, Sendable {
    let productVersion: String
    let build: String?
    let releaseDate: String?
    let securityInfo: String?
    let activelyExploitedCVEs: [String]?

    private enum CodingKeys: String, CodingKey {
        case productVersion = "ProductVersion"
        case build = "Build"
        case releaseDate = "ReleaseDate"
        case securityInfo = "SecurityInfo"
        case activelyExploitedCVEs = "ActivelyExploitedCVEs"
    }
}
