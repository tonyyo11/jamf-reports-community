import Foundation

/// The daily summary's aggregate device maps (environment model P9-R3), built from the
/// snapshots the MDM summary writers already read. A map with no entries is nil, a bucket with
/// no device is left out (absent is not zero), and a device missing the field a map keys on
/// is left out of that map only.
enum SummaryDeviceMaps {

    /// The four summary fields one writer sets; every one nil when nothing reports it.
    struct Fields: Sendable, Equatable {
        var osMajor: [String: Int]?
        var modelFamily: [String: Int]?
        var formFactor: [String: Int]?
        var lastSeen: LastSeenBuckets?
    }

    private static let families = [
        "MacBook Air", "MacBook Pro", "MacBook", "Mac mini", "iMac", "Mac Pro", "Mac Studio",
    ].sorted { $0.count > $1.count }

    /// The marketing model's family by prefix, longest first; an identifier such as `Mac14,13`
    /// or no name is `Other`.
    static func modelFamily(_ marketingName: String?) -> String {
        let name = marketingName?.trimmingCharacters(in: .whitespaces) ?? ""
        return families.first { name.range(of: $0, options: [.anchored, .caseInsensitive]) != nil }
            ?? "Other"
    }

    /// `"macOS 26"` from a platform word and a version; nil when the version has no major.
    static func osMajorKey(platform: String, version: String?) -> String? {
        let digits = (version ?? "").drop { !$0.isNumber }.prefix { $0.isNumber }
        guard !platform.isEmpty, !digits.isEmpty else { return nil }
        return "\(platform) \(Int(digits) ?? 0)"
    }

    static func computers(
        _ records: [DeviceInventoryRecord], rule: StaleRule, now: Date
    ) -> (osMajor: [String: Int], modelFamily: [String: Int], lastSeen: LastSeenBuckets.Counts?) {
        let ages = records.compactMap { $0.staleAge(rule, now: now) }
        return (
            tally(records.map { osMajorKey(platform: "macOS", version: $0.osVersion) }),
            tally(records.map { modelFamily($0.marketingModel) }),
            buckets(ages.compactMap { age -> Int? in
                if case .days(let days) = age { return days }
                return nil
            }, never: ages.filter { $0 == .never }.count))
    }

    static func mobile(
        _ items: [MobileDeviceInventoryItem], now: Date
    ) -> (osMajor: [String: Int], formFactor: [String: Int], lastSeen: LastSeenBuckets.Counts?) {
        let parser = DateParser()
        let forms = items.map {
            MobileFleetService.classifyFormFactor(
                model: $0.hardware?.model, modelIdentifier: $0.hardware?.modelIdentifier,
                deviceType: $0.deviceType)
        }
        let osKeys = zip(items, forms).map { item, form in
            osMajorKey(
                platform: mobilePlatform(deviceType: item.deviceType, form: form),
                version: item.general?.osVersion)
        }
        let days = items.compactMap { item in
            item.general?.lastInventoryUpdateDate.flatMap(parser.parse)
                .map { wholeDays(from: $0, to: now) }
        }
        return (
            tally(osKeys), tally(forms.map(formFactorKey)), buckets(days, never: 0))
    }

    static func school(
        _ devices: [SchoolFleetService.Device], now: Date
    ) -> (
        osMajor: [String: Int], computersLastSeen: LastSeenBuckets.Counts?,
        mobileLastSeen: LastSeenBuckets.Counts?
    ) {
        func days(_ list: [SchoolFleetService.Device]) -> [Int] {
            list.compactMap { $0.lastCheckin.map { wholeDays(from: $0, to: now) } }
        }
        let macs = devices.filter { $0.platform == "macOS" }
        let others = devices.filter { !["macOS", "Unknown"].contains($0.platform) }
        let keys = devices.map {
            $0.platform == "Unknown" ? nil : osMajorKey(platform: $0.platform, version: $0.os)
        }
        return (tally(keys), buckets(days(macs), never: 0), buckets(days(others), never: 0))
    }

