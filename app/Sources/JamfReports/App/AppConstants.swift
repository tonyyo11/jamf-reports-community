import Foundation

/// Centralized UI thresholds and magic numbers used across views.
///
/// These were inlined at call sites until the QoL audit (May 2026) pulled them
/// here for visibility and one-place editing. Every value here is **purely
/// presentational** — they don't drive any behavior the user can't override
/// via config.yaml. For data-driven thresholds (e.g. patch warning windows),
/// keep those in `Models.swift` / `DEFAULT_CONFIG`.
enum AppConstants {

    /// Minimum / maximum value the Devices "Stale (days)" picker accepts.
    /// Below 1 makes the filter meaningless (every device is "stale"); above
    /// 365 the bucket is wider than the typical Jamf lifecycle so we cap it.
    static let staleDaysMin = 1
    static let staleDaysMax = 365

    /// Range for the "Keep latest runs" picker in the Customize wizard.
    /// Below 1 disables the on-disk archive behavior; above 50 the directory
    /// listing in the GUI gets sluggish on slower disks.
    static let keepLatestRunsMin = 1
    static let keepLatestRunsMax = 50
}
