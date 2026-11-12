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

    /// The Jamf Pro a platform profile reaches can be a custom domain the jamfcloud pattern
    /// misses; the host-check warning names it, so shared logs must mask it.
    func testServerHostsIncludeAConnectionMembersJamfProURL() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-conn-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let store = ConnectionStore(url: url)
        try store.recordMember(profile: "api", scopeID: "e1", product: .pro,
                               region: .us, level: .environment)
        try store.recordJamfProURL(profile: "api", url: "https://jss.example-district.org")
        let hosts = DiagnosticBundleService.serverHosts(
            profile: "api", configURL: url.appendingPathExtension("none"),
            proxy: .none, connections: store)
        XCTAssertTrue(hosts.contains("jss.example-district.org"), "\(hosts)")
        let shared = LogRedactor.redactedForSharing(
            "[warn] Platform API not collected: profiles.platform reaches "
                + "jss.example-district.org, not other.example.org",
            profile: "api", scopeIDs: { _ in [] }, serverHosts: { _ in hosts })
        XCTAssertFalse(shared.contains("jss.example-district.org"), shared)
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
        XCTAssertEqual(DiagnosticBundleService.serverHosts(
            profile: "onprem", configURL: file, proxy: .none), expected)
        XCTAssertEqual(DiagnosticBundleService.serverHosts(
            profile: "missing", configURL: file, proxy: .none), expected)
        XCTAssertEqual(DiagnosticBundleService.serverHosts(
            profile: "onprem",
            configURL: file.deletingLastPathComponent().appendingPathComponent("absent.yaml"),
            proxy: .none),
            [])
    }

    /// A scheduled run hands jamf-cli the system proxy, and a failing proxy is named in
    /// jamf-cli's errors, so a shared log loses its host too; a skipped proxy never reached it.
    func testSystemProxyHostIsSeeded() throws {
        let file = try writeConfig("")
        let proxy = SystemProxy.Proxy(
            host: "proxy.corp.example", port: 3128, noProxy: nil, untranslated: 0)
        XCTAssertEqual(DiagnosticBundleService.serverHosts(
            profile: "onprem", configURL: file, proxy: .use(proxy)),
            ["proxy.corp.example:3128", "proxy.corp.example"])
        XCTAssertEqual(DiagnosticBundleService.serverHosts(
            profile: "onprem", configURL: file, proxy: .skipped(reason: "names a user")), [])
        let line = "Get https://x: proxyconnect tcp: dial tcp: lookup proxy.corp.example: no such host"
        let shared = LogRedactor.redactedForSharing(
            line, profile: "onprem", scopeIDs: { _ in [] },
            serverHosts: { DiagnosticBundleService.serverHosts(
                profile: $0, configURL: file, proxy: .use(proxy)) })
        XCTAssertFalse(shared.contains("proxy.corp.example"), shared)
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
        let hosts = DiagnosticBundleService.serverHosts(
            profile: "gw", configURL: file, proxy: .none)
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
            serverHosts: { DiagnosticBundleService.serverHosts(
                profile: $0, configURL: file, proxy: .none) })
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

    /// The workspace rule runs last, so a peer-chosen word cannot split a seeded name or address.
    func testAWorkspaceNameCannotSplitASeededNameOrAnAddress() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ws-seed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try #"[{"general": {"name": "Jane Smith"}}]"#.write(
            to: dir.appendingPathComponent("computers.json"), atomically: true, encoding: .utf8)
        let r = DiagnosticRedactor()
        r.seedFromWorkspace(dir)
        r.seedWorkspaceNames(["Jane", "10"])
        let out = r.redactText("Jane Smith checked in from 10.0.0.1")
        XCTAssertFalse(out.contains("Smith"), "got: \(out)")
        XCTAssertFalse(out.contains(".0.0.1"), "got: \(out)")
        XCTAssertFalse(out.contains("10.0"), "got: \(out)")
    }

    /// config.yaml's timestamp authority is peer-writable: a bare word there ("partial") must
    /// not mask that word, and the `[partial]` marker, in every shared log.
    func testAPeerWrittenTimestampHostSeedsOnlyADottedHost() {
        XCTAssertEqual(DiagnosticBundleService.seedableHostForms(ofURL: "https://partial"), [])
        XCTAssertEqual(DiagnosticBundleService.seedableHostForms(ofURL: "https://warn:8443/x"), [])
        XCTAssertEqual(
            Set(DiagnosticBundleService.seedableHostForms(ofURL: "https://tsa.example.org:8443/tsr")),
            ["tsa.example.org:8443", "tsa.example.org"])
        XCTAssertFalse(DiagnosticBundleService.seedableHostForms(ofURL: "https://[2001:db8::1]/")
            .isEmpty)
    }

    /// No host seed, whatever its source, is a word run logs are made of.
    func testAHostSeedThatIsALogWordIsNotMasked() {
        let r = DiagnosticRedactor()
        r.seedServerHosts(["partial", "Error", "jss.example.org"])
        let out = r.redactText("[partial] Error reaching jss.example.org")
        XCTAssertTrue(out.hasPrefix("[partial] Error reaching "), "got: \(out)")
        XCTAssertFalse(out.contains("jss.example.org"), "got: \(out)")
    }
}
