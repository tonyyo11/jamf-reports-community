import SwiftUI
import TipKit

/// Tips for the CSV → Extension Attribute adoption sheet (`CSVEAWalkthroughSheet`).
enum WalkthroughTips {
    static let adoptTarget = AdoptTargetTip()
    static let connectedValue = ConnectedValueTip()
}

/// Rendered inline (as a `TipView`) near the top of the walkthrough content to
/// explain the two ways a detected column can be tracked.
struct AdoptTargetTip: Tip {
    var title: Text { Text("How should this column be tracked?") }

    var message: Text? {
        Text("Custom EA reports the full distribution of a column's values. "
            + "Security Agent checks each device against a single "
            + "connected / installed value.")
    }

    var image: Image? { Image(systemName: "slider.horizontal.3") }

    var options: [TipOption] { [Tips.MaxDisplayCount(3)] }
}

/// Anchored to the connected-value field shown when a column is adopted as a
/// Security Agent.
struct ConnectedValueTip: Tip {
    var title: Text { Text("Set the connected value") }

    var message: Text? {
        Text("Enter what this column shows when the agent is installed or "
            + "connected. It is matched as a case-insensitive substring, so "
            + "\"Installed\" also matches \"Installed and running\".")
    }

    var image: Image? { Image(systemName: "checkmark.seal") }

    var options: [TipOption] { [Tips.MaxDisplayCount(3)] }
}
