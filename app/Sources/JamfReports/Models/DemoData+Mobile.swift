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
}
