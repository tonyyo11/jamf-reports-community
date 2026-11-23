import Foundation

/// meridianedu, the demo Jamf School environment: one district fleet the School Overview, School
/// Devices, Trends and Fleet Overview all read through the live readers, so they cannot
/// disagree. Its Mac count is the sidebar's for that workspace. Reads no disk.
extension DemoData {

    static let schoolWorkspace = "meridianedu"

    /// The district's Macs: the sidebar and Fleet Overview count for meridianedu.
    static var schoolMacCount: Int {
        deviceCount(forProfileAt: cliProfiles.firstIndex { $0.name == schoolWorkspace } ?? 1)
    }
    static let schoolIPadCount = 340
    static let schoolAppleTVCount = 12
    /// Devices in School's trash: counted apart, never in a fleet figure.
    static let schoolTrashedCount = 9

    static let schoolUserCount = 1_212
    static let schoolDeviceGroupCount = 38
    static let schoolClassCount = 186

    /// When meridianedu's newest collect wrote `school-devices`.
    static var schoolCollectedAt: Date {
        cacheDate(for: [SchoolFleetService.devicesKind], profile: schoolWorkspace) ?? referenceDate
    }

    /// The district fleet as `SchoolFleetService.load` would read it.
    static let schoolSnapshot: SchoolFleetService.Snapshot = {
        var snapshot = SchoolFleetService.Snapshot()
        snapshot.devices = schoolMacs() + schoolIPads() + schoolAppleTVs()
        snapshot.trashedCount = schoolTrashedCount
        snapshot.depDevices = schoolDEPDevices
        snapshot.overview = schoolOverviewRows(deviceCount: snapshot.devices.count)
        snapshot.users = schoolUsers
        snapshot.deviceGroups = schoolDeviceGroups
        snapshot.classes = schoolClasses
        snapshot.deviceDetail = SchoolDeviceDetail(
            rows: schoolDeviceDetailRows(snapshot.devices), date: schoolCollectedAt)
        snapshot.devicesDate = schoolCollectedAt
        snapshot.depDate = schoolCollectedAt
        snapshot.overviewDate = schoolCollectedAt
        return snapshot
    }()

    /// The district's newest daily summary, written by the live School writer and dated on the
    /// last demo trend week, as meridian-prod's newest summary is.
    static let schoolSummary: DailySummary? = {
        ReportEngine.schoolSummary(
            from: schoolSnapshot, date: trendDates.last ?? "2026-04-20",
            staleDays: 30, now: schoolCollectedAt,
            collectionSources: [SchoolFleetService.devicesKind: "live"], collectedByHost: nil)
    }()

    // MARK: - Devices

    private static func schoolMacs() -> [SchoolFleetService.Device] {
        let versions = ["15.4", "15.4", "15.4", "15.4", "15.4", "15.4",
                        "15.3.2", "15.3.2", "15.3.2", "14.7.4"]
        let models = ["MacBook Air (M2, 2022)", "MacBook Air (M2, 2022)",
                      "MacBook Air (M2, 2022)", "iMac (24-inch, M3, 2023)"]
        return (0..<schoolMacCount).map { i in
            let managed = i % 97 != 50
            return schoolDevice(
                kind: "MAC", index: i, model: models[i % models.count],
                os: "macOS \(versions[(i * 7) % versions.count])", managed: managed,
                supervised: managed && i % 23 != 4, staleEvery: 41, staleAt: 7)
        }
    }

    private static func schoolIPads() -> [SchoolFleetService.Device] {
        let versions = ["18.2.1", "18.2.1", "18.2.1", "18.2.1", "18.2.1", "18.2.1",
                        "18.1.1", "18.1.1", "17.6.1", "17.6.1"]
        let models = ["iPad (10th generation)", "iPad (10th generation)", "iPad Air (M2)"]
        return (0..<schoolIPadCount).map { i in
            let managed = i % 113 != 60
            return schoolDevice(
                kind: "IPAD", index: i, model: models[i % models.count],
                os: "iPadOS \(versions[(i * 3) % versions.count])", managed: managed,
                supervised: managed && i % 53 != 20, staleEvery: 29, staleAt: 11)
        }
    }

    private static func schoolAppleTVs() -> [SchoolFleetService.Device] {
        (0..<schoolAppleTVCount).map { i in
            schoolDevice(
                kind: "ATV", index: i, model: "Apple TV 4K (3rd generation)", os: "tvOS 18.2",
                managed: true, supervised: true, staleEvery: 0, staleAt: 0)
        }
    }

