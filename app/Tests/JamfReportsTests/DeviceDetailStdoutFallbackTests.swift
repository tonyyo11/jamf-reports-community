import Foundation
import XCTest
@testable import JamfReports

// jamf-cli's `pro device` accepts `--out-file` but prints its structured
// output to stdout instead (its local formatter drops the out-file writer,
// observed through 1.26.0). runDeviceDetailProcess therefore captures stdout
// and writes it to `stdoutFallbackFile` when the CLI didn't produce the file.
// These tests pin the fallback against stub executables (not named jamf-cli,
// so the codesign gate does not fire).
final class DeviceDetailStdoutFallbackTests: XCTestCase {

    nonisolated(unsafe) private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DeviceDetailStdout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDir = nil
        try super.tearDownWithError()
    }

    private func writeStub(_ name: String, script: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try Data(("#!/bin/zsh\n" + script + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: url.path
        )
        return url
    }

    func testStdoutIsWrittenToFallbackFileWhenCLIIgnoresOutFile() async throws {
        let stub = try writeStub("fake-cli", script: #"echo '[{"resource":"Name","value":"mac1"}]'"#)
        let dest = tempDir.appendingPathComponent("partial.json")

        let exit = await runDeviceDetailProcess(
            executable: stub,
            arguments: ["--out-file", dest.path],
            outputDirectory: tempDir,
            stdoutFallbackFile: dest
        )
        XCTAssertEqual(exit, 0)
        let written = try XCTUnwrap(try? Data(contentsOf: dest), "stdout must land in the fallback file")
        XCTAssertTrue(String(decoding: written, as: UTF8.self).contains("mac1"))
    }

    func testCLIWrittenOutFileIsNeverClobberedByStdout() async throws {
        let dest = tempDir.appendingPathComponent("partial.json")
        // A fixed CLI writes the file itself; any stray stdout must not replace it.
        let stub = try writeStub("fake-cli", script: """
            printf '{"from":"file"}' > "\(dest.path)"
            echo '{"from":"stdout"}'
            """)

        let exit = await runDeviceDetailProcess(
            executable: stub,
            arguments: [],
            outputDirectory: tempDir,
            stdoutFallbackFile: dest
        )
        XCTAssertEqual(exit, 0)
        let written = try XCTUnwrap(try? Data(contentsOf: dest))
        XCTAssertTrue(String(decoding: written, as: UTF8.self).contains("from\":\"file"))
    }

    func testFailedExitNeverWritesFallbackFile() async throws {
        let stub = try writeStub("fake-cli", script: """
            echo 'partial junk before dying'
            exit 4
            """)
        let dest = tempDir.appendingPathComponent("partial.json")

        let exit = await runDeviceDetailProcess(
            executable: stub,
            arguments: [],
            outputDirectory: tempDir,
            stdoutFallbackFile: dest
        )
        XCTAssertEqual(exit, 4)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: dest.path),
            "A non-zero exit must not persist captured stdout as device detail"
        )
    }
}
