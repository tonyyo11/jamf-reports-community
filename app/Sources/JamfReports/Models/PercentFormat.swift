import Foundation

/// The one way a percentage is printed: `display.percent_decimals` (0 or 1) decides the
/// precision. Rounding is half away from zero, and a share above 0 or below 100 never prints as
/// 0% or 100%, which mean "none" and "every device". Only display rounds: stored figures,
/// thresholds and scores keep full precision.
struct PercentFormat: Hashable, Sendable {
    /// 0, 1, or 2 for a figure `text(_:beside:)` needs to keep apart from its threshold.
    let decimals: Int

    static let standard = PercentFormat(uncheckedDecimals: 1)
    static let whole = PercentFormat(uncheckedDecimals: 0)

    /// From config: 0 is whole numbers, anything else one decimal.
    init(decimals: Int?) { self.decimals = decimals == 0 ? 0 : 1 }

    private init(uncheckedDecimals: Int) { decimals = uncheckedDecimals }

    private var scale: Double { pow(10, Double(decimals)) }

    /// The share as printed, with the end guard; for code that compares printed figures.
    func rounded(_ value: Double) -> Double {
        guard value.isFinite else { return value }
        var r = roundedChange(value)
        let step = 1 / scale
        if r >= 100, value < 100 { r = 100 - step }
        if r <= 0, value > 0 { r = step }
        return r
    }

    /// A difference or other non-share figure at this precision, with no end guard.
    func roundedChange(_ value: Double) -> Double {
        guard value.isFinite else { return value }
        let r = (value * scale).rounded(.toNearestOrAwayFromZero) / scale
        return r == 0 ? 0 : r
    }

    /// "57%" or "56.7%".
    func text(_ value: Double) -> String {
        value.isFinite ? number(rounded(value)) + "%" : "—"
    }

    /// The dash (or `missing`) when nothing was measured: absent is not zero.
    func text(_ value: Double?, missing: String = "—") -> String {
        value.map { text($0) } ?? missing
    }

    /// A share of `of`, or `missing` when `of` is 0.
    func text(_ part: Int, of whole: Int, missing: String = "—") -> String {
        whole > 0 ? text(Double(part) / Double(whole) * 100) : missing
    }

    /// The number without the sign, for a site that puts "%" itself (a chart label).
    func numberText(_ value: Double) -> String { number(rounded(value)) }

    /// A difference or other non-share number at this precision, no sign added, no end guard.
    func changeNumberText(_ value: Double) -> String { number(roundedChange(value)) }

    /// A change in percentage points, "1 pp" or "0.4 pp"; the caller adds any sign.
    func points(_ delta: Double) -> String { changeNumberText(delta) + " pp" }

    /// A non-share percentage such as a relative change, rounded with no end guard.
    func changeText(_ value: Double) -> String { changeNumberText(value) + "%" }

    /// For a figure printed beside the threshold it was compared with: when rounding would
    /// reach or cross a threshold the raw value did not, one more decimal is shown, so 89.6
    /// never reads "90% (below 90%)".
    func text(_ value: Double, beside threshold: Double) -> String {
        keptApart(value, from: threshold).text(value)
    }

    /// `text(_:beside:)` without the sign, for a score.
    func numberText(_ value: Double, beside threshold: Double) -> String {
        keptApart(value, from: threshold).numberText(value)
    }

    private func keptApart(_ value: Double, from threshold: Double) -> PercentFormat {
        var format = self
        // shortcut: stops at 2 decimals, so 89.999 beside 90 still reads "90.00%"; needs a
        // denominator over 10,000 to happen, upgrade if a fleet that size reports it.
        while format.decimals < 2 {
            let shown = format.rounded(value)
            let crosses = (value < threshold && shown >= threshold)
                || (value > threshold && shown <= threshold)
            if !crosses { break }
            format = PercentFormat(uncheckedDecimals: format.decimals + 1)
        }
        return format
    }

    private func number(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        return String(format: "%.\(decimals)f", value)
    }
}

/// `display:` in config.yaml.
struct DisplayConfig: Decodable, Sendable {
    /// `percent_decimals`: 0 or 1. Anything else reads as 1 rather than failing the decode,
    /// and Config Doctor names it.
    var percentDecimals: Int?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case percentDecimals = "percent_decimals"
    }

    init(percentDecimals: Int? = nil) { self.percentDecimals = percentDecimals }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        percentDecimals = try? container.decodeIfPresent(Int.self, forKey: .percentDecimals)
    }

    var percentFormat: PercentFormat { PercentFormat(decimals: percentDecimals) }
}

extension ReportConfig {
    /// How this workspace prints percentages.
    var percentFormat: PercentFormat { display?.percentFormat ?? .standard }
}
