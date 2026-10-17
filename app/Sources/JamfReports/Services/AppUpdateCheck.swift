import Foundation
import Observation

/// Checks GitHub for a newer stable release of this app and reports it. Nothing is downloaded
/// or installed: updating stays the user's choice, since a release can change behaviour they
/// rely on. Pre-releases (beta, RC) are never offered.
enum AppUpdateCheck {

    /// The Settings switch, on by default. A configuration profile that sets this key in the
    /// app's preference domain turns the check off for every user (`isForcedByProfile`).
    static let enabledKey = "checkForAppUpdates"
    static let lastCheckKey = "appUpdateLastCheck"
    static let latestVersionKey = "appUpdateLatestVersion"
    static let skippedVersionKey = "appUpdateSkippedVersion"

    /// `releases/latest` never returns a draft or a release marked pre-release.
    static let latestReleaseURL =
        URL(string: "https://api.github.com/repos/tonyyo11/jamf-reports-community/releases/latest")!
    static let releasesPage =
        URL(string: "https://github.com/tonyyo11/jamf-reports-community/releases")!
    static let checkInterval: TimeInterval = 24 * 60 * 60
    /// A release document is a few KB; anything past this is not one.
    static let maxResponseBytes = 1_048_576
    static let requestTimeout: TimeInterval = 15

    struct Release: Equatable, Sendable {
        /// The version without its `v`, e.g. `2.10.1`; digits and dots only (`stableVersion`).
        let version: String

        /// This project's page for the release, built from the version rather than taken from
        /// the answer, so it can only open this project's release notes.
        var page: URL {
            URL(string: "\(releasesPage.absoluteString)/tag/v\(version)") ?? releasesPage
        }
    }

    enum Outcome: Equatable, Sendable {
        case upToDate(latest: String)
        case available(Release)
        case failed(String)
    }

    enum CheckError: Error, Equatable {
        case httpStatus(Int)
        case unexpectedHost
        case tooLarge
        case notAStableRelease

        var reason: String {
            switch self {
            case .httpStatus(let code): "GitHub answered HTTP \(code)"
            case .unexpectedHost: "the answer came from a host other than api.github.com"
            case .tooLarge: "the answer was larger than a release"
            case .notAStableRelease: "the latest release is not a stable version"
            }
        }
    }

    typealias Fetch = @Sendable (URLRequest) async throws -> Data

    // MARK: - Pure decisions

    /// The stable release in a `releases/latest` answer. Refuses a draft, a pre-release, and a
    /// tag that is not plain `v<major>.<minor>[.<patch>]` (so `-rc1` or `-beta2` never pass).
    static func release(from data: Data) throws -> Release {
        struct Raw: Decodable {
            let tag_name: String
            let prerelease: Bool?
            let draft: Bool?
        }
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        guard raw.prerelease != true, raw.draft != true,
              let version = stableVersion(fromTag: raw.tag_name)
        else { throw CheckError.notAStableRelease }
        return Release(version: version)
    }

