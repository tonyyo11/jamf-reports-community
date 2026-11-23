import SwiftUI

extension EnvironmentValues {
    /// The active workspace's `display.percent_decimals`, set once at `ContentView`.
    @Entry var percentFormat: PercentFormat = .standard
}
