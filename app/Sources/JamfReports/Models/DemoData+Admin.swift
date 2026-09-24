import Foundation

/// The demo workspace as the admin screens see it — Automation, Run History,
/// Data Sources and Settings — in place of this Mac's own workspace, schedules
/// and jamf-cli. Every value is fixed and dated on or before `referenceDate`;
/// nothing here reads the disk or runs jamf-cli.
extension DemoData {

    /// The tooltip on a control demo mode disables because it would read or
    /// write the real workspace, run jamf-cli or open a real path.
    static let liveOnlyHelp = "Available with a live profile"
}
