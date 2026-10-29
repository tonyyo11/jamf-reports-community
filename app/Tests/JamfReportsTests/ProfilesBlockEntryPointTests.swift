import XCTest
@testable import JamfReports

/// A `profiles:` block that cannot run stops every Jamf Pro entry point through
/// `CLIBridge.refusesProCommand`, and the old-key product writers refuse to write keys a block
/// makes unread.
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

    // MARK: - Old-key writers

    private func assertWriteRefused(
        slot: String, _ write: () throws -> Void,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        try writeConfig("profiles:\n  jamf_pro: blockws\n  protect: blockws-protect\n")
        let before = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertThrowsError(try write(), file: file, line: line) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "config.yaml has a profiles block, so nothing was written here; edit "
                    + "profiles.\(slot) in config.yaml instead.", file: file, line: line)
        }
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), before,
                       file: file, line: line)
    }

    func testDisconnectingProtectUnderABlockWritesNothing() throws {
        try assertWriteRefused(slot: "protect") {
            try ProtectConnection.disconnect(
                workspace: ws, appSupport: root.appendingPathComponent(".support"))
        }
    }

    @MainActor
    func testConnectingProtectUnderABlockWritesNothing() throws {
        try assertWriteRefused(slot: "protect") {
            try OnboardingFlow.writeProtectConfig(profileSlug: ws, protectProfileName: "other")
        }
    }

    @MainActor
    func testWritingSchoolUnderABlockWritesNothing() throws {
        try assertWriteRefused(slot: "jamf_school") {
            _ = try OnboardingFlow.writeProductBlock("school_cli", profile: ws, for: ws)
        }
    }

    /// The block already names this login: connecting it again changes nothing and is not an
    /// error. Another login is still refused.
    @MainActor
    func testConnectingTheLoginTheBlockNamesWritesNothingAndSucceeds() throws {
        try writeConfig("profiles:\n  jamf_pro: blockws\n  protect: blockws-protect\n")
        let before = try String(contentsOf: configURL, encoding: .utf8)
        let report = try OnboardingFlow.writeProductBlock(
            "protect", profile: " blockws-protect ", for: ws)
        XCTAssertNil(report.backupName)
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), before)
        XCTAssertThrowsError(
            try OnboardingFlow.writeProductBlock("protect", profile: "other", for: ws))
    }

    func testOldShapeWritersStillWrite() throws {
        try writeConfig("protect:\n  enabled: true\n  profile: p\n")
        try ProtectConnection.disconnect(
            workspace: ws, appSupport: root.appendingPathComponent(".support"))
        XCTAssertNil(EnvironmentProfiles.read(workspace: ws).protect)
    }
}
