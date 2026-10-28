import XCTest
@testable import JamfReports

/// A background run hands jamf-cli the system HTTPS proxy as `HTTPS_PROXY`: host and port only,
/// and not at all when the settings name a user.
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
        XCTAssertEqual(reading, .use(host: "proxy.example.org", port: 3128))
        XCTAssertEqual(reading.url, "http://proxy.example.org:3128")
        XCTAssertEqual(reading.runLine, "[info] using the system proxy proxy.example.org:3128")
    }

    func testNoProxyIsReadWhenDisabledMissingOrAbsent() {
        XCTAssertEqual(SystemProxy.reading(from: settings(enabled: 0)), .none)
        XCTAssertEqual(SystemProxy.reading(from: settings(host: nil)), .none)
        XCTAssertEqual(SystemProxy.reading(from: settings(host: "  ")), .none)
        XCTAssertEqual(SystemProxy.reading(from: nil), .none)
        XCTAssertNil(SystemProxy.Reading.none.runLine)
    }

    func testAProxyWithAUserNameIsSkippedAndNeverPassed() {
        for key in ["HTTPSUser", "HTTPSUsername", "HTTPSPassword"] {
            let reading = SystemProxy.reading(from: settings(extra: [key: "svc-account"]))
            XCTAssertNil(reading.url, key)
            XCTAssertEqual(reading.runLine,
                           "[warn] the system proxy is not used: it carries a user name or password")
        }
        let embedded = SystemProxy.reading(from: settings(host: "user:secret@proxy.example.org"))
        XCTAssertNil(embedded.url)
        XCTAssertFalse(embedded.runLine?.contains("secret") ?? false)
    }

    func testAnUnusableHostOrPortIsSkipped() {
        XCTAssertNil(SystemProxy.reading(from: settings(host: "proxy.example.org/path")).url)
        XCTAssertNil(SystemProxy.reading(from: settings(port: nil)).url)
        XCTAssertNil(SystemProxy.reading(from: settings(port: 70000)).url)
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
        XCTAssertNil(CLIBridge.environmentForJamfCLI(
            parent: ["https_proxy": "http://shell.example.org:8080"], proxy: proxy)["HTTPS_PROXY"])
    }
}
