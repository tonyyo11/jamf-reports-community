import XCTest
@testable import JamfReports

/// A background run hands jamf-cli the system HTTPS proxy as `HTTPS_PROXY` (host and port only)
/// and its bypass list as `NO_PROXY`, and not at all when the settings name a user.
final class SystemProxyTests: XCTestCase {

    private func settings(
        enabled: Int = 1, host: String? = "proxy.example.org", port: Int? = 3128,
        extra: [String: Any] = [:]
    ) -> [String: Any] {
        var dictionary: [String: Any] = [kCFNetworkProxiesHTTPSEnable as String: enabled]
        if let host { dictionary[kCFNetworkProxiesHTTPSProxy as String] = host }
        if let port { dictionary[kCFNetworkProxiesHTTPSPort as String] = port }
        return dictionary.merging(extra) { $1 }
    }

    func testAnEnabledProxyIsReadAsHostAndPort() {
        let reading = SystemProxy.reading(from: settings())
        XCTAssertEqual(reading, .use(SystemProxy.Proxy(
            host: "proxy.example.org", port: 3128, noProxy: nil, untranslated: 0)))
        XCTAssertEqual(reading.url, "http://proxy.example.org:3128")
        XCTAssertEqual(reading.runLines, ["[info] using the system HTTPS proxy"],
                       "the host stays out of the run record")
    }

    func testNoProxyIsReadWhenDisabledMissingOrAbsent() {
        XCTAssertEqual(SystemProxy.reading(from: settings(enabled: 0)), .none)
        XCTAssertEqual(SystemProxy.reading(from: settings(host: nil)), .none)
        XCTAssertEqual(SystemProxy.reading(from: settings(host: "  ")), .none)
        XCTAssertEqual(SystemProxy.reading(from: nil), .none)
        XCTAssertEqual(SystemProxy.Reading.none.runLines, [])
    }

    func testAProxyWithAUserNameIsSkippedAndNeverPassed() {
        for key in ["HTTPSUser", "HTTPSUsername", "HTTPSPassword"] {
            let reading = SystemProxy.reading(from: settings(extra: [key: "svc-account"]))
            XCTAssertNil(reading.url, key)
            XCTAssertEqual(reading.runLines, [
                "[warn] the system proxy is not used: it carries a user name or password"])
        }
        let embedded = SystemProxy.reading(from: settings(host: "user:secret@proxy.example.org"))
        XCTAssertNil(embedded.url)
        XCTAssertFalse(embedded.runLines.joined().contains("secret"))
    }

    func testAnUnusableHostOrPortIsSkipped() {
        XCTAssertNil(SystemProxy.reading(from: settings(host: "proxy.example.org/path")).url)
        XCTAssertNil(SystemProxy.reading(from: settings(port: nil)).url)
        XCTAssertNil(SystemProxy.reading(from: settings(port: 70000)).url)
        XCTAssertNil(SystemProxy.reading(from: settings(host: "pr\u{F6}xy.example.org")).url,
                     "ASCII hosts only")
    }

    func testTheBypassListBecomesNoProxyInTheFormGoReads() {
        let exceptions = [
            "*.example.gov", "localhost", "169.254/16", "10.0.0.0/8", "192.168.1.5", "*",
            "fe80::/64", "*.corp.*", "bad host"]
        let reading = SystemProxy.reading(from: settings(extra: [
            kCFNetworkProxiesExceptionsList as String: exceptions,
            kCFNetworkProxiesExcludeSimpleHostnames as String: 1]))
        XCTAssertEqual(
            reading.noProxy,
            ".example.gov,localhost,169.254.0.0/16,10.0.0.0/8,192.168.1.5,*")
        guard case .use(let proxy) = reading else { return XCTFail("\(reading)") }
        XCTAssertEqual(proxy.untranslated, 4, "IPv6, a mid-name wildcard, a bad name, simple hosts")
        XCTAssertEqual(reading.runLines.count, 2)
        XCTAssertTrue(reading.runLines[1].hasPrefix("[warn] 4 system proxy bypass entries"))
        XCTAssertFalse(reading.runLines.joined().contains("example.gov"), "entries are not named")
        XCTAssertNil(SystemProxy.noProxyEntry("169.254.1/40"))
        XCTAssertNil(SystemProxy.noProxyEntry("300.1/8"))
    }

    func testTheEnvironmentCarriesTheProxyUnlessTheParentSetOne() {
        let proxy = "http://proxy.example.org:3128"
        XCTAssertEqual(
            CLIBridge.environmentForJamfCLI(parent: [:], proxy: proxy)["HTTPS_PROXY"], proxy)
        XCTAssertNil(CLIBridge.environmentForJamfCLI(parent: [:], proxy: nil)["HTTPS_PROXY"])
        let shell = ["HTTPS_PROXY": "http://shell.example.org:8080"]
        XCTAssertEqual(
            CLIBridge.environmentForJamfCLI(parent: shell, proxy: proxy)["HTTPS_PROXY"],
            "http://shell.example.org:8080", "a proxy the shell set wins")
        let withBypass = CLIBridge.environmentForJamfCLI(
            parent: [:], proxy: proxy, noProxy: ".example.gov,169.254.0.0/16")
        XCTAssertEqual(withBypass["NO_PROXY"], ".example.gov,169.254.0.0/16")
        XCTAssertEqual(CLIBridge.environmentForJamfCLI(
            parent: ["no_proxy": "internal.example.org"], proxy: proxy,
            noProxy: ".example.gov")["NO_PROXY"], nil, "the shell's list wins")
        XCTAssertNil(CLIBridge.environmentForJamfCLI(
            parent: ["https_proxy": "http://shell.example.org:8080"], proxy: proxy)["HTTPS_PROXY"])
    }
}
