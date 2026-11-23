import Foundation
import CoreGraphics

/// The workbook's "macOS Adoption by Major Version" chart: one bar per major, named from the
/// cached SOFA feed ("macOS Tahoe 26"), with how many Macs run it and how many of those are on
/// its latest release. "On the latest release" is `SOFAFeedService.isCurrent`, the rule behind
/// the OS-current figure, so the chart and that figure agree.
enum OSAdoptionChart {

    struct Bar: Equatable, Sendable {
        /// The major, or nil for Macs whose version Jamf did not report.
        let major: Int?
        let label: String
        let macs: Int
        /// Macs at or past the feed's latest release of this major; nil when the feed does not
        /// track the major (or there is no feed), so "behind" is never guessed.
        let onLatest: Int?
        let latest: String?
    }

    /// Bars from `inventory-summary` rows, newest major first, unreported versions last.
    static func bars(rows: [InventorySummaryRow], sofaRows: [SOFAFeedService.OSFamilyRow]) -> [Bar] {
        let macRows = sofaRows.filter { $0.platform == SOFAFeedService.platformLabels["macos"] }
        let latestByMajor = SOFAFeedService.latestByMajor(macRows)
        var names: [Int: String] = [:]
        for row in macRows {
            if let major = SOFAFeedService.versionTuple(row.productVersion).first {
                names[major] = "macOS \(row.osFamily)"
            }
        }
        var macs: [Int: Int] = [:], current: [Int: Int] = [:], unreported = 0
        for row in rows where row.count > 0 {
            guard OSVersionName.isMeasured(row.osVersion),
                  let major = SOFAFeedService.versionTuple(row.osVersion).first else {
                unreported += row.count
                continue
            }
            macs[major, default: 0] += row.count
            if SOFAFeedService.isCurrent(row.osVersion, latestByMajor: latestByMajor) == true {
                current[major, default: 0] += row.count
            }
        }
        var out = macs.keys.sorted(by: >).map { major in
            Bar(major: major, label: names[major] ?? "macOS \(major)", macs: macs[major] ?? 0,
                onLatest: latestByMajor[major] == nil ? nil : current[major] ?? 0,
                latest: latestByMajor[major])
        }
        if unreported > 0 {
            out.append(Bar(major: nil, label: "Version not reported", macs: unreported,
                           onLatest: nil, latest: nil))
        }
        return out
    }

    /// The bar data, with each bar's share of all Macs, its count and its latest-release line.
    static func chartData(_ bars: [Bar]) -> BarChartData {
        let total = bars.reduce(0) { $0 + $1.macs }
        let shares = bars.map { total > 0 ? Double($0.macs) / Double(total) * 100 : 0 }
        let keys = bars.map { $0.major.map(String.init) ?? "" }
        let hexes = ChartPalette.hexes(for: .version, keys: keys, scheme: .light)
        let colors = zip(bars, hexes).map { bar, hex in
            bar.major == nil ? ChartPalette.noDataColor : ChartPalette.cgColor(hex: hex)
        }
        let valueLabels = zip(bars, shares).map { bar, share in
            "\(bar.macs) \(bar.macs == 1 ? "Mac" : "Macs") · \(PercentFormat.whole.text(share))"
        }
        let subLabels = bars.map { bar -> String in
            guard bar.major != nil else { return "Jamf has no version for these Macs" }
            guard let latest = bar.latest, let onLatest = bar.onLatest else {
                return "Latest release not in the SOFA feed"
            }
            return "\(onLatest) of \(bar.macs) on \(latest)"
        }
        return BarChartData(categories: bars.map(\.label), values: shares, colors: colors,
                            subLabels: subLabels, valueLabels: valueLabels)
    }

    static func footnote(_ bars: [Bar], hasFeed: Bool) -> String {
        let total = bars.reduce(0) { $0 + $1.macs }
        let source = hasFeed ? "latest releases from the cached SOFA feed"
                             : "no SOFA feed cached, so latest releases are not shown"
        return "Share of all \(total) \(total == 1 ? "Mac" : "Macs"); \(source)."
    }
}
