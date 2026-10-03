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

    // MARK: A block that is not a list

    /// The audit read a mapping under custom_eas or security_agents as no entries, and a
    /// save wrote `[]` over it.
    func testAListBlockTypedAsAMappingIsLeftAsTyped() throws {
        let eas = "custom_eas:\n  Battery:\n    column: Battery Cycle Count\n    type: text\n"
        let agents = "security_agents: Agent One\n"
        let (root, url) = try workspace(with: "columns:\n  computer_name: Name\n" + eas + agents)

        let loaded = try ConfigService.load(profile: Self.profile, workspaceRoot: root)
        XCTAssertEqual(loaded.state.customEAs, [], "the editor reads it as empty")
        XCTAssertEqual(loaded.state.securityAgents, [])
        var state = loaded.state
        state.columns["computer_name"] = "Device Name"
        state.securityAgents = [
            ConfigSecurityAgent(name: "Added", column: "Added - Status", connectedValue: "Up"),
        ]
        let saved = try ConfigService.save(
            profile: Self.profile, state: state, existingDocument: loaded.document,
            workspaceRoot: root)

        XCTAssertEqual(saved.report.keptBlocks, ["custom_eas", "security_agents"])
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains(eas + agents), text)
        XCTAssertTrue(text.contains("computer_name: Device Name"), text)
        XCTAssertFalse(text.contains("Added"), text)
    }

    func testAnEmptyOrNullListBlockIsStillWritten() throws {
        for typed in ["custom_eas:\nsecurity_agents: []\n", "custom_eas: null\n"] {
            let (root, url) = try workspace(with: typed)
            let loaded = try ConfigService.load(profile: Self.profile, workspaceRoot: root)
            var state = loaded.state
            state.securityAgents = [
                ConfigSecurityAgent(name: "Added", column: "Added - Status", connectedValue: "Up"),
            ]
            let saved = try ConfigService.save(
                profile: Self.profile, state: state, existingDocument: loaded.document,
                workspaceRoot: root)
            XCTAssertEqual(saved.report.keptBlocks, [], typed)
            XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("- name: Added"))
        }
    }

    // MARK: Comments inside a rewritten block

    /// A rewritten block is emitted afresh, so a comment inside it is gone. The first save
    /// that drops one keeps a copy of the file, once per launch.
    func testASaveThatDropsACommentInsideABlockKeepsOneCopy() throws {
        let typed = "columns:\n  # the export's name column\n  computer_name: Name  # mine\n"
            + "\n# Thresholds\nthresholds:\n  stale_device_days: 30\n"
        let (root, url) = try workspace(with: typed)

        let first = try saveLoaded(root: root)
        XCTAssertTrue(first.report.droppedComments)
        let name = try XCTUnwrap(first.report.backupName)
        let copy = url.deletingLastPathComponent().appendingPathComponent(name)
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), typed)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("# the export's"), text)
        XCTAssertTrue(text.contains("\n# Thresholds\n"), "a comment between blocks stays")

        try (text + "  # typed later\n").write(to: url, atomically: true, encoding: .utf8)
        let second = try saveLoaded(root: root)
        XCTAssertTrue(second.report.droppedComments)
        XCTAssertEqual(second.report.backupName, name, "one copy per launch")
        XCTAssertEqual(try backups(beside: url), [name])
    }

    func testASaveWithNoCommentInsideTheBlocksItRewritesMakesNoCopy() throws {
        let (root, url) = try workspace(
            with: "# Columns\ncolumns:\n  computer_name: \"Name # 1\"\n\n# Others\nhtml:\n"
                + "  # not a block this screen edits\n  track_history: false\n")
        let saved = try saveLoaded(root: root)
        XCTAssertEqual(saved.report, ConfigSaveReport())
        XCTAssertEqual(try backups(beside: url), [])
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

    /// Loads the file and saves it back unedited, as a Save with no edits does.
    private func saveLoaded(root: URL) throws -> SavedConfig {
        let loaded = try ConfigService.load(profile: Self.profile, workspaceRoot: root)
        return try ConfigService.save(
            profile: Self.profile, state: loaded.state, existingDocument: loaded.document,
            workspaceRoot: root)
    }

    private func backups(beside url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
            .filter { $0.hasPrefix("config.yaml.bak-") }
    }

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
