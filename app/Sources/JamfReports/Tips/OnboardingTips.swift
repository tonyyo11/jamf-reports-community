import SwiftUI
import TipKit

/// Tips for the first-run onboarding flow (`OnboardingView`).
enum OnboardingTips {
    static let connectionType = ConnectionTypeTip()
    static let secretField = SecretFieldTip()
}

/// Anchored to the Jamf Account / OAuth2 connection-type picker.
struct ConnectionTypeTip: Tip {
    var title: Text { Text("Pick your connection") }

    var message: Text? {
        Text("Use a Jamf Account integration (Platform API) for Jamf Cloud, or OAuth2 "
            + "for an on-prem, GovCloud or other Jamf Pro server. You can add Protect later.")
    }

    var image: Image? { Image(systemName: "point.3.connected.trianglepath.dotted") }

    var options: [TipOption] { [Tips.MaxDisplayCount(2)] }
}

/// Anchored to the credential / secret entry field.
struct SecretFieldTip: Tip {
    var title: Text { Text("Your secret stays local") }

    var message: Text? {
        Text("The app passes credentials to jamf-cli over stdin, and jamf-cli keeps "
            + "them in the macOS keychain. The app never writes them to its files.")
    }

    var image: Image? { Image(systemName: "lock.shield") }

    var options: [TipOption] { [Tips.MaxDisplayCount(2)] }
}
