import XCTest
@testable import JamfReports

/// Guards the single-source-of-truth contract for the app version: the
/// compile-time fallback in `AppVersionState` must equal the canonical
/// `MARKETING_VERSION` default in `build-app.sh`. A half-finished bump (one
/// place updated, the other not) fails here instead of shipping a stale
/// version string when the bundle lookup is unavailable.
@MainActor
final class AppVersionDriftTests: XCTestCase {

    func testFallbackVersionMatchesBuildScript() throws {
        let script = try locateBuildAppScript()
        let contents = try String(contentsOf: script, encoding: .utf8)
        let scriptVersion = try Self.marketingVersion(in: contents)

        XCTAssertEqual(
            AppVersionState.fallbackVersion, scriptVersion,
            "Version drift: AppVersionState.fallbackVersion is " +
            "'\(AppVersionState.fallbackVersion)' but build-app.sh MARKETING_VERSION " +
            "is '\(scriptVersion)'. Bump both (build-app.sh is the source of truth)."
        )
    }

    /// Extracts the default from `MARKETING_VERSION="${MARKETING_VERSION:-X.Y.Z}"`.
    static func marketingVersion(in script: String) throws -> String {
        let pattern = #"MARKETING_VERSION="\$\{MARKETING_VERSION:-([0-9]+\.[0-9]+(?:\.[0-9]+)?)\}""#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(script.startIndex..., in: script)
        guard let match = regex.firstMatch(in: script, range: range),
              let r = Range(match.range(at: 1), in: script) else {
            // File was found but the MARKETING_VERSION line no longer matches the regex.
            // This is the drift condition to catch — fail, not skip. (XCTSkip here would
            // silently pass whenever build-app.sh is reformatted, defeating the guard.)
            struct RegexMismatch: Error {
                let message: String
            }
            throw RegexMismatch(message:
                "MARKETING_VERSION pattern not found in build-app.sh; " +
                "update the regex in marketingVersion(in:) to match the current format"
            )
        }
        return String(script[r])
    }

    /// Walks up from this test file to find `app/build-app.sh`, so the test is
    /// robust to where the test target lives in the build tree.
    private func locateBuildAppScript() throws -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("build-app.sh")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        throw XCTSkip("build-app.sh not found above \(#filePath)")
    }
}
