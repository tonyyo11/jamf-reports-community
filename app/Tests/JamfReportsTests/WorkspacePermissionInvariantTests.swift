import XCTest
@testable import JamfReports

/// MFS-3 — invariants for `WorkspacePermissionHardener`.
///
/// Wave 1 introduced the post-write sweep; this suite locks down the contract
/// so future refactors can't quietly relax it:
///
/// - Every regular file under the swept root ends at 0600
/// - Every directory ends at 0700
/// - Symlinks are NOT followed — chmod targets must remain untouched
/// - Two consecutive sweeps converge to the same state (idempotent)
/// - Files written *after* a sweep are NOT auto-secured — the helper is
///   explicit invocation only (documented in the helper docstring)
@MainActor
final class WorkspacePermissionInvariantTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-perm-invariant-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o755))]
        )
    }

    override func tearDownWithError() throws {
        if let tempRoot, FileManager.default.fileExists(atPath: tempRoot.path) {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    // MARK: - Mixed-mode sweep converges to 0600/0700

    func test_tighten_normalizesMixedModes() throws {
        let fm = FileManager.default
        // Layout: root/ (0755), nested/ (0700), file_a 0644, file_b 0600,
        //         nested/file_c 0666, nested/sub/ (0770)
        let nested = tempRoot.appendingPathComponent("nested", isDirectory: true)
        let sub = nested.appendingPathComponent("sub", isDirectory: true)
        try fm.createDirectory(at: nested, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        try fm.createDirectory(at: sub, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: NSNumber(value: Int16(0o770))])

        let fileA = tempRoot.appendingPathComponent("file_a.json")
        let fileB = tempRoot.appendingPathComponent("file_b.json")
        let fileC = nested.appendingPathComponent("file_c.json")
        try Data("a".utf8).write(to: fileA)
        try Data("b".utf8).write(to: fileB)
        try Data("c".utf8).write(to: fileC)
        try fm.setAttributes([.posixPermissions: NSNumber(value: Int16(0o644))], ofItemAtPath: fileA.path)
        try fm.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: fileB.path)
        try fm.setAttributes([.posixPermissions: NSNumber(value: Int16(0o666))], ofItemAtPath: fileC.path)

        WorkspacePermissionHardener.tighten(directory: tempRoot)

        XCTAssertEqual(try mode(of: fileA), 0o600)
        XCTAssertEqual(try mode(of: fileB), 0o600)
        XCTAssertEqual(try mode(of: fileC), 0o600)
        XCTAssertEqual(try mode(of: nested), 0o700)
        XCTAssertEqual(try mode(of: sub), 0o700)
    }

    // MARK: - Symlinks are not followed

    func test_tighten_doesNotChmodSymlinkTargets() throws {
        let fm = FileManager.default
        // Target lives outside the sweep root so the only way the hardener could
        // touch it is by following the symlink — which it must not do.
        let outsideRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-perm-outside-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: outsideRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: outsideRoot) }

        let target = outsideRoot.appendingPathComponent("target.json")
        try Data("target".utf8).write(to: target)
        try fm.setAttributes([.posixPermissions: NSNumber(value: Int16(0o644))], ofItemAtPath: target.path)

        let link = tempRoot.appendingPathComponent("symlink.json")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)

        WorkspacePermissionHardener.tighten(directory: tempRoot)

        XCTAssertEqual(try mode(of: target), 0o644,
                       "symlink targets outside the workspace must be untouched by the sweep")
    }

    // MARK: - Idempotent

    func test_tighten_isIdempotent() throws {
        let fm = FileManager.default
        let nested = tempRoot.appendingPathComponent("nested", isDirectory: true)
        try fm.createDirectory(at: nested, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: NSNumber(value: Int16(0o755))])
        let file = nested.appendingPathComponent("idem.json")
        try Data("x".utf8).write(to: file)
        try fm.setAttributes([.posixPermissions: NSNumber(value: Int16(0o644))], ofItemAtPath: file.path)

        WorkspacePermissionHardener.tighten(directory: tempRoot)
        let modeAfterFirst = try mode(of: file)
        let dirAfterFirst = try mode(of: nested)
        WorkspacePermissionHardener.tighten(directory: tempRoot)
        let modeAfterSecond = try mode(of: file)
        let dirAfterSecond = try mode(of: nested)

        XCTAssertEqual(modeAfterFirst, 0o600)
        XCTAssertEqual(modeAfterSecond, 0o600)
        XCTAssertEqual(dirAfterFirst, 0o700)
        XCTAssertEqual(dirAfterSecond, 0o700)
    }

    // MARK: - Explicit-invocation contract

    func test_tighten_doesNotAutoSecureFutureWrites() throws {
        // Sweep an empty workspace. Then write a new file. The sweep does not
        // re-run automatically — the new file keeps the umask-default mode.
        WorkspacePermissionHardener.tighten(directory: tempRoot)
        let postSweep = tempRoot.appendingPathComponent("post.json")
        try Data("post".utf8).write(to: postSweep)
        // Force a known loose mode so we are testing the contract, not umask defaults.
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o644))],
            ofItemAtPath: postSweep.path
        )

        XCTAssertEqual(try mode(of: postSweep), 0o644,
                       "files written after the sweep must NOT be auto-secured — " +
                       "the contract is explicit invocation only")

        // Re-running the sweep must catch them up — the explicit-invocation contract.
        WorkspacePermissionHardener.tighten(directory: tempRoot)
        XCTAssertEqual(try mode(of: postSweep), 0o600)
    }

    // MARK: - Helpers

    private func mode(of url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let n = attrs[.posixPermissions] as? NSNumber else {
            XCTFail("no posix permissions for \(url.path)")
            return 0
        }
        return n.intValue & 0o7777
    }
}