    /// The fields a Jamf Pro summary carries, from the raw `computers` and `mobile-devices-list`
    /// snapshots; either may be absent.
    static func jamfPro(
        computersData: Data?, mobileData: Data?, rule: StaleRule, now: Date
    ) -> Fields {
        var fields = Fields()
        var os: [String: Int] = [:]
        var seen = LastSeenBuckets()
        if let items = computersData.flatMap({ try? JSONSerialization.jsonObject(with: $0) })
            as? [[String: Any]], !items.isEmpty {
            let result = computers(
                items.map { DeviceInventoryService.recordFromComputer($0, source: "computers") },
                rule: rule, now: now)
            os = result.osMajor
            fields.modelFamily = nilIfEmpty(result.modelFamily)
            seen.computers = result.lastSeen
        }
        if let rows = mobileData.flatMap({
            try? JSONDecoder().decode([MobileDeviceInventoryItem].self, from: $0)
        }), !rows.isEmpty {
            let result = mobile(rows, now: now)
            os.merge(result.osMajor, uniquingKeysWith: +)
            fields.formFactor = nilIfEmpty(result.formFactor)
            seen.mobile = result.lastSeen
        }
        fields.osMajor = nilIfEmpty(os)
        fields.lastSeen = seen.computers == nil && seen.mobile == nil ? nil : seen
        return fields
    }

    /// The fields a School summary carries (`osMajor` and `lastSeen` only).
    static func schoolFields(_ devices: [SchoolFleetService.Device], now: Date) -> Fields {
        let result = school(devices, now: now)
        let seen = LastSeenBuckets(
            computers: result.computersLastSeen, mobile: result.mobileLastSeen)
        return Fields(
            osMajor: nilIfEmpty(result.osMajor),
            lastSeen: seen.computers == nil && seen.mobile == nil ? nil : seen)
    }

    // MARK: - Helpers

    private static func nilIfEmpty(_ map: [String: Int]) -> [String: Int]? {
        map.isEmpty ? nil : map
    }

    private static func tally(_ keys: [String?]) -> [String: Int] {
        keys.compactMap { $0 }.reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }

    private static func wholeDays(from date: Date, to now: Date) -> Int {
        max(0, Int(now.timeIntervalSince(date) / 86_400))
    }

    /// Under one day is 0 whole days, under seven is 1-6; a bucket nobody is in is nil, and no
    /// bucket at all is a nil `Counts`.
    private static func buckets(_ known: [Int], never: Int) -> LastSeenBuckets.Counts? {
        func count(_ n: Int) -> Int? { n > 0 ? n : nil }
        let result = LastSeenBuckets.Counts(
            underOneDay: count(known.filter { $0 < 1 }.count),
            underSevenDays: count(known.filter { $0 >= 1 && $0 < 7 }.count),
            sevenDaysOrMore: count(known.filter { $0 >= 7 }.count),
            never: count(never))
        return result.values.isEmpty ? nil : result
    }

    /// The form factor's platform; the device's own OS type only for a device the form factor
    /// cannot place (Jamf reports iPads with `deviceType` "iOS", so it cannot come first).
    private static func mobilePlatform(
        deviceType: String?, form: MobileFleetService.FormFactor
    ) -> String {
        switch form {
        case .iPad: return "iPadOS"
        case .iPhone: return "iOS"
        case .appleTV: return "tvOS"
        case .other:
            switch (deviceType ?? "").lowercased() {
            case "ios": return "iOS"
            case "ipados": return "iPadOS"
            case "tvos": return "tvOS"
            default: return ""
            }
        }
    }

    private static func formFactorKey(_ form: MobileFleetService.FormFactor) -> String {
        switch form {
        case .iPad: "iPad"
        case .iPhone: "iPhone"
        case .appleTV: "Apple TV"
        case .other: "Other"
        }
    }
}
