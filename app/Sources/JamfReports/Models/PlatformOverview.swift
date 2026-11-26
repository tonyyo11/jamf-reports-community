import Foundation

/// The cross-platform overview: one section per platform the newest daily summary's
/// `osMajorCounts` names ("macOS 26" is platform macOS, major 26), with the share of each major
/// over the last weeks. Every figure comes from the summaries; one a summary lacks is nil (left
/// out), never 0. Shares are of the devices reporting an OS version, the map's own total. Keys
/// are data: nothing here is localized, and "Other" is the view's word to translate.
struct PlatformOverview: Equatable, Sendable {
    struct Platform: Equatable, Sendable {
        struct Version: Equatable, Sendable {
            let key: String
            let count: Int
            let percent: Double
        }
        struct Point: Equatable, Sendable {
            let date: Date
            let percent: Double
        }
        struct Series: Equatable, Sendable {
            /// A map key, or `PlatformOverview.otherKey` for the pooled older majors.
            let key: String
            let points: [Point]
        }

        let name: String
        /// Devices reporting a version on the newest day.
        let devices: Int
        /// The newest day's majors, newest first.
        let versions: [Version]
        /// The newest `drawnMajors` majors seen in the window, then "Other" when more were.
        let adoption: [Series]
        /// Majors seen in the window, and how many of them "Other" holds (0 when none).
        let versionsSeen: Int
        let versionsPooled: Int
        /// macOS only: `modelFamilyCounts` families ("Other" not counted), `osCurrentPct` and
        /// `actionItemsP0`, each nil when the summary lacks it.
        let modelFamilies: Int?
        let onCurrentRelease: Double?
        let securityGaps: Int?

        var isMac: Bool { name == PlatformOverview.macPlatform }
    }

    let platforms: [Platform]
    /// Every non-Mac device together (`MobileSummary`): iOS and iPadOS share these figures.
    let mobileOSCurrent: MobileSummary.Share?
    let mobileJailbroken: Int?

    static let otherKey = "Other"
    static let macPlatform = "macOS"
    static let drawnMajors = 4
    static let windowWeeks = 12

    static let empty = PlatformOverview(platforms: [], mobileOSCurrent: nil, mobileJailbroken: nil)

    var isEmpty: Bool { platforms.isEmpty }

    /// `"macOS 26"` as platform and major; nil when the last word is not a whole number.
    static func parts(_ key: String) -> (platform: String, major: Int)? {
        let words = key.split(separator: " ")
        guard words.count > 1, let last = words.last, last.allSatisfy(\.isNumber),
              let major = Int(last) else { return nil }
        return (words.dropLast().joined(separator: " "), major)
    }

    static func build(_ summaries: [DailySummary], weeks: Int = windowWeeks) -> PlatformOverview {
        let days = summaries.filter { $0.parsedDate != .distantPast }
            .sorted { $0.parsedDate < $1.parsedDate }
        guard let newest = days.last, let current = newest.osMajorCounts.map(byPlatform),
              !current.isEmpty else { return .empty }
        let start = Calendar(identifier: .gregorian)
            .date(byAdding: .weekOfYear, value: -weeks, to: newest.parsedDate) ?? newest.parsedDate
        let window = days.filter { $0.parsedDate >= start }
            .compactMap { day in day.osMajorCounts.map { (day.parsedDate, byPlatform($0)) } }

        let names = current.keys.sorted {
            ($0 == macPlatform) != ($1 == macPlatform) ? $0 == macPlatform : $0 < $1
        }
        let platforms = names.compactMap { name -> Platform? in
            guard let today = current[name] else { return nil }
            let total = today.values.reduce(0, +)
            let isMac = name == macPlatform
            return Platform(
                name: name, devices: total,
                versions: today.sorted { $0.key > $1.key }.map {
                    .init(key: "\(name) \($0.key)", count: $0.value,
                          percent: Double($0.value) / Double(total) * 100)
                },
                adoption: [], versionsSeen: 0, versionsPooled: 0,
                modelFamilies: isMac ? newest.modelFamilyCounts.map {
                    $0.filter { $0.key != otherKey && $0.value > 0 }.count
                } : nil,
                onCurrentRelease: isMac ? newest.osCurrentPct : nil,
                securityGaps: isMac ? newest.actionItemsP0 : nil
            ).withAdoption(window.map { ($0.0, $0.1[name]) })
        }
        let hasMobile = names.contains { $0 != macPlatform }
        return PlatformOverview(
            platforms: platforms,
            mobileOSCurrent: hasMobile ? newest.mobile?.osCurrent : nil,
            mobileJailbroken: hasMobile ? newest.mobile?.jailbroken : nil)
    }

    /// Platform to major to count; a count at or below 0 or a key with no major is skipped
    /// (summaries are peer-writable; the writer produces neither).
    private static func byPlatform(_ map: [String: Int]) -> [String: [Int: Int]] {
        var result: [String: [Int: Int]] = [:]
        for (key, count) in map where count > 0 {
            guard let (platform, major) = parts(key) else { continue }
            result[platform, default: [:]][major, default: 0] += count
        }
        return result
    }
}

private extension PlatformOverview.Platform {
    /// A day whose map lacks this platform has no point; a major absent on a day the platform
    /// was measured is 0, since the tally writes only majors that have devices.
    func withAdoption(_ days: [(Date, [Int: Int]?)]) -> Self {
        let measured = days.compactMap { date, majors -> (Date, [Int: Int], Int)? in
            guard let majors else { return nil }
            let total = majors.values.reduce(0, +)
            return total > 0 ? (date, majors, total) : nil
        }
        let seen = Set(measured.flatMap(\.1.keys)).sorted(by: >)
        let drawnCount = min(seen.count, PlatformOverview.drawnMajors)
        let drawn = Array(seen.prefix(drawnCount))
        let pooled = Set(seen.dropFirst(drawnCount))
        func series(_ key: String, _ count: ([Int: Int]) -> Int) -> Series {
            Series(key: key, points: measured.map { date, majors, total in
                Point(date: date, percent: Double(count(majors)) / Double(total) * 100)
            })
        }
        var adoption = drawn.map { major in series("\(name) \(major)") { $0[major] ?? 0 } }
        if !pooled.isEmpty {
            adoption.append(series(PlatformOverview.otherKey) { majors in
                majors.filter { pooled.contains($0.key) }.values.reduce(0, +)
            })
        }
        return Self(
            name: name, devices: devices, versions: versions, adoption: adoption,
            versionsSeen: seen.count, versionsPooled: pooled.count, modelFamilies: modelFamilies,
            onCurrentRelease: onCurrentRelease, securityGaps: securityGaps)
    }
}
