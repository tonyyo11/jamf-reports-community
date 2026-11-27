import Foundation

/// One Automated Device Enrollment instance and when its token expires, from the newest
/// `device-enrollment-instances` snapshot.
struct EnrollmentToken: Sendable, Equatable {
    typealias State = CredentialExpiry.State

    let id: String?
    let name: String?
    /// The raw `tokenExpirationDate` (`yyyy-MM-dd`), kept for the daily summary's expiry map.
    let expiryDay: String?
    /// Whole calendar days from today to the expiry day; negative once expired.
    let daysLeft: Int?
    let state: State

    /// `tokenExpirationDate` is date-only (`yyyy-MM-dd`) and read as a local calendar day: the
    /// token is good through that day and expired from the start of the next. Any other format
    /// is not reported.
    init(row: [String: Any], warningDays: Int, now: Date, calendar: Calendar = .current) {
        let name = (row["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = name?.isEmpty == false ? name : nil
        id = (row["id"] as? String) ?? (row["id"] as? NSNumber).map(\.stringValue)
        let expiry = CredentialExpiry(
            key: "ade", label: "", raw: row["tokenExpirationDate"], warningDays: warningDays,
            now: now, calendar: calendar)
        // Date-only is the shape this token has; an instant string is not reported.
        guard case .day(let day)? = expiry.source else {
            expiryDay = nil
            daysLeft = nil
            state = .notReported
            return
        }
        expiryDay = day
        daysLeft = expiry.daysLeft
        state = expiry.state
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
