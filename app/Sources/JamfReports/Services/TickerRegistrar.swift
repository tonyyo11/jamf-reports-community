import Foundation
import Synchronization
import ServiceManagement

/// What Login Items › "Allow in the Background" says about our one agent.
enum TickerStatus: String, Sendable, Equatable {
    case enabled, requiresApproval, notRegistered
    /// No bundled plist (a `swift run` / dev binary) — registration cannot apply.
    case unavailable

    var isRunning: Bool { self == .enabled }
}

/// Seam over `SMAppService` so the tick loop, `WorkspaceStore` and the health
/// inputs run against a stub; the real calls are exercised only by a beta.
protocol TickerRegistrar: Sendable {
    func register() throws
    func unregister() throws
    var status: TickerStatus { get }
    func openLoginItems()
}

struct SMAppServiceRegistrar: TickerRegistrar {
    static let plistName = "com.github.tonyyo11.jamf-reports-community.tick.plist"

    /// True only for a real .app that ships the agent plist.
    ///
    /// Derived from the RESOLVED executable path, not `Bundle.main.bundleURL`:
    /// the included CLI is normally reached through the `/usr/local/bin`
    /// symlink `CLIInstaller` writes, and there `bundleURL` is `/usr/local/bin`
    /// — so registration would be skipped on exactly the headless hosts that
    /// need it. Resolving the symlink lands back inside the real bundle.
    static func isBundled(
        executableURL: URL? = Bundle.main.executableURL?.resolvingSymlinksInPath(),
        fileManager: FileManager = .default
    ) -> Bool {
        guard let executableURL else { return false }
        let bundle = executableURL
            .deletingLastPathComponent()   // Contents/MacOS
            .deletingLastPathComponent()   // Contents
            .deletingLastPathComponent()   // JamfReports.app
        return isBundled(bundleURL: bundle, fileManager: fileManager)
    }

    /// The bundle-shaped check itself, kept as its own seam so a test can drive
    /// it without building a `Contents/MacOS` tree.
    static func isBundled(bundleURL: URL, fileManager: FileManager = .default) -> Bool {
        guard bundleURL.pathExtension == "app" else { return false }
        let plist = bundleURL.appendingPathComponent(
            "Contents/Library/LaunchAgents/\(plistName)")
        return fileManager.fileExists(atPath: plist.path)
    }

    nonisolated static func map(_ status: SMAppService.Status) -> TickerStatus {
        switch status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered: .notRegistered
        case .notFound: .unavailable
        @unknown default: .notRegistered
        }
    }

    private var service: SMAppService { SMAppService.agent(plistName: Self.plistName) }

    func register() throws {
        guard Self.isBundled() else { return }
        try service.register()
    }

    func unregister() throws {
        guard Self.isBundled() else { return }
        try service.unregister()
    }

    var status: TickerStatus {
        Self.isBundled() ? Self.map(service.status) : .unavailable
    }

    func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }
}

/// Test double; a mutex guards its state.
final class StubTickerRegistrar: TickerRegistrar, Sendable {
    private struct State {
        var status: TickerStatus
        var registerCalls = 0
        var unregisterCalls = 0
        var registerError: (any Error)?
    }
    private let state: Mutex<State>

    init(status: TickerStatus = .enabled) { state = Mutex(State(status: status)) }

    var status: TickerStatus {
        get { state.withLock { $0.status } }
        set { state.withLock { $0.status = newValue } }
    }
    var registerCalls: Int { state.withLock { $0.registerCalls } }
    var unregisterCalls: Int { state.withLock { $0.unregisterCalls } }
    var registerError: Error? {
        get { state.withLock { $0.registerError } }
        set { state.withLock { $0.registerError = newValue } }
    }

    func register() throws {
        try state.withLock { state in
            state.registerCalls += 1
            if let e = state.registerError { throw e }
            state.status = .enabled
        }
    }

    func unregister() throws {
        state.withLock { $0.unregisterCalls += 1; $0.status = .notRegistered }
    }

    func openLoginItems() {}
}
