import Foundation

/// One Automated Device Enrollment instance and when its token expires, from the newest
/// `device-enrollment-instances` snapshot.
struct EnrollmentToken: Sendable, Equatable {
    enum State: Sendable, Equatable { case expired, expiring, ok, notReported }

    let name: String?
    /// Whole calendar days from today to the expiry day; negative once expired.
    let daysLeft: Int?
    let state: State

    /// `tokenExpirationDate` is date-only (`yyyy-MM-dd`) and read as a local calendar day: the
    /// token is good through that day and expired from the start of the next. Any other format
    /// is not reported.
    init(row: [String: Any], warningDays: Int, now: Date, calendar: Calendar = .current) {
        let name = (row["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = name?.isEmpty == false ? name : nil
        guard let text = row["tokenExpirationDate"] as? String,
              let day = Self.localDay(text, calendar: calendar),
              let left = calendar.dateComponents(
                  [.day], from: calendar.startOfDay(for: now), to: day).day
        else {
            daysLeft = nil
            state = .notReported
            return
        }
        daysLeft = left
        state = left < 0 ? .expired : left <= warningDays ? .expiring : .ok
    }

    private static func localDay(_ text: String, calendar: Calendar) -> Date? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              text.allSatisfy({ $0 == "-" || ($0.isASCII && $0.isNumber) }),
              let year = Int(parts[0]), let month = Int(parts[1]), let dayOfMonth = Int(parts[2])
        else { return nil }
        let parts3 = DateComponents(year: year, month: month, day: dayOfMonth)
        guard let date = calendar.date(from: parts3),
              calendar.dateComponents([.year, .month, .day], from: date) == parts3
        else { return nil }
        return date
    }
}

/// Reads the newest `device-enrollment-instances` snapshot, telling "not collected" from
/// "could not be read" from "no instances".
struct EnrollmentTokenSnapshot: Sendable, Equatable {
    let tokens: [EnrollmentToken]
    /// True when a snapshot decoded, even to no rows.
    let isDetected: Bool
    /// True when a snapshot file exists but could not be read or decoded.
    let readFailed: Bool

    static let empty = EnrollmentTokenSnapshot(tokens: [], isDetected: false, readFailed: false)
    static let unreadable = EnrollmentTokenSnapshot(tokens: [], isDetected: false, readFailed: true)

    /// The rows of a saved list: a bare list, jamf-cli's `null` for an empty one, or the
    /// `results` of an envelope. Nil for anything else.
    private static func rows(in data: Data) -> [[String: Any]]? {
        guard let object = try? JSONSerialization.jsonObject(
            with: data, options: [.fragmentsAllowed]) else { return nil }
        if object is NSNull { return [] }
        if let rows = object as? [[String: Any]] { return rows }
        if let envelope = object as? [String: Any] {
            return envelope["results"] as? [[String: Any]]
        }
        return nil
    }

    static func load(
        dataDir: URL, warningDays: Int, now: Date = Date(), calendar: Calendar = .current
    ) -> EnrollmentTokenSnapshot {
        let kindDir = dataDir.appendingPathComponent(
            "device-enrollment-instances", isDirectory: true)
        guard let url = FileManager.newestJSONFile(in: kindDir) else { return .empty }
        guard let data = BoundedFile.readLogged(url, inside: dataDir),
              let rows = Self.rows(in: data) else { return .unreadable }
        let tokens = rows.map {
            EnrollmentToken(row: $0, warningDays: warningDays, now: now, calendar: calendar)
        }
        return EnrollmentTokenSnapshot(tokens: tokens, isDetected: true, readFailed: false)
    }
}
