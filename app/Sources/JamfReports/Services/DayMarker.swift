import Foundation

/// One-line day stamp at <workspace>/automation/.<name>-last (yyyy-MM-dd).
/// Best-effort persistence shared by GUI and headless once-per-day signals.
struct DayMarker: Sendable {
    let name: String

    /// The day last stamped, or nil when the marker is absent or unreadable.
    func lastStampedDay(in workspace: URL) -> String? {
        guard let text = try? String(contentsOf: markerURL(in: workspace), encoding: .utf8)
        else { return nil }
        let day = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return day.isEmpty ? nil : day
    }

    /// Best-effort: creates `automation/` if needed and never throws.
    func stamp(day: String, in workspace: URL) {
        let automation = workspace.appendingPathComponent("automation", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: automation, withIntermediateDirectories: true)
        try? day.write(to: markerURL(in: workspace), atomically: true, encoding: .utf8)
    }

    private func markerURL(in workspace: URL) -> URL {
        workspace
            .appendingPathComponent("automation", isDirectory: true)
            .appendingPathComponent(".\(name)-last")
    }
}
