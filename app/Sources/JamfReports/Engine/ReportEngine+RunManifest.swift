import CryptoKit
import Foundation

/// The run manifest and its optional RFC 3161 timestamp, written once every file of a generate
/// run is on disk. One function does the step: `CLIBridge.generateAll` calls it after its last
/// format, and the single-workbook paths (`CLIBridge.generate` and `schoolGenerate` called on
/// their own, the scheduled run, the included CLI's `generate`) after the companion HTML.
extension ReportEngine {

    static let runManifestFailureMarker = "[warn] run manifest not written: "
    static let timestampFailureMarker = "[warn] report timestamp not saved: "

    /// Writes `<stem>.manifest.json` over `artifacts`, named after the first (the workbook,
    /// when the run wrote one), then, with `output.timestamp_authority` set and confirmed on this
    /// Mac, asks that authority to time-stamp the manifest's SHA-256 and saves the reply as
    /// `<stem>.tsr`. Only that hash, a random nonce and fixed headers leave the Mac. A `.tsr`
    /// left by an earlier run of the same name is removed when no new one is saved, so it never
    /// sits beside a manifest it does not sign. Every failure is one `[warn]` line naming the
    /// step, never `[partial]`: the reports are written and the run's result stands. Returns the
    /// manifest, nil when it was not written.
    @discardableResult
    static func sealRun(
        artifacts: [URL], config: ReportConfig?, profile: String?,
        now: Date = Date(), session: URLSessionConfiguration = .ephemeral,
        appSupport: URL = AppSupport.directory(),
        onLine: (@Sendable (CLIBridge.LogLine) -> Void)?
    ) async -> URL? {
        guard let primary = artifacts.first else { return nil }
        let manifestURL = RunManifest.manifestURL(for: primary)
        let data: Data
        do {
            data = try RunManifest.build(
                artifacts: artifacts, in: primary.deletingLastPathComponent(), now: now).encoded()
            try RunManifest.install(data, at: manifestURL)
        } catch {
            warn(runManifestFailureMarker + error.localizedDescription, onLine: onLine)
            return nil
        }
        onLine?(.init(timestamp: Date(), level: .ok,
                      text: "[ok] run manifest written: \(manifestURL.lastPathComponent)"))
        let tsrURL = RunManifest.timestampURL(for: primary)
        var saved = false
        if let config, let authority = timestampAuthority(
            config, profile: profile, appSupport: appSupport) {
            saved = await saveTimestamp(
                of: data, at: tsrURL, authority: authority, session: session, onLine: onLine)
        }
        // A stale reply from an earlier run of the name; never a folder a person put there.
        var held = stat()
        if !saved, lstat(tsrURL.path, &held) == 0, (held.st_mode & S_IFMT) != S_IFDIR {
            unlink(tsrURL.path)
        }
        return manifestURL
    }

    /// Sends `manifest`'s SHA-256 to `authority` and saves the checked reply at `tsrURL`. A
    /// failure is one `[warn]` line naming the step. True when the reply was saved.
    @discardableResult
    static func saveTimestamp(
        of manifest: Data, at tsrURL: URL, authority: URL,
        session: URLSessionConfiguration = .ephemeral,
        nonce: [UInt8] = TimestampToken.randomNonce(),
        onLine: (@Sendable (CLIBridge.LogLine) -> Void)?
    ) async -> Bool {
        do {
            let reply = try await TimestampAuthority.stamp(
                sha256: Array(SHA256.hash(data: manifest)), authority: authority,
                session: session, nonce: nonce)
            do { try RunManifest.install(reply, at: tsrURL) } catch {
                throw TimestampAuthority.Failure(
                    step: "saving \(tsrURL.lastPathComponent)", reason: error.localizedDescription)
            }
        } catch let failure as TimestampAuthority.Failure {
            warn(timestampFailureMarker + failure.text, onLine: onLine)
            return false
        } catch {
            warn(timestampFailureMarker + error.localizedDescription, onLine: onLine)
            return false
        }
        onLine?(.init(timestamp: Date(), level: .ok,
                      text: "[ok] report timestamp saved: \(tsrURL.lastPathComponent) "
                        + "(\(authority.host ?? ""))"))
        return true
    }

    /// `output.timestamp_authority` as this Mac may use it: nil when unset, not https, or
    /// changed in a shared config.yaml since this Mac pinned it (`SharedConfigPin`).
    static func timestampAuthority(
        _ config: ReportConfig, profile: String?, appSupport: URL = AppSupport.directory()
    ) -> URL? {
        guard let url = config.output?.timestampAuthorityURL else { return nil }
        if let profile, !SharedConfigPin.timestampAuthorityAllowed(
            config.output?.timestampAuthority ?? "", profile: profile, appSupport: appSupport) {
            return nil
        }
        return url
    }

