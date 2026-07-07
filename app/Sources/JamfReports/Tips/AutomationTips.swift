import SwiftUI
import TipKit

/// Tips for the Automation screen (`AutomationView`).
enum AutomationTips {
    static let notifications = NotificationsTip()
}

/// Anchored to the "Enable notifications" toggle in the Notifications card.
struct NotificationsTip: Tip {
    var title: Text { Text("Get notified on schedule") }

    var message: Text? {
        Text("Turn this on, pick Microsoft Teams or Slack, and paste an incoming "
            + "webhook URL — then send a test notification to confirm it. Full "
            + "detail includes metric values and error text; Minimal sends counts only.")
    }

    var image: Image? { Image(systemName: "bell.badge") }

    var options: [TipOption] { [Tips.MaxDisplayCount(3)] }
}
