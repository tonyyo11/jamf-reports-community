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

    static func post(now: Date = Date(), appSupport: URL = AppSupport.directory()) {
        let file = url(appSupport: appSupport)
        try? AtomicInstall.write(
            Data(ISO8601Time.string(now).utf8), to: file, mode: 0o600)
    }

    static func clear(appSupport: URL = AppSupport.directory()) {
        try? FileManager.default.removeItem(at: url(appSupport: appSupport))
    }

    /// A request posted within `lifetime`. One dated ahead of now is not trusted.
    static func isPending(now: Date = Date(), appSupport: URL = AppSupport.directory()) -> Bool {
        guard let text = try? String(contentsOf: url(appSupport: appSupport), encoding: .utf8),
              let posted = ISO8601Time.parse(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return false }
        let age = now.timeIntervalSince(posted)
        return age >= -SharedWorkspace.clockSkewTolerance && age <= lifetime
    }
}
