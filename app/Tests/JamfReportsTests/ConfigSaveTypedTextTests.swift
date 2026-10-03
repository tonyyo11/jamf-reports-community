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

    /// A rewritten block is emitted afresh, so a comment inside it is gone. Every save that
    /// drops one keeps a copy of the file that holds it.
    func testEverySaveThatDropsACommentKeepsACopyHoldingIt() throws {
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

        let later = text + "  # typed later\n"
        try later.write(to: url, atomically: true, encoding: .utf8)
        let second = try saveLoaded(root: root)
        XCTAssertTrue(second.report.droppedComments)
        let secondName = try XCTUnwrap(second.report.backupName)
        XCTAssertNotEqual(secondName, name)
        let secondCopy = url.deletingLastPathComponent().appendingPathComponent(secondName)
        XCTAssertEqual(try String(contentsOf: secondCopy, encoding: .utf8), later,
                       "the copy the notice names holds the line typed since the first save")
        XCTAssertEqual(try backups(beside: url).sorted(), [name, secondName].sorted())
    }

    func testASaveWithNoCommentInsideTheBlocksItRewritesMakesNoCopy() throws {
        let (root, url) = try workspace(
            with: "# Columns\ncolumns:\n  computer_name: \"Name # 1\"\n\n# Others\nhtml:\n"
                + "  # not a block this screen edits\n  track_history: false\n")
        let saved = try saveLoaded(root: root)
        XCTAssertEqual(saved.report, ConfigSaveReport())
        XCTAssertEqual(try backups(beside: url), [])
    }

    // MARK: Unread lines inside a rewritten block

    /// A line the reader skipped is not in what it read, so a rewrite of its block loses it,
    /// and the refresh after the save clears its note.
    func testASaveThatDropsAnUnreadLineInsideABlockKeepsACopy() throws {
        let typed = "columns:\n  computer_name: Name\n  just some words\n"
            + "html:\n  also some words\n  track_history: false\n"
        let (root, url) = try workspace(with: typed)
        let loaded = try ConfigService.load(profile: Self.profile, workspaceRoot: root)
        XCTAssertEqual(loaded.document.parseNotes.map(\.line), [3, 5])

        let saved = try saveLoaded(root: root)
        XCTAssertTrue(saved.report.droppedUnreadLines)
        XCTAssertFalse(saved.report.droppedComments)
        let name = try XCTUnwrap(saved.report.backupName)
        let copy = url.deletingLastPathComponent().appendingPathComponent(name)
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), typed)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("just some words"), text)
        XCTAssertTrue(text.contains("\n  also some words\n"), "html is not rewritten")
    }

    /// A duplicate key is read (both copies are written back), and html is not rewritten.
    func testNotesOnLinesThatAreKeptMakeNoCopy() throws {
        let (root, url) = try workspace(
            with: "columns:\n  computer_name: A\n  computer_name: B\nhtml:\n  stray words\n")
        let loaded = try ConfigService.load(profile: Self.profile, workspaceRoot: root)
        XCTAssertEqual(loaded.document.parseNotes.map(\.line), [2, 5])

        let saved = try saveLoaded(root: root)
        XCTAssertFalse(saved.report.droppedUnreadLines)
        XCTAssertNil(saved.report.backupName)
        XCTAssertEqual(try backups(beside: url), [])
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("computer_name: A"))
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
            let text = typed + "# edit \(minute)\n"
            try text.write(to: url, atomically: true, encoding: .utf8)
            let backup = try XCTUnwrap(
                ConfigService.backUp(url, now: start.addingTimeInterval(Double(minute) * 60)))
            XCTAssertEqual(backup.deletingLastPathComponent().path, dir.path)
            XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), text)
            names.append(backup.lastPathComponent)
        }
        XCTAssertNotNil(names[0].range(
            of: #"^config\.yaml\.bak-\d{8}-\d{6}$"#, options: .regularExpression), names[0])
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("config.yaml.") }.sorted()
        XCTAssertEqual(left, (names.suffix(5) + ["config.yaml.bak-notes",
                                                 "config.yaml.broken-20200101-000000"]).sorted())
    }

    /// A copy holding the same bytes already is the copy; one made in the same second as
    /// another, with other text, takes the next free second rather than naming the old one.
    func testACopyIsMadeOnlyWhenNoCopyHoldsTheSameText() throws {
        let (_, url) = try workspace(with: "columns: {}\n")
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let first = try XCTUnwrap(ConfigService.backUp(url, now: now))
        XCTAssertEqual(try ConfigService.backUp(url, now: now.addingTimeInterval(90)), first)
        XCTAssertEqual(try backups(beside: url), [first.lastPathComponent])

        try "columns: {}\n# more\n".write(to: url, atomically: true, encoding: .utf8)
        let second = try XCTUnwrap(ConfigService.backUp(url, now: now))
        XCTAssertNotEqual(second, first)
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "columns: {}\n# more\n")
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "columns: {}\n")
    }

    /// Names carry local time, so on a workspace shared across time zones the copy just made
    /// can sort before older ones. It is kept all the same.
    func testTheCopyJustMadeIsNeverPruned() throws {
        let (_, url) = try workspace(with: "columns: {}\n")
        let dir = url.deletingLastPathComponent()
        let later = (1...5).map { "config.yaml.bak-2099010\($0)-000000" }
        for name in later {
            try name.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let made = try XCTUnwrap(
            ConfigService.backUp(url, now: Date(timeIntervalSince1970: 1_790_000_000)))
        XCTAssertEqual(try backups(beside: url).sorted(),
                       ([made.lastPathComponent] + later.suffix(4)).sorted())
    }

    func testNoFileMeansNoBackup() throws {
        let (_, url) = try workspace(with: "")
        try FileManager.default.removeItem(at: url)
        XCTAssertNil(try ConfigService.backUp(url))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            atPath: url.deletingLastPathComponent().path), [])
    }

    /// The reader reads a tab-led line at column 0, so a tab-led comment after a block is
    /// not the block's.
    func testATabLedCommentAfterABlockIsKept() throws {
        var document = try YAMLCodec.decode(
            "output:\n  output_dir: A\n\t# typed with a tab\nhtml:\n  x: 1\n")
        var root = try XCTUnwrap(document.root.mapping)
        root.set("output", value: .mapping(.init(entries: [
            .init(key: "output_dir", value: .scalar(.string("B"))),
        ])))
        document.root = .mapping(root)
        XCTAssertEqual(try YAMLCodec.encode(document, replacingTopLevelKeys: ["output"]),
                       "output:\n  output_dir: B\n\t# typed with a tab\nhtml:\n  x: 1\n")
    }

    // MARK: A scoped writer's block

    private func saveNotify(
        enabled: Bool, root: URL
    ) throws -> (stamp: ConfigFileStamp, report: ConfigSaveReport) {
        try ConfigService.saveBlock(key: "notify", profile: Self.profile, workspaceRoot: root) {
            NotifyConfigWriter.apply(
                enabled: enabled, provider: "teams", url: "", detail: "full", to: &$0)
        }
    }

    /// The four scoped writers (charts, notify, ai, security_policy) used to drop a block's
    /// comments with no copy; config.example.yaml documents each block in comments.
    func testAScopedWriteThatDropsACommentKeepsACopyAndEveryOtherLine() throws {
        let typed = "columns:\n  computer_name: Name  # mine\nnotify:\n  # the team channel\n"
            + "  enabled: false\n  provider: teams\n  url: \"\"\n  detail: full\n"
        let (root, url) = try workspace(with: typed)

        let saved = try saveNotify(enabled: true, root: root)

        XCTAssertTrue(saved.report.droppedComments)
        let name = try XCTUnwrap(saved.report.backupName)
        let copy = url.deletingLastPathComponent().appendingPathComponent(name)
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), typed)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("columns:\n  computer_name: Name  # mine\nnotify:\n"), text)
        XCTAssertTrue(text.contains("  enabled: true\n"), text)
        XCTAssertFalse(text.contains("# the team channel"), text)
        XCTAssertTrue(saved.stamp.matches(url), "the stamp is the file as written")
    }

    func testAScopedWriteThatDropsAnUnreadLineKeepsACopy() throws {
        let (root, _) = try workspace(with: "notify:\n  enabled: false\n  just some words\n")
        let saved = try saveNotify(enabled: true, root: root)
        XCTAssertTrue(saved.report.droppedUnreadLines)
        XCTAssertNotNil(saved.report.backupName)
    }

    /// Nothing changes, so nothing is written: the comments stay and no copy is made.
    func testAScopedWriteOfWhatTheFileHoldsWritesNothing() throws {
        let typed = "notify:\n  # the team channel\n  enabled: false\n  provider: teams\n"
            + "  url: \"\"\n  detail: full\n"
        let (root, url) = try workspace(with: typed)

        let saved = try saveNotify(enabled: false, root: root)

        XCTAssertEqual(saved.report, ConfigSaveReport())
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), typed)
        XCTAssertEqual(try backups(beside: url), [])
        XCTAssertTrue(saved.stamp.matches(url))
    }

    /// Like `custom_eas` typed as a mapping for the Config screen: a block typed as a single
    /// value is left as typed, and the error says so.
    func testAScopedWriteLeavesABlockTypedAsAValueAsTyped() throws {
        let typed = "security_policy: strict\nnotify: [teams]\n"
        let (root, url) = try workspace(with: typed)

        for key in ["security_policy", "notify"] {
            XCTAssertThrowsError(try ConfigService.saveBlock(
                key: key, profile: Self.profile, workspaceRoot: root
            ) { $0.set(key, value: .mapping(.init(entries: []))) }) { error in
                guard case ConfigService.ConfigError.notASettingsBlock(key) = error else {
                    return XCTFail("expected notASettingsBlock(\(key)), got \(error)")
                }
                XCTAssertTrue(error.localizedDescription.hasPrefix(
                    "\(key) in config.yaml is not a set of settings"), "\(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), typed)
    }

    func testAScopedWriteToAnEmptyBlockOrNoFileWrites() throws {
        let (root, url) = try workspace(with: "notify:\n")
        _ = try saveNotify(enabled: true, root: root)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("  enabled: true\n"))

        try FileManager.default.removeItem(at: url)
        let saved = try saveNotify(enabled: true, root: root)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).hasPrefix("notify:\n"))
        XCTAssertTrue(saved.stamp.matches(url))
    }

    func testAScopedWriteRefusesASymlinkedConfig() throws {
        let (root, url) = try workspace(with: "notify:\n  enabled: false\n")
        let target = url.deletingLastPathComponent().appendingPathComponent("elsewhere.yaml")
        try FileManager.default.moveItem(at: url, to: target)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)

        XCTAssertThrowsError(try saveNotify(enabled: true, root: root)) { error in
            guard case ConfigService.ConfigError.symlinkDestination = error else {
                return XCTFail("expected symlinkDestination, got \(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8),
                       "notify:\n  enabled: false\n")
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
            line.hasPrefix("- ") || line == "-"
                || (line.first == " " && !line.trimmingCharacters(in: .whitespaces).isEmpty)
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
