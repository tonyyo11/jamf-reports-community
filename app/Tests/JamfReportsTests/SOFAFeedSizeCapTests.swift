import Foundation
import XCTest
@testable import JamfReports

/// Answers the SOFA host with a valid feed padded to one byte over `SOFAFeedService.maxFeedBytes`,
/// so only the cap can refuse it.
private final class OversizedSOFA: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "sofafeed.macadmins.io"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // The other platforms get a quick 404, so only the macOS feed is read in full.
        let macOS = request.url?.lastPathComponent == "macos_data_feed.json"
        let response = HTTPURLResponse(
            url: request.url!, statusCode: macOS ? 200 : 404, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        guard macOS else { return client?.urlProtocolDidFinishLoading(self) ?? () }
        var body = Data(#"{"OSVersions":[]}"#.utf8)
        body.append(Data(repeating: UInt8(ascii: " "), count: SOFAFeedService.maxFeedBytes + 1 - body.count))
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class SOFAFeedSizeCapTests: XCTestCase {
    func testAFeedOverTheCapIsAFailedFetchAndTheCacheStays() async throws {
        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sofa-cap-\(UUID().uuidString)", isDirectory: true)
        let sofa = dataDir.appendingPathComponent("sofa", isDirectory: true)
        try FileManager.default.createDirectory(at: sofa, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dataDir) }
        let cached = sofa.appendingPathComponent("macos_data_feed.json")
        try Data("cached".utf8).write(to: cached)

        HTTPSession.testProtocolClasses = [OversizedSOFA.self]
        defer { HTTPSession.testProtocolClasses = nil }
        let (_, warnings) = await SOFAFeedService.refresh(dataDir: dataDir, timeout: 10)

        XCTAssertTrue(warnings.contains { $0.hasPrefix("SOFA macos: fetch failed") }, "\(warnings)")
        XCTAssertEqual(try String(contentsOf: cached, encoding: .utf8), "cached",
                       "an oversized answer never replaces the cache")
    }
}
