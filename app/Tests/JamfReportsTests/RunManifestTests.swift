import CryptoKit
import Foundation
import XCTest
@testable import JamfReports

// The per-run manifest, its RFC 3161 timestamp and `jamf-reports verify`. The timestamp fixture
// is FreeTSA's real reply, captured once (see Fixtures/README.md); no test reaches a network.

/// Serves the TSA's answer for `host` and records what was sent, so a test sees the request
/// bytes without a network.
final class TSAStub: URLProtocol, @unchecked Sendable {
    static let host = "tsa.example.test"
    enum Answer {
        case reply(Int, Data)
        case failure(URLError.Code)
        case redirect(to: URL)
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var answer = Answer.reply(200, Data())
    nonisolated(unsafe) private static var seen: [(host: String, body: Data)] = []
    nonisolated(unsafe) private static var seenHeaders: [[String: String]] = []

    static func answer(_ next: Answer) {
        lock.withLock { answer = next; seen = []; seenHeaders = [] }
    }
    static var requests: [(host: String, body: Data)] { lock.withLock { seen } }
    static var headers: [[String: String]] { lock.withLock { seenHeaders } }

    static var session: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TSAStub.self]
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            stream.close()
        }
        let url = request.url ?? URL(fileURLWithPath: "/")
        let next = Self.lock.withLock {
            Self.seen.append((url.host ?? "", body))
            Self.seenHeaders.append(request.allHTTPHeaderFields ?? [:])
            return Self.answer
        }
        switch next {
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .reply(let status, let data):
            let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/timestamp-reply"])
            if let response {
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            }
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .redirect(let target):
            let response = HTTPURLResponse(
                url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                headerFields: ["Location": target.absoluteString])
            if let response {
                client?.urlProtocol(
                    self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            }
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}

private final class ManifestLines: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func add(_ line: CLIBridge.LogLine) { lock.withLock { stored.append(line.text) } }
    var all: [String] { lock.withLock { stored } }
}

final class RunManifestTests: XCTestCase {

