import Foundation

/// Allow-list reductions for the server-health kinds: only the figure a screen needs reaches
/// disk, and never a name, whatever `jamf_cli.keep_account_names` says.
enum ServerHealthReduction {

    /// The saved payload for `kind`, or nil when `payload` is not the shape the command prints,
    /// so nothing is saved on a guess.
    static func reduce(kind: String, payload: Data, now: Date = Date()) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(
            with: payload, options: [.fragmentsAllowed]) else { return nil }
        switch kind {
        case "certificate-authority": return certificateAuthority(object)
        case "jamf-pro-notifications": return notifications(object)
        case "laps-pending-rotations": return lapsPending(object)
        case "admin-accounts": return accounts(object, now: now)
        case "api-integrations": return apiClients(object)
        default: return nil
        }
    }

    /// `{notAfter}` as epoch seconds; `{}` when the answer carries none (read as "expiry not
    /// reported"). One object, or a list of one.
    private static func certificateAuthority(_ object: Any) -> Data? {
        // An envelope with no `notAfter` of its own may hold the row in `results`.
        let dict = object as? [String: Any]
        let row = dict.flatMap { $0["notAfter"] != nil ? $0 : nil }
            ?? (ReportEngine.listRows(of: object)?.first as? [String: Any]) ?? dict
        guard let row else { return nil }
        var kept: [String: Any] = [:]
        if let number = row["notAfter"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            kept["notAfter"] = number
        } else if let text = row["notAfter"] as? String,
                  CredentialExpiry.parse(text) != nil {
            kept["notAfter"] = text
        }
        return try? JSONSerialization.data(withJSONObject: kept)
    }

    /// One `{type}` per notification: `params` names Jamf objects and `id` is the server's, and
    /// neither is shown. An empty list is a real zero and is saved as `[]`.
    private static func notifications(_ object: Any) -> Data? {
        guard let rows = ReportEngine.listRows(of: object) else { return nil }
        let kept: [[String: Any]] = rows.map { row in
            guard let type = (row as? [String: Any])?["type"] as? String else { return [:] }
            return ["type": type]
        }
        return try? JSONSerialization.data(withJSONObject: kept)
    }
}

/// The opt-in admin-hygiene reductions: counts only, so no username, name, email, client ID or
/// display name is ever saved.
extension ServerHealthReduction {

    /// `{totalCount}`: the rotations waiting, from the envelope's own count or its rows.
    fileprivate static func lapsPending(_ object: Any) -> Data? {
        let count = int((object as? [String: Any])?["totalCount"])
            ?? ReportEngine.listRows(of: object)?.count
        guard let count else { return nil }
        return try? JSONSerialization.data(withJSONObject: ["totalCount": count])
    }

    fileprivate static func accounts(_ object: Any, now: Date) -> Data? {
        guard let rows = ReportEngine.listRows(of: object) else { return nil }
        var counts = ["total": rows.count, "fullAccessLocal": 0, "fullAccessFederated": 0,
                      "withFailedLogins": 0, "passwordOlderThanYear": 0, "passwordAgeUnknown": 0,
                      "failedLoginsUnknown": 0]
        for case let row as [String: Any] in rows {
            let enabled = row["accountStatus"] as? String == "Enabled"
            let type = row["accountType"] as? String
            let fullAdmin = enabled && row["accessLevel"] as? String == "FullAccess"
                && row["privilegeLevel"] as? String == "ADMINISTRATOR"
            if fullAdmin, type == "DEFAULT" { counts["fullAccessLocal", default: 0] += 1 }
            if fullAdmin, type == "FEDERATED" { counts["fullAccessFederated", default: 0] += 1 }
            if let failed = int(row["failedLoginAttempts"]) {
                if failed > 0 { counts["withFailedLogins", default: 0] += 1 }
            } else {
                counts["failedLoginsUnknown", default: 0] += 1
            }
            guard enabled, type == "DEFAULT" else { continue }
            let changed = (row["lastPasswordChange"] as? String).flatMap(passwordChangeDate)
            if let changed {
                if now.timeIntervalSince(changed) > 365 * 86_400 {
                    counts["passwordOlderThanYear", default: 0] += 1
                }
            } else {
                counts["passwordAgeUnknown", default: 0] += 1
            }
        }
        return try? JSONSerialization.data(withJSONObject: counts)
    }

    fileprivate static func apiClients(_ object: Any) -> Data? {
        guard let rows = ReportEngine.listRows(of: object) else { return nil }
        var counts = ["total": rows.count, "disabled": 0, "enabledWithTokenOverOneDay": 0,
                      "tokenLifetimeUnknown": 0, "enabledUnknown": 0]
        for case let row as [String: Any] in rows {
            switch bool(row["enabled"]) {
            case nil: counts["enabledUnknown", default: 0] += 1
            case false?: counts["disabled", default: 0] += 1
            case true?:
                if let lifetime = int(row["accessTokenLifetimeSeconds"]) {
                    if lifetime > 86_400 { counts["enabledWithTokenOverOneDay", default: 0] += 1 }
                } else {
                    counts["tokenLifetimeUnknown", default: 0] += 1
                }
            }
        }
        return try? JSONSerialization.data(withJSONObject: counts)
    }

    /// Jamf prints `yyyy-MM-ddTHH:mm:ss` with no zone; read as UTC, so every Mac agrees.
    private static func passwordChangeDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.date(from: text)
    }

    private static func int(_ value: Any?) -> Int? { wholeCount(value) }

    private static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID()
        else { return nil }
        return number.boolValue
    }
}

extension ReportEngine {
    /// The rows of a saved list: a bare list, jamf-cli's `null` for an empty one, or the
    /// `results` of an envelope. Nil for anything else.
    static func listRows(of object: Any) -> [Any]? {
        if object is NSNull { return [] }
        if let rows = object as? [Any] { return rows }
        return (object as? [String: Any])?["results"] as? [Any]
    }
}
