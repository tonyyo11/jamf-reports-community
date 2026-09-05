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
        "device.operating-system.build-version",
        "device.model.identifier",
        "management.declarations.configurations",
        "management.declarations.activations",
        "softwareupdate.pending-version.os-version",
        "softwareupdate.pending-version.build-version",
        "softwareupdate.install-state",
        "softwareupdate.install-reason.reason",
        "softwareupdate.failure-reason",
        "softwareupdate.beta-enrollment",
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
            osBuild: kept["device.operating-system.build-version"],
            reportDate: newest, ddmReported: true, declarations: declarations,
            softwareUpdate: .init(
                pendingOSVersion: kept["softwareupdate.pending-version.os-version"],
                pendingBuild: kept["softwareupdate.pending-version.build-version"],
                installState: kept["softwareupdate.install-state"],
                installReason: kept["softwareupdate.install-reason.reason"],
                failureReason: kept["softwareupdate.failure-reason"],
                failureAt: payload.statusItems.first {
                    $0.key == "softwareupdate.failure-reason" && !($0.value ?? "").isEmpty
                }?.lastUpdateTime,
                betaEnrollment: kept["softwareupdate.beta-enrollment"]))
    }

    static func ddmRecordNotReported(
        deviceId: String, name: String, managementId: String
    ) -> DDMDeviceStatusRecord {
        DDMDeviceStatusRecord(deviceId: deviceId, name: name, managementId: managementId,
                              osVersion: nil, osBuild: nil, reportDate: nil, ddmReported: false,
                              declarations: [], softwareUpdate: .empty)
    }

    // MARK: - Declaration string

    /// `{active=true, identifier=…, valid=true, server-token=…}` groups, possibly
    /// several, possibly with a nested `reasons={code=…, description=…}`.
    /// Top-level groups are found by brace depth; a group without an
    /// `identifier` is dropped. `server-token` is read and discarded here.
    static func parseDeclarations(_ raw: String) -> [DDMDeviceStatusRecord.Declaration] {
        topLevelGroups(raw).compactMap { group in
            let fields = keyValues(group)
            guard let identifier = fields["identifier"], !identifier.isEmpty else { return nil }
            let reasons = reasonsBody(group)
            return .init(
                identifier: identifier,
                active: fields["active"].flatMap(bool),
                valid: fields["valid"].flatMap(validState),
                reasonCode: reasons.flatMap { capture(#"code=([^,}]*)"#, in: $0) },
                reasonText: reasons.flatMap { capture(#"description=([^}]*)"#, in: $0) })
        }
    }

    /// The body of a `reasons={…}` sub-group inside a declaration group, or
    /// nil when absent. `code=`/`description=` are read from THIS substring
    /// only, so a same-named field elsewhere in the group is never mistaken
    /// for a failure reason.
    private static func reasonsBody(_ group: String) -> String? {
        guard let marker = group.range(of: "reasons={") else { return nil }
        var depth = 1
        var idx = marker.upperBound
        let start = idx
        while idx < group.endIndex {
            switch group[idx] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return String(group[start..<idx]) }
            default: break
            }
            idx = group.index(after: idx)
        }
        return nil
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

    private static func bool(_ s: String) -> Bool? {
        switch s.lowercased() {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    /// `valid` is a WORD on prod (`valid`/`invalid`), not a boolean literal —
    /// accept both the observed word form and a plain boolean, in case a
    /// future jamf-cli version emits `true`/`false` here instead.
    private static func validState(_ s: String) -> Bool? {
        switch s.lowercased() {
        case "valid", "true": return true
        case "invalid", "false": return false
        default: return nil
        }
    }

    private static func capture(_ pattern: String, in s: String) -> String? {
        guard let r = s.range(of: pattern, options: .regularExpression) else { return nil }
        let m = String(s[r])
        guard let eq = m.firstIndex(of: "=") else { return nil }
        let v = m[m.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? nil : v
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