    private let stem = "report_fixture_2026-10-29_090000"
    private var folder: URL!
    private let authority = URL(string: "https://\(TSAStub.host)/tsr?token=secret")!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-manifest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Fixture

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: TestFixtures.dir("timestamp/\(name)"))
    }

    private var manifestName: String { stem + RunManifest.manifestSuffix }

    /// The three artifacts the captured manifest lists, the manifest and, optionally, the reply.
    private func layOutFixtureRun(withReply: Bool = true) throws {
        let csv = folder.appendingPathComponent("\(stem)_csv", isDirectory: true)
        try FileManager.default.createDirectory(at: csv, withIntermediateDirectories: true)
        try Data("fixture workbook\n".utf8).write(to: folder.appendingPathComponent("\(stem).xlsx"))
        try Data("<p>fixture report</p>\n".utf8)
            .write(to: folder.appendingPathComponent("\(stem).html"))
        try Data("Metric,Value\nComputers,3\n".utf8)
            .write(to: csv.appendingPathComponent("Overview.csv"))
        try fixture(manifestName).write(to: folder.appendingPathComponent(manifestName))
        if withReply {
            try fixture("freetsa.tsr").write(to: folder.appendingPathComponent("\(stem).tsr"))
        }
    }

    private var manifestHash: [UInt8] {
        get throws { Array(SHA256.hash(data: try fixture(manifestName))) }
    }

    /// The nonce openssl put in the captured query: its third field.
    private func capturedNonce() throws -> [UInt8] {
        let fields = try DER.children(
            of: DER.single(Array(try fixture("freetsa.tsq"))), expecting: 0x30)
        return DER.unsignedMagnitude(fields[2].content)
    }

    // MARK: Request and reply

    /// The app's query is byte for byte the one FreeTSA answered: version, the SHA-256 imprint,
    /// the nonce and certReq, and nothing else.
    func testTheRequestIsTheCapturedQueryAndCarriesOnlyTheHashAndANonce() throws {
        let request = TimestampToken.request(sha256: try manifestHash, nonce: try capturedNonce())
        XCTAssertEqual(request, try fixture("freetsa.tsq"))
        XCTAssertEqual(request.count, 69, "32 bytes of hash, 8 of nonce, and the DER around them")
    }

    func testTheCapturedReplySignsTheManifestHashAtFreeTSAsTime() throws {
        let inspection = try TimestampToken.inspect(reply: try fixture("freetsa.tsr"))
        XCTAssertEqual(inspection.imprint,
                       try manifestHash.map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(inspection.nonce, try capturedNonce())
        XCTAssertEqual(inspection.signedAt, Date(timeIntervalSince1970: 1_793_255_904),
                       "2026-10-29 06:38:24 UTC, as openssl ts -reply -text reads it")
        XCTAssertTrue(inspection.signatureValid)
        XCTAssertFalse(inspection.chainTrusted, "FreeTSA's root is not in the system trust")
        XCTAssertEqual(inspection.signer.map { $0.lowercased().contains("freetsa") }, true)
        // openssl x509 -fingerprint -sha256 of the TSA certificate the token carries.
        XCTAssertEqual(inspection.signerSHA256,
                       "32e841a95cc1164101ffde41298ef2fc75c1c4372ef095e88a6bbd47dfb191fc")
    }

    /// A reply whose signed TSTInfo was edited (here its serial number) no longer verifies.
    func testAnEditedTokenFailsItsSignature() throws {
        try layOutFixtureRun()
        var reply = try fixture("freetsa.tsr")
        let serial = Data([0x02, 0x04, 0x09, 0x88, 0x54, 0x1e])
        let at = try XCTUnwrap(reply.range(of: serial)).upperBound - 1
        reply[at] ^= 0x01
        XCTAssertFalse(try TimestampToken.inspect(reply: reply).signatureValid)
        try reply.write(to: folder.appendingPathComponent("\(stem).tsr"))
        let result = RunManifest.verify(manifestAt: folder.appendingPathComponent(manifestName))
        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.lines.contains("FAIL  timestamp signature does not verify"))
    }

    func testARefusedOrGarbledReplyIsNotAToken() {
        // TimeStampResp { status { 2 (rejection) } }
        let rejected = Data([0x30, 0x05, 0x30, 0x03, 0x02, 0x01, 0x02])
        XCTAssertThrowsError(try TimestampToken.inspect(reply: rejected)) {
            XCTAssertEqual($0 as? TimestampToken.Failure, .refused(status: 2))
        }
        XCTAssertThrowsError(try TimestampToken.inspect(reply: Data("<html>".utf8)))
        XCTAssertThrowsError(try TimestampToken.inspect(reply: Data()))
    }

    // MARK: verify

    func testVerifyPassesAGoodRunAndPrintsTheTimeAndAnUntrustedChain() throws {
        try layOutFixtureRun()
        let result = RunManifest.verify(manifestAt: folder.appendingPathComponent(manifestName))
        XCTAssertTrue(result.passed, result.lines.joined(separator: "\n"))
        XCTAssertEqual(result.lines.filter { $0.hasPrefix("OK ") }.count, 3)
        XCTAssertTrue(result.lines.contains("3 of 3 artifacts match."))
        XCTAssertTrue(result.lines.contains { $0.hasPrefix(
            "Timestamp: manifest signed 2026-10-29T06:38:24Z") }, "\(result.lines)")
        XCTAssertTrue(result.lines.contains { $0.hasPrefix("Timestamp chain: not trusted") })
        XCTAssertTrue(result.lines.contains(RunManifest.untrustedChainNote))
        XCTAssertTrue(result.lines.contains { $0.hasPrefix(
            "Timestamp signer certificate SHA-256: 32e841a95cc1164101ffde41298ef2fc") })
    }

    /// A file added to the CSV folder, at its top or in a folder inside it, is not part of the
    /// run; Finder's `.DS_Store` is the one entry left alone.
    func testVerifyNamesAnExtraFileInTheCSVFolderAndFails() throws {
        try layOutFixtureRun()
        let csv = folder.appendingPathComponent("\(stem)_csv", isDirectory: true)
        try Data("x".utf8).write(to: csv.appendingPathComponent(".DS_Store"))
        var result = RunManifest.verify(manifestAt: folder.appendingPathComponent(manifestName))
        XCTAssertTrue(result.passed, "\(result.lines)")

        try Data("=cmd".utf8).write(to: csv.appendingPathComponent("Added.csv"))
        let nested = csv.appendingPathComponent("more", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: nested.appendingPathComponent("Hidden.csv"))
        try FileManager.default.createDirectory(
            at: csv.appendingPathComponent("empty"), withIntermediateDirectories: true)
        result = RunManifest.verify(manifestAt: folder.appendingPathComponent(manifestName))
        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.lines.filter { $0.hasPrefix("EXTRA") }, [
            "EXTRA    \(stem)_csv/Added.csv", "EXTRA    \(stem)_csv/empty/",
            "EXTRA    \(stem)_csv/more/Hidden.csv",
        ])
        XCTAssertTrue(result.lines.contains("3 of 3 artifacts match."))
    }

    /// What a manifest says is shown on one line, whoever wrote it.
    func testVerifyShowsManifestTextOnOneLine() throws {
        try layOutFixtureRun(withReply: false)
        let forged = RunManifest(
            generatedAt: "2026\nOK       everything", generator: "x\u{1b}[2Jy", artifacts: [])
        let url = folder.appendingPathComponent("forged" + RunManifest.manifestSuffix)
        try forged.encoded().write(to: url)
        let result = RunManifest.verify(manifestAt: url)
        XCTAssertTrue(result.lines.contains("Written 2026OK       everything by x[2Jy"),
                      "\(result.lines)")
        XCTAssertFalse(result.lines.contains { $0.contains("\n") || $0.contains("\u{1b}") })
    }

    func testVerifyNamesAChangedArtifactAndFails() throws {
        try layOutFixtureRun()
        try Data("Metric,Value\nComputers,4\n".utf8).write(
            to: folder.appendingPathComponent("\(stem)_csv/Overview.csv"))
        let result = RunManifest.verify(manifestAt: folder.appendingPathComponent(manifestName))
        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.lines.contains("CHANGED  \(stem)_csv/Overview.csv"))
        XCTAssertTrue(result.lines.contains("2 of 3 artifacts match."))
        XCTAssertTrue(result.lines.contains { $0.hasPrefix("Timestamp: manifest signed") },
                      "the manifest itself is unchanged, so its timestamp still holds")
    }

    func testVerifyNamesAMissingOrLinkedArtifactAndFails() throws {
        try layOutFixtureRun()
        let html = folder.appendingPathComponent("\(stem).html")
        try FileManager.default.removeItem(at: html)
        let workbook = folder.appendingPathComponent("\(stem).xlsx")
        let elsewhere = folder.appendingPathComponent("elsewhere.xlsx")
        try FileManager.default.moveItem(at: workbook, to: elsewhere)
        try FileManager.default.createSymbolicLink(at: workbook, withDestinationURL: elsewhere)
        let result = RunManifest.verify(manifestAt: folder.appendingPathComponent(manifestName))
        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.lines.contains("MISSING \(stem).html"), "\(result.lines)")
        XCTAssertTrue(result.lines.contains("UNREADABLE \(stem).xlsx"), "a link is not read")
    }

    /// A manifest edited to match a changed file no longer matches its timestamp.
    func testVerifyFailsAManifestTheTimestampDoesNotSign() throws {
        try layOutFixtureRun()
        let url = folder.appendingPathComponent(manifestName)
        var text = try String(contentsOf: url, encoding: .utf8)
        text = text.replacingOccurrences(of: "\"size\" : 25", with: "\"size\" : 26")
        try text.write(to: url, atomically: true, encoding: .utf8)
        let result = RunManifest.verify(manifestAt: url)
        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.lines.contains { $0.hasPrefix("FAIL  timestamp is for another file") })
    }

    func testVerifyWithoutAReplySaysSoAndRefusesNamesOutsideTheFolder() throws {
        try layOutFixtureRun(withReply: false)
        var result = RunManifest.verify(manifestAt: folder.appendingPathComponent(manifestName))
        XCTAssertTrue(result.passed)
        XCTAssertTrue(result.lines.contains { $0.hasPrefix("Timestamp: none") })
        XCTAssertTrue(result.lines.contains(RunManifest.untimestampedNote))

        let forged = RunManifest(generatedAt: "x", generator: "x", artifacts: [
            .init(name: "../escape.txt", size: 1, sha256: "00"),
            .init(name: "/etc/hosts", size: 1, sha256: "00"),
        ])
        let url = folder.appendingPathComponent("forged" + RunManifest.manifestSuffix)
        try forged.encoded().write(to: url)
        result = RunManifest.verify(manifestAt: url)
        XCTAssertFalse(result.passed)
        let refused = result.lines.filter {
            $0.hasSuffix("not a name inside the manifest's folder")
        }
        XCTAssertEqual(refused.count, 2)
    }

    // MARK: Writing through the real writers

    func testAManifestOverALinkedArtifactIsNotWrittenAndWarnsOnce() async throws {
        let target = folder.appendingPathComponent("real.xlsx")
        try Data("x".utf8).write(to: target)
        let workbook = folder.appendingPathComponent("report_a.xlsx")
        try FileManager.default.createSymbolicLink(at: workbook, withDestinationURL: target)
        let lines = ManifestLines()
        let written = await ReportEngine.sealRun(
            artifacts: [workbook], config: ReportConfig(), profile: nil,
            now: Date(timeIntervalSince1970: 1_793_264_400), onLine: lines.add)
        XCTAssertNil(written)
        XCTAssertEqual(lines.all.filter { $0.hasPrefix(ReportEngine.runManifestFailureMarker) }
            .count, 1, "\(lines.all)")
        XCTAssertFalse(lines.all.contains { $0.contains("[partial]") })
    }

    // MARK: The timestamp step

    /// The stubbed authority answers with the captured reply; the app sends exactly the
    /// captured query and saves exactly that reply, which `verify` then reads.
    func testTheTimestampIsRequestedOverTheManifestHashAndSaved() async throws {
        try layOutFixtureRun(withReply: false)
        TSAStub.answer(.reply(200, try fixture("freetsa.tsr")))
        let lines = ManifestLines()
        let tsr = folder.appendingPathComponent("\(stem).tsr")
        await ReportEngine.saveTimestamp(
            of: try fixture(manifestName), at: tsr, authority: authority,
            session: TSAStub.session, nonce: try capturedNonce(), onLine: lines.add)

        XCTAssertEqual(TSAStub.requests.map(\.host), [TSAStub.host])
        XCTAssertEqual(TSAStub.requests.first?.body, try fixture("freetsa.tsq"),
                       "the manifest's SHA-256 and the nonce are all that leave the Mac")
        // CFNetwork adds Host, Accept-Encoding, Content-Length and Connection after this point.
        XCTAssertEqual(TSAStub.headers.first?.filter { $0.key != "Content-Length" },
                       TimestampAuthority.headers)
        XCTAssertEqual(TimestampAuthority.headers["User-Agent"], "JamfReports")
        XCTAssertEqual(TimestampAuthority.headers["Accept-Language"], "*")
        XCTAssertEqual(try Data(contentsOf: tsr), try fixture("freetsa.tsr"))
        XCTAssertTrue(lines.all.contains(
            "[ok] report timestamp saved: \(stem).tsr (\(TSAStub.host))"))
        XCTAssertTrue(RunManifest.verify(manifestAt: folder.appendingPathComponent(manifestName))
            .passed)
    }

    /// Each failure is one `[warn]` naming the step, never `[partial]`, never the URL (its query
    /// holds a token), and leaves no `.tsr`.
    func testEveryTimestampFailureIsOneWarningNamingTheStep() async throws {
        let manifest = try fixture(manifestName)
        let cases: [(TSAStub.Answer, [UInt8]?, String)] = [
            (.reply(500, Data()), nil, "sending the request to \(TSAStub.host): the authority "
                + "answered HTTP 500"),
            (.failure(.notConnectedToInternet), nil,
             "sending the request to \(TSAStub.host): no network connection"),
            (.reply(200, Data("<html>busy</html>".utf8)), nil,
             "reading the reply from \(TSAStub.host): the reply is not an RFC 3161"),
            // The real reply, but for a nonce this request did not send.
            (.reply(200, try fixture("freetsa.tsr")), [0x01],
             "reading the reply from \(TSAStub.host): the reply does not sign this manifest"),
            (.reply(200, Data(count: RunManifest.maxReplyBytes + 1)), nil,
             "sending the request to \(TSAStub.host): the reply was larger than"),
        ]
        let captured = try capturedNonce()
        for (answer, nonce, expected) in cases {
            TSAStub.answer(answer)
            let lines = ManifestLines()
            let tsr = folder.appendingPathComponent("\(stem).tsr")
            await ReportEngine.saveTimestamp(
                of: manifest, at: tsr, authority: authority, session: TSAStub.session,
                nonce: nonce ?? captured, onLine: lines.add)
            let warnings = lines.all.filter { $0.hasPrefix(ReportEngine.timestampFailureMarker) }
            XCTAssertEqual(warnings.count, 1, "\(expected): \(lines.all)")
            XCTAssertTrue(warnings.first?.contains(expected) == true, "\(lines.all)")
            XCTAssertFalse(lines.all.contains { $0.contains("[partial]") || $0.contains("secret") })
            XCTAssertFalse(FileManager.default.fileExists(atPath: tsr.path), expected)
        }
    }

    func testARedirectToAnotherHostOrPortIsNotFollowed() async throws {
        for target in ["https://collector.attacker.test/tsr", "https://\(TSAStub.host):8443/tsr",
                       "http://\(TSAStub.host)/tsr"] {
            TSAStub.answer(.redirect(to: try XCTUnwrap(URL(string: target))))
            let lines = ManifestLines()
            await ReportEngine.saveTimestamp(
                of: try fixture(manifestName), at: folder.appendingPathComponent("x.tsr"),
                authority: authority, session: TSAStub.session, onLine: lines.add)
            XCTAssertEqual(TSAStub.requests.count, 1, "\(target): \(lines.all)")
            XCTAssertEqual(lines.all.filter { $0.hasPrefix(ReportEngine.timestampFailureMarker) }
                .count, 1, "\(lines.all)")
        }
    }

    /// The whole step with the authority set: a failing authority leaves the manifest, no
    /// `.tsr` (the one an earlier run of the same name left is removed) and no `[partial]`.
    func testASealWhoseAuthorityFailsKeepsTheManifestAndDropsAStaleReply() async throws {
        try layOutFixtureRun(withReply: true)
        let config = try ConfigLoader.loadFromString(
            "output:\n  timestamp_authority: \"\(authority.absoluteString)\"\n")
        TSAStub.answer(.reply(503, Data()))
        let lines = ManifestLines()
        let workbook = folder.appendingPathComponent("\(stem).xlsx")
        let manifest = await ReportEngine.sealRun(
            artifacts: [workbook], config: config, profile: nil,
            now: Date(timeIntervalSince1970: 1_793_264_400), session: TSAStub.session,
            onLine: lines.add)
        XCTAssertEqual(manifest?.lastPathComponent, manifestName)
        XCTAssertEqual(TSAStub.requests.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: folder.appendingPathComponent("\(stem).tsr").path),
            "the earlier run's reply does not sign this manifest")
        XCTAssertEqual(lines.all.filter { $0.hasPrefix(ReportEngine.timestampFailureMarker) }
            .count, 1, "\(lines.all)")
        XCTAssertFalse(lines.all.contains { $0.contains("[partial]") })
        XCTAssertTrue(RunManifest.verify(manifestAt: try XCTUnwrap(manifest)).passed)
    }

    // MARK: Rotation and retention

    func testRotationMovesTheManifestAndReplyWithTheirWorkbookAndNeverCountsThem() throws {
        let archive = folder.appendingPathComponent("archive", isDirectory: true)
        let old = "report_p_2026-10-01_090000"
        let new = "report_p_2026-10-02_090000"
        for name in ["\(old).xlsx", "\(old).manifest.json", "\(old).tsr", "\(new).xlsx",
                     "\(new).manifest.json", "\(new).tsr", "report_p_2026-09-01_090000.tsr"] {
            try Data("x".utf8).write(to: folder.appendingPathComponent(name))
        }
        let engine = ReportEngine(config: ReportConfig(), dataDir: folder)
        engine.archiveOldRuns(outputDir: folder, archiveDir: archive, stem: "report_p", keep: 1)

        let archived = Set(try FileManager.default.contentsOfDirectory(atPath: archive.path))
        XCTAssertEqual(archived, ["\(old).xlsx", "\(old).manifest.json", "\(old).tsr"])
        let kept = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        XCTAssertTrue(kept.isSuperset(of: ["\(new).xlsx", "\(new).manifest.json", "\(new).tsr",
                                           "report_p_2026-09-01_090000.tsr"]),
                      "a reply with no workbook of its name stays where it is")
    }

    /// A Generate run's own HTML, PDF and CSV, listed in the workbook's manifest, move with it.
    func testRotationMovesWhatTheManifestListsWithTheWorkbook() throws {
        let archive = folder.appendingPathComponent("archive", isDirectory: true)
        let old = "report_p_2026-10-01_090000"
        let new = "report_p_2026-10-02_090000"
        let page = "jamf_report_p_2026-10-01_090001.html"
        for name in ["\(old).xlsx", page, "\(new).xlsx"] {
            try Data(name.utf8).write(to: folder.appendingPathComponent(name))
        }
        let manifest = try RunManifest.build(
            artifacts: [folder.appendingPathComponent("\(old).xlsx"),
                        folder.appendingPathComponent(page)],
            in: folder, now: Date(timeIntervalSince1970: 1_793_264_400))
        try manifest.encoded().write(to: folder.appendingPathComponent("\(old).manifest.json"))
        ReportEngine(config: ReportConfig(), dataDir: folder).archiveOldRuns(
            outputDir: folder, archiveDir: archive, stem: "report_p", keep: 1)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: archive.path)),
                       ["\(old).xlsx", page, "\(old).manifest.json"])
        XCTAssertTrue(RunManifest.verify(
            manifestAt: archive.appendingPathComponent("\(old).manifest.json")).passed)
    }

    /// When a file of the run cannot be archived, its manifest stays with the files left.
    func testRotationLeavesTheManifestWhenAFileOfItsRunDidNotMove() throws {
        let archive = folder.appendingPathComponent("archive", isDirectory: true)
        let old = "report_p_2026-10-01_090000"
        for name in ["\(old).xlsx", "\(old).html", "\(old).manifest.json",
                     "report_p_2026-10-02_090000.xlsx"] {
            try Data("x".utf8).write(to: folder.appendingPathComponent(name))
        }
        // A read-only folder at the HTML's name in the archive cannot be replaced.
        let blocker = archive.appendingPathComponent("\(old).html", isDirectory: true)
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: blocker.appendingPathComponent("held"))
        try FileManager.default.setAttributes([.posixPermissions: 0o500],
                                              ofItemAtPath: blocker.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                   ofItemAtPath: blocker.path)
        }
        let lines = ManifestLines()
        ReportEngine(config: ReportConfig(), dataDir: folder).archiveOldRuns(
            outputDir: folder, archiveDir: archive, stem: "report_p", keep: 1, onLine: lines.add)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: folder.appendingPathComponent("\(old).manifest.json").path))
        XCTAssertTrue(lines.all.contains {
            $0.hasPrefix("[warn] Run manifest \(old).manifest.json left in the report folder")
        }, "\(lines.all)")
    }

    /// A planted manifest can name only this app's report formats, and never displaces an
    /// archive entry: `notes.txt` and the archive's own `notes.txt` and `kept.html` stay put.
    func testAPlantedManifestCannotMakeRotationMoveOrDeleteOtherFiles() throws {
        let archive = folder.appendingPathComponent("archive", isDirectory: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        let old = "report_p_2026-10-01_090000"
        for name in ["\(old).xlsx", "report_p_2026-10-02_090000.xlsx", "notes.txt", "kept.html",
                     ".hidden.pdf", "target.pdf", "fresh.html", "fresh.html.sha256"] {
            try Data(name.utf8).write(to: folder.appendingPathComponent(name))
        }
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("link.pdf"),
            withDestinationURL: folder.appendingPathComponent("target.pdf"))
        try Data("archived notes".utf8).write(to: archive.appendingPathComponent("notes.txt"))
        try Data("archived page".utf8).write(to: archive.appendingPathComponent("kept.html"))
        try Data("archived sidecar".utf8).write(
            to: archive.appendingPathComponent("fresh.html.sha256"))
        let planted = RunManifest(generatedAt: "x", generator: "x", artifacts: [
            "notes.txt", "kept.html", ".hidden.pdf", "link.pdf", "fresh.html",
        ].map { .init(name: $0, size: 1, sha256: "00") })
        try planted.encoded().write(to: folder.appendingPathComponent("\(old).manifest.json"))
        let lines = ManifestLines()
        ReportEngine(config: ReportConfig(), dataDir: folder).archiveOldRuns(
            outputDir: folder, archiveDir: archive, stem: "report_p", keep: 1, onLine: lines.add)

        for name in ["notes.txt", "kept.html", ".hidden.pdf", "link.pdf"] {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: folder.appendingPathComponent(name).path), name)
        }
        XCTAssertEqual(try String(contentsOf: archive.appendingPathComponent("notes.txt"),
                                  encoding: .utf8), "archived notes")
        XCTAssertEqual(try String(contentsOf: archive.appendingPathComponent("kept.html"),
                                  encoding: .utf8), "archived page")
        XCTAssertEqual(try String(contentsOf: archive.appendingPathComponent("fresh.html.sha256"),
                                  encoding: .utf8), "archived sidecar",
                       "a listed file's sidecar never replaces an archive entry")
        XCTAssertEqual(lines.all.filter { $0.contains("already holds an entry") }.count, 2,
                       "\(lines.all)")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: folder.appendingPathComponent("\(old).manifest.json").path),
            "a run that did not move whole keeps its manifest")
    }

    /// A rotation failure reads in plain words, never a Swift error's description.
    func testARotationFailureWarnsInPlainWords() throws {
        for name in ["report_p_2026-10-01_090000.xlsx", "report_p_2026-10-02_090000.xlsx"] {
            try Data("x".utf8).write(to: folder.appendingPathComponent(name))
        }
        let blocker = folder.appendingPathComponent("blocker")
        try Data("x".utf8).write(to: blocker)
        let lines = ManifestLines()
        ReportEngine(config: ReportConfig(), dataDir: folder).archiveOldRuns(
            outputDir: folder, archiveDir: blocker.appendingPathComponent("archive"),
            stem: "report_p", keep: 1, onLine: lines.add)
        let warning = try XCTUnwrap(lines.all.first { $0.hasPrefix("[warn] Could not create") })
        XCTAssertFalse(warning.contains("Error Domain") || warning.contains("NSCocoaErrorDomain"),
                       warning)
    }

    func testRetentionNeverTakesAManifestOrReply() {
        for name in ["report_p_2026-10-01_090000.manifest.json", "report_p_2026-10-01_090000.tsr",
                     "computers_20261001T090000.manifest.json", "computers_20261001T090000.tsr"] {
            XCTAssertFalse(SnapshotRetentionService.isSnapshotFile(
                URL(fileURLWithPath: "/w/jamf-cli-data/computers/\(name)")), name)
        }
    }

    func testTheStagingSweepRemovesAnOldStagedManifestOrReply() throws {
        let now = Date(timeIntervalSince1970: 1_793_264_400)
        let names = [".r.manifest.json.tmp-\(UUID().uuidString)", ".r.tsr.tmp-\(UUID().uuidString)"]
        for name in names {
            let url = folder.appendingPathComponent(name)
            try Data("x".utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(-2 * AtomicInstall.staleStagingAge)],
                ofItemAtPath: url.path)
        }
        AtomicInstall.removeStaleStaging(in: folder, now: now)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
    }

    // MARK: The config key

    func testTheAuthorityIsAnHTTPSURLOrOff() throws {
        func url(_ yaml: String) throws -> URL? {
            try ConfigLoader.loadFromString("output:\n  " + yaml + "\n")
                .output?.timestampAuthorityURL
        }
        XCTAssertEqual(try url("timestamp_authority: \"https://freetsa.org/tsr\""),
                       URL(string: "https://freetsa.org/tsr"))
        XCTAssertNil(try url("timestamp_authority: \"http://freetsa.org/tsr\""))
        XCTAssertNil(try url("timestamp_authority: \"\""))
        XCTAssertNil(try url("timestamp_authority: true"), "a mistyped value reads as off")
        XCTAssertNil(try url("csv_folder: true"))
    }

    func testConfigDoctorNamesAnAuthorityTheRunCannotUse() throws {
        let config = try ConfigLoader.loadFromString(
            "output:\n  timestamp_authority: \"http://tsa.example.test/tsr\"\n")
        let rows = ConfigDoctorService.valueRows(config, raw: [:], profile: "p")
        let row = try XCTUnwrap(rows.first { $0.title == "output.timestamp_authority" })
        XCTAssertEqual(row.severity, .warn)
        XCTAssertTrue(row.detail.contains("tsa.example.test"))
        XCTAssertFalse(row.detail.contains("http://"), "the host only, as for the webhook")
    }
}

