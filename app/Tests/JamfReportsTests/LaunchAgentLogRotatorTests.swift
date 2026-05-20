import Foundation
import XCTest
@testable import JamfReports

final class LaunchAgentLogRotatorTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LogRotatorTests_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    // MARK: - No-op cases

    func testNoOpWhenFileDoesNotExist() throws {
        let log = tmpDir.appendingPathComponent("missing.log")
        XCTAssertNoThrow(try LaunchAgentLogRotator.rotateIfNeeded(logURL: log, sizeLimit: 1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))
    }

    func testNoOpWhenFileBelowSizeLimit() throws {
        let log = tmpDir.appendingPathComponent("small.log")
        let content = "tiny".data(using: .utf8)!
        try content.write(to: log)

        try LaunchAgentLogRotator.rotateIfNeeded(logURL: log, sizeLimit: 100)

        // File still exists with original content; no .1 rotation created.
        XCTAssertTrue(FileManager.default.fileExists(atPath: log.path))
        let gen1 = LaunchAgentLogRotator.generationURL(log, generation: 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: gen1.path))
    }

    // MARK: - Rotation trigger

    func testRotationTriggersWhenFileSizeExceedsLimit() throws {
        let log = tmpDir.appendingPathComponent("stdout.log")
        let content = String(repeating: "x", count: 200).data(using: .utf8)!
        try content.write(to: log)

        try LaunchAgentLogRotator.rotateIfNeeded(logURL: log, sizeLimit: 100)

        // Active log should now be empty.
        let activeSize = (try FileManager.default.attributesOfItem(atPath: log.path)[.size] as? Int) ?? -1
        XCTAssertEqual(activeSize, 0, "Active log should be truncated to 0 bytes after rotation")

        // Generation 1 should contain the original content.
        let gen1 = LaunchAgentLogRotator.generationURL(log, generation: 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: gen1.path))
        let gen1Data = try Data(contentsOf: gen1)
        XCTAssertEqual(gen1Data, content)
    }

    // MARK: - Generation shifting

    func testExistingGenerationShiftsDown() throws {
        let log = tmpDir.appendingPathComponent("out.log")
        let original = "original".data(using: .utf8)!
        let gen1Content = "gen1-previous".data(using: .utf8)!

        try original.write(to: log)
        let gen1 = LaunchAgentLogRotator.generationURL(log, generation: 1)
        try gen1Content.write(to: gen1)

        try LaunchAgentLogRotator.rotateIfNeeded(logURL: log, sizeLimit: 1)

        let gen2 = LaunchAgentLogRotator.generationURL(log, generation: 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: gen2.path))
        XCTAssertEqual(try Data(contentsOf: gen2), gen1Content, "Old gen1 should have moved to gen2")
        XCTAssertEqual(try Data(contentsOf: gen1), original, "Current log should have moved to gen1")
    }

    func testOldestGenerationDeletedWhenMaxExceeded() throws {
        let log = tmpDir.appendingPathComponent("rotate.log")
        let content = "data".data(using: .utf8)!

        // Create maxGenerations worth of existing generation files.
        for gen in 1...3 {
            try content.write(to: LaunchAgentLogRotator.generationURL(log, generation: gen))
        }
        try content.write(to: log)

        try LaunchAgentLogRotator.rotateIfNeeded(logURL: log, sizeLimit: 1, maxGenerations: 3)

        // Generation 3 should be deleted before the shift.
        let gen3 = LaunchAgentLogRotator.generationURL(log, generation: 3)
        let gen4 = LaunchAgentLogRotator.generationURL(log, generation: 4)
        // After rotation: old gen3 is deleted, old gen2 → gen3, old gen1 → gen2, active → gen1.
        XCTAssertTrue(FileManager.default.fileExists(atPath: gen3.path),
                      "gen3 should now hold what was gen2")
        XCTAssertFalse(FileManager.default.fileExists(atPath: gen4.path),
                       "gen4 should not exist — maxGenerations is 3")
    }

    // MARK: - Active log is always recreated

    func testActiveLogExistsAfterRotation() throws {
        let log = tmpDir.appendingPathComponent("active.log")
        let big = String(repeating: "y", count: 300).data(using: .utf8)!
        try big.write(to: log)

        try LaunchAgentLogRotator.rotateIfNeeded(logURL: log, sizeLimit: 100)

        XCTAssertTrue(FileManager.default.fileExists(atPath: log.path),
                      "Active log must exist after rotation so the agent can continue writing")
    }

    // MARK: - generationURL helper

    func testGenerationURLAppendsSuffix() {
        let base = URL(fileURLWithPath: "/tmp/test.log")
        let gen2 = LaunchAgentLogRotator.generationURL(base, generation: 2)
        XCTAssertEqual(gen2.lastPathComponent, "test.log.2")
    }

    func testGenerationURLPreservesDirectory() {
        let base = URL(fileURLWithPath: "/tmp/logs/stdout.log")
        let gen1 = LaunchAgentLogRotator.generationURL(base, generation: 1)
        XCTAssertEqual(gen1.deletingLastPathComponent().path, "/tmp/logs")
    }

    // MARK: - Default constants

    func testDefaultSizeLimit() {
        XCTAssertEqual(LaunchAgentLogRotator.defaultSizeLimit, 5 * 1_024 * 1_024)
    }

    func testDefaultMaxGenerations() {
        XCTAssertEqual(LaunchAgentLogRotator.defaultMaxGenerations, 3)
    }
}
