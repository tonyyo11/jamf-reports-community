import Foundation

// MARK: - Every definition's release date (`patch-version-dates`)

/// One row of the `patch-version-dates` sidecar: one definition of one patch title, as the
/// definitions walk read it. Nil keys are left out of the file, so a row with no date has no
/// `release_date` key, and a title that answered with no definitions is one marker row with
/// `no_versions`.
struct PatchVersionDate: Codable, Sendable, Equatable {
    var titleId: String
    var title: String?
    var version: String?
    var releaseDate: String?
    var absoluteOrderId: String?
    /// The stamp of the sidecar this row was carried from, set when the title did not answer.
    var staleSince: String?
    var noVersions: Bool?

    private enum CodingKeys: String, CodingKey {
        case titleId = "title_id"
        case title, version
        case releaseDate = "release_date"
        case absoluteOrderId = "absolute_order_id"
        case staleSince = "stale_since"
        case noVersions = "no_versions"
    }
}

/// What reading the newest sidecar found. A file that is there but cannot be read is not
/// the same as no file: the Patch screen says "could not be read" for the first.
enum VersionDatesRead: Sendable, Equatable {
    case absent
    case unreadable(String)
    case rows([PatchVersionDate], stamp: String, bytes: Data)
}

extension PatchReleaseDateService {

    static let versionDatesKind = "patch-version-dates"

    /// The rows one title's `definitions` call returned. Values are trimmed and a blank one
    /// is nil; a definition with no version is dropped.
    static func versionRows(
        fromDefinitions definitions: [[String: Any]], titleId: String, title: String
    ) -> [PatchVersionDate] {
        definitions.compactMap { def in
            guard let version = text(def["version"]) else { return nil }
            return PatchVersionDate(
                titleId: titleId, title: title, version: version,
                releaseDate: text(def["releaseDate"]),
                absoluteOrderId: text(def["absoluteOrderId"]))
        }
    }

