import SwiftUI
import TipKit

/// Tips for the Configuration screen (`ConfigView`).
enum ConfigTips {
    static let columnMapping = ColumnMappingTip()
    static let rescaffold = RescaffoldTip()
}

/// Anchored to the macOS / Mobile family toggle in the Columns tab.
struct ColumnMappingTip: Tip {
    var title: Text { Text("Map your Jamf columns") }

    var message: Text? {
        Text("Match each report field to the column name in your CSV export. "
            + "Switch between macOS and Mobile to map each device family.")
    }

    var image: Image? { Image(systemName: "tablecells") }

    var options: [TipOption] { [Tips.MaxDisplayCount(3)] }
}

/// Anchored to the "Re-scaffold from CSV" button.
struct RescaffoldTip: Tip {
    var title: Text { Text("Re-scaffold safely") }

    var message: Text? {
        Text("Detect column names from a fresh CSV. Re-scaffold merges into your "
            + "config — it fills empty mappings and repairs renamed columns "
            + "without overwriting your agents, EAs, or thresholds.")
    }

    var image: Image? { Image(systemName: "bolt") }

    var options: [TipOption] { [Tips.MaxDisplayCount(3)] }
}
