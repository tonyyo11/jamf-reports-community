import SwiftUI
import TipKit

/// Tips for the first-run onboarding flow (`OnboardingView`).
enum OnboardingTips {
    static let connectionType = ConnectionTypeTip()
    static let secretField = SecretFieldTip()
}

/// Anchored to the OAuth2 / Platform Gateway connection-type picker.
struct ConnectionTypeTip: Tip {
    var title: Text { Text("Pick your connection") }

    var message: Text? {
        Text("Use OAuth2 for a standard Jamf Pro server, or Platform Gateway for "
            + "platform API-client auth. You can add Protect or School later.")
    }

    var image: Image? { Image(systemName: "point.3.connected.trianglepath.dotted") }

    var options: [TipOption] { [Tips.MaxDisplayCount(2)] }
}

/// Anchored to the credential / secret entry field.
struct SecretFieldTip: Tip {
    var title: Text { Text("Your secret stays local") }

    var message: Text? {
        Text("Credentials are passed to jamf-cli over stdin and kept in the "
            + "system keychain — they are never written to the app's files.")
    }

    var image: Image? { Image(systemName: "lock.shield") }

    var options: [TipOption] { [Tips.MaxDisplayCount(2)] }
}
