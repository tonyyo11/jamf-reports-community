import Foundation

/// Finds the inventory record (a Jamf Pro computer or mobile device, a Jamf School device) a
/// probe row describes, by identifier only. Same rule as
/// `DeviceRecordMerger`: a candidate shares an identifier with the probe and no identifier
/// they both carry differs. A name never decides. An identifier value on more than
/// `DeviceRecordMerger.maxRecordsPerSharedIdentifier` records is a placeholder and joins nothing.
struct DeviceCorrelation: Sendable {
    enum Match: Equatable, Sendable {
        case matched(Int, via: DeviceIdentifier)
        case unmatched
        case ambiguous(Int)
        case noIdentifier
    }

    private let records: [DeviceInventoryRecord]
    private let index: [DeviceIdentifier: [String: [Int]]]

    init(records: [DeviceInventoryRecord]) {
        self.records = records
        var index: [DeviceIdentifier: [String: [Int]]] = [:]
        for (position, record) in records.enumerated() {
            for (kind, value) in record.identifiers {
                index[kind, default: [:]][value, default: []].append(position)
            }
        }
        self.index = index
    }

    /// `probe` carries the identifiers of the row to place (a record with only those set).
    func match(_ probe: DeviceInventoryRecord) -> Match {
        let identifiers = probe.identifiers
        guard !identifiers.isEmpty else { return .noIdentifier }
        let cap = DeviceRecordMerger.maxRecordsPerSharedIdentifier
        var via: [Int: DeviceIdentifier] = [:]
        // Strongest first, so a candidate keeps the strongest identifier it shares.
        for (kind, value) in identifiers {
            guard let holders = index[kind]?[value], holders.count <= cap else { continue }
            for position in holders
            where via[position] == nil && !probe.disagrees(with: records[position]) {
                via[position] = kind
            }
        }
        let strong = via.filter { $0.value.isStrong }
        let pool = strong.isEmpty ? via : strong
        switch pool.count {
        case 0: return .unmatched
        case 1: return pool.first.map { .matched($0.key, via: $0.value) } ?? .unmatched
        default: return .ambiguous(pool.count)
        }
    }
}

/// Which Protect computers are Jamf Pro computers, or on a Jamf School workspace (2.11) Jamf
/// School devices. Protect's `uuid` is taken to be the hardware UUID, the inventory's `udid`
/// (Protect writes it lowercased; identifiers compare lowercased); `hostname` is never matched.
struct ProtectProCorrelation: Sendable {
    /// The inventory Protect is matched against.
    enum Inventory: Sendable {
        case jamfPro, jamfSchool

        var product: String { self == .jamfPro ? "Jamf Pro" : "Jamf School" }
    }

    var inventory = Inventory.jamfPro
    var protectCount = 0
    /// How many inventory records the match ran against.
    var inventorySize = 0
    var matched = 0
    var ambiguous = 0
    var noIdentifier = 0
    var notInPro: [ProtectComputerRow] = []
    var proWithoutProtect: [DeviceInventoryRecord] = []

    /// Protect computers that carry a UUID or serial: the denominator of the match.
    var identified: Int { protectCount - noIdentifier }

    /// matched of identified; nil with no inventory or no identified Protect computer.
    var matchedShare: MobileSummary.Share? {
        inventorySize > 0 && identified > 0 ? .init(met: matched, of: identified) : nil
    }

    static func build(
        protect: [ProtectComputerRow], pro: [DeviceInventoryRecord]
    ) -> ProtectProCorrelation {
        let correlation = DeviceCorrelation(records: pro)
        var result = ProtectProCorrelation(protectCount: protect.count)
        var claimed = Set<Int>()
        for row in protect {
            var probe = DeviceInventoryRecord.empty(id: "protect", source: "protect")
            probe.udid = row.uuid
            probe.serial = row.serial ?? ""
            switch correlation.match(probe) {
            case .matched(let position, _):
                result.matched += 1
                claimed.insert(position)
            case .unmatched: result.notInPro.append(row)
            case .ambiguous: result.ambiguous += 1
            case .noIdentifier: result.noIdentifier += 1
            }
        }
        // A record with no UDID or serial can never match, so it is not inventory to match against.
        result.inventorySize = pro.filter {
            $0.identifier(.udid) != nil || $0.identifier(.serial) != nil
        }.count
        result.proWithoutProtect = pro.enumerated()
            .filter { !claimed.contains($0.offset) }.map(\.element)
        return result
    }

