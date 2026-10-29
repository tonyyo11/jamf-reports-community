import Foundation

/// The day's mobile-device figures, `DailySummary.mobile` (mobile spec 4.2): every device that
/// is not a Mac, counted apart from the Mac fields. A share is `{met, of}` over the devices that
/// report the field, and a pair or count no device reports is absent, never 0.
struct MobileSummary: Codable, Sendable, Equatable {
    struct Share: Codable, Sendable, Equatable {
        let met: Int
        let of: Int

        /// `met / of` on 0-100; nil when no device reports the field.
        var pct: Double? { of > 0 ? Double(met) / Double(of) * 100 : nil }
    }

    var managed: Int
    var unmanaged: Int
    var supervised: Share?
    var passcode: Share?
    var dataProtection: Share?
    var activationLock: Share?
    var osCurrent: Share?
    var stale: Int?
    var jailbroken: Int?
    var updateErrors: Int?

    /// One device as the summary reads it. nil is "not reported"; School fills only the
    /// fields its rows carry.
    struct Device: Sendable {
        var managed: Bool?
        var supervised: Bool?
        var passcodeCompliant: Bool?
        var dataProtected: Bool?
        var activationLock: Bool?
        var jailbroken: Bool?
        /// An iOS or iPadOS version; nil for a platform the iOS feed does not cover.
        var iOSVersion: String?
        var lastSeen: Date?
    }

    /// A device last seen MORE than `staleDays` whole days before `now`: the one stale rule for
    /// the summary, the Health Audit and the Mobile Devices filter.
    static func isStale(lastSeen: Date, staleDays: Int, now: Date) -> Bool {
        max(0, Int(now.timeIntervalSince(lastSeen) / 86_400)) > staleDays
    }

    /// The figures for `devices`, nil when there are none. `latestByMajor` is the iOS feed's
    /// (`SOFAFeedService.latestByMajor`); empty leaves `osCurrent` out. A device is stale when
    /// `lastSeen` is MORE than `staleDays` whole days before `now`.
    static func build(
        _ devices: [Device], latestByMajor: [Int: String], staleDays: Int, now: Date,
        updateErrors: Int? = nil
    ) -> MobileSummary? {
        guard !devices.isEmpty else { return nil }
        func share(_ values: [Bool?]) -> Share? {
            let reported = values.compactMap { $0 }
            guard !reported.isEmpty else { return nil }
            return Share(met: reported.filter { $0 }.count, of: reported.count)
        }
        func count(_ values: [Bool?]) -> Int? { share(values)?.met }
        let seen = devices.compactMap(\.lastSeen)
        let current = devices.compactMap(\.iOSVersion).map {
            SOFAFeedService.isCurrent($0, latestByMajor: latestByMajor)
        }
        return MobileSummary(
            managed: devices.filter { $0.managed == true }.count,
            unmanaged: devices.filter { $0.managed == false }.count,
            supervised: share(devices.filter { $0.managed == true }.map(\.supervised)),
            passcode: share(devices.map(\.passcodeCompliant)),
            dataProtection: share(devices.map(\.dataProtected)),
            activationLock: share(devices.map(\.activationLock)),
            osCurrent: share(current),
            stale: seen.isEmpty ? nil : seen.filter {
                isStale(lastSeen: $0, staleDays: staleDays, now: now)
            }.count,
            jailbroken: count(devices.map(\.jailbroken)),
            updateErrors: updateErrors)
    }

    /// The Jamf Pro reading of one `mobile-devices-list` row (`MobileFleetService` accessors).
    /// Apple TV is outside the iOS feed, so its version is not judged.
    static func device(_ item: MobileDeviceInventoryItem) -> Device {
        let isTV = MobileFleetService.classifyFormFactor(
            model: item.hardware?.model, modelIdentifier: item.hardware?.modelIdentifier,
            deviceType: item.deviceType) == .appleTV
        return Device(
            managed: item.general?.managed,
            supervised: item.general?.supervised,
            passcodeCompliant: MobileFleetService.passcodeCompliant(of: item),
            dataProtected: MobileFleetService.dataProtected(of: item),
            activationLock: MobileFleetService.activationLockEnabled(of: item),
            jailbroken: MobileFleetService.jailbreakStatus(of: item)
                .map { !$0.localizedCaseInsensitiveContains("none") },
            iOSVersion: isTV ? nil : MobileFleetService.firstNonBlank(item.general?.osVersion),
            lastSeen: item.general?.lastInventoryUpdateDate.flatMap(DateParser().parse))
    }

    /// The Jamf School reading of one device: its rows carry no passcode, data protection,
    /// Activation Lock or jailbreak field, and staleness is by last check-in.
    static func device(_ school: SchoolFleetService.Device) -> Device {
        let isIOS = ["iOS", "iPadOS"].contains(school.platform)
        let version = school.os.drop { !$0.isNumber }
        return Device(
            managed: school.isManaged, supervised: school.isSupervised,
            iOSVersion: isIOS && !version.isEmpty ? String(version) : nil,
            lastSeen: school.lastCheckin)
    }

    /// The figures from the bytes of a `mobile-devices-list` snapshot, nil when it does not
    /// decode or no row has a GENERAL or SECURITY section (a row without either, such as an
    /// "Unknown" record or the flat list older jamf-cli wrote, says nothing a figure counts).
    static func fromMobileDevicesList(
        _ data: Data, latestByMajor: [Int: String], staleDays: Int, now: Date,
        updateErrors: Int? = nil
    ) -> MobileSummary? {
        guard let rows = try? JSONDecoder().decode([MobileDeviceInventoryItem].self, from: data)
        else { return nil }
        let devices = rows.filter(MobileFleetService.reportsPosture).map { device($0) }
        return build(
            devices, latestByMajor: latestByMajor, staleDays: staleDays, now: now,
            updateErrors: updateErrors)
    }

    /// This day's figures with each one it lacks taken from `older`, the same day's earlier
    /// summary; the device counts are this run's.
    func filling(from older: MobileSummary?) -> MobileSummary {
        guard let older else { return self }
        var merged = self
        merged.supervised = supervised ?? older.supervised
        merged.passcode = passcode ?? older.passcode
        merged.dataProtection = dataProtection ?? older.dataProtection
        merged.activationLock = activationLock ?? older.activationLock
        merged.osCurrent = osCurrent ?? older.osCurrent
        merged.stale = stale ?? older.stale
        merged.jailbroken = jailbroken ?? older.jailbroken
        merged.updateErrors = updateErrors ?? older.updateErrors
        return merged
    }

    var counts: [Int] {
        [managed, unmanaged] + [stale, jailbroken, updateErrors].compactMap { $0 }
            + shares.flatMap { [$0.met, $0.of] }
    }

    /// Every pair has `0 <= met <= of`.
    var sharesAreConsistent: Bool { shares.allSatisfy { 0 <= $0.met && $0.met <= $0.of } }

    private var shares: [Share] {
        [supervised, passcode, dataProtection, activationLock, osCurrent].compactMap { $0 }
    }
}
