import XCTest
@testable import JamfReports

/// CLIInstaller symlink behavior — exercised against temp dirs so no test ever
/// touches the real `/usr/local/bin`.
final class CLIInstallerTests: XCTestCase {
    private var tmp: URL!
    private var source: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clii-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        source = tmp.appendingPathComponent("JamfReports")
        try Data("#!/bin/sh\n".utf8).write(to: source)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testInstallsSymlinkIntoWritableDir() throws {
        let binDir = tmp.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)

        let outcome = CLIInstaller.install(source: source, targetDir: binDir)
        let dest = binDir.appendingPathComponent(CLIInstaller.linkName)
        XCTAssertEqual(outcome, .installed(path: dest.path))

        let target = try FileManager.default.destinationOfSymbolicLink(atPath: dest.path)
        XCTAssertEqual(URL(fileURLWithPath: target).resolvingSymlinksInPath().path,
                       source.resolvingSymlinksInPath().path)
    }

    func testSecondInstallIsIdempotent() throws {
        let binDir = tmp.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)

        _ = CLIInstaller.install(source: source, targetDir: binDir)
        let outcome = CLIInstaller.install(source: source, targetDir: binDir)
        XCTAssertEqual(outcome, .alreadyInstalled(path: binDir.appendingPathComponent("jamf-reports").path))
    }

    func testReplacesStaleSymlink() throws {
        let binDir = tmp.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        // A symlink pointing somewhere else entirely must be replaced, not kept.
        let stale = tmp.appendingPathComponent("old-binary")
        try Data("old".utf8).write(to: stale)
        let dest = binDir.appendingPathComponent(CLIInstaller.linkName)
        try FileManager.default.createSymbolicLink(at: dest, withDestinationURL: stale)

        let outcome = CLIInstaller.install(source: source, targetDir: binDir)
        XCTAssertEqual(outcome, .installed(path: dest.path))
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: dest.path)
        XCTAssertEqual(URL(fileURLWithPath: target).resolvingSymlinksInPath().path,
                       source.resolvingSymlinksInPath().path)
    }

    func testMissingTargetDirReturnsManualCommand() {
        let missing = tmp.appendingPathComponent("does-not-exist", isDirectory: true)
        let outcome = CLIInstaller.install(source: source, targetDir: missing)
        guard case let .manual(command) = outcome else {
            return XCTFail("expected .manual, got \(outcome)")
        }
        XCTAssertTrue(command.contains("ln -sf"))
        XCTAssertTrue(command.contains("sudo"))
    }

    func testNeverClobbersARealFile() throws {
        let binDir = tmp.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        // A real file sitting where the symlink would go must not be removed.
        let dest = binDir.appendingPathComponent(CLIInstaller.linkName)
        try Data("real file".utf8).write(to: dest)

        let outcome = CLIInstaller.install(source: source, targetDir: binDir)
        guard case .failed = outcome else { return XCTFail("expected .failed, got \(outcome)") }
        XCTAssertEqual(try String(contentsOf: dest, encoding: .utf8), "real file")
    }
}