@MainActor
final class RunManifestGenerateTests: XCTestCase {

    /// A GUI generate with the CSV folder and the companion HTML: one manifest beside the
    /// workbook listing the workbook, the HTML and each CSV with the hash of the file on disk.
    func testAGenerateWritesOneManifestOfEveryArtifact() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-manifest-gui-\(UUID().uuidString)", isDirectory: true)
        let profile = "manifestrun"
        let workspace = root.appendingPathComponent(profile, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try "html:\n  with_workbook: true\noutput:\n  csv_folder: true\n".write(
            to: workspace.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        defer {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: root)
        }
        let lines = ManifestLines()
        let result = await CLIBridge().generateAll(
            types: [.xlsx], outputDir: nil, profile: profile, onLine: lines.add)
        XCTAssertEqual(result.succeeded, [.xlsx], "\(lines.all)")

        let reports = workspace.appendingPathComponent("Generated Reports")
        let names = try FileManager.default.contentsOfDirectory(atPath: reports.path)
        let manifests = names.filter { $0.hasSuffix(RunManifest.manifestSuffix) }
        XCTAssertEqual(manifests.count, 1, "\(names)")
        let manifestURL = reports.appendingPathComponent(try XCTUnwrap(manifests.first))
        let manifest = try JSONDecoder().decode(
            RunManifest.self, from: try Data(contentsOf: manifestURL))
        let workbookStem = String(manifestURL.lastPathComponent.dropLast(
            RunManifest.manifestSuffix.count))
        let listed = manifest.artifacts.map(\.name)
        XCTAssertEqual(Array(listed.prefix(2)), ["\(workbookStem).xlsx", "\(workbookStem).html"])
        XCTAssertGreaterThan(listed.filter { $0.hasPrefix("\(workbookStem)_csv/") }.count, 0)
        for artifact in manifest.artifacts {
            let data = try Data(contentsOf: reports.appendingPathComponent(artifact.name))
            XCTAssertEqual(artifact.sha256,
                           SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
            XCTAssertEqual(artifact.size, data.count)
        }
        XCTAssertTrue(lines.all.contains(
            "[ok] run manifest written: \(manifestURL.lastPathComponent)"))
        XCTAssertTrue(RunManifest.verify(manifestAt: manifestURL).passed)
        XCTAssertFalse(names.contains { $0.hasSuffix(".tsr") }, "no authority, no request")
    }

    /// A Generate run with every format: one manifest, named after the workbook, listing the
    /// workbook and the HTML, PDF and CSV formats the run also wrote, all in one folder.
    func testAGenerateOfEveryFormatSealsTheRunOnce() async throws {
        // PDF and CSV refuse a folder under /tmp or /var (`isSensitiveAbsolutePath`).
        let root = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("jrc-manifest-all-\(UUID().uuidString)", isDirectory: true)
        let profile = "manifestall"
        let workspace = root.appendingPathComponent(profile, isDirectory: true)
        let chosen = root.appendingPathComponent("Chosen", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        try "output:\n  timestamp_outputs: true\n".write(
            to: workspace.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
        // The inventory CSV needs a computers snapshot.
        let computers = workspace.appendingPathComponent("jamf-cli-data/computers")
        try FileManager.default.createDirectory(at: computers, withIntermediateDirectories: true)
        try TestFixtures.copyFile(
            TestFixtures.dir("jamf-cli-data/computers-v4/computers-v4.json"),
            to: computers.appendingPathComponent("computers_20261029T090000.json"))
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        defer {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: root)
        }
        let lines = ManifestLines()
        let result = await CLIBridge().generateAll(
            types: [.xlsx, .html, .pdf, .csv], outputDir: chosen, profile: profile,
            onLine: lines.add)
        let names = try FileManager.default.contentsOfDirectory(atPath: chosen.path)
        let manifests = names.filter { $0.hasSuffix(RunManifest.manifestSuffix) }
        XCTAssertEqual(manifests.count, 1, "\(names) \(lines.all)")
        let manifestURL = chosen.appendingPathComponent(try XCTUnwrap(manifests.first))
        let manifest = try JSONDecoder().decode(
            RunManifest.self, from: try Data(contentsOf: manifestURL))
        let listed = manifest.artifacts.map(\.name)
        XCTAssertEqual(listed.first.map { $0.hasSuffix(".xlsx") }, true, "\(listed)")
        XCTAssertEqual(manifestURL.lastPathComponent,
                       listed.first.map { String($0.dropLast(5)) + RunManifest.manifestSuffix })
        let written = Set(result.succeeded)
        for (type, ext) in [(GenerateOutputType.html, ".html"), (.pdf, ".pdf"), (.csv, ".csv")]
        where written.contains(type) {
            XCTAssertEqual(listed.filter { $0.hasSuffix(ext) }.count, 1, "\(ext): \(listed)")
        }
        XCTAssertEqual(written, [.xlsx, .html, .pdf, .csv], "\(lines.all)")
        XCTAssertEqual(lines.all.filter { $0.hasPrefix("[ok] run manifest written") }.count, 1)
        XCTAssertTrue(RunManifest.verify(manifestAt: manifestURL).passed)
    }
}

/// A report file written on its own (the Reports screen's PDF and CSV exports, a lone HTML
/// report) is sealed by itself, and a School Generate run follows the chosen folder.
@MainActor
final class RunManifestStandaloneTests: XCTestCase {
    private nonisolated(unsafe) var root: URL!
    private let profile = "manifestsolo"
    private nonisolated var workspace: URL {
        root.appendingPathComponent(profile, isDirectory: true)
    }

    override func setUpWithError() throws {
        // CSV and PDF refuse a folder under /tmp or /var (`isSensitiveAbsolutePath`).
        root = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("jrc-manifest-solo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        try? FileManager.default.removeItem(at: root)
    }

    private func manifests(in folder: URL) throws -> [RunManifest] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasSuffix(RunManifest.manifestSuffix) }
            .map { try JSONDecoder().decode(
                RunManifest.self, from: Data(contentsOf: folder.appendingPathComponent($0))) }
    }

    func testAnExportedCSVAndALoneHTMLReportAreEachSealed() async throws {
        let computers = workspace.appendingPathComponent("jamf-cli-data/computers")
        try FileManager.default.createDirectory(at: computers, withIntermediateDirectories: true)
        try TestFixtures.copyFile(
            TestFixtures.dir("jamf-cli-data/computers-v4/computers-v4.json"),
            to: computers.appendingPathComponent("computers_20261029T090000.json"))
        let exports = root.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        let bridge = CLIBridge()
        let csv = exports.appendingPathComponent("inventory.csv")
        let csvCode = try await bridge.exportInventoryCSV(
            profile: profile, outFile: csv.path, onLine: CLIBridge.noOpOnLine)
        let page = exports.appendingPathComponent("page.html")
        let htmlCode = try await bridge.generateHTML(
            profile: profile, outFile: page.path, onLine: CLIBridge.noOpOnLine)
        XCTAssertEqual([csvCode, htmlCode], [0, 0])
        let names = Set(try manifests(in: exports).flatMap { $0.artifacts.map(\.name) })
        XCTAssertEqual(names, ["inventory.csv", "page.html"])
    }

    func testASchoolGenerateIntoAChosenFolderSealsThere() async throws {
        try "school_cli:\n  enabled: true\n".write(
            to: workspace.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
        let chosen = root.appendingPathComponent("Chosen", isDirectory: true)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        let lines = ManifestLines()
        let result = await CLIBridge().generateAll(
            types: [.xlsx], outputDir: chosen, profile: profile, schoolMode: true,
            onLine: lines.add)
        XCTAssertEqual(result.succeeded, [.xlsx], "\(lines.all)")
        let names = try FileManager.default.contentsOfDirectory(atPath: chosen.path)
        XCTAssertEqual(names.filter { $0.hasSuffix(".xlsx") }.count, 1, "\(names)")
        XCTAssertEqual(try manifests(in: chosen).count, 1, "\(names)")
    }
}

/// A shared workspace's peer can change `output.timestamp_authority`; this Mac then sends no
/// hash anywhere until its operator confirms the new authority.
final class TimestampAuthorityPinTests: XCTestCase {
    private let profile = "tsapin"
    private var root: URL!
    private var appSupport: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-tsa-pin-\(UUID().uuidString)", isDirectory: true)
        appSupport = root.appendingPathComponent(".app-support", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(profile), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        try? FileManager.default.removeItem(at: root)
    }

    private func config(authority: String) throws -> ReportConfig {
        let yaml = "shared_workspace:\n  enabled: true\n"
            + "output:\n  timestamp_authority: \"\(authority)\"\n"
        let url = root.appendingPathComponent(profile).appendingPathComponent("config.yaml")
        try yaml.write(to: url, atomically: true, encoding: .utf8)
        return try ConfigLoader.load(from: url)
    }

    private var configURL: URL {
        root.appendingPathComponent(profile).appendingPathComponent("config.yaml")
    }

    /// A pinned workspace with `authority` confirmed on this Mac.
    private func confirmed(_ authority: String) throws -> ReportConfig {
        let config = try config(authority: authority)
        try SharedConfigPin.confirm(
            profile: profile,
            drifts: SharedConfigPin.check(profile: profile, appSupport: appSupport).drifts,
            appSupport: appSupport)
        XCTAssertNotNil(ReportEngine.timestampAuthority(
            config, profile: profile, appSupport: appSupport))
        return config
    }

    /// A peer plants an address, the run loads it, then the peer removes config.yaml before the
    /// seal: with nothing to compare, the pinned workspace fails closed and nothing is sent.
    func testASealAfterConfigYamlIsRemovedSendsNothing() async throws {
        _ = try confirmed("https://tsa.example.test/tsr")
        let planted = try config(authority: "https://collector.attacker.test/tsr")
        try FileManager.default.removeItem(at: configURL)
        let workbook = root.appendingPathComponent(profile).appendingPathComponent("r.xlsx")
        try Data("x".utf8).write(to: workbook)
        TSAStub.answer(.reply(200, Data()))
        let manifest = await ReportEngine.sealRun(
            artifacts: [workbook], config: planted, profile: profile,
            now: Date(timeIntervalSince1970: 1_793_264_400), session: TSAStub.session,
            appSupport: appSupport, onLine: nil)
        XCTAssertNotNil(manifest)
        XCTAssertTrue(TSAStub.requests.isEmpty)
    }

    /// Unreadable rather than gone (over the 4 MB config limit): the same.
    func testAnOversizedConfigYamlFailsClosedForTheConfirmedAddressToo() throws {
        let config = try confirmed("https://tsa.example.test/tsr")
        try Data(count: ConfigLoader.maxConfigBytes + 1).write(to: configURL)
        XCTAssertNil(ReportEngine.timestampAuthority(
            config, profile: profile, appSupport: appSupport))
        XCTAssertFalse(SharedConfigPin.timestampAuthorityAllowed(
            "https://tsa.example.test/tsr", profile: profile, appSupport: appSupport))
    }

    /// The other pinned values fail closed by the same rule, in `check`.
    func testEveryPinnedValueFailsClosedWhenConfigYamlCannotBeRead() throws {
        let yaml = "shared_workspace:\n  enabled: true\nnotify:\n  enabled: true\n"
            + "  url: \"https://hooks.example.com/a\"\nprotect:\n  enabled: true\n"
            + "  profile: \"protect-a\"\n  backup_on_synced_storage: true\n"
            + "backup:\n  pro_on_synced_storage: true\n"
        try yaml.write(to: configURL, atomically: true, encoding: .utf8)
        let notify = try ConfigLoader.load(from: configURL).notify
        try SharedConfigPin.confirm(
            profile: profile,
            drifts: SharedConfigPin.check(profile: profile, appSupport: appSupport).drifts,
            appSupport: appSupport)
        XCTAssertNotNil(SharedConfigPin.effectiveNotify(
            notify, profile: profile, appSupport: appSupport))
        XCTAssertTrue(SharedConfigPin.protectAllowed(profile: profile, appSupport: appSupport))

        try FileManager.default.removeItem(at: configURL)
        XCTAssertNil(SharedConfigPin.effectiveNotify(
            notify, profile: profile, appSupport: appSupport))
        XCTAssertFalse(SharedConfigPin.protectAllowed(profile: profile, appSupport: appSupport))
        XCTAssertFalse(SharedConfigPin.protectBackupOnSyncedStorage(
            true, profile: profile, appSupport: appSupport))
        XCTAssertEqual(SharedConfigPin.proBackupSetting(
            true, profile: profile, appSupport: appSupport), .awaitingConfirmation)
        XCTAssertThrowsError(try SharedConfigPin.confirm(
            profile: profile,
            drifts: SharedConfigPin.check(profile: profile, appSupport: appSupport).drifts,
            appSupport: appSupport), "nothing to compare, so nothing is confirmed")

        // A Confirm shown while the file was unreadable must not match the unset keys once it is
        // readable again: the person never saw their values.
        let shownWhileUnreadable = SharedConfigPin.check(profile: profile, appSupport: appSupport)
            .drifts
        try "shared_workspace:\n  enabled: true\n".write(
            to: configURL, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try SharedConfigPin.confirm(
            profile: profile, drifts: shownWhileUnreadable, appSupport: appSupport),
            "blank keys such as protect.profile must not match the unreadable rows")
    }

    /// A workspace that is neither shared nor pinned keeps its address with no config.yaml read.
    func testALocalWorkspaceIsNotHeldBack() throws {
        XCTAssertTrue(SharedConfigPin.timestampAuthorityAllowed(
            "https://tsa.example.test/tsr", profile: profile, appSupport: appSupport))
    }

    /// An address in the shared file, even at this Mac's first sight of it, is used only once
    /// confirmed here.
    func testAnAuthorityIsUnsetUntilConfirmedEvenAtFirstSight() throws {
        let first = try config(authority: "https://tsa.example.test/tsr")
        XCTAssertNil(ReportEngine.timestampAuthority(first, profile: profile,
                                                     appSupport: appSupport))
        var drift = try XCTUnwrap(SharedConfigPin.check(profile: profile, appSupport: appSupport)
            .drifts.first { $0.key == .timestampAuthority })
        try SharedConfigPin.confirm(profile: profile, drifts: [drift], appSupport: appSupport)
        XCTAssertEqual(ReportEngine.timestampAuthority(first, profile: profile,
                                                       appSupport: appSupport),
                       URL(string: "https://tsa.example.test/tsr"))

        let changed = try config(authority: "https://collector.attacker.test/tsr?k=1")
        XCTAssertNil(ReportEngine.timestampAuthority(changed, profile: profile,
                                                     appSupport: appSupport))
        drift = try XCTUnwrap(SharedConfigPin.check(profile: profile, appSupport: appSupport)
            .drifts.first { $0.key == .timestampAuthority })
        XCTAssertTrue(drift.current.hasPrefix("collector.attacker.test (URL fingerprint "))
        XCTAssertFalse(drift.current.contains("k=1"), "the URL itself is never shown")

        try SharedConfigPin.confirm(profile: profile, drifts: [drift], appSupport: appSupport)
        XCTAssertEqual(ReportEngine.timestampAuthority(changed, profile: profile,
                                                       appSupport: appSupport),
                       URL(string: "https://collector.attacker.test/tsr?k=1"))
        // A run that loaded the earlier address does not send there now.
        XCTAssertNil(ReportEngine.timestampAuthority(first, profile: profile,
                                                     appSupport: appSupport))
    }

    /// A shared workspace whose authority was never confirmed here sends nothing.
    func testASealOnAnUnconfirmedAuthoritySendsNothing() async throws {
        let config = try config(authority: "https://\(TSAStub.host)/tsr")
        let reports = root.appendingPathComponent(profile).appendingPathComponent("Reports")
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        let workbook = reports.appendingPathComponent("report_a.xlsx")
        try Data("x".utf8).write(to: workbook)
        TSAStub.answer(.reply(200, Data()))
        let manifest = await ReportEngine.sealRun(
            artifacts: [workbook], config: config, profile: profile,
            now: Date(timeIntervalSince1970: 1_793_264_400), session: TSAStub.session,
            appSupport: appSupport, onLine: nil)
        XCTAssertNotNil(manifest)
        XCTAssertTrue(TSAStub.requests.isEmpty)
    }
}

/// `output.timestamp_authority` can carry a token, as `notify.url` does: every place that shows,
/// copies or bundles config.yaml or a log treats it the same way.
final class TimestampAuthorityRedactionTests: XCTestCase {
    private let address = "https://tsa.example.test/tsr?token=tsa-secret-4417"

    func testTheFromFileTabShowsOnlyThatItIsSet() {
        let value = YAMLCodec.YAMLValue.scalar(.string(address))
        XCTAssertEqual(ConfigFileSections.displayValue(
            value, keyPath: "output.timestamp_authority"), "(set)")
    }

    func testAConfigBackupHoldsNeitherTheTokenNorTheAddress() throws {
        let yaml = "output:\n  csv_folder: true\n  timestamp_authority: \"\(address)\"\n"
            + "# old: \(address)\n"
        let copy = String(decoding: ConfigService.scrubbedForBackup(Data(yaml.utf8)), as: UTF8.self)
        XCTAssertFalse(copy.contains("tsa-secret-4417"), copy)
        XCTAssertTrue(copy.contains("  timestamp_authority: \"\""), copy)
        XCTAssertTrue(copy.contains(
            "# output.timestamp_authority removed from this copy "
                + "(was https://tsa.example.test/…)"))
        XCTAssertTrue(copy.contains("  csv_folder: true"))
    }

    func testABundledConfigOrLogHoldsNoAuthorityAddress() {
        let text = DiagnosticRedactor().redactText("timestamp_authority: \"\(address)\"")
        XCTAssertFalse(text.contains("tsa-secret-4417"), text)
        XCTAssertFalse(text.contains("tsa.example.test"), text)
    }

    /// The configured host joins the hosts a shared log or bundle masks.
    func testTheAuthorityHostIsMaskedInSharedText() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-tsa-redact-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("tsaredact", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try "output:\n  timestamp_authority: \"https://tsa.example.test:8443/tsr\"\n".write(
            to: workspace.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        defer {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: root)
        }
        let none = root.appendingPathComponent("no-jamf-cli-config.yaml")
        XCTAssertEqual(DiagnosticBundleService.serverHosts(profile: "tsaredact", configURL: none),
                       ["tsa.example.test:8443", "tsa.example.test"])
        let shared = LogRedactor.redactedForSharing(
            "[warn] report timestamp not saved: sending the request to tsa.example.test: "
                + "the authority answered HTTP 500",
            profile: "tsaredact", scopeIDs: { _ in [] },
            serverHosts: { DiagnosticBundleService.serverHosts(profile: $0, configURL: none) })
        XCTAssertFalse(shared.contains("tsa.example.test"), shared)
    }

    func testConfigDoctorNamesAnAuthorityThatIsNotText() throws {
        let yaml = "output:\n  timestamp_authority: 5\n"
        let rows = ConfigDoctorService.valueRows(
            try ConfigLoader.loadFromString(yaml), raw: try ConfigLoader.rawMapping(fromYAML: yaml),
            profile: "p")
        let row = try XCTUnwrap(rows.first { $0.title == "output.timestamp_authority" })
        XCTAssertTrue(row.detail.contains("is not text"), row.detail)
    }
}
