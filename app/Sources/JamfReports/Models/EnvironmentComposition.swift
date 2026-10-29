import Foundation

/// Which device types an environment holds (mobile spec 3.2), read from the newest daily
/// summary. It decides which Overview sections and score cards have anything to show.
enum EnvironmentComposition: Equatable, Sendable {
    case macsOnly
    case mobileOnly
    case mixed
    /// Nothing says: no summary yet, or one that lists devices of neither kind. Every Mac
    /// section stays offered, as before this existed, and mobile sections wait for evidence.
    case unknown

    /// A summary with no Macs (`totalDevices` 0, as `mobileOnlySummary` writes it) holds none.
    /// Mobile devices are there when the summary carries the `mobile` figures or a count above
    /// 0; an absent count is not evidence of any, and is not read as 0 devices either way: it
    /// only means the Mobile Devices section has nothing to draw.
    init(summary: DailySummary?) {
        guard let summary else {
            self = .unknown
            return
        }
        let macs = summary.totalDevices > 0
        let mobile = summary.mobile != nil || (summary.mobileDeviceCount ?? 0) > 0
        switch (macs, mobile) {
        case (true, true): self = .mixed
        case (true, false): self = .macsOnly
        case (false, true): self = .mobileOnly
        case (false, false): self = .unknown
        }
    }

    /// Mac sections and cards are offered unless the environment is known to have no Macs.
    var allowsMacs: Bool { self != .mobileOnly }

    /// Mobile sections and cards are offered only where mobile devices are known to exist.
    var allowsMobile: Bool { self == .mobileOnly || self == .mixed }
}
