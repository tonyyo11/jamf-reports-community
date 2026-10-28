import XCTest
@testable import JamfReports

/// Records what a `ScreenLoad` read did; the read runs on another thread.
private final class ReadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _ran = false, _onMain = false, _stale = false
    var ran: Bool { lock.withLock { _ran } }
    var ranOnMain: Bool { lock.withLock { _onMain } }
    var stale: Bool { lock.withLock { _stale } }
    func didRun() { lock.withLock { _ran = true; _onMain = Thread.isMainThread } }
    /// The profile (or demo mode) changing under a read in flight.
    func switchSource() { lock.withLock { _stale = true } }
}

/// The six snapshot screens (Mobile Devices, Extension Attributes, Protect, Patch, OS Updates,
/// Groups) decode through `ScreenLoad.paint` in their `.task(id:)`: off the main thread, and a
/// result whose profile went out of date, or whose task was cancelled, is dropped.
@MainActor
final class ScreenLoadTests: XCTestCase {
    private func dataDir(_ files: [String: [String]]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenLoad-\(UUID().uuidString)", isDirectory: true)
        for (kind, names) in files {
            let dir = root.appendingPathComponent(kind, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for name in names {
                try TestFixtures.copyFile(
                    TestFixtures.dir("jamf-cli-data/\(kind)/\(name)"),
                    to: dir.appendingPathComponent(name))
            }
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// The load runs off the main thread and reaches the screen; a source that changed while
    /// it read, or a task cancelled before it started, paints nothing.
    private func assertScreenLoad<T: Sendable>(
        _ screen: String, loaded: (T) -> Bool, read: @escaping @Sendable () -> T
    ) async {
        let probe = ReadProbe()
        let value = await ScreenLoad.paint(stillCurrent: { true }) {
            probe.didRun()
            return read()
        }
        XCTAssertTrue(value.map(loaded) ?? false, "\(screen): the fixture did not load")
        XCTAssertFalse(probe.ranOnMain, "\(screen): the read ran on the main thread")

        let midLoad = ReadProbe()
        let dropped = await ScreenLoad.paint(stillCurrent: { !midLoad.stale }) {
            midLoad.switchSource()
            return read()
        }
        XCTAssertNil(dropped, "\(screen): a result for a source that changed mid-load painted")

        let cancelledProbe = ReadProbe()
        let cancelled = await Task { @MainActor () -> T? in
            withUnsafeCurrentTask { $0?.cancel() }
            return await ScreenLoad.paint(stillCurrent: { true }) {
                cancelledProbe.didRun()
                return read()
            }
        }.value
        XCTAssertNil(cancelled, "\(screen): a cancelled load painted")
        XCTAssertFalse(cancelledProbe.ran, "\(screen): a cancelled load still read the snapshot")
    }

    func testMobileDevicesLoadOffMain() async throws {
        let dir = try dataDir(["mobile-devices-list": ["mobile-devices-list.json"]])
        await assertScreenLoad("Mobile Devices", loaded: { $0.totalDevices > 0 }) {
            MobileFleetService.load(dataDir: dir)
        }
    }

    func testExtensionAttributesLoadOffMain() async throws {
        let dir = try dataDir([
            "ea-results": ["ea-results.json"],
            "computer-extension-attributes": ["computer-extension-attributes.json"],
        ])
        await assertScreenLoad("Extension Attributes", loaded: { $0.reportingEAs > 0 }) {
            ExtensionAttributeService.load(dataDir: dir)
        }
        // The second phase, coverage drift, walks every dated ea-results snapshot.
        await assertScreenLoad("Extension Attributes drift", loaded: { _ in true }) {
            EAParseHealthService.coverageDrift(dataDir: dir)
        }
    }

    func testProtectLoadsOffMain() async throws {
        let dir = try dataDir([
            "protect-alerts": ["alerts_happy.json"],
            "protect-computers": ["computers_happy.json"],
        ])
        await assertScreenLoad("Protect", loaded: { $0.isDetected && !$0.computers.isEmpty }) {
            ProtectDashboardService.load(dataDir: dir)
        }
        // The second phase, the Jamf Pro match, reads the correlated inventory.
        let protect = ProtectDashboardService.load(dataDir: dir).computers
        await assertScreenLoad("Protect match", loaded: { $0 != nil }) {
            ProtectProCorrelation.load(protect: protect, profile: "unused", demoMode: true)
        }
    }

    func testPatchLoadsOffMain() async throws {
        let dir = try dataDir([
            "patch-status": ["patch-status.json"],
            "patch-device-failures": ["patch-device-failures.json"],
        ])
        await assertScreenLoad("Patch", loaded: { $0.totalTitles > 0 }) {
            PatchStatusService.load(dataDir: dir)
        }
        // The second phase, adoption velocity, walks every dated patch-status snapshot.
        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        await assertScreenLoad("Patch velocity", loaded: { _ in true }) {
            PatchVelocityBuilder.compute(dataDir: dir, releaseRows: [], now: fixedNow)
        }
    }

    func testOSUpdatesLoadOffMain() async throws {
        let dir = try dataDir([
            "update-status": ["update-status.json"],
            "update-device-failures": ["update-device-failures.json"],
        ])
        await assertScreenLoad("OS Updates", loaded: { !$0.planStateBreakdown.isEmpty }) {
            UpdateStatusService.load(dataDir: dir)
        }
    }

    func testGroupsLoadOffMain() async throws {
        let dir = try dataDir([
            "classic-computer-groups": ["classic-computer-groups_2026-04-13T121845801514.json"],
            "classic-mobile-device-groups": [
                "classic-mobile-device-groups_2026-04-13T121845801514.json",
            ],
        ])
        await assertScreenLoad("Groups", loaded: { $0.isDetected }) {
            GroupInventoryService.load(dataDir: dir)
        }
    }
}
