import Darwin
import XCTest
@testable import JamfReports

/// `OnboardingFlow.runWithPTY` is bounded and answers prompts one line at a time. The stubs are
/// shell scripts that are not named `jamf-cli`; the signature gate is off for them.
final class OnboardingFlowPTYTests: XCTestCase {
    nonisolated(unsafe) private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("pty-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func stub(_ name: String, body: String) throws -> URL {
        let url = scratch.appendingPathComponent(name)
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func run(_ stub: URL, input: String, timeout: TimeInterval = 120) async throws
        -> OnboardingFlow.PTYResult {
        try await OnboardingFlow.runWithPTY(
            executable: stub, arguments: [], stdin: Data(input.utf8),
            enforce: false, expectedTeamID: nil, verify: { _, _ in true }, timeout: timeout)
    }

    func test_aChildThatNeverFinishesIsStoppedAndReported() async throws {
        let pidFile = scratch.appendingPathComponent("pid")
        let sleeper = try stub("sleep-stub", body: "echo $$ > '\(pidFile.path)'\nexec sleep 10")
        let started = Date()
        do {
            _ = try await run(sleeper, input: "id\nsecret\n", timeout: 1)
            XCTFail("expected a timeout error")
        } catch let OnboardingFlow.FlowError.processFailed(message) {
            XCTAssertEqual(message, "jamf-cli did not finish within 1 s")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        let pid = try XCTUnwrap(
            Int32(try String(contentsOf: pidFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertNotEqual(kill(pid, 0), 0, "child \(pid) is still running")
    }

    func test_eachValueIsWrittenInAnswerToItsPrompt() async throws {
        let marker = scratch.appendingPathComponent("marker")
        let prompter = try stub("prompt-stub", body: """
            printf 'Client ID: '
            read a
            printf 'Client Secret: '
            read b
            printf '%s|%s' "$a" "$b" > '\(marker.path)'
            """)
        let result = try await run(prompter, input: "the-id\nthe-secret\n")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "the-id|the-secret")
        XCTAssertFalse(result.combined.contains("the-secret"), "echo must stay off")
    }

    func test_aChildThatPrintsNoPromptStillGetsItsInput() async throws {
        let marker = scratch.appendingPathComponent("marker")
        let silent = try stub("silent-stub", body: """
            read a
            read b
            printf '%s|%s' "$a" "$b" > '\(marker.path)'
            """)
        let result = try await run(silent, input: "one\ntwo\n")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "one|two")
    }

    func test_ptyLines_cutsAfterEachNewlineAndKeepsATrailingValue() {
        let lines = OnboardingFlow.ptyLines(Data("a\nbb\nc".utf8)).map {
            String(decoding: $0, as: UTF8.self)
        }
        XCTAssertEqual(lines, ["a\n", "bb\n", "c"])
        XCTAssertTrue(OnboardingFlow.ptyLines(Data()).isEmpty)
    }
}
