import Foundation

extension MobileFleetService {

    /// Whether a row carries a GENERAL or SECURITY section. A row with neither (an "Unknown"
    /// record, or the flat list older jamf-cli wrote) counts toward the device total and toward
    /// no figure, so the summary and the findings skip it.
    static func reportsPosture(_ device: MobileDeviceInventoryItem) -> Bool {
        device.general != nil || device.security != nil
    }
}

extension MobileFleetService.Snapshot {

    /// What the rules judge this snapshot's devices against.
    func findingContext(staleDays: Int, now: Date) -> MobileFinding.Context {
        MobileFinding.Context(
            latestByMajor: iOSLatestByMajor, staleDays: staleDays, now: now,
            updateErrors: updateErrors)
    }

    /// Each finding's device count. A finding no device reports the field for is absent, never
    /// 0; a finding that judged devices and found none is 0.
    func findingCounts(_ context: MobileFinding.Context) -> [MobileFinding: Int] {
        var counts: [MobileFinding: Int] = [:]
        let listRows = lightDevicesByID
        for device in richDevices where MobileFleetService.reportsPosture(device) {
            let reading = MobileSummary.device(device)
            let identity = identity(of: device, listRows: listRows)
            for finding in MobileFinding.allCases {
                guard let hit = finding.isAffected(
                    reading, serial: identity.serial, name: identity.name, context: context)
                else { continue }
                counts[finding, default: 0] += hit ? 1 : 0
            }
        }
        return counts
    }

    /// The devices among `devices` that show `finding`, in their original order: what the
    /// Mobile Devices table lists when the filter is set.
    func devices(
        _ devices: [MobileDeviceInventoryItem], affectedBy finding: MobileFinding,
        context: MobileFinding.Context
    ) -> [MobileDeviceInventoryItem] {
        let listRows = lightDevicesByID
        return devices.filter { device in
            guard MobileFleetService.reportsPosture(device) else { return false }
            let identity = identity(of: device, listRows: listRows)
            return finding.isAffected(
                MobileSummary.device(device), serial: identity.serial, name: identity.name,
                context: context) == true
        }
    }

    /// How the update scan names a device: its serial and display name.
    private func identity(
        of device: MobileDeviceInventoryItem, listRows: [String: MobileDeviceListRow]
    ) -> (serial: String?, name: String?) {
        (MobileFleetService.serialNumber(
            of: device, listRow: device.mobileDeviceId.flatMap { listRows[$0] }),
         device.general?.displayName)
    }
}
