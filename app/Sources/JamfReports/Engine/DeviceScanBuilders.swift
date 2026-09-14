import Foundation

/// Pure reductions from the two raw jamf-cli payloads into the persisted rows.
/// No I/O, no clock reads (callers pass `now`), so every rule here is unit-testable.
enum DeviceScanBuilders {

    // MARK: - Status items

    /// The ONLY status-item keys that reach disk. An allow-list, not a
    /// deny-list: the payload also carries `mdm.push-token`, `mdm.push-magic`,
    /// per-declaration `server-token`s and certificate lists, and a key Apple
    /// adds next year must not leak by default.
    static let statusItemAllowList: Set<String> = [
        "device.operating-system.version",
        "device.model.identifier",
        "management.declarations.configurations",
        "management.declarations.activations",
        "softwareupdate.pending-version.os-version",
        "softwareupdate.install-state",
        "softwareupdate.failure-reason",
    ]

    static func ddmRecord(
        deviceId: String, name: String, managementId: String, payload: DDMStatusItemsPayload
    ) -> DDMDeviceStatusRecord {
        var kept: [String: String] = [:]
        var newest: String?
        for item in payload.statusItems where statusItemAllowList.contains(item.key) {
            if let v = item.value, !v.isEmpty { kept[item.key] = v }
            if let t = item.lastUpdateTime, t > (newest ?? "") { newest = t }
        }
        let declarations = parseDeclarations(kept["management.declarations.configurations"] ?? "")
            + parseDeclarations(kept["management.declarations.activations"] ?? "")
        return DDMDeviceStatusRecord(
            deviceId: deviceId, name: name, managementId: managementId,
            osVersion: kept["device.operating-system.version"],
            reportDate: newest, ddmReported: true, declarations: declarations,
            softwareUpdate: .init(
                pendingOSVersion: kept["softwareupdate.pending-version.os-version"],
                installState: kept["softwareupdate.install-state"],
                failureReason: kept["softwareupdate.failure-reason"]))
    }

    static func ddmRecordNotReported(
        deviceId: String, name: String, managementId: String
    ) -> DDMDeviceStatusRecord {
        DDMDeviceStatusRecord(deviceId: deviceId, name: name, managementId: managementId,
                              osVersion: nil, reportDate: nil, ddmReported: false,
                              declarations: [], softwareUpdate: .empty)
    }

    // MARK: - Declaration string

    /// `{active=true, identifier=…, valid=true, server-token=…}` groups, possibly
    /// several, possibly with a nested `reasons={code=…, description=…}` group
    /// (skipped — nothing reads it). Top-level groups are found by brace depth;
    /// a group without an `identifier` is dropped. `server-token` is read and
    /// discarded here.
    static func parseDeclarations(_ raw: String) -> [DDMDeviceStatusRecord.Declaration] {
        topLevelGroups(raw).compactMap { group in
            let fields = keyValues(group)
            guard let identifier = fields["identifier"], !identifier.isEmpty else { return nil }
            return .init(
                identifier: identifier,
                active: fields["active"].flatMap(flag),
                valid: fields["valid"].flatMap(flag))
        }
    }

    private static func topLevelGroups(_ s: String) -> [String] {
        var groups: [String] = []
        var depth = 0
        var start: String.Index?
        for i in s.indices {
            switch s[i] {
            case "{":
                if depth == 0 { start = s.index(after: i) }
                depth += 1
            case "}":
                depth -= 1
                if depth == 0, let st = start { groups.append(String(s[st..<i])) ; start = nil }
            default: break
            }
        }
        return groups
    }

    /// Flat `key=value` pairs of a group body, ignoring anything inside a nested `{…}`.
    private static func keyValues(_ body: String) -> [String: String] {
        var flat = ""
        var depth = 0
        for ch in body {
            if ch == "{" { depth += 1; continue }
            if ch == "}" { depth -= 1; continue }
            if depth == 0 { flat.append(ch) }
        }
        var out: [String: String] = [:]
        for pair in flat.split(separator: ",") {
            let parts = pair.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if parts.count == 2, !parts[0].isEmpty { out[parts[0]] = parts[1] }
        }
        return out
    }

    /// `true`/`false` (the `active` field) or the observed word form
    /// `valid`/`invalid` (the `valid` field on prod) — one parser for both,
    /// since neither field's vocabulary overlaps the other's.
    private static func flag(_ s: String) -> Bool? {
        switch s.lowercased() {
        case "true", "valid": return true
        case "false", "invalid": return false
        default: return nil
        }
    }

    // MARK: - Command history

    static let pendingAgeThresholdDays = 7

    static func healthRecord(
        deviceId: String, name: String, history: ComputerHistoryCommands, now: Date
    ) -> MDMCommandHealthRecord {
        let failed = history.commands.failed.command
        let pending = history.commands.pending.command
        let oldestIssuedMs = pending.compactMap(\.issuedEpoch).min()
        let oldestDays = oldestIssuedMs.map { ms -> Int in
            let issued = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
            return max(0, Int(now.timeIntervalSince(issued) / 86_400))
        }
        return MDMCommandHealthRecord(
            deviceId: deviceId, name: name,
            failedCount: failed.count, pendingCount: pending.count,
            failedCommands: failed.compactMap { $0.name?.isEmpty == false ? $0.name : nil },
            oldestPendingDays: oldestDays)
    }

    // MARK: - Run verdict

    /// Strictly more than a quarter of devices failed the call type.
    static func exceedsFailureBudget(failed: Int, total: Int) -> Bool {
        total > 0 && failed * 4 > total
    }
}
