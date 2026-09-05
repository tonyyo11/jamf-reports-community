import XCTest
import ServiceManagement
@testable import JamfReports

final class TickerRegistrarTests: XCTestCase {

    func testStatusMappingCoversEveryCase() {
        XCTAssertEqual(SMAppServiceRegistrar.map(.enabled), .enabled)
        XCTAssertEqual(SMAppServiceRegistrar.map(.requiresApproval), .requiresApproval)
        XCTAssertEqual(SMAppServiceRegistrar.map(.notRegistered), .notRegistered)
        XCTAssertEqual(SMAppServiceRegistrar.map(.notFound), .unavailable)
    }

    func testOnlyEnabledCountsAsRunning() {
        XCTAssertTrue(TickerStatus.enabled.isRunning)
        for s in [TickerStatus.requiresApproval, .notRegistered, .unavailable] {
            XCTAssertFalse(s.isRunning)
        }
    }

    func testIsBundledRequiresAppBundleWithThePlist() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("JamfReports.app", isDirectory: true)
        let agents = app.appendingPathComponent("Contents/Library/LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        XCTAssertFalse(SMAppServiceRegistrar.isBundled(bundleURL: app))
        try Data().write(to: agents.appendingPathComponent(SMAppServiceRegistrar.plistName))
        XCTAssertTrue(SMAppServiceRegistrar.isBundled(bundleURL: app))
        XCTAssertFalse(
            SMAppServiceRegistrar.isBundled(bundleURL: root.appendingPathComponent("JamfReports")))
    }

    /// The production path derives the bundle from the executable, which is how
    /// a CLI invocation reached through the `/usr/local/bin` symlink still finds
    /// the agent plist instead of looking in `/usr/local/bin` for it.
    func testIsBundledWalksUpFromTheExecutable() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("JamfReports.app", isDirectory: true)
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        let agents = app.appendingPathComponent("Contents/Library/LaunchAgents", isDirectory: true)
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fm.createDirectory(at: agents, withIntermediateDirectories: true)
        let executable = macOS.appendingPathComponent("JamfReports")
        try Data().write(to: executable)

        XCTAssertFalse(SMAppServiceRegistrar.isBundled(executableURL: executable))
        try Data().write(to: agents.appendingPathComponent(SMAppServiceRegistrar.plistName))
        XCTAssertTrue(SMAppServiceRegistrar.isBundled(executableURL: executable))
        XCTAssertFalse(SMAppServiceRegistrar.isBundled(executableURL: nil))
    }

    func testStubRecordsCallsAndSurfacesErrors() throws {
        let stub = StubTickerRegistrar()
        try stub.register()
        try stub.unregister()
        XCTAssertEqual(stub.registerCalls, 1)
        XCTAssertEqual(stub.unregisterCalls, 1)
        stub.registerError = NSError(domain: "t", code: 1)
        XCTAssertThrowsError(try stub.register())
        stub.status = .requiresApproval
        XCTAssertEqual(stub.status, .requiresApproval)
    }
}
