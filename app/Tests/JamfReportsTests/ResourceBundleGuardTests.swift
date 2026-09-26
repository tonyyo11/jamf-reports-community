import XCTest

/// SwiftPM's generated `Bundle.module` accessor calls `fatalError` when its resource
/// bundle is missing, and `build-app.sh` never ships that bundle inside the .app. So a
/// production lookup goes through `Bundle.main` and reaches `Bundle.module` only in
/// DEBUG (`swift run`, tests). Before 2.8.1 the Acknowledgements window skipped that
/// rule and crashed every installed copy on a Mac other than the one that built it;
/// tests and `swift run` never saw it, because the build folder exists there.
final class ResourceBundleGuardTests: XCTestCase {

    func testBundleModuleIsReachableOnlyInDebugBuilds() throws {
        let sources = try locate("Sources/JamfReports")
        var offenders: [String] = []
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            offenders += Self.unguardedBundleModuleLines(in: text).map {
                "\(url.lastPathComponent):\($0)"
            }
        }
        XCTAssertEqual(offenders, [], "Bundle.module outside #if DEBUG crashes the packaged app")
    }

    /// The Acknowledgements window reads LICENSE.txt, NOTICE.md and
    /// THIRD_PARTY_NOTICES.md through `Bundle.main`, so the packaging step has to copy
    /// both extensions into Contents/Resources.
    func testBuildScriptCopiesTheAcknowledgementsFiles() throws {
        let script = try String(contentsOf: try locate("build-app.sh"), encoding: .utf8)
        for ext in ["txt", "md"] {
            XCTAssertTrue(
                script.contains("-name \"*.\(ext)\""), "build-app.sh must copy *.\(ext) files")
        }
    }

    func testTheScannerSeesThroughElseBranches() {
        let source = """
            #if DEBUG
            let a = Bundle.module
            #else
            let b = Bundle.module
            #endif
            // Bundle.module in a comment is fine
            let c = Bundle.module
            """
        XCTAssertEqual(Self.unguardedBundleModuleLines(in: source), [4, 7])
    }

    /// One-based line numbers of code lines that use `Bundle.module` outside an active
    /// `#if DEBUG` branch. `#else` negates the innermost condition and `#elseif`
    /// replaces it, so a use in the release branch of `#if DEBUG` is reported.
    static func unguardedBundleModuleLines(in source: String) -> [Int] {
        var conditions: [String] = []
        var lines: [Int] = []
        for (index, raw) in source.components(separatedBy: .newlines).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#if ") {
                conditions.append(String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces))
            } else if line.hasPrefix("#elseif "), !conditions.isEmpty {
                conditions[conditions.count - 1] = "elseif"
            } else if line.hasPrefix("#else"), !conditions.isEmpty {
                conditions[conditions.count - 1] = "!" + conditions[conditions.count - 1]
            } else if line.hasPrefix("#endif"), !conditions.isEmpty {
                conditions.removeLast()
            } else if !line.hasPrefix("//"), line.contains("Bundle.module"),
                      !conditions.contains("DEBUG") {
                lines.append(index + 1)
            }
        }
        return lines
    }

    /// Walks up from this file to the first folder holding `relativePath`, so the test
    /// does not depend on where the checkout or the test target sits.
    private func locate(_ relativePath: String) throws -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        throw XCTSkip("\(relativePath) not found above \(#filePath)")
    }
}