    /// Active devices checked in within the week before the collect; every `staleEvery`th
    /// from `staleAt` has been silent 35 to 94 days.
    private static func schoolDevice(
        kind: String, index i: Int, model: String, os: String, managed: Bool,
        supervised: Bool, staleEvery: Int, staleAt: Int
    ) -> SchoolFleetService.Device {
        let activeDays = [0, 0, 1, 0, 2, 0, 0, 3, 0, 1, 5, 0]
        let stale = staleEvery > 0 && i % staleEvery == staleAt
        let days = stale ? 35 + (i * 13) % 60 : activeDays[i % activeDays.count]
        let minutes = days * 1_440 + (i * 37) % 600
        let serial = "MHS\(kind.prefix(1))" + String(format: "%07X", (i + 1) * 104_729)
        return SchoolFleetService.Device(
            id: "demo-school-\(kind.lowercased())-\(i + 1)",
            name: "MHS-\(kind)-" + String(format: "%04d", i + 1),
            serial: serial, model: model, os: os,
            isManaged: managed, isSupervised: managed ? supervised : false,
            lastCheckin: schoolCollectedAt.addingTimeInterval(-Double(minutes) * 60),
            inTrash: false, udid: "demo-school-\(kind.lowercased())-\(i + 1)")
    }

    /// The weekly scan reached the Macs and iPads but not the Apple TVs, and missed every tenth
    /// device. A Mac reports no battery.
    private static func schoolDeviceDetailRows(
        _ devices: [SchoolFleetService.Device]
    ) -> [String: SchoolDeviceDetail.Row] {
        let batteries = [88, 72, 95, 64, 15, 100, 43, 0, 81, 18, 56]
        var rows: [String: SchoolDeviceDetail.Row] = [:]
        for (i, device) in devices.enumerated() where device.platform != "tvOS" && i % 10 != 9 {
            let mac = device.platform == "macOS"
            rows[device.udid.lowercased()] = SchoolDeviceDetail.Row(
                enrollType: i % 7 == 3 ? "manual" : "dep",
                capacityGB: mac ? [256, 512][i % 2] : [64, 128, 256][i % 3],
                battery: mac ? nil : batteries[i % batteries.count])
        }
        return rows
    }

    /// iPads bought for the new term, waiting in Automated Device Enrollment.
    private static let schoolDEPDevices: [SchoolFleetService.DEPDevice] = (1...6).map { i in
        let serial = "MHSD" + String(format: "%07X", i * 7_919)
        return SchoolFleetService.DEPDevice(
            id: serial, serial: serial, name: "", model: "iPad (10th generation)",
            status: i <= 4 ? "Assigned" : "Pending", profile: "Meridian Schools ADE")
    }

    /// Staff and students: two in five hold a device.
    private static let schoolUsers: [SchoolFleetService.UserRow] = (0..<schoolUserCount).map {
        .init(deviceCount: $0 % 5 < 2 ? 1 : 0)
    }

    /// Every third group is smart; every fourth has no members.
    private static let schoolDeviceGroups: [SchoolFleetService.GroupRow] =
        (0..<schoolDeviceGroupCount).map {
            .init(members: $0 % 4 == 3 ? 0 : 20 + $0, isSmart: $0 % 3 == 0)
        }

    /// Classes hold students and a teacher; a few are not set up yet and none lists devices.
    private static let schoolClasses: [SchoolFleetService.ClassRow] =
        (0..<schoolClassCount).map {
            .init(devices: 0, students: $0 % 31 == 5 ? 0 : 18 + $0 % 9,
                  teachers: $0 % 17 == 3 ? 0 : 1)
        }

    /// The lines `jamf-cli school overview` prints; Devices is the fleet above.
    private static func schoolOverviewRows(deviceCount: Int) -> [SchoolFleetService.OverviewRow] {
        [
            ("Devices", "Devices", "\(deviceCount)"),
            ("Devices", "Device Groups", "\(schoolDeviceGroupCount)"),
            ("Users", "Users", "\(schoolUserCount)"), ("Users", "User Groups", "64"),
            ("Classes", "Classes", "\(schoolClassCount)"), ("Apps", "Apps", "143"),
            ("Profiles", "Profiles", "27"), ("Locations", "Locations", "6"),
        ].map { SchoolFleetService.OverviewRow(section: $0.0, resource: $0.1, value: $0.2) }
    }
}
