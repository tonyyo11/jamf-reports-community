import Foundation

/// Declares whether a snapshot of cached jamf-cli or summary data is fresh,
/// stale, or has never been refreshed from a live source.
///
/// The three states map onto the user-perceivable distinctions a banner needs
/// to surface:
///   - `.fresh` — the most recent snapshot is within the freshness window;
///     the consumer should render nothing (no banner).
///   - `.stale(at:)` — a successful live fetch happened at some point but the
///     most recent snapshot is older than the window. Surface as "Stale data —
///     last fetched X ago".
///   - `.neverFetchedLive` — no live snapshot exists on disk at all. Distinct
///     from `.stale` so a fresh install does not falsely accuse the user of
///     working from stale data. Closes the PR-7 BACKLOG CONSIDER item where
///     the device-lookup banner always fired on first launch.
///
/// The enum is the contract callers consume; the freshness threshold (and any
/// service-specific source-of-truth for the snapshot mtime) lives inside the
/// individual `CacheSourceProviding` conformers.
enum CacheSource: Equatable, Sendable {
    case fresh
    case stale(at: Date)
    case neverFetchedLive

    /// `true` when a banner should render — i.e., the data is not fresh.
    var shouldDisplayBanner: Bool {
        switch self {
        case .fresh: return false
        case .stale, .neverFetchedLive: return true
        }
    }
}

/// Protocol seam for services that surface cached snapshot data and want to
/// expose freshness to a `StaleDataBanner` consumer.
///
/// PR-13 wires `TrendStore` (and `OverviewView` via the same store) onto this
/// seam alongside the existing `DeviceLookupView` migration. Five additional
/// services (`PolicyHealthService`, `CompliancePostureService`,
/// `SecurityPostureService`, `MobileFleetService`, `ProtectDashboardService`)
/// are tracked in `BACKLOG.md` for a follow-up PR.
protocol CacheSourceProviding {
    var cacheSource: CacheSource { get }
}

extension CacheSource {
    /// Convenience constructor for callers that have a snapshot mtime (or nil
    /// if no snapshot exists) and want to derive the right state from a
    /// freshness window. Returns `.neverFetchedLive` when `snapshotDate` is
    /// nil, `.fresh` when the date is within `withinHours`, and `.stale(at:)`
    /// otherwise.
    static func from(snapshotDate: Date?, withinHours: Double = 36, now: Date = Date()) -> CacheSource {
        guard let snapshotDate else { return .neverFetchedLive }
        let ageSeconds = now.timeIntervalSince(snapshotDate)
        let windowSeconds = withinHours * 3600
        return ageSeconds <= windowSeconds ? .fresh : .stale(at: snapshotDate)
    }
}
