import SwiftUI
import TipKit

/// Tips for the Sources screen (`SourcesView`).
enum SourcesTips {
    static let connectionHealth = ConnectionHealthTip()
    static let eaTracking = EATrackingTip()
}

/// Anchored to the "Check connection" button in the connection-health card.
struct ConnectionHealthTip: Tip {
    var title: Text { Text("Check your connection") }

    var message: Text? {
        Text("Run jamf-cli doctor to confirm your credentials resolve and the "
            + "server is reachable before generating reports.")
    }

    var image: Image? { Image(systemName: "stethoscope") }

    var options: [TipOption] { [Tips.MaxDisplayCount(3)] }
}

/// Anchored to the "EA tracking guide" button.
struct EATrackingTip: Tip {
    var title: Text { Text("Bring in custom EAs") }

    var message: Text? {
        Text("Detect Extension Attribute columns in your newest CSV and adopt "
            + "them as tracked fields — no manual config editing required.")
    }

    var image: Image? { Image(systemName: "tablecells.badge.ellipsis") }

    var options: [TipOption] { [Tips.MaxDisplayCount(3)] }
}