    /// `v2.10.1` → `2.10.1`; nil for anything with a suffix or other characters.
    static func stableVersion(fromTag tag: String) -> String? {
        var text = Substring(tag)
        if text.first == "v" || text.first == "V" { text = text.dropFirst() }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...4).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.count <= 6 && $0.allSatisfy(\.isASCII)
                  && $0.allSatisfy(\.isNumber) })
        else { return nil }
        return String(text)
    }

    /// A release newer than the running version is offered; a beta of the next version
    /// (`2.11.0-beta1`) is ahead of `2.10.1` and is offered `2.11.0` when it ships.
    static func outcome(current: String, release: Release) -> Outcome {
        JamfCLIInstaller.compareVersions(current, release.version) == .orderedAscending
            ? .available(release) : .upToDate(latest: release.version)
    }

    /// Due when never checked, a day after the last check, or when the clock went backwards.
    static func isDue(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck, lastCheck <= now else { return true }
        return now.timeIntervalSince(lastCheck) >= checkInterval
    }

    /// The bytes of `sequence`, refusing more than `limit`.
    static func collect<S: AsyncSequence>(_ sequence: S, limit: Int) async throws -> Data
    where S.Element == UInt8 {
        var data = Data()
        for try await byte in sequence {
            data.append(byte)
            if data.count > limit { throw CheckError.tooLarge }
        }
        return data
    }

    // MARK: - Network

    static var request: URLRequest {
        var request = URLRequest(
            url: latestReleaseURL, cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: requestTimeout)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("JamfReports", forHTTPHeaderField: "User-Agent")
        return request
    }

    /// One GET with no cookies or cache, read up to `maxResponseBytes`.
    static let liveFetch: Fetch = { request in
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (bytes, response) = try await session.bytes(for: request)
        guard response.url?.host == "api.github.com" else { throw CheckError.unexpectedHost }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw CheckError.httpStatus(status) }
        return try await collect(bytes, limit: maxResponseBytes)
    }

    /// Fetches the latest release and compares it with `current`. Never throws.
    static func check(current: String, fetch: Fetch) async -> Outcome {
        do {
            let release = try release(from: try await fetch(request))
            return outcome(current: current, release: release)
        } catch let error as CheckError {
            return .failed(error.reason)
        } catch is DecodingError {
            return .failed("the answer was not a GitHub release")
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

/// What the banner and Settings show about app updates. GUI only: the tick, the scheduled run
/// and the included CLI never check.
@MainActor
@Observable
final class AppUpdateModel {
    static let shared = AppUpdateModel()

    private(set) var latest: AppUpdateCheck.Release?
    private(set) var lastCheck: Date?
    private(set) var lastError: String?
    private(set) var isChecking = false
    private(set) var skippedVersion: String?
    /// On unless the user or a configuration profile turned it off.
    private(set) var isEnabled: Bool

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let fetch: AppUpdateCheck.Fetch
    @ObservationIgnored private let currentVersion: String

    init(
        defaults: UserDefaults = .standard,
        currentVersion: String = AppVersionState.currentVersion,
        fetch: @escaping AppUpdateCheck.Fetch = AppUpdateCheck.liveFetch
    ) {
        self.defaults = defaults
        self.currentVersion = currentVersion
        self.fetch = fetch
        isEnabled = Self.readEnabled(defaults)
        lastCheck = defaults.object(forKey: AppUpdateCheck.lastCheckKey) as? Date
        skippedVersion = defaults.string(forKey: AppUpdateCheck.skippedVersionKey)
        if let version = defaults.string(forKey: AppUpdateCheck.latestVersionKey),
           AppUpdateCheck.stableVersion(fromTag: version) != nil,
           case .available(let release) = AppUpdateCheck.outcome(
               current: currentVersion, release: .init(version: version))
        {
            latest = release
        }
    }

    private static func readEnabled(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: AppUpdateCheck.enabledKey) as? Bool ?? true
    }

    /// The Settings switch. A value a configuration profile forces wins over the write.
    func setEnabled(_ on: Bool) {
        defaults.set(on, forKey: AppUpdateCheck.enabledKey)
        isEnabled = Self.readEnabled(defaults)
    }

    /// Whether a configuration profile sets the switch, so Settings shows it as managed.
    var isForcedByProfile: Bool {
        defaults.objectIsForced(forKey: AppUpdateCheck.enabledKey)
    }

    /// The release the banner offers: newer, not skipped, and the check still on.
    var bannerRelease: AppUpdateCheck.Release? {
        guard isEnabled, let latest, latest.version != skippedVersion else { return nil }
        return latest
    }

    /// At launch: one request a day at most, none when the switch is off.
    func checkIfDue(now: Date = Date()) async {
        guard isEnabled, AppUpdateCheck.isDue(lastCheck: lastCheck, now: now) else { return }
        await checkNow(now: now)
    }

    /// Settings' Check now: runs even when the daily check is not due.
    func checkNow(now: Date = Date()) async {
        guard isEnabled, !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        let outcome = await AppUpdateCheck.check(current: currentVersion, fetch: fetch)
        lastCheck = now
        defaults.set(now, forKey: AppUpdateCheck.lastCheckKey)
        switch outcome {
        case .available(let release):
            latest = release
            lastError = nil
            defaults.set(release.version, forKey: AppUpdateCheck.latestVersionKey)
        case .upToDate:
            latest = nil
            lastError = nil
            defaults.removeObject(forKey: AppUpdateCheck.latestVersionKey)
        case .failed(let reason):
            lastError = reason
            AppLogger.event(.ui, .notice, "App update check failed: \(reason)")
        }
    }

    /// Hides the banner for this version; a later release shows it again.
    func skip(_ version: String) {
        skippedVersion = version
        defaults.set(version, forKey: AppUpdateCheck.skippedVersionKey)
    }

    /// The Settings line under the switch.
    var statusText: String {
        if !isEnabled { return "Off. Jamf Reports does not contact GitHub for updates." }
        if isChecking { return "Checking GitHub…" }
        if let latest { return "Jamf Reports \(latest.version) is available." }
        if let lastError { return "Last check failed: \(lastError)." }
        guard let lastCheck else { return "Checks GitHub once a day for a new stable release." }
        let when = lastCheck.formatted(date: .abbreviated, time: .shortened)
        return "Up to date (\(currentVersion)). Last checked \(when)."
    }
}
