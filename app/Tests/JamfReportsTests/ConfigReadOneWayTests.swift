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
}
