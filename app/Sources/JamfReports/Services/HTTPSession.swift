import Foundation

/// The one way the app builds an outbound `URLSession`: ephemeral (no cache, cookie or
/// credential store on disk or shared with the rest of the process), with explicit timeouts, and
/// a redirect rule where the destination matters.
enum HTTPSession {

    static func make(request: TimeInterval, resource: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = request
        configuration.timeoutIntervalForResource = resource
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }

    /// Follows a redirect only to a URL `allows` accepts and refuses the rest (a 307 or 308
    /// would otherwise send the same body to the new address).
    final class RedirectRule: NSObject, URLSessionTaskDelegate, Sendable {
        private let allows: @Sendable (URL) -> Bool

        init(allows: @escaping @Sendable (URL) -> Bool) { self.allows = allows }

        /// https on `url`'s own host and port.
        static func sameHost(as url: URL) -> RedirectRule {
            let host = url.host?.lowercased() ?? ""
            let port = url.port ?? 443
            return RedirectRule { target in
                target.scheme?.lowercased() == "https"
                    && target.host?.lowercased() == host && (target.port ?? 443) == port
            }
        }

        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
        ) async -> URLRequest? {
            guard let url = request.url, allows(url) else { return nil }
            return request
        }
    }
}
