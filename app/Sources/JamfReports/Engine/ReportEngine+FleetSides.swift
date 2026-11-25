import Foundation

/// Fleet-aware collecting: a Jamf Pro fleet with no mobile devices does not collect the mobile
/// sources, and one with no computers does not collect the Mac sources, until `pro overview`
/// counts one. Jamf School, Protect and Security Cloud are not affected.
enum FleetSide: String, Sendable, CaseIterable, Codable {
    case mac
    case mobile

    /// The list whose rows confirm the overview's zero.
    var listKind: String { self == .mac ? "computers" : "mobile-devices-list" }
}

/// Which side of the fleet a Jamf Pro source describes.
enum SourceSides: Sendable, Equatable {
    case mac
    case mobile
    case both

    var side: FleetSide? {
        switch self {
        case .mac: .mac
        case .mobile: .mobile
        case .both: nil
        }
    }
}

/// What the newest `pro overview` says about the fleet, and the sides a collect leaves out.
struct FleetState: Sendable, Equatable {
    /// Managed plus unmanaged, from Fleet rows; nil when not known.
    var computers: Int?
    var mobileDevices: Int?
    /// Sides whose sources are skipped (`ReportEngine.skippedSides`).
    var skipped: Set<FleetSide> = []

    static let unknown = FleetState()

    /// Mobile devices and no computers: the daily summary is built from the mobile list.
    var isMobileOnly: Bool { computers == 0 && (mobileDevices ?? 0) > 0 }

    func count(_ side: FleetSide) -> Int? { side == .mac ? computers : mobileDevices }

    /// The overview counts older than this say nothing.
    static let overviewMaxAge: TimeInterval = 48 * 3600
    /// A side is collected at least this often, as a check on the overview's zero.
    static let recheckInterval: TimeInterval = 7 * 86_400

    /// The two sides from `pro overview` rows. Either addend missing or not a whole number
    /// makes that side unknown.
    static func presence(overview rows: [Any]) -> FleetState {
        func side(_ managed: String, _ unmanaged: String) -> Int? {
            guard let a = SiteScope.fleetTotal(rows, resource: managed),
                  let b = SiteScope.fleetTotal(rows, resource: unmanaged) else { return nil }
            return a + b
        }
        return FleetState(
            computers: side("Managed Computers", "Unmanaged Computers"),
            mobileDevices: side("Managed Devices", "Unmanaged Devices"))
    }

    /// The fleet for a Jamf Pro collect from `dataDir`: the overview's counts when its newest
    /// snapshot is readable and stamped within 48 hours, then each side whose count is 0 and
    /// whose own list, newest snapshot readable and under 7 days old, holds no rows.
    static func load(dataDir: URL?, now: Date = Date()) -> FleetState {
        guard let dataDir,
              let (data, _) = newest("overview", in: dataDir, maxAge: overviewMaxAge, now: now),
              let rows = (try? JSONSerialization.jsonObject(with: data)) as? [Any]
        else { return .unknown }
        var state = presence(overview: rows)
        for side in FleetSide.allCases where state.count(side) == 0 {
            guard let (list, _) = newest(side.listKind, in: dataDir, maxAge: recheckInterval,
                                         now: now),
                  rowCount(list, side: side) == 0 else { continue }
            state.skipped.insert(side)
        }
        return state
    }

    /// Newest snapshot of `kind` stamped within `maxAge` of `now`, read through the snapshot
    /// seam; nil when absent, older, unreadable or stamped more than the clock-skew tolerance
    /// ahead (a peer's planted future file must not keep a side skipped for good).
    private static func newest(
        _ kind: String, in dataDir: URL, maxAge: TimeInterval, now: Date
    ) -> (Data, Date)? {
        let dir = dataDir.appendingPathComponent(kind, isDirectory: true)
        guard let url = FileManager.newestJSONFile(in: dir),
              let stamp = CloudStorage.snapshotTimestamp(of: url),
              stamp.timeIntervalSince(now) <= SharedWorkspace.clockSkewTolerance,
              now.timeIntervalSince(min(stamp, now)) < maxAge,
              let data = BoundedFile.readSnapshotLogged(url) else { return nil }
        return (data, stamp)
    }

    private static func rowCount(_ data: Data, side: FleetSide) -> Int? {
        switch side {
        case .mac: ((try? JSONSerialization.jsonObject(with: data)) as? [Any])?.count
        case .mobile: MobileFleetService.deviceCount(fromMobileDevicesListData: data)
        }
    }
}

extension ReportEngine {

    /// The side each Jamf Pro source describes: every matrix kind, both device-scan kinds and
    /// both after-matrix kinds. A kind missing here is never skipped for its side.
    // When unsure, `.both`: a source wrongly classed to one side would be skipped on a fleet
    // that has only the other. `profile-status` and `app-status` read MDM command history for
    // every device, `ddm-status` and `blueprint-status` cover all Platform devices, and
    // Compliance Benchmarks are not Mac-only by contract.
    static let sourceSides: [String: SourceSides] = [
        "overview": .both, "sites": .both, "buildings": .both, "departments": .both,
        "categories": .both, "groups": .both, "update-status": .both,
        "update-device-failures": .both, "device-enrollment-instances": .both, "audit": .both,
        dashboardKind: .both, sofaKind: .both,
        "mobile-devices-list": .mobile, "classic-mobile-device-groups": .mobile,
        "advanced-mobile-device-searches": .mobile, "classic-ios-profiles": .mobile,
        "security": .mac, "inventory-summary": .mac, "device-compliance": .mac,
        "computers": .mac, "patch-status": .mac, "patch-device-failures": .mac,
        patchReleaseDatesKind: .mac, "policy-status": .mac, "classic-macos-profiles": .mac,
        "app-status": .both, "software-installs": .mac, "computer-extension-attributes": .mac,
        "ea-results": .mac, "profile-status": .both, "compliance-devices": .both,
        "compliance-rules": .both, "ddm-status": .both, "blueprint-status": .both,
        "policies": .mac, "scripts": .mac, "packages": .mac, "smart-computer-groups": .mac,
        "classic-computer-groups": .mac, "duplicate-serials": .mac,
        "certificate-authority": .both,
        ddmDeviceStatusKind: .mac, mdmCommandHealthKind: .mac,
    ]

    /// The side whose skip leaves `kind` out, or nil.
    static func skippedSide(of kind: String, skipped: Set<FleetSide>) -> FleetSide? {
        sourceSides[kind]?.side.flatMap { skipped.contains($0) ? $0 : nil }
    }

    /// Every kind of the skipped sides, for the readers that treat them as absent.
    static func kinds(of sides: Set<FleetSide>) -> Set<String> {
        Set(sourceSides.compactMap { kind, value in
            value.side.map(sides.contains) == true ? kind : nil
        })
    }
}
