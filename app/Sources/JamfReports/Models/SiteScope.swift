import Foundation

/// Whether the jamf-cli login sees every managed device of Jamf Pro or only some sites' (a
/// site-limited user account on a `token` profile). `pro overview`'s Fleet counts are
/// server-wide while every list is filtered, so the two disagree only for such a login.
enum SiteScope: Codable, Equatable, Sendable {
    case notApplicable
    case unknown
    case whole
    case limited(computers: Seen?, mobileDevices: Seen?)

    struct Seen: Codable, Equatable, Sendable {
        let seen: Int
        let total: Int
    }

    /// Pure over decoded payloads (the `pro overview` rows and the two device lists, nil when
    /// not saved this run). Only a login that is neither an API client, Platform, School nor
    /// Security Cloud is judged.
    static func evaluate(
        auth: JamfCLIAuthMethod?, overview: [Any]?, computers: [Any]?,
        mobileDevices: [MobileDeviceInventoryItem]?
    ) -> SiteScope {
        switch auth {
        case nil: return .unknown
        case .oauth2?, .platform?, .apiKey?, .security?: return .notApplicable
        case .other?: break
        }
        let computerSeen = seen(
            computers, total: fleetTotal(overview, resource: "Managed Computers")
        ) {
            BinaryMissing.managed(DeviceInventoryService.managedFlag(ofComputer: $0))
        }
        let mobileSeen = mobileDevices.flatMap { rows in
            fleetTotal(overview, resource: "Managed Devices").flatMap { total -> Seen? in
                let states = rows.map { MobileSummary.device($0).managed }
                return states.contains(nil) ? nil
                    : Seen(seen: states.filter { $0 == true }.count, total: total)
            }
        }
        let compared = [computerSeen, mobileSeen].compactMap { $0 }
        if compared.isEmpty { return .unknown }
        let limitedOnly = { (value: Seen?) in value.flatMap { $0.seen < $0.total ? $0 : nil } }
        let computersLimited = limitedOnly(computerSeen)
        let mobileLimited = limitedOnly(mobileSeen)
        if computersLimited == nil && mobileLimited == nil { return .whole }
        return .limited(computers: computersLimited, mobileDevices: mobileLimited)
    }

    /// Fleet › `resource` as a whole number: a JSON number, digits, or digits with `,` group
    /// separators ("1,234"); anything else (`N/A`, blank, text) is nil.
    private static func fleetTotal(_ overview: [Any]?, resource: String) -> Int? {
        let row = overview?.lazy.compactMap { $0 as? [String: Any] }.first {
            $0["section"] as? String == "Fleet" && $0["resource"] as? String == resource
        }
        if let number = row?["value"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            let value = number.intValue
            return value >= 0 && Double(value) == number.doubleValue ? value : nil
        }
        guard let text = (row?["value"] as? String)?.trimmingCharacters(in: .whitespaces),
              text.range(of: #"^(\d+|\d{1,3}(,\d{3})+)$"#, options: .regularExpression) != nil
        else { return nil }
        return Int(text.replacingOccurrences(of: ",", with: ""))
    }

    /// Managed rows of `rows` against `total`; nil when either is missing or a row's managed
    /// state is unknown (absent is not zero).
    private static func seen(
        _ rows: [Any]?, total: Int?, managed: ([String: Any]) -> Bool?
    ) -> Seen? {
        guard let rows, let total else { return nil }
        var count = 0
        for case let row as [String: Any] in rows {
            guard let isManaged = managed(row) else { return nil }
            if isManaged { count += 1 }
        }
        return Seen(seen: count, total: total)
    }

    /// The counts, as the log line words them.
    var summary: String? {
        guard case .limited(let computers, let mobile) = self else { return nil }
        let parts = [
            computers.map {
                $0.total == 1 ? "\($0.seen) of 1 managed computer"
                    : "\($0.seen) of \($0.total) managed computers"
            },
            mobile.map { $0.total == 1
                ? "\($0.seen) of 1 managed mobile device"
                : "\($0.seen) of \($0.total) managed mobile devices" },
        ]
        return parts.compactMap { $0 }.joined(separator: ", and ")
    }
}

/// `state/site-scope.json`: the verdict of the newest collect that saw both inputs. Report-time
/// code reads this and never re-derives it (a report can outlive the login that collected).
struct SiteScopeRecord: Codable, Equatable, Sendable {
    let scope: SiteScope
    let collectedAt: Date
    let profile: String

    static let fileName = "site-scope.json"

    /// The persisted verdict; missing, unreadable, oversized or a link reads as `.unknown`.
    static func load(stateDir: URL) -> SiteScope {
        guard let data = BoundedFile.readLogged(
                stateDir.appendingPathComponent(fileName),
                inside: stateDir.deletingLastPathComponent()),
              let record = try? ISO8601Coding.decoder.decode(SiteScopeRecord.self, from: data)
        else { return .unknown }
        return record.scope
    }

    func save(stateDir: URL) throws {
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try AtomicInstall.write(
            try ISO8601Coding.encoder.encode(self),
            to: stateDir.appendingPathComponent(Self.fileName), mode: 0o600)
    }
}

private enum ISO8601Coding {
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
