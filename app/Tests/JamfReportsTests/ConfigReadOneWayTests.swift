import XCTest
@testable import JamfReports

/// Every reader of config.yaml reads a value the way the report engine's decoder does.
final class ConfigReadOneWayTests: XCTestCase {

    private let fileManager = FileManager.default

    // MARK: - Byte-order mark

    /// `YAMLCodec.decode` and `ConfigLoader.loadFromString` take text from any caller, and
    /// `String(decoding:as:)` keeps a byte-order mark.
    func testAByteOrderMarkIsNotPartOfTheFirstKey() throws {
        let text = "\u{FEFF}thresholds:\n  stale_device_days: 45\n"
        let root = try YAMLCodec.decode(text).root.mapping
        XCTAssertEqual(root?.entries.first?.key, "thresholds")
        XCTAssertEqual(try ConfigLoader.loadFromString(text).thresholds?.staleDeviceDays, 45)
        let bytes = Data([0xEF, 0xBB, 0xBF] + Array("thresholds:\n  a: 1\n".utf8))
        XCTAssertEqual(try YAMLCodec.decode(String(decoding: bytes, as: UTF8.self))
            .root.mapping?.entries.first?.key, "thresholds")
    }

    /// Through a file: Foundation's UTF-8 file read already drops the mark, so this passed
    /// before the codec stripped it too.
    func testAConfigFileThatStartsWithAByteOrderMarkLoads() throws {
        let dir = fileManager.temporaryDirectory
            .appendingPathComponent("jrc-bom-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.yaml")
        try Data([0xEF, 0xBB, 0xBF] + Array("thresholds:\n  stale_device_days: 45\n".utf8))
            .write(to: url)
        XCTAssertEqual(try ConfigLoader.load(from: url).thresholds?.staleDeviceDays, 45)
    }

    // MARK: - A key set twice

    private static let repeatedKeys = """
        thresholds:
          stale_device_days: 10
          stale_device_days: 45
        output:
          output_dir: First Reports
        output:
          output_dir: Second Reports
        """

    func testEveryReaderTakesTheLastOfARepeatedKey() throws {
        try withWorkspace(config: Self.repeatedKeys) { root, profile in
            let url = try ConfigService.configURL(for: profile, workspaceRoot: root)
            let engine = try ConfigLoader.load(from: url)
            XCTAssertEqual(engine.thresholds?.staleDeviceDays, 45)
            XCTAssertEqual(engine.output?.outputDir, "Second Reports")

            let screen = try ConfigService.load(profile: profile, workspaceRoot: root)
            XCTAssertEqual(screen.state.staleDeviceDays, "45")
            XCTAssertEqual(screen.state.outputDir, "Second Reports")
            XCTAssertEqual(try WorkspacePaths.outputDir(for: profile).lastPathComponent,
                           "Second Reports")
            XCTAssertEqual(screen.document.parseNotes.map(\.kind), [
                .duplicateKey("stale_device_days", readLine: 3),
                .duplicateKey("output", readLine: 6),
            ])
        }
    }

    /// A Config screen edit lands on the occurrence every reader takes.
    func testASaveChangesTheRepeatedKeyThatIsRead() throws {
        try withWorkspace(config: Self.repeatedKeys) { root, profile in
            var state = try ConfigService.load(profile: profile, workspaceRoot: root).state
            state.staleDeviceDays = "60"
            state.outputDir = "Edited Reports"
            _ = try ConfigService.save(
                profile: profile, state: state, existingDocument: nil, workspaceRoot: root)
            let url = try ConfigService.configURL(for: profile, workspaceRoot: root)
            let engine = try ConfigLoader.load(from: url)
            XCTAssertEqual(engine.thresholds?.staleDeviceDays, 60)
            XCTAssertEqual(engine.output?.outputDir, "Edited Reports")
            let screen = try ConfigService.load(profile: profile, workspaceRoot: root).state
            XCTAssertEqual(screen.staleDeviceDays, "60")
            XCTAssertEqual(screen.outputDir, "Edited Reports")
        }
    }

    // MARK: - Helpers

    /// A temp workspaces root holding one workspace with `config`; `JRC_TEST_WORKSPACES_ROOT`
    /// points at it for the duration and is then restored.
    private func withWorkspace(
        config: String, _ body: (URL, String) throws -> Void
    ) throws {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("jrc-read-\(UUID().uuidString)", isDirectory: true)
        let profile = "readers"
        let workspace = root.appendingPathComponent(profile, isDirectory: true)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }
        try config.write(
            to: workspace.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
        let previous = ProcessInfo.processInfo.environment["JRC_TEST_WORKSPACES_ROOT"]
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        defer {
            if let previous {
                setenv("JRC_TEST_WORKSPACES_ROOT", previous, 1)
            } else {
                unsetenv("JRC_TEST_WORKSPACES_ROOT")
            }
        }
        try body(root, profile)
    }
}
