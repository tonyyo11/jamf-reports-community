import XCTest
@testable import JamfReports

final class HTTPSessionTests: XCTestCase {

    private func decision(_ rule: HTTPSession.RedirectRule, to target: String) async throws -> URL? {
        let session = HTTPSession.make(request: 5, resource: 5)
        defer { session.invalidateAndCancel() }
        let origin = try XCTUnwrap(URL(string: "https://hooks.example.com/a"))
        let task = session.dataTask(with: origin)
        let response = try XCTUnwrap(HTTPURLResponse(
            url: origin, statusCode: 307, httpVersion: nil, headerFields: nil))
        let next = URLRequest(url: try XCTUnwrap(URL(string: target)))
        return await rule.urlSession(
            session, task: task, willPerformHTTPRedirection: response, newRequest: next)?.url
    }

    func testSameHostRuleFollowsOnlyHTTPSOnTheSameHostAndPort() async throws {
        let rule = HTTPSession.RedirectRule.sameHost(
            as: try XCTUnwrap(URL(string: "https://Hooks.example.com/a")))
        let same = try await decision(rule, to: "https://hooks.example.com/b")
        XCTAssertEqual(same?.path, "/b")
        let otherHost = try await decision(rule, to: "https://evil.example.net/b")
        XCTAssertNil(otherHost)
        let downgrade = try await decision(rule, to: "http://hooks.example.com/b")
        XCTAssertNil(downgrade)
        let otherPort = try await decision(rule, to: "https://hooks.example.com:8443/b")
        XCTAssertNil(otherPort)
    }

    func testInstallerRuleFollowsOnlyTheTrustedAssetHosts() async throws {
        let rule = HTTPSession.RedirectRule { JamfCLIInstaller.isTrustedFinalURL($0) }
        let github = try await decision(rule, to: "https://objects.githubusercontent.com/x")
        XCTAssertNotNil(github)
        let other = try await decision(rule, to: "https://example.com/x")
        XCTAssertNil(other)
    }
}
