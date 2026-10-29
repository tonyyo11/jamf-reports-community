import Foundation
import XCTest
@testable import JamfReports

/// The small-file writers install through `AtomicInstall`: a link planted at the destination
/// is replaced by a regular file (never written through), and the file's mode is the one the
/// writer sets, or the mode of the file it replaces.
final class AtomicInstallWritersTests: XCTestCase {
    private var root: URL!
    private var victim: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("atomic-writers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        victim = root.appendingPathComponent("victim.txt")
        try Data("keep".utf8).write(to: victim)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func plantLink(at url: URL) throws {
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: victim)
    }

    private func assertReplaced(_ url: URL, mode: Int16? = nil, file: StaticString = #filePath,
                                line: UInt = #line) throws {
        XCTAssertEqual(try String(contentsOf: victim, encoding: .utf8), "keep", file: file, line: line)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(attrs[.type] as? FileAttributeType, .typeRegular, "not a link", file: file, line: line)
        if let mode {
            XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.int16Value, mode, file: file, line: line)
        }
        let left = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
            .filter { $0.contains(".tmp-") }
        XCTAssertEqual(left, [], "no staging file left", file: file, line: line)
    }

    private func mode(of url: URL) throws -> Int16 {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.posixPermissions] as? NSNumber)?.int16Value ?? -1
    }

    func testWriteReplacesALinkAndSetsTheMode() throws {
        let dest = root.appendingPathComponent("out.json")
        try plantLink(at: dest)
        try AtomicInstall.write(Data("new".utf8), to: dest, mode: 0o600)
        XCTAssertEqual(try String(contentsOf: dest, encoding: .utf8), "new")
        try assertReplaced(dest, mode: 0o600)
    }

    func testWriteKeepsTheModeOfTheFileItReplaces() throws {
        let dest = root.appendingPathComponent("out.json")
        try Data("old".utf8).write(to: dest)
        chmod(dest.path, 0o640)
        try AtomicInstall.write(Data("new".utf8), to: dest)
        XCTAssertEqual(try String(contentsOf: dest, encoding: .utf8), "new")
        XCTAssertEqual(try mode(of: dest), 0o640)
    }

    func testStatusFileReplacesALinkAt0600() throws {
        let dest = root.appendingPathComponent("daily_status.json")
        try plantLink(at: dest)
        try ScheduledRunRecorder.replaceStatusFile(at: dest, with: ["label": "daily"])
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: dest)) as? [String: Any]
        XCTAssertEqual(json?["label"] as? String, "daily")
        try assertReplaced(dest, mode: 0o600)
    }

    func testStateFileReplacesALink() throws {
        let store = StateFileStore(directory: root)
        let dest = root.appendingPathComponent("computers.last")
        try plantLink(at: dest)
        try store.recordRun(report: "computers", at: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertNotNil(store.lastRun(report: "computers"))
        try assertReplaced(dest)
    }

    func testStateFileKeepsTheModeOfTheFileItReplaces() throws {
        let store = StateFileStore(directory: root)
        let dest = root.appendingPathComponent("computers.last")
        try store.recordRun(report: "computers", at: Date(timeIntervalSince1970: 1_700_000_000))
        chmod(dest.path, 0o600)
        try store.recordRun(report: "computers", at: Date(timeIntervalSince1970: 1_700_000_100))
        XCTAssertEqual(try mode(of: dest), 0o600)
    }

    func testSnapshotManifestReplacesALinkAt0600() throws {
        let dest = root.appendingPathComponent(SnapshotManifest.fileName)
        try plantLink(at: dest)
        let snapshot = root.appendingPathComponent("audit_20261011T010203.json")
        try SnapshotManifest.record(snapshotFile: snapshot, data: Data("{}".utf8))
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: dest)) as? [String: Any]
        XCTAssertNotNil((json?["files"] as? [String: Any])?[snapshot.lastPathComponent])
        try assertReplaced(dest, mode: 0o600)
    }

    func testSOFACacheReplacesALink() throws {
        let dest = root.appendingPathComponent("macos.json")
        try plantLink(at: dest)
        SOFAFeedService.writeCacheAtomic(data: Data("{}".utf8), to: dest)
        XCTAssertEqual(try String(contentsOf: dest, encoding: .utf8), "{}")
        try assertReplaced(dest)
    }

    func testConfigSaveKeepsAPrivateMode() throws {
        let profile = "atomic-config-\(UUID().uuidString.lowercased())"
        let url = try ConfigService.configURL(for: profile, workspaceRoot: root)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "jamf_cli:\n  profile: \(profile)\n".write(to: url, atomically: true, encoding: .utf8)
        chmod(url.path, 0o600)

        let loaded = try ConfigService.load(profile: profile, workspaceRoot: root)
        var state = loaded.state
        state.staleDeviceDays = "61"
        _ = try ConfigService.save(
            profile: profile, state: state, existingDocument: loaded.document, workspaceRoot: root)

        XCTAssertEqual(try ConfigService.load(profile: profile, workspaceRoot: root)
            .state.staleDeviceDays, "61")
        XCTAssertEqual(try mode(of: url), 0o600)
    }

    /// Every writer's folder is swept of the staged files a crash left (`.json`, `.last`, config
    /// text, anything `AtomicInstall.write` names), by the same name parser the stagers use.
    func testWriteSweepsOldStagedFilesOfEveryShape() throws {
        let fm = FileManager.default
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func staged(_ name: String, age: TimeInterval) throws -> URL {
            let url = root.appendingPathComponent(name)
            try Data("x".utf8).write(to: url)
            try fm.setAttributes([.modificationDate: now.addingTimeInterval(-age)],
                                 ofItemAtPath: url.path)
            return url
        }
        let day: TimeInterval = 86_400
        let oldJSON = try staged(".daily_status.json.tmp-\(UUID().uuidString)", age: 2 * day)
        let oldLast = try staged(".computers.last.tmp-\(UUID().uuidString)", age: 2 * day)
        let oldConfig = try staged(".config.yaml.tmp-\(UUID().uuidString)", age: 2 * day)
        let fresh = try staged(".computers.last.tmp-\(UUID().uuidString)", age: 3_600)
        let notUUID = try staged(".computers.last.tmp-nope", age: 2 * day)
        let visible = try staged("computers.last.tmp-\(UUID().uuidString)", age: 2 * day)
        let link = root.appendingPathComponent(".linked.json.tmp-\(UUID().uuidString)")
        try plantLink(at: link)
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-2 * day)],
                             ofItemAtPath: root.path)

        try AtomicInstall.write(Data("new".utf8), to: root.appendingPathComponent("a.json"),
                                now: now)

        for gone in [oldJSON, oldLast, oldConfig] {
            XCTAssertFalse(fm.fileExists(atPath: gone.path), gone.lastPathComponent)
        }
        for kept in [fresh, notUUID, visible, victim!] {
            XCTAssertTrue(fm.fileExists(atPath: kept.path), kept.lastPathComponent)
        }
        XCTAssertNotNil(try? fm.destinationOfSymbolicLink(atPath: link.path), "a link is kept")
    }
}
