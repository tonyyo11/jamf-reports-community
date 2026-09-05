import Foundation
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
    static func isBundled(
        bundleURL: URL = Bundle.main.bundleURL, fileManager: FileManager = .default
    ) -> Bool {
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

/// Test double. `@unchecked Sendable`: a lock guards every stored property.
final class StubTickerRegistrar: TickerRegistrar, @unchecked Sendable {
    private let lock = NSLock()
    private var _status: TickerStatus
    private var _registerCalls = 0
    private var _unregisterCalls = 0
    private var _registerError: Error?

    init(status: TickerStatus = .enabled) { _status = status }

    var status: TickerStatus {
        get { lock.withLock { _status } }
        set { lock.withLock { _status = newValue } }
    }
    var registerCalls: Int { lock.withLock { _registerCalls } }
    var unregisterCalls: Int { lock.withLock { _unregisterCalls } }
    var registerError: Error? {
        get { lock.withLock { _registerError } }
        set { lock.withLock { _registerError = newValue } }
    }

    func register() throws {
        try lock.withLock {
            _registerCalls += 1
            if let e = _registerError { throw e }
            _status = .enabled
        }
    }

    func unregister() throws {
        lock.withLock { _unregisterCalls += 1; _status = .notRegistered }
    }

    func openLoginItems() {}
}
