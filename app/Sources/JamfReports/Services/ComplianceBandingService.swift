import Foundation

/// Buckets per-device mSCP failure counts into the six v3.5 compliance bands
/// used by the legacy STIG donut and the new Compliance Posture screen.
///
/// Lifted from `jamf_reports_cli_v3.5.py:_category_counts()`. The thresholds
/// (Pass=0, Low=1–10, MedLow=11–30, Medium=31–50, High=>50) are also encoded
/// in `Config.COMPLIANCE_THRESHOLDS` and surface in the donut legend.
///
/// Returns the existing `ComplianceBand` struct (`Models.swift:162`) so the
/// service plugs into the SwiftUI Charts code without a wrapper layer.
struct ComplianceBandingService: Sendable {

    /// Bucket definitions. Order matches the donut legend (best → worst, with
    /// "No Data" pinned last so it reads as a tail).
    enum Band: CaseIterable, Sendable {
        case pass, low, medLow, medium, high, noData

        var label: String {
            switch self {
            case .pass:   return "Pass"
            case .low:    return "Low"
            case .medLow: return "Med-Low"
            case .medium: return "Medium"
            case .high:   return "High"
            case .noData: return "No Data"
            }
        }

        var rangeLabel: String {
            switch self {
            case .pass:   return "0"
            case .low:    return "1–10"
            case .medLow: return "11–30"
            case .medium: return "31–50"
            case .high:   return ">50"
            case .noData: return "—"
            }
        }

        /// Inclusive failure-count range, or nil for `.noData`.
        var failureRange: ClosedRange<Int>? {
            switch self {
            case .pass:   return 0...0
            case .low:    return 1...10
            case .medLow: return 11...30
            case .medium: return 31...50
            case .high:   return 51...Int.max
            case .noData: return nil
            }
        }

        /// Aligned to existing Theme tokens (green/info/gold/warn/danger/gray)
        /// so the donut reads consistently with the rest of the app's bands.
        var colorHex: UInt32 {
            switch self {
            case .pass:   return 0x30D158  // ok / green
            case .low:    return 0x0A84FF  // info / blue
            case .medLow: return 0xE8B614  // gold
            case .medium: return 0xFF9F0A  // warn / orange
            case .high:   return 0xFF453A  // danger / red
            case .noData: return 0x8E8E93  // muted gray
            }
        }

        /// Returns the band that contains the given failure count, or
        /// `.noData` when `failures` is nil.
        static func from(failures: Int?) -> Band {
            guard let f = failures else { return .noData }
            switch f {
            case ..<0:    return .noData  // negative counts are nonsense → mark as no-data
            case 0:       return .pass
            case 1...10:  return .low
            case 11...30: return .medLow
            case 31...50: return .medium
            default:      return .high
            }
        }
    }

    /// Bucket `failures` into the six bands and return `[ComplianceBand]` in
    /// donut-legend order. An empty input returns six bands with zero counts
    /// (so the donut renders an "empty state" disc instead of disappearing).
    static func bands(failures: [Int?]) -> [ComplianceBand] {
        var counts: [Band: Int] = [:]
        for band in Band.allCases { counts[band] = 0 }
        for value in failures {
            counts[Band.from(failures: value), default: 0] += 1
        }
        let total = failures.count
        return Band.allCases.map { band in
            let count = counts[band, default: 0]
            let pct = total > 0 ? (Double(count) / Double(total)) * 100 : 0
            return ComplianceBand(
                label: band.label,
                range: band.rangeLabel,
                count: count,
                pct: pct,
                colorHex: band.colorHex
            )
        }
    }

    /// Per-OS variant: groups failures by `OS major` (e.g. "macOS 15"), then
    /// returns one `[ComplianceBand]` slice per OS, sorted newest OS first.
    /// Used by the per-OS breakdown table in `CompliancePostureView`.
    static func bandsByOSMajor(_ pairs: [(osMajor: Int, failures: Int?)]) -> [(osMajor: Int, bands: [ComplianceBand])] {
        let grouped = Dictionary(grouping: pairs, by: \.osMajor)
        return grouped
            .map { (major, items) in
                (osMajor: major, bands: bands(failures: items.map(\.failures)))
            }
            .sorted { $0.osMajor > $1.osMajor }
    }

    /// Extracts the OS major version from a string like "15.4.1" or
    /// "macOS 14.7". Returns nil when no leading integer is found.
    static func parseOSMajor(_ raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let scanner = Scanner(string: trimmed)
        _ = scanner.scanUpToCharacters(from: .decimalDigits)
        var major: Int = 0
        guard scanner.scanInt(&major), major > 0 else { return nil }
        return major
    }
}
