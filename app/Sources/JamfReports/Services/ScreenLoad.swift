import Foundation

/// The off-main read the snapshot screens share, in `OverviewLiveDataLoader`'s shape: the
/// read runs in the view's `.task(id:)`, and a result that task no longer wants is dropped.
enum ScreenLoad {
    /// Runs `read` off the main actor, in the caller's task. nil when that task was cancelled
    /// (the id changed: profile, demo mode or a reload) or `stillCurrent` is false once the
    /// read returns, because the refresh paths and a profile switch can outrun the
    /// cancellation. The only error `read` can end with is `CancellationError`.
    @MainActor
    static func paint<T: Sendable>(
        stillCurrent: @MainActor () -> Bool,
        read: @escaping @Sendable () -> T
    ) async -> T? {
        let value: T
        do { value = try await offMain(read) } catch { return nil }
        guard !Task.isCancelled, stillCurrent() else { return nil }
        return value
    }

    private nonisolated static func offMain<T: Sendable>(
        _ read: @Sendable () -> T
    ) async throws -> T {
        try Task.checkCancellation()
        let value = read()
        try Task.checkCancellation()
        return value
    }
}
