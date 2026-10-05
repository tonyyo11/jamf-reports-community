import Foundation

/// The three Jamf Pro dates of one Mac in a `computers` snapshot, with the identifiers that
/// find it from a row of another snapshot.
struct ComputerDates: Sendable, Equatable {
    var jamfID: String?
    var serial: String?
    /// `general.lastCheckIn`: the Jamf binary checking in.
    var checkIn: Date?
    /// `general.reportDate`: the Jamf binary submitting inventory.
    var inventory: Date?
    /// `general.lastContact`: any contact, MDM included. Nil before Jamf Pro 11.30 and for a
    /// Mac with no contact since it was first recorded.
    var contact: Date?

    init(
        jamfID: String? = nil, serial: String? = nil,
        checkIn: Date? = nil, inventory: Date? = nil, contact: Date? = nil
    ) {
        self.jamfID = jamfID
        self.serial = serial
        self.checkIn = checkIn
        self.inventory = inventory
        self.contact = contact
    }

    /// One element of a `computers` snapshot. Jamf Pro's v4 inventory renamed
    /// `lastContactTime` to `lastCheckIn`; the older name is read for a snapshot that has it,
    /// and so are the flat `last_check_in` and `last_contact` of the fixtures and exports that
    /// have no `general` section. Jamf's own `general.lastContact` is a different field: any
    /// contact, MDM included.
    init(item: [String: Any]) {
        let general = item["general"] as? [String: Any] ?? [:]
        let hardware = item["hardware"] as? [String: Any] ?? [:]
        func text(_ values: [String: Any], _ keys: [String]) -> String? {
            keys.lazy.compactMap { values[$0] as? String }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
        }
        func date(_ values: [String: Any], _ keys: [String]) -> Date? {
            text(values, keys).flatMap(DeviceInventoryService.parseDate)
        }
        let checkIn = date(general, ["lastCheckIn", "lastContactTime", "lastContactDate"])
            ?? date(item, ["lastContactDate", "last_check_in", "last_contact"])
        self.init(
            jamfID: Self.numericID(item["id"]) ?? Self.numericID(general["id"]),
            serial: text(hardware, ["serialNumber"]) ?? text(general, ["serialNumber"]),
            checkIn: checkIn,
            inventory: date(general, ["reportDate", "lastReportDate"])
                ?? date(item, ["lastReportDate"]),
            contact: date(general, ["lastContact"]))
    }

    private static func numericID(_ value: Any?) -> String? {
        let text: String? = switch value {
        case let value as String: value
        case _ as Bool: nil
        case let value as NSNumber: value.stringValue
        default: nil
        }
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty, trimmed.allSatisfy(\.isASCII), trimmed.allSatisfy(\.isNumber)
        else { return nil }
        return trimmed
    }

    /// The Macs of a `computers` snapshot: a bare array, or an envelope with `results`.
    /// Nil when the data is neither.
    static func decodeSnapshot(_ data: Data) -> [ComputerDates]? {
        let object = try? JSONSerialization.jsonObject(with: data)
        let items = (object as? [[String: Any]])
            ?? (object as? [String: Any]).flatMap { $0["results"] as? [[String: Any]] }
        return items?.map(ComputerDates.init(item:))
    }
}

/// Finds a Mac's dates from a row that carries a Jamf ID, a serial or both, by the identifiers
/// the Devices merge uses (`DeviceRecordMerger`): the Jamf ID first, then the serial. An
/// identifier two Macs share finds neither (a logic-board swap leaves two records on one
/// serial), and a serial never joins two records whose Jamf IDs differ. A computer name never
/// decides: two Macs can share one.
struct ComputerDateIndex: Sendable {
    private let byID: [String: ComputerDates]
    private let bySerial: [String: ComputerDates]

    init(_ computers: [ComputerDates]) {
        byID = Self.unique(computers) { $0.jamfID }
        bySerial = Self.unique(computers) { $0.serial }
    }

    /// Nil when the data is not a `computers` snapshot.
    init?(snapshot data: Data) {
        guard let computers = ComputerDates.decodeSnapshot(data) else { return nil }
        self.init(computers)
    }

    func match(jamfID: String?, serial: String?) -> ComputerDates? {
        let id = Self.key(jamfID)
        if let id, let found = byID[id] { return found }
        guard let serial = Self.key(serial), let found = bySerial[serial] else { return nil }
        if let id, let theirs = Self.key(found.jamfID), theirs != id { return nil }
        return found
    }

    private static func unique(
        _ computers: [ComputerDates], by identifier: (ComputerDates) -> String?
    ) -> [String: ComputerDates] {
        var seen: [String: ComputerDates] = [:]
        var shared: Set<String> = []
        for computer in computers {
            guard let key = key(identifier(computer)) else { continue }
            if seen[key] != nil { shared.insert(key) } else { seen[key] = computer }
        }
        return seen.filter { !shared.contains($0.key) }
    }

    private static func key(_ identifier: String?) -> String? {
        let trimmed = identifier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}
