import XCTest
@testable import JamfReports

/// A bare on-prem Jamf host in a shared log is removed once the profile's configured server
/// is seeded (#284). The host is made up.
final class ServerHostRedactionTests: XCTestCase {

    private let line = "[error] request to jss.example.org:8443 failed; retry jss.example.org later"

    func testSeededServerHostIsRedactedWithAndWithoutPort() {
        let r = DiagnosticRedactor()
        r.seedServerHosts(["jss.example.org:8443", "jss.example.org"])
        let out = r.redactText(line)
        XCTAssertFalse(out.contains("jss.example.org"), "got: \(out)")
        XCTAssertFalse(out.contains(":8443"), "got: \(out)")
        XCTAssertTrue(out.contains("host-"), "got: \(out)")
    }

    /// A profile named after a label of its own server must not break the host match.
    func testAWorkspaceNameThatIsAHostLabelLeavesNoDomain() {
        let r = DiagnosticRedactor()
        r.seedWorkspaceNames(["jamf"])
        r.seedServerHosts(["jamf.example.org:8443", "jamf.example.org"])
        let out = r.redactText("lookup jamf.example.org: no such host; profile jamf")
        XCTAssertFalse(out.contains("example.org"), "got: \(out)")
        XCTAssertFalse(out.contains("jamf"), "got: \(out)")
    }

    func testAShortWorkspaceNameIsRedactedAsAWholeWord() {
        let r = DiagnosticRedactor()
        r.seedWorkspaceNames(["ABC"])
        let out = r.redactText("collect for abc failed; keychain:jamf-cli/ABC/api-key; ABCD kept")
        XCTAssertFalse(out.contains("abc "), "got: \(out)")
        XCTAssertFalse(out.contains("/ABC/"), "got: \(out)")
        XCTAssertTrue(out.contains("ABCD kept"), "got: \(out)")
    }

    func testUnseededBareHostSurvives() {
        XCTAssertTrue(DiagnosticRedactor().redactText(line).contains("jss.example.org"))
    }

    func testHostMatchesAnyCaseAndIgnoresLookalikes() {
        let r = DiagnosticRedactor()
        r.seedServerHosts(["jss.example.org"])
        XCTAssertFalse(r.redactText("JSS.Example.ORG down").contains("Example"))
        XCTAssertTrue(r.redactText("myjss.example.org.test").contains("myjss.example.org.test"))
    }

    /// A multi-label Jamf Cloud host (`acme.protect.jamfcloud.com`) leaves no tenant label.
    func testMultiLabelJamfCloudHostLeavesNoResidue() {
        let r = DiagnosticRedactor()
        for text in ["protect alerts failed at acme.protect.jamfcloud.com",
                     "GET https://acme.protect.jamfcloud.com/api/alerts failed"] {
            let out = r.redactText(text)
            XCTAssertFalse(out.lowercased().contains("jamfcloud"), "got: \(out)")
            XCTAssertFalse(out.contains("acme"), "got: \(out)")
            XCTAssertTrue(out.contains("host-"), "got: \(out)")
        }
        XCTAssertTrue(r.redactText("jamfcloud.com docs and v1.2.3").contains("v1.2.3"))
    }

    func testSeededServerHostWinsOverTheGenericHostPattern() {
        let r = DiagnosticRedactor()
        r.seedServerHosts(["acme.protect.jamfcloud.com"])
        let out = r.redactText("failed at acme.protect.jamfcloud.com")
        XCTAssertFalse(out.contains("jamfcloud"), "got: \(out)")
    }

    func testHostIsLeftAloneWhenHostnameRedactionIsOff() {
        let r = DiagnosticRedactor(redactHostnames: false)
        r.seedServerHosts(["jss.example.org"])
        XCTAssertTrue(r.redactText(line).contains("jss.example.org"))
    }

    func testSharedLogRedactsTheProfilesServer() {
        let shared = LogRedactor.redactedForSharing(
            line, profile: "onprem", scopeIDs: { _ in [] },
            serverHosts: { $0 == "onprem" ? ["jss.example.org:8443", "jss.example.org"] : [] })
        XCTAssertFalse(shared.contains("jss.example.org"), "got: \(shared)")
    }

