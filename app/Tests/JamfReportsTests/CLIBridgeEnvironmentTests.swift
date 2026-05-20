import XCTest
@testable import JamfReports

/// Track B Wave 2 — B-13: minimal environment for jamf-cli subprocess.
///
/// `Process.environment` defaults to inheriting the parent verbatim, which
/// allows attacker-controlled vars like `LD_PRELOAD`, `DYLD_INSERT_LIBRARIES`,
/// `SSL_CERT_FILE`, `JAMF_CLI_*` to alter how jamf-cli validates TLS, loads
/// dynamic libraries, or interprets its own config. The bridge now builds a
/// minimal env (PATH, HOME, LANG, TMPDIR + a small proxy allow-list) and
/// passes it explicitly.
final class CLIBridgeEnvironmentTests: XCTestCase {

    func test_environmentForJamfCLI_excludesDangerousVars() {
        // Set the dangerous vars in the parent so we know they are present
        // in `ProcessInfo.processInfo.environment`.
        setenv("LD_PRELOAD", "/tmp/evil.dylib", 1)
        setenv("DYLD_INSERT_LIBRARIES", "/tmp/evil.dylib", 1)
        setenv("SSL_CERT_FILE", "/tmp/evil.pem", 1)
        setenv("JAMF_CLI_OVERRIDE", "yes", 1)
        defer {
            unsetenv("LD_PRELOAD")
            unsetenv("DYLD_INSERT_LIBRARIES")
            unsetenv("SSL_CERT_FILE")
            unsetenv("JAMF_CLI_OVERRIDE")
        }

        let env = CLIBridge.environmentForJamfCLI()
        XCTAssertNil(env["LD_PRELOAD"])
        XCTAssertNil(env["DYLD_INSERT_LIBRARIES"])
        XCTAssertNil(env["SSL_CERT_FILE"])
        XCTAssertNil(env["JAMF_CLI_OVERRIDE"])
        // Sanity: the minimal env still contains PATH and HOME.
        XCTAssertNotNil(env["PATH"])
        XCTAssertNotNil(env["HOME"])
    }

    func test_environmentForJamfCLI_passesProxyAllowlist() {
        setenv("HTTP_PROXY", "http://proxy.local:8080", 1)
        defer { unsetenv("HTTP_PROXY") }

        let env = CLIBridge.environmentForJamfCLI()
        XCTAssertEqual(env["HTTP_PROXY"], "http://proxy.local:8080")
    }
}
