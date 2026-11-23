import Foundation
@testable import JamfReports

/// Answers every request to `captureHost` with 200 and records its body, so a test sees the
/// webhook cards a run posts without a network. Reaches the sessions `HTTPSession.make` builds
/// through `HTTPSession.testProtocolClasses`.
final class WebhookCapture: URLProtocol, @unchecked Sendable {
    static let captureHost = "hooks.example.test"
    static let webhookURL = "https://\(captureHost)/incoming"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var bodies: [String] = []
    nonisolated(unsafe) private static var status = 200

    /// The HTTP status the stand-in webhook answers with; `start()` resets it to 200.
    static func respond(with code: Int) { lock.withLock { status = code } }

    /// The request bodies seen since `start()`.
    static var posted: [String] { lock.withLock { bodies } }

    static func start() {
        lock.withLock { bodies = []; status = 200 }
        HTTPSession.testProtocolClasses = [WebhookCapture.self]
    }

    static func stop() { HTTPSession.testProtocolClasses = nil }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == captureHost
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open()
            var collected = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                collected.append(buffer, count: count)
            }
            stream.close()
            data = collected
        }
        let body = String(decoding: data ?? Data(), as: UTF8.self)
        Self.lock.withLock { Self.bodies.append(body) }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: Self.lock.withLock { Self.status }, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