    func testHostFormsOfAConfiguredURL() {
        let forms = DiagnosticBundleService.hostForms(ofURL:)
        let both = ["jss.example.org:8443", "jss.example.org"]
        XCTAssertEqual(forms("https://jss.example.org:8443/"), both)
        XCTAssertEqual(forms("jss.example.org:8443"), both)
        XCTAssertEqual(forms("https://user:pw@jss.example.org/path?x=1"), ["jss.example.org"])
        XCTAssertEqual(forms(""), [])
    }

    private func writeConfig(_ text: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("config.yaml")
        try text.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    func testServerHostsReturnsEveryProfileInJamfCLIConfig() throws {
        let file = try writeConfig("""
        profiles:
            onprem:
                url: https://jss.example.org:8443
                auth-method: oauth2
            shield:
                url: https://acme-label.protect.example.com
            other:
                url: https://other.example.net
        """)
        let expected = ["jss.example.org:8443", "jss.example.org",
                        "acme-label.protect.example.com", "other.example.net"]
        XCTAssertEqual(DiagnosticBundleService.serverHosts(profile: "onprem", configURL: file),
                       expected)
        XCTAssertEqual(DiagnosticBundleService.serverHosts(profile: "missing", configURL: file),
                       expected)
        XCTAssertEqual(DiagnosticBundleService.serverHosts(
            profile: "onprem",
            configURL: file.deletingLastPathComponent().appendingPathComponent("absent.yaml")),
            [])
    }

    /// A Platform profile on a custom gateway host (Other in the region picker) is seeded like any
    /// other profile URL, so a bundle or shared log loses the host.
    func testServerHostsSeedsACustomGatewayHost() throws {
        let file = try writeConfig("""
        profiles:
            gw:
                url: https://gateway.corp-example.org:8443
                auth-method: platform
                environment-id: 11111111-2222-3333-4444-555555555555
        """)
        let hosts = DiagnosticBundleService.serverHosts(profile: "gw", configURL: file)
        XCTAssertEqual(hosts, ["gateway.corp-example.org:8443", "gateway.corp-example.org"])
        let text = "POST https://gateway.corp-example.org:8443/devices failed"
        let redactor = DiagnosticRedactor()
        redactor.seedServerHosts(hosts)
        let redacted = redactor.redactText(text)
        XCTAssertFalse(redacted.contains("corp-example"))
    }

    func testSharedLogRedactsAnotherProfilesHost() throws {
        let file = try writeConfig("""
        profiles:
            prod:
                url: https://jss.example.org:8443
            shield:
                url: https://acme-label.protect.example.com
        """)
        let shared = LogRedactor.redactedForSharing(
            "[error] protect alerts failed at acme-label.protect.example.com", profile: "prod",
            scopeIDs: { _ in [] },
            serverHosts: { DiagnosticBundleService.serverHosts(profile: $0, configURL: file) })
        XCTAssertFalse(shared.contains("acme-label"), "got: \(shared)")
    }

    func testLoggingExportRedactsEveryProfilesHostAndID() {
        let id = "3f2b8c1e-5d4a-4e7b-9c10-a1b2c3d4e5f6"
        let text = "[collect] a: jss.example.org down\n[collect] b: school.example.net "
            + "Environment '\(id)' not found"
        let shared = LogRedactor.redactedForSharing(
            text, profiles: ["a", "b"],
            scopeIDs: { $0 == "b" ? [id] : [] },
            serverHosts: { $0 == "a" ? ["jss.example.org"] : ["school.example.net"] })
        XCTAssertFalse(shared.contains("jss.example.org"), "got: \(shared)")
        XCTAssertFalse(shared.contains("school.example.net"), "got: \(shared)")
        XCTAssertFalse(shared.contains("3f2b8c1e"), "got: \(shared)")
    }

    func testSharedLogRedactsTheProfileName() {
        let text = "[collect] Contoso: patch-status failed; keychain:jamf-cli/Contoso/api-key"
        let shared = LogRedactor.redactedForSharing(
            text, profile: "Contoso", scopeIDs: { _ in [] }, serverHosts: { _ in [] })
        XCTAssertFalse(shared.contains("Contoso"), "got: \(shared)")
        XCTAssertTrue(shared.contains("patch-status failed"), "got: \(shared)")
        let plain = "[collect] patch-status failed"
        XCTAssertEqual(LogRedactor.redactedForSharing(
            plain, profile: "Contoso", scopeIDs: { _ in [] }, serverHosts: { _ in [] }), plain)
        XCTAssertEqual(LogRedactor.redactedForSharing(
            text, profile: nil, scopeIDs: { _ in [] }, serverHosts: { _ in [] }), text)
    }
}
