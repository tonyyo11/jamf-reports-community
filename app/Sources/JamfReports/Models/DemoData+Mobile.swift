import Foundation

/// The demo fleet's mobile figures for the Overview, taken from the same 25 devices the Mobile
/// Devices screen lists (`MobileFleetView.makeDemoSnapshot`) through the reader a live
/// summary uses, so the two screens cannot disagree. Reads no disk and runs no jamf-cli.
extension DemoData {

    /// The demo fleet holds Macs and mobile devices.
    static let composition = EnvironmentComposition.mixed

    /// The newest iOS and iPadOS release of each major the demo devices run, as an iOS feed
    /// would list them: the devices on 18.2.1 and 17.6.1 are current, those on 18.1.1 are not.
    private static let demoLatestByMajor: [Int: String] = [18: "18.2.1", 17: "17.6.1"]

    static let mobileSummary: MobileSummary? = {
        let devices = MobileFleetView.makeDemoSnapshot().richDevices
            .map { MobileSummary.device($0) }
        return MobileSummary.build(
            devices, latestByMajor: demoLatestByMajor, staleDays: 30, now: referenceDate)
    }()

    /// The 524 demo Macs and 25 mobile devices as `SummaryDeviceMaps` writes a live summary's
    /// maps, for the Fleet Overview's device tiles. The demo Macs carry no model name, so there
    /// is no model-family map, as a live summary has none when no Mac reports one.
    static let summaryDeviceMaps: SummaryDeviceMaps.Fields = {
        let macs = SummaryDeviceMaps.computers(
            outreachRecords, rule: StaleRule(days: 30), now: referenceDate)
        let mobile = SummaryDeviceMaps.mobile(
            MobileFleetView.makeDemoSnapshot().richDevices, now: referenceDate)
        return SummaryDeviceMaps.Fields(
            osMajor: macs.osMajor.merging(mobile.osMajor, uniquingKeysWith: +),
            modelFamily: macs.modelFamily.isEmpty ? nil : macs.modelFamily,
            formFactor: mobile.formFactor,
            lastSeen: LastSeenBuckets(computers: macs.lastSeen, mobile: mobile.lastSeen))
    }()

    /// The same 25 devices by type, as `SummaryDeviceMaps` writes a live summary's map.
    static let mobileFormFactorCounts: [String: Int]? = SummaryDeviceMaps.mobile(
        MobileFleetView.makeDemoSnapshot().richDevices, now: referenceDate).formFactor
}
