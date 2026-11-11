import XCTest
@testable import JamfReports

@MainActor
final class EnvironmentProductsReportTests: XCTestCase {
    nonisolated(unsafe) private var root = URL(fileURLWithPath: "/")

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EnvProductsReport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        let dir = root
        addTeardownBlock {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private func makeWorkspace(_ name: String, config: String?) throws -> WorkspaceID {
        let id = try XCTUnwrap(WorkspaceID(name))
        let dir = WorkspacePaths.workspaceURL(for: id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let config {
            try config.write(to: dir.appendingPathComponent("config.yaml"),
                             atomically: true, encoding: .utf8)
        }
        return id
    }

    private func header(_ id: WorkspaceID) async throws -> String {
        let dir = WorkspacePaths.workspaceURL(for: id)
        var report = HtmlReport(
            config: ReportConfig().withDefaults(),
            dataDir: dir.appendingPathComponent("jamf-cli-data"))
        report.workspace = id
        let out = dir.appendingPathComponent("report.html")
        try await report.generate(outputURL: out, profileName: id.name, sections: [])
        return try String(contentsOf: out, encoding: .utf8)
    }

    func testHeaderListsProductsInOrderWithEscapedProfileNames() async throws {
        let id = try makeWorkspace("Example", config: """
        profiles:
          jamf_pro: "Example"
          protect: "<b>Prot</b>"
          platform: "Example-API"
        """)
        let html = try await header(id)
        XCTAssertTrue(html.contains(
            "Products: <strong>Jamf Pro (Example), Platform API (Example-API), "
                + "Jamf Protect (&lt;b&gt;Prot&lt;/b&gt;)</strong>"), html)
        XCTAssertFalse(html.contains("<b>Prot</b>"))
    }

    func testHeaderHasNoProductsLineWithoutConfig() async throws {
        let id = try makeWorkspace("Bare", config: nil)
        let html = try await header(id)
        XCTAssertFalse(html.contains("Products:"))
    }

    func testWebhookFactNamesProductsNotProfilesInFullDetailOnly() throws {
        _ = try makeWorkspace("Acme", config: """
        profiles:
          jamf_pro: "Acme"
          protect: "Acme-Protect"
        """)
        let value = EnvironmentProducts.webhookValue(workspace: "Acme")
        XCTAssertEqual(value, "Jamf Pro, Jamf Protect")
        let full = successFacts(
            detail: .full, profile: "Acme", mode: .jamfCLIFull, artifact: nil,
            sheetFailures: 0, products: value)
        XCTAssertEqual(full.last?.label, "Products")
        XCTAssertFalse(full.contains { $0.value.contains("Acme-Protect") })
        let minimal = successFacts(
            detail: .minimal, profile: "Acme", mode: .jamfCLIFull, artifact: nil,
            sheetFailures: 0, products: value)
        XCTAssertFalse(minimal.contains { $0.label == "Products" })
        XCTAssertTrue(heartbeatFacts(
            detail: .full, profile: "Acme", newestSummaryDay: nil, products: value)
            .contains { $0.label == "Products" })
        XCTAssertFalse(heartbeatFacts(
            detail: .minimal, profile: "Acme", newestSummaryDay: nil, products: value)
            .contains { $0.label == "Products" })
    }
}
