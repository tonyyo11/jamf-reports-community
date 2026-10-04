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

    init(metric: TrendSeries.Metric, first: Double, last: Double) {
        let isShare = metric.unit == "%"
        let delta = isShare ? Self.tenths(Self.tenths(last) - Self.tenths(first))
            : (last - first).rounded()
        let moved: Direction = delta == 0 ? .flat : (delta > 0 ? .up : .down)
        direction = moved
        size = switch moved {
        case .flat: ""
        default: isShare ? String(format: "%.1f pp", abs(delta)) : "\(Int(abs(delta)))"
        }
        verdict = switch (moved, metric.polarity) {
        case (.flat, _), (_, .neutral): .neutral
        case (.up, .higherIsBetter), (.down, .lowerIsBetter): .better
        default: .worse
        }
    }

    /// The hero's text: the size, and for a count the relative change beside it when the
    /// baseline is large enough for a ratio to mean something. A percentage-point change
    /// has no second percentage, which read as a different, relative change.
    func heroText(relativeChange: Double?) -> String {
        guard direction != .flat else { return "No change" }
        guard let relativeChange else { return size }
        return "\(size) (\(String(format: "%.1f", relativeChange))%)"
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

    private static func tenths(_ value: Double) -> Double { (value * 10).rounded() / 10 }
}
