import XCTest
@testable import JamfReports

/// Pins how the YAML reader parses the shipped `config.example.yaml` and every YAML fixture, so
/// a parser change that alters how a valid file reads fails here. Each golden lists one line per
/// leaf in file order. After an intended change to one of these files, regenerate with
/// `JRC_UPDATE_PARSE_GOLDENS=1 swift test --filter YAMLParseCharacterizationTests`.
final class YAMLParseCharacterizationTests: XCTestCase {

    private static let goldenDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/config/parsed", isDirectory: true)

    func testTheShippedExampleConfigParsesAsPinned() throws {
        try assertPinned(try exampleConfig(), golden: "config.example.yaml.txt")
    }

    func testTheConfigFixturesParseAsPinned() throws {
        for name in ["dummy.yaml", "mobile-insights.yaml"] {
            try assertPinned(TestFixtures.dir("config/\(name)"), golden: "\(name).txt")
        }
    }

    private func assertPinned(_ file: URL, golden: String) throws {
        let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        let document = try YAMLCodec.decode(text)
        var lines: [String] = []
        Self.serialize(document.root, path: "", into: &lines)
        lines.append("repaired: \(document.repairedKeys.sorted().joined(separator: ", "))")
        let actual = lines.joined(separator: "\n") + "\n"
        let goldenURL = Self.goldenDir.appendingPathComponent(golden)
        if ProcessInfo.processInfo.environment["JRC_UPDATE_PARSE_GOLDENS"] == "1" {
            try FileManager.default.createDirectory(
                at: Self.goldenDir, withIntermediateDirectories: true)
            try actual.write(to: goldenURL, atomically: true, encoding: .utf8)
            return
        }
        let expected = String(decoding: try Data(contentsOf: goldenURL), as: UTF8.self)
        XCTAssertEqual(actual, expected, "\(file.lastPathComponent) no longer parses as pinned")
    }

    private static func serialize(
        _ value: YAMLCodec.YAMLValue, path: String, into lines: inout [String]
    ) {
        switch value {
        case .scalar(let scalar):
            lines.append("\(path) = \(describe(scalar))")
        case .mapping(let mapping):
            if mapping.entries.isEmpty { lines.append("\(path) = {}") }
            for entry in mapping.entries {
                serialize(entry.value, path: path.isEmpty ? entry.key : "\(path).\(entry.key)",
                          into: &lines)
            }
        case .sequence(let items):
            if items.isEmpty { lines.append("\(path) = []") }
            for (index, item) in items.enumerated() {
                serialize(item, path: "\(path)[\(index)]", into: &lines)
            }
        }
    }

    private static func describe(_ scalar: YAMLCodec.YAMLScalar) -> String {
        switch scalar {
        case .string(let value): "string \(value.debugDescription)"
        case .int(let value): "int \(value)"
        case .bool(let value): "bool \(value)"
        case .null: "null"
        }
    }

    private func exampleConfig() throws -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("config.example.yaml")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        throw XCTSkip("config.example.yaml not found above \(#filePath)")
    }
}
