import Foundation

/// How a metric moved from the first point of the range to the last, for the Trends hero,
/// its pills and their VoiceOver labels. A share or score is a percentage, so its change is
/// in percentage points; a count's is in devices. The size is taken between the figures
/// rounded to what is shown, so a change that rounds to nothing is "no change", never an
/// arrow and a colour for 0.
struct TrendChange: Equatable, Sendable {
    enum Direction: Equatable, Sendable { case up, down, flat }

    /// From the metric's polarity: a device count with no good direction is neutral.
    enum Verdict: Equatable, Sendable { case better, worse, neutral }

    let direction: Direction
    let verdict: Verdict
    /// The magnitude with its unit, "2.0 pp" or "9"; empty when flat.
    let size: String
    /// How the figures are printed, which the hero's relative change follows too.
    let format: PercentFormat

    init(metric: TrendSeries.Metric, first: Double, last: Double, format: PercentFormat) {
        self.init(unit: metric.unit, polarity: metric.polarity, first: first, last: last,
                  format: format)
    }

    /// For a figure that is not a trend metric (the HTML report's P0 count): `unit` is "%" for
    /// a share or score, whose change is in percentage points, and "" for a count.
    init(
        unit: String, polarity: FleetInsightInput.Polarity, first: Double, last: Double,
        format: PercentFormat
    ) {
        self.format = format
        let isShare = unit == "%"
        let delta = isShare
            ? format.roundedChange(format.rounded(last) - format.rounded(first))
            : (last - first).rounded()
        let moved: Direction = delta == 0 ? .flat : (delta > 0 ? .up : .down)
        direction = moved
        size = switch moved {
        case .flat: ""
        default: isShare ? format.points(abs(delta)) : "\(Int(abs(delta)))"
        }
        verdict = switch (moved, polarity) {
        case (.flat, _), (_, .neutral): .neutral
        case (.up, .higherIsBetter), (.down, .lowerIsBetter): .better
        default: .worse
        }
    }

    /// The hero's text: the size, and for a count the relative change beside it when the
    /// baseline is large enough for a ratio to mean something. A percentage-point change
    /// has no second percentage, which read as a different, relative change.
    func heroText(relativeChange: Double?) -> String {
        guard direction != .flat else { return L("No change") }
        guard let relativeChange else { return size }
        return "\(size) (\(format.changeText(relativeChange)))"
    }

    var symbol: String {
        switch direction {
        case .up: "arrow.up"
        case .down: "arrow.down"
        case .flat: "minus"
        }
    }

    /// The pill's text: signed, "+2.0 pp", "-9", or "±0" when flat.
    var pillText: String {
        switch direction {
        case .up: "+" + size
        case .down: "-" + size
        case .flat: "±0"
        }
    }
}
