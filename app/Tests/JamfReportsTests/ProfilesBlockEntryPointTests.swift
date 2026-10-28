import XCTest
@testable import JamfReports

/// A `profiles:` block that cannot run stops every Jamf Pro entry point through
/// `CLIBridge.refusesProCommand`.
final class ProfilesBlockEntryPointTests: XCTestCase {
    private let ws = "blockws"
    private var root: URL!
    private let refusal = "profiles.jamf_pro names 'tenant-b' but this workspace is 'blockws', "
        + "so nothing runs. Set profiles.jamf_pro to 'blockws'."

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlockEntry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(ws, isDirectory: true),
            withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        try writeConfig("profiles:\n  jamf_pro: tenant-b\n")
    }

    override func tearDownWithError() throws {
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private var configURL: URL {
        root.appendingPathComponent(ws, isDirectory: true).appendingPathComponent("config.yaml")
    }

    private func writeConfig(_ yaml: String) throws {
        try yaml.write(to: configURL, atomically: true, encoding: .utf8)
    }

    private func assertRefused(
        _ operation: String, _ run: () async throws -> Void,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            try await run()
            XCTFail("\(operation) ran under a block that cannot run", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? CLIBridgeError, .wrongProduct(refusal), operation,
                           file: file, line: line)
        }
    }

    func testRefusesProCommandAppliesTheBlockRefusalFirst() async {
        let lines = ProductGuardLines()
        let answer = await CLIBridge.refusesProCommand(
            profile: ws, operation: "Health audit", onLine: lines.add,
            resolved: { _ in XCTFail("asked jamf-cli before the block refusal"); return nil })
        XCTAssertEqual(answer, refusal)
        XCTAssertEqual(lines.all, ["[error] \(refusal)"])
    }

    func testHealthAuditIsRefused() async {
        let bridge = CLIBridge()
        await assertRefused("Health audit") {
            _ = try await bridge.audit(profile: ws, category: nil) { _ in }
        }
    }

    func testGroupAnalysisIsRefused() async {
        let bridge = CLIBridge()
        await assertRefused("Group analysis") {
            _ = try await bridge.groupHygiene(profile: ws) { _ in }
        }
    }

    func testBackupIsRefused() async {
        let bridge = CLIBridge()
        await assertRefused("Backup") {
            _ = try await bridge.backup(profile: ws, label: nil) { _ in }
        }
    }

    func testBackupDiffIsRefused() async {
        let bridge = CLIBridge()
        let dir: URL = root
        await assertRefused("Backup diff") {
            _ = try await bridge.diffBackups(profile: ws, left: dir, right: dir) { _ in }
        }
    }

    func testDeviceLookupsAreRefusedBeforeJamfCLI() async {
        let bridge = CLIBridge()
        let lookups: [(String, (ProductGuardLines) async -> CLIBridge.DeviceDetailResult?)] = [
            ("device", { await bridge.deviceDetailWithProvenance(
                profile: self.ws, deviceID: "1", onLine: $0.add) }),
            ("mobile", { await bridge.mobileDeviceDetailWithProvenance(
                profile: self.ws, deviceID: "1", onLine: $0.add) }),
            ("single", { await bridge.singleDeviceDetail(
                profile: self.ws, deviceID: "1", cacheSubdir: "computers",
                jamfCLIArgs: { ["pro", "computers", "get", $0] },
                locateJamfCLI: { XCTFail("looked for jamf-cli"); return nil },
                onLine: $0.add) }),
        ]
        for (name, lookup) in lookups {
            let lines = ProductGuardLines()
            let result = await lookup(lines)
            XCTAssertNil(result, name)
            XCTAssertEqual(lines.all, ["[error] \(refusal)"], name)
        }
    }

    func testTheCLIDeviceCommandIsRefused() async {
        let answer = await Device.refusal(profile: ws)
        XCTAssertEqual(answer, refusal)
    }
}