    private static func text(_ value: Any?) -> String? {
        let raw: String?
        switch value {
        case let string as String: raw = string
        case let number as NSNumber: raw = number.stringValue
        default: raw = nil
        }
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// The newest sidecar in `dataDir`.
    static func versionDates(dataDir: URL, now: Date = Date()) -> VersionDatesRead {
        guard let newest = versionDateFiles(dataDir: dataDir, now: now).last else { return .absent }
        return versionDates(at: newest.url)
    }

    /// The sidecars oldest first, leaving out any stamped past now (beyond the clock-skew
    /// tolerance), so a future-dated file never stands as the newest.
    static func versionDateFiles(dataDir: URL, now: Date = Date()) -> [(url: URL, date: Date)] {
        let latest = now.addingTimeInterval(SharedWorkspace.clockSkewTolerance)
        return TrendStore.datedSnapshots(of: versionDatesKind, in: dataDir)
            .filter { $0.date <= latest }
    }

    /// One sidecar. Each row decodes on its own, so one odd row costs that row, not the file.
    static func versionDates(at url: URL) -> VersionDatesRead {
        guard let stamp = snapshotStamp(of: url) else {
            return .unreadable("\(url.lastPathComponent) has no snapshot stamp")
        }
        guard let data = BoundedFile.readSnapshotLogged(url) else {
            return .unreadable("\(url.lastPathComponent) could not be read")
        }
        guard let rows = LenientElement<PatchVersionDate>.rows(in: data) else {
            return .unreadable("\(url.lastPathComponent) could not be decoded")
        }
        if rows.skipped > 0 {
            AppLogger.event(.report, .notice, "\(ConfigSchema.displayText(url.lastPathComponent)): "
                + "skipped \(rows.skipped) rows that are not version dates")
        }
        return .rows(rows.rows, stamp: stamp, bytes: data)
    }

    /// The newest sidecar, and what a walk carries rows from: the newest itself, or when it
    /// cannot be read, the newest earlier one that can, so an unreadable file never shrinks
    /// the next. Each file is read at most once.
    static func newestAndCarryable(
        dataDir: URL, now: Date = Date()
    ) -> (newest: VersionDatesRead, carryable: VersionDatesRead) {
        let files = versionDateFiles(dataDir: dataDir, now: now)
        guard let last = files.last else { return (.absent, .absent) }
        let newest = versionDates(at: last.url)
        guard case .unreadable = newest else { return (newest, newest) }
        for file in files.dropLast().reversed() {
            let read = versionDates(at: file.url)
            if case .rows = read { return (newest, read) }
        }
        return (newest, newest)
    }

    /// The sidecar a walk should hold, and whether it differs from the newest one on disk.
    ///
    /// `answered` holds only titles whose call returned a JSON array (`[]` is answered with
    /// no versions). A title in `currentTitles` that did not answer keeps its earlier rows,
    /// marked with the stamp of the file they came from; a title no longer in `patch-status`
    /// is dropped. The bytes are compact with sorted keys, so the same rows always encode the
    /// same way. A file is due when the bytes differ, the newest file is missing or
    /// unreadable, or it is older than `refreshAfter` (so retention never sweeps the last one).
    static func patchVersionDatesUpdate(
        answered: [String: [PatchVersionDate]],
        currentTitles: [String: String],
        previous: VersionDatesRead,
        now: Date,
        refreshAfter: TimeInterval
    ) -> (rows: [PatchVersionDate], data: Data, changed: Bool) {
        var earlier: [String: [PatchVersionDate]] = [:]
        var earlierStamp: String?
        var earlierBytes: Data?
        if case .rows(let rows, let stamp, let bytes) = previous {
            earlier = Dictionary(grouping: rows, by: \.titleId)
            (earlierStamp, earlierBytes) = (stamp, bytes)
        }
        var rows: [PatchVersionDate] = []
        for (titleId, title) in currentTitles {
            if let fresh = answered[titleId] {
                rows += fresh.isEmpty
                    ? [PatchVersionDate(titleId: titleId, title: title, noVersions: true)]
                    : fresh
            } else if let carried = earlier[titleId] {
                rows += carried.map { row in
                    var row = row
                    if row.staleSince == nil { row.staleSince = earlierStamp }
                    return row
                }
            }
        }
        rows.sort(by: versionRowOrder)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(rows)) ?? Data("[]".utf8)
        let aged = earlierStamp.flatMap(stampDate).map { now.timeIntervalSince($0) > refreshAfter }
        let changed = earlierBytes != data || aged ?? true
        return (rows, data, changed)
    }

    /// How old the newest sidecar may get before an unchanged walk writes it again: half the
    /// effective `snapshot_keep_days`, at most 7 days, and 7 days when retention is off or
    /// keeps every age.
    static func patchVersionRefreshInterval(_ retention: RetentionConfig?) -> TimeInterval {
        let week: TimeInterval = 7 * 86_400
        guard let retention, retention.isEnabled, retention.keepDays > 0 else { return week }
        return min(Double(retention.keepDays) * 86_400 / 2, week)
    }

    /// Title, then Jamf's order (0 is newest; a non-number sorts last), then version.
    private static func versionRowOrder(_ lhs: PatchVersionDate, _ rhs: PatchVersionDate) -> Bool {
        if lhs.titleId != rhs.titleId { return lhs.titleId < rhs.titleId }
        let (left, right) = (orderNumber(lhs), orderNumber(rhs))
        if left != right { return left < right }
        return (lhs.version ?? "") < (rhs.version ?? "")
    }

    private static func orderNumber(_ row: PatchVersionDate) -> Int {
        row.absoluteOrderId.flatMap { Int($0) } ?? Int.max
    }

    static func snapshotStamp(of url: URL) -> String? {
        let name = url.deletingPathExtension().lastPathComponent
        guard let stamp = name.split(separator: "_").last.map(String.init),
              stampDate(stamp) != nil else { return nil }
        return stamp
    }

    static func stampDate(_ stamp: String) -> Date? { stampFormatter.date(from: stamp) }

    /// Snapshot stamps are local time, as `saveSnapshot` writes them.
    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}

// MARK: - Release-date lookup

