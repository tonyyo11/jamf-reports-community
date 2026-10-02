import XCTest
@testable import JamfReports

/// Config Doctor rows for what the YAML reader did not take as written.
final class ConfigDoctorReaderRowsTests: XCTestCase {

    private let fileManager = FileManager.default

    // MARK: - true/false keys read outside the decoder

    func testANonBooleanValueForAKeyReadOutsideTheDecoderIsStated() throws {
        let root = try ConfigLoader.rawMapping(fromYAML: """
            output:
              allow_absolute_paths: yes
            html:
              track_history: 1
            """)
        let rows = ConfigDoctorService.fileReadBooleanRows(root)
        XCTAssertEqual(rows.map(\.id), ["config.value.output.allow_absolute_paths",
                                        "config.value.html.track_history"])
        XCTAssertEqual(rows.map(\.severity), [.warn, .warn])
        XCTAssertEqual(rows.first?.detail,
                       "\"yes\" is not true or false, so the app reads it as false.")
        XCTAssertEqual(rows.last?.detail,
                       "\"1\" is not true or false, so the app reads it as false.")
    }

    func testTrueFalseAndAbsentKeysGiveNoRow() throws {
        for yaml in [
            "output:\n  allow_absolute_paths: \"true\"\nhtml:\n  track_history: False\n",
            "output:\n  allow_absolute_paths:\n",
            "other: 1\n",
        ] {
            let root = try ConfigLoader.rawMapping(fromYAML: yaml)
            XCTAssertEqual(ConfigDoctorService.fileReadBooleanRows(root), [], yaml)
        }
    }

    func testReaderRowsReadTheWorkspaceConfig() throws {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("jrc-doctor-reader-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("doctor", isDirectory: true)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }
        try "output:\n  allow_absolute_paths: on\n".write(
            to: workspace.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
        XCTAssertEqual(
            ConfigDoctorService.readerRows(profile: "doctor", workspaceRoot: root).map(\.id),
            ["config.value.output.allow_absolute_paths"])
        XCTAssertEqual(ConfigDoctorService.readerRows(profile: "absent", workspaceRoot: root), [])
    }
}