    private static func warn(_ message: String, onLine: (@Sendable (CLIBridge.LogLine) -> Void)?) {
        AppLogger.report.warning("\(message, privacy: .private)")
        if let onLine {
            onLine(.init(timestamp: Date(), level: .warn, text: message))
        } else {
            print(message)
        }
    }
}

/// The RFC 3161 client: one POST of a time-stamp query, read up to `RunManifest.maxReplyBytes`
/// within `timeout` seconds, following a redirect only on the same https host.
enum TimestampAuthority {
    static let timeout: TimeInterval = 15

    /// Every header the app sets. CFNetwork still adds Host, Accept-Encoding, Content-Length
    /// and Connection; a fixed User-Agent and Accept-Language replace its defaults, which name
    /// the app build, the Darwin version and the Mac's languages.
    static let headers = [
        "Content-Type": "application/timestamp-query",
        "Accept": "application/timestamp-reply",
        "User-Agent": "JamfReports",
        "Accept-Language": "*",
    ]

    /// Which step failed, and why, in words that never carry the authority's URL (it can hold a
    /// token); the host is named.
    struct Failure: Error, Equatable {
        let step: String
        let reason: String
        var text: String { "\(step): \(reason)" }
    }

    /// Sends the query for `sha256` to `authority` and returns the reply, checked: granted, a
    /// SHA-256 imprint equal to `sha256`, the nonce sent, and a signature that verifies.
    static func stamp(
        sha256: [UInt8], authority: URL, session configuration: URLSessionConfiguration,
        nonce: [UInt8] = TimestampToken.randomNonce()
    ) async throws -> Data {
        let host = authority.host ?? ""
        var request = URLRequest(
            url: authority, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        request.httpBody = TimestampToken.request(sha256: sha256, nonce: nonce)
        let reply = try await send(request, to: authority, configuration: configuration)
        let inspection: TimestampToken.Inspection
        do {
            inspection = try TimestampToken.inspect(reply: reply)
        } catch {
            throw Failure(step: "reading the reply from \(host)",
                          reason: error.localizedDescription)
        }
        let expected = sha256.hexString
        guard inspection.imprint == expected,
              inspection.nonce == DER.unsignedMagnitude(nonce[...]),
              inspection.signatureValid else {
            throw Failure(step: "reading the reply from \(host)",
                          reason: "the reply does not sign this manifest with the nonce sent")
        }
        return reply
    }

    private static func send(
        _ request: URLRequest, to authority: URL, configuration: URLSessionConfiguration
    ) async throws -> Data {
        let step = "sending the request to \(authority.host ?? "")"
        let fetch: AppUpdateCheck.Fetch = { request in
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let (bytes, response) = try await session.bytes(
                for: request, delegate: SameHostRedirects(authority: authority))
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                throw AppUpdateCheck.CheckError.httpStatus(status)
            }
            return try await AppUpdateCheck.collect(bytes, limit: RunManifest.maxReplyBytes)
        }
        do {
            return try await AppUpdateCheck.fetch(request, using: fetch, deadline: timeout)
        } catch let error as AppUpdateCheck.CheckError {
            let reason = switch error {
            case .httpStatus(let code): "the authority answered HTTP \(code)"
            case .tooLarge: "the reply was larger than \(RunManifest.maxReplyBytes) bytes"
            case .timedOut: "no reply within \(Int(timeout)) s"
            default: "the request failed"
            }
            throw Failure(step: step, reason: reason)
        } catch let error as URLError {
            let reason = switch error.code {
            case .notConnectedToInternet, .networkConnectionLost: "no network connection"
            case .cannotFindHost, .dnsLookupFailed: "the host could not be found"
            case .timedOut: "no reply within \(Int(timeout)) s"
            case .secureConnectionFailed, .serverCertificateUntrusted,
                 .serverCertificateHasBadDate, .serverCertificateNotYetValid:
                "the TLS connection failed"
            default: "network error \(error.code.rawValue)"
            }
            throw Failure(step: step, reason: reason)
        }
    }

    /// Follows a redirect only to https on the authority's own host and port, so the query
    /// never goes to an address config.yaml did not name.
    private final class SameHostRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        let host: String
        let port: Int
        init(authority: URL) {
            host = authority.host?.lowercased() ?? ""
            port = authority.port ?? 443
        }

        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
        ) async -> URLRequest? {
            guard let url = request.url, url.scheme?.lowercased() == "https",
                  url.host?.lowercased() == host, (url.port ?? 443) == port else { return nil }
            return request
        }
    }
}