    /// Against Jamf School devices by `udid`, then serial. Every device can match, but only
    /// Macs can run Protect, so `proWithoutProtect` lists the Macs no Protect computer claimed.
    static func build(
        protect: [ProtectComputerRow], school: [SchoolFleetService.Device]
    ) -> ProtectProCorrelation {
        // The position is the id: two School rows can share an `id` when neither has a udid.
        let records = school.enumerated().map { position, device in
            var record = DeviceInventoryRecord.empty(id: "\(position)", source: "school")
            record.name = device.name
            record.serial = device.serial
            record.udid = device.udid
            record.osVersion = device.os
            return record
        }
        let macs = Set(school.indices.filter { school[$0].platform == "macOS" }.map { "\($0)" })
        var result = build(protect: protect, pro: records)
        result.inventory = .jamfSchool
        result.proWithoutProtect.removeAll { !macs.contains($0.id) }
        return result
    }

    /// nil when there is no Jamf Pro `computers` snapshot (or, for Jamf School, no
    /// `school-devices` snapshot) to match against.
    static func load(
        protect: [ProtectComputerRow], profile: String, demoMode: Bool, school: Bool = false
    ) -> ProtectProCorrelation? {
        if school, !demoMode {
            let snapshot = SchoolFleetService.load(profile: profile)
            guard snapshot.devicesDate != nil else { return nil }
            return build(protect: protect, school: snapshot.devices)
        }
        let pro = demoMode
            ? DemoData.outreachRecords
            : DeviceInventoryService.cachedComputerRecords(profile: profile)
        return pro.map { build(protect: protect, pro: $0) }
    }
}

/// Which Security Cloud risk rows are devices of this environment's inventory, by `externalId`
/// (the device UDID; Security Cloud writes it lowercased, Jamf Pro uppercase, so identifiers
/// compare lowercased). The inventory is the Jamf Pro computers and mobile devices, or the Jamf
/// School devices (their `udid` is assumed the same, unverified against a tenant). A name never
/// joins and a row with no `externalId` is counted apart.
struct SecurityCloudCorrelation: Sendable {
    var inventory = ProtectProCorrelation.Inventory.jamfPro
    var securityCount = 0
    var inventorySize = 0
    var matched = 0
    var ambiguous = 0
    var noIdentifier = 0

    /// Rows that carry an `externalId`: the denominator of the match.
    var identified: Int { securityCount - noIdentifier }

    /// matched of identified; nil with no inventory or no identified row.
    var matchedShare: MobileSummary.Share? {
        inventorySize > 0 && identified > 0 ? .init(met: matched, of: identified) : nil
    }

    static func build(
        rows: [SecurityRiskRow], inventory records: [DeviceInventoryRecord]
    ) -> SecurityCloudCorrelation {
        let correlation = DeviceCorrelation(records: records)
        // Only a UDID can match, so a record with none is not inventory to match against.
        var result = SecurityCloudCorrelation(
            securityCount: rows.count,
            inventorySize: records.filter { $0.identifier(.udid) != nil }.count)
        for row in rows {
            var probe = DeviceInventoryRecord.empty(id: "security-cloud", source: "security-cloud")
            probe.udid = row.externalId ?? ""
            switch correlation.match(probe) {
            case .matched: result.matched += 1
            case .unmatched: break
            case .ambiguous: result.ambiguous += 1
            case .noIdentifier: result.noIdentifier += 1
            }
        }
        return result
    }

    /// A record carrying only a UDID, for a device whose snapshot offers nothing else to join on.
    private static func udidRecord(_ udid: String?, source: String) -> DeviceInventoryRecord {
        var record = DeviceInventoryRecord.empty(id: source, source: source)
        record.udid = udid ?? ""
        return record
    }

    /// Against Jamf Pro: the `computers` snapshot plus the mobile devices' `general.udid`; nil
    /// when neither snapshot exists. Protect's match stays computers only.
    static func load(
        rows: [SecurityRiskRow], profile: String, mobile: MobileFleetService.Snapshot
    ) -> SecurityCloudCorrelation? {
        let computers = DeviceInventoryService.cachedComputerRecords(profile: profile)
        guard computers != nil || mobile.isDetected else { return nil }
        let devices = mobile.richDevices.map { udidRecord($0.general?.udid, source: "mobile") }
        return build(rows: rows, inventory: (computers ?? []) + devices)
    }

    /// Against the Jamf School devices by `udid`; nil when there is no `school-devices`
    /// snapshot.
    static func load(rows: [SecurityRiskRow], schoolProfile: String) -> SecurityCloudCorrelation? {
        let snapshot = SchoolFleetService.load(profile: schoolProfile)
        guard snapshot.devicesDate != nil else { return nil }
        var result = build(
            rows: rows, inventory: snapshot.devices.map { udidRecord($0.udid, source: "school") })
        result.inventory = .jamfSchool
        return result
    }
}