/// One version's release date, from every source on disk, built once per read.
///
/// The key is the title (its ID, else its lower-cased name) plus the trimmed version.
/// Precedence: a sidecar row this walk answered with a date, then the newest dated
/// `patch-release-dates` row for that version, then a carried (`stale_since`) sidecar row.
struct ReleaseDateLookup: Sendable {
    private var answered: [String: Date] = [:]
    private var released: [String: Date] = [:]
    private var carried: [String: Date] = [:]
    /// The newest `patch-release-dates` date per title, whatever version it names. That file
    /// holds the date of the title's latest version, so it stands for the current window
    /// when its version string does not match.
    private var latestByTitle: [String: Date] = [:]

    init(
        versionRows: [PatchVersionDate],
        releaseFilesNewestFirst: [[PatchReleaseDateService.Row]]
    ) {
        for row in versionRows {
            guard let version = row.version,
                  let date = row.releaseDate.flatMap(SOFAFeedService.parseSOFADate)
            else { continue }
            for key in Self.keys(titleId: row.titleId, title: row.title, version: version) {
                if row.staleSince == nil {
                    answered[key] = answered[key] ?? date
                } else {
                    carried[key] = carried[key] ?? date
                }
            }
        }
        for file in releaseFilesNewestFirst {
            for row in file {
                guard let date = SOFAFeedService.parseSOFADate(row.releaseDate) else { continue }
                let keys = Self.keys(
                    titleId: row.titleId, title: row.title, version: row.latestVersion)
                for key in keys {
                    released[key] = released[key] ?? date
                }
                for key in Self.titleKeys(titleId: row.titleId, title: row.title) {
                    latestByTitle[key] = latestByTitle[key] ?? date
                }
            }
        }
    }

    func date(titleId: String, title: String, version: String) -> Date? {
        let keys = Self.keys(titleId: titleId, title: title, version: version)
        for table in [answered, released, carried] {
            if let date = keys.lazy.compactMap({ table[$0] }).first { return date }
        }
        return nil
    }

    /// The newest `patch-release-dates` date for the title, any version.
    func latestReleaseDate(titleId: String, title: String) -> Date? {
        Self.titleKeys(titleId: titleId, title: title).lazy.compactMap { latestByTitle[$0] }.first
    }

    private static func titleKeys(titleId: String, title: String?) -> [String] {
        var keys = ["id:\(titleId.trimmingCharacters(in: .whitespacesAndNewlines))"]
        if let name = title?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            keys.append("name:\(name.lowercased())")
        }
        return keys
    }

    private static func keys(titleId: String, title: String?, version: String) -> [String] {
        let version = version.trimmingCharacters(in: .whitespacesAndNewlines)
        return titleKeys(titleId: titleId, title: title).map { "\($0)|\(version)" }
    }
}

extension PatchReleaseDateService {

    static let releaseFileDays = 180

    /// The one lookup factory. `releaseRows` stand for the newest `patch-release-dates` file
    /// (always read, whatever its age), ahead of the dated files of the last
    /// `releaseFileDays`; `versionDates` is the sidecar read the caller made once.
    static func releaseDateLookup(
        releaseRows: [Row], dataDir: URL, versionDates read: VersionDatesRead, now: Date
    ) -> ReleaseDateLookup {
        var versionRows: [PatchVersionDate] = []
        if case .rows(let rows, _, _) = read { versionRows = rows }
        // The walk lands this file on every collect; the newest of each local day over the last
        // `releaseFileDays` cover the 90-day fleet figure and long windows at any collect rate,
        // and the sidecar dates older versions.
        let since = now.addingTimeInterval(-Double(releaseFileDays) * 86_400)
        var newestPerDay: [Date: URL] = [:]
        for file in TrendStore.datedSnapshots(of: "patch-release-dates", in: dataDir)
        where file.date >= since {
            newestPerDay[Calendar.current.startOfDay(for: file.date)] = file.url  // ascending
        }
        let files = newestPerDay.sorted { $0.key > $1.key }.map { load(from: $0.value) }
        return ReleaseDateLookup(
            versionRows: versionRows, releaseFilesNewestFirst: [releaseRows] + files)
    }
}
