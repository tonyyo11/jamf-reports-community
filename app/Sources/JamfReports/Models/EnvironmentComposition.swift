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
    /// 0; an absent count is no evidence of any, and is not read as 0 devices either way: it
    /// only means the Mobile Devices section has nothing to draw.
    ///
    /// `previous` is the summary before `summary`, from everything loaded (not the range
    /// shown); nil means there is none. The writer also gives `totalDevices` 0 to a mixed fleet
    /// on a day its Mac sources are past `jamf_cli.max_cache_age_hours` while the mobile list
    /// landed, so a day with no Macs reads as mobile only only when the day before had none
    /// too, as mixed when it had Macs, and as unknown on a first day. The limit: a mixed
    /// fleet whose Mac sources stay unmeasured two days running reads as mobile only on the
    /// second, and a workspace that is mobile only from the start reads unknown for its first
    /// day. The durable fix is for the writer to leave `totalDevices` unmeasured.
    init(summary: DailySummary?, previous: DailySummary? = nil) {
        guard let summary else {
            self = .unknown
            return
        }
        let macs = summary.totalDevices > 0
        let mobile = summary.mobile != nil || (summary.mobileDeviceCount ?? 0) > 0
        switch (macs, mobile) {
        case (true, true): self = .mixed
        case (true, false): self = .macsOnly
        case (false, false): self = .unknown
        case (false, true):
            guard let previous else {
                self = .unknown
                return
            }
            self = previous.totalDevices > 0 ? .mixed : .mobileOnly
        }
    }

    /// Mac sections and cards are offered unless the environment is known to have no Macs.
    var allowsMacs: Bool { self != .mobileOnly }

    /// Mobile sections and cards are offered only where mobile devices are known to exist.
    var allowsMobile: Bool { self == .mobileOnly || self == .mixed }
}
