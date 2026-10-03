import Foundation
import XCTest
@testable import JamfReports

/// A save from the Config screen keeps what was typed outside the blocks it rewrites.
final class ConfigSaveTypedTextTests: XCTestCase {
    private static let managedKeys: Set<String> = [
        "columns", "mobile_columns", "security_agents", "custom_eas", "thresholds",
        "compliance", "platform", "output", "jamf_cli", "branding",
    ]

    /// The banner comments between sections of a file copied from the example, and the blank
    /// lines around them, used to go with the block above them when it was rewritten.
    func testASaveOfTheExampleKeepsEveryLineBetweenBlocks() throws {
        let example = try String(contentsOf: exampleConfig(), encoding: .utf8)
        let (root, url) = try workspace(with: example)

        let loaded = try ConfigService.load(profile: Self.profile, workspaceRoot: root)
        _ = try ConfigService.save(
            profile: Self.profile, state: loaded.state, existingDocument: loaded.document,
            workspaceRoot: root)

        let saved = try String(contentsOf: url, encoding: .utf8)
        let kept = spacingLines(example, outsideBlocks: Self.managedKeys)
        XCTAssertGreaterThan(kept.filter { $0.hasPrefix("# ===") }.count, 20)
        XCTAssertEqual(spacingLines(saved, outsideBlocks: []), kept)
    }

    func testARewrittenBlockEndsAtItsLastIndentedLine() throws {
        var document = try YAMLCodec.decode(
            "output:\n  output_dir: A\n  # inside\n\n# Next section\n\nhtml:\n  x: 1\n")
        var root = try XCTUnwrap(document.root.mapping)
        root.set("output", value: .mapping(.init(entries: [
            .init(key: "output_dir", value: .scalar(.string("B"))),
        ])))
        document.root = .mapping(root)
        XCTAssertEqual(try YAMLCodec.encode(document, replacingTopLevelKeys: ["output"]),
                       "output:\n  output_dir: B\n\n# Next section\n\nhtml:\n  x: 1\n")
    }

    // MARK: Backups

    func testABackupIsACopyBesideTheFileAndOnlyTheNewestFiveAreKept() throws {
        let typed = "columns:\n  computer_name: Typed Name # mine\n"
        let (_, url) = try workspace(with: typed)
        let dir = url.deletingLastPathComponent()
        for unrelated in ["config.yaml.broken-20200101-000000", "config.yaml.bak-notes"] {
            try "x".write(to: dir.appendingPathComponent(unrelated), atomically: true,
                          encoding: .utf8)
        }
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        var names: [String] = []
        for minute in 0..<7 {
            let backup = try XCTUnwrap(
                ConfigService.backUp(url, now: start.addingTimeInterval(Double(minute) * 60)))
            XCTAssertEqual(backup.deletingLastPathComponent().path, dir.path)
            XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), typed)
            names.append(backup.lastPathComponent)
        }
        XCTAssertNotNil(names[0].range(
            of: #"^config\.yaml\.bak-\d{8}-\d{6}$"#, options: .regularExpression), names[0])
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("config.yaml.") }.sorted()
        XCTAssertEqual(left, (names.suffix(5) + ["config.yaml.bak-notes",
                                                 "config.yaml.broken-20200101-000000"]).sorted())
    }

    func testNoFileMeansNoBackup() throws {
        let (_, url) = try workspace(with: "")
        try FileManager.default.removeItem(at: url)
        XCTAssertNil(try ConfigService.backUp(url))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            atPath: url.deletingLastPathComponent().path), [])
    }

    // MARK: Helpers

    private static let profile = "typed-text"

    /// Blank lines and unindented comments, in order, leaving out those inside the text of the
    /// blocks `keys` names: from the key's line through the block's last indented line.
    private func spacingLines(_ text: String, outsideBlocks keys: Set<String>) -> [String] {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        func topLevelKey(_ line: String) -> String? {
            guard let first = line.first, !" \t#-".contains(first),
                  let colon = line.firstIndex(of: ":") else { return nil }
            return String(line[..<colon])
        }
        func isBlockText(_ line: String) -> Bool {
            line.hasPrefix("- ") || line == "-" || ((line.first == " " || line.first == "\t")
                && !line.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        var inBlock = Set<Int>()
        for (start, line) in lines.enumerated() {
            guard let key = topLevelKey(line), keys.contains(key) else { continue }
            var end = start
            var next = start + 1
            while next < lines.count, topLevelKey(lines[next]) == nil {
                if isBlockText(lines[next]) { end = next }
                next += 1
            }
            inBlock.formUnion(start...end)
        }
        return lines.enumerated().filter { offset, line in
            !inBlock.contains(offset) && (line.trimmingCharacters(in: .whitespaces).isEmpty
                || line.hasPrefix("#"))
        }.map(\.element)
    }

    private func workspace(with text: String) throws -> (root: URL, config: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConfigSaveTypedText-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = try ConfigService.configURL(for: Self.profile, workspaceRoot: root)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return (root, url)
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
