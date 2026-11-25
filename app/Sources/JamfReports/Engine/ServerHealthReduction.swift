import Foundation

/// Allow-list reductions for the server-health kinds: only the figure a screen needs reaches
/// disk, and never a name, whatever `jamf_cli.keep_account_names` says.
enum ServerHealthReduction {

    /// The saved payload for `kind`, or nil when `payload` is not the shape the command prints,
    /// so nothing is saved on a guess.
    static func reduce(kind: String, payload: Data) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(
            with: payload, options: [.fragmentsAllowed]) else { return nil }
        switch kind {
        case "certificate-authority": return certificateAuthority(object)
        default: return nil
        }
    }

    /// `{notAfter}` as epoch seconds; `{}` when the answer carries none (read as "expiry not
    /// reported"). One object, or a list of one.
    private static func certificateAuthority(_ object: Any) -> Data? {
        let row = (object as? [String: Any]) ?? (ReportEngine.listRows(of: object)?.first
            as? [String: Any])
        guard let row else { return nil }
        var kept: [String: Any] = [:]
        if let number = row["notAfter"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            kept["notAfter"] = number
        }
        return try? JSONSerialization.data(withJSONObject: kept)
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
