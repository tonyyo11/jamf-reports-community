import Foundation

/// A person's request, from the app, that a scheduled run in another process give up the
/// tick lock at its next source (`ReportEngine.RunStop.manualRefresh`). One per-Mac file in
/// Application Support, never in a workspace. The app removes it when its refresh starts or
/// it stops waiting; a request older than `lifetime` is ignored, so one left by an app that
/// quit cannot stop every scheduled run after it.
enum ManualRefreshRequest {
    static let lifetime: TimeInterval = 2_100

    static func url(appSupport: URL = AppSupport.directory()) -> URL {
        appSupport.appendingPathComponent("refresh-requested", isDirectory: false)
    }

    /// What a pending request says about the refresh behind it. `unnamed` is a file an older
    /// build wrote (timestamp only), read as a full refresh of the run's own workspace, as 2.12 did.
    enum Pending: Equatable, Sendable {
        case none
        case unnamed
        case named(workspace: String, full: Bool)

        /// The refresh that follows collects everything due in `profile`, so a run stopped for
        /// it has nothing to continue.
        func isFullRefresh(of profile: String) -> Bool {
            switch self {
            case .none: return false
            case .unnamed: return true
            case .named(let workspace, let full): return full && workspace == profile
            }
        }
    }

    /// `workspace` is the one the refresh collects; `full` is false for a refresh of only some
    /// tiers, which leaves the rest of a stopped run for the tick.
    static func post(
        workspace: String? = nil, full: Bool = true,
        now: Date = Date(), appSupport: URL = AppSupport.directory()
    ) {
        let file = url(appSupport: appSupport)
        var lines = [ISO8601Time.string(now)]
        if let workspace { lines += [workspace, full ? "full" : "tiers"] }
        try? AtomicInstall.write(
            Data(lines.joined(separator: "\n").utf8), to: file, mode: 0o600)
    }

    static func clear(appSupport: URL = AppSupport.directory()) {
        try? FileManager.default.removeItem(at: url(appSupport: appSupport))
    }

    /// A request posted within `lifetime`. One dated ahead of now is not trusted.
    static func pending(now: Date = Date(), appSupport: URL = AppSupport.directory()) -> Pending {
        guard let text = try? String(contentsOf: url(appSupport: appSupport), encoding: .utf8)
        else { return .none }
        let lines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let posted = ISO8601Time.parse(lines[0]) else { return .none }
        let age = now.timeIntervalSince(posted)
        guard age >= -SharedWorkspace.clockSkewTolerance, age <= lifetime else { return .none }
        guard lines.count >= 2, !lines[1].isEmpty else { return .unnamed }
        return .named(workspace: lines[1], full: lines.count < 3 || lines[2] != "tiers")
    }

    static func isPending(now: Date = Date(), appSupport: URL = AppSupport.directory()) -> Bool {
        pending(now: now, appSupport: appSupport) != .none
    }
}
