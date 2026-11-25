import XCTest
@testable import JamfReports

/// Signatures behind, agent behind and disconnected over a day: the one calculator and the
/// loader that reads its baselines (wave E). Row values are synthetic in jamf-cli's shapes.
final class ProtectAgentHealthTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_795_000_000)
    private func hoursAgo(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3_600) }

    private func rows(_ json: String) throws -> [ProtectComputerRow] {
        try JSONDecoder().decode([ProtectComputerRow].self, from: Data(json.utf8))
    }

    private func published(_ pairs: [(Int, Double)]) -> ProtectAgentHealth.Input<
        [ProtectAgentHealth.PublishedSignature]
    > {
        .value(pairs.map { .init(id: $0.0, created: hoursAgo($0.1)) })
    }

    private func installer(_ version: String, hours: Double) -> ProtectAgentHealth.Input<
        ProtectAgentHealth.InstallerBaseline
    > {
        .value(.init(version: version, firstSeen: hoursAgo(hours)))
    }

    private func evaluate(
        _ computers: [ProtectComputerRow],
        published: ProtectAgentHealth.Input<[ProtectAgentHealth.PublishedSignature]> =
            .unavailable(.notCollected(kind: "x")),
        installer: ProtectAgentHealth.Input<ProtectAgentHealth.InstallerBaseline> =
            .unavailable(.notCollected(kind: "x"))
    ) -> ProtectAgentHealth {
        ProtectAgentHealth.evaluate(
            computers: computers, published: published, installer: installer, now: now)
    }

    // MARK: - Signatures

    func testAWholeFleetOneReleaseBehindIsAllBehind() throws {
        let computers = try rows(#"[{"signaturesVersion":100},{"signaturesVersion":100}]"#)
        let health = evaluate(computers, published: published([(101, 30), (100, 72)]))
        XCTAssertEqual(health.signaturesBehind.share, .init(met: 2, of: 2))
        XCTAssertEqual(health.signaturesBehind.baseline,
                       .published(id: 101, created: hoursAgo(30)))
    }

    func testAReleaseUnderADayOldIsNotTheBaseline() throws {
        let computers = try rows(
            #"[{"signaturesVersion":100},{"signaturesVersion":99},{"signaturesVersion":101}]"#)
        let health = evaluate(computers, published: published([(101, 3), (100, 48)]))
        XCTAssertEqual(health.signaturesBehind.share, .init(met: 1, of: 3))
        XCTAssertEqual(health.macs.map(\.signaturesBehind), [.no, .yes, .no])
    }

    func testNoUsableListIsNotEvaluatedNeverZero() throws {
        let computers = try rows(#"[{"signaturesVersion":100}]"#)
        XCTAssertEqual(evaluate(computers).signaturesBehind,
                       .unavailable(.notCollected(kind: "x")))
        XCTAssertEqual(evaluate(computers, published: published([(101, 2)])).signaturesBehind,
                       .unavailable(.noVersionOldEnough))
        XCTAssertEqual(evaluate(computers, published: .value([])).signaturesBehind,
                       .unavailable(.noPublishedVersions))
        XCTAssertEqual(evaluate(computers).macs.map(\.signaturesBehind), [.notEvaluated])
    }

    func testAMacBelowTheOldestListedIsBehindAndAFractionOrMissingIsLeftOut() throws {
        let computers = try rows(
            #"[{"signaturesVersion":50},{"signaturesVersion":1.5},{"hostname":"none"}]"#)
        let health = evaluate(computers, published: published([(101, 30), (100, 72)]))
        XCTAssertEqual(health.signaturesBehind.share, .init(met: 1, of: 1))
    }

    // MARK: - Agent

    func testAgentBehindOnlyOnceTheInstallerIsADayOld() throws {
        let computers = try rows(
            #"[{"version":"5.0.9.1"},{"version":"5.1.0.7"},{"version":"5.2"},{"version":""},"#
                + #"{"version":"5.x"},{"hostname":"none"}]"#)
        XCTAssertEqual(evaluate(computers, installer: installer("5.1.0.7", hours: 2)).agentBehind,
                       .unavailable(.installerTooNew(version: "5.1.0.7", firstSeen: hoursAgo(2))))
        let health = evaluate(computers, installer: installer("5.1.0.7", hours: 30))
        XCTAssertEqual(health.agentBehind.share, .init(met: 1, of: 3),
                       "an empty or unparseable version is left out; newer is not behind")
        XCTAssertEqual(health.macs.map(\.agentBehind),
                       [.yes, .no, .no, .notEvaluated, .notEvaluated, .notEvaluated])
    }

    func testAnInstallerVersionThatIsNoVersionIsNotEvaluated() throws {
        let computers = try rows(#"[{"version":"1.0"}]"#)
        XCTAssertEqual(evaluate(computers, installer: installer("", hours: 30)).agentBehind,
                       .unavailable(.installerNotAVersion("")))
        XCTAssertNil(ProtectAgentHealth.dottedVersion("abc 5"))
        XCTAssertNil(ProtectAgentHealth.dottedVersion("5..1"))
        XCTAssertEqual(ProtectAgentHealth.dottedVersion("5.1.0.7"), [5, 1, 0, 7])
        XCTAssertFalse(ProtectAgentHealth.isLower([4, 6], than: [4, 6, 0]))
    }

    // MARK: - Disconnected

    func testDisconnectedOverADayCountsAndReasonsAreOverThoseMacs() throws {
        let recent = ISO8601Time.string(hoursAgo(2)), old = ISO8601Time.string(hoursAgo(30))
        let computers = try rows("""
        [{"connectionStatus":"Disconnected","lastDisconnection":"\(recent)",
          "lastDisconnectionReason":"A"},
         {"connectionStatus":"Disconnected","lastDisconnection":"\(old)",
          "lastDisconnectionReason":"B"},
         {"connectionStatus":"Disconnected"},
         {"connectionStatus":"online"},
         {"hostname":"no status"}]
        """)
        let health = evaluate(computers)
        XCTAssertEqual(health.disconnected.share, .init(met: 1, of: 4))
        XCTAssertEqual(health.disconnectedTimeUnknown, 1)
        XCTAssertEqual(health.disconnectedReasons, [.init(reason: "B", count: 1)])
        XCTAssertEqual(health.macs.map(\.disconnected), [.no, .yes, .no, .no, .notEvaluated])
        XCTAssertEqual(health.macs.count, computers.count)
    }

    // MARK: - Loader

    private func dataDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-health-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// A snapshot named with the app's own stamp, `<kind>_yyyyMMdd'T'HHmmss.json`.
    @discardableResult
    private func write(_ text: String, kind: String, at date: Date?, in dir: URL) throws -> URL {
        let folder = dir.appendingPathComponent(kind, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name: String
        if let date {
            let format = DateFormatter()
            format.locale = Locale(identifier: "en_US_POSIX")
            format.dateFormat = "yyyyMMdd'T'HHmmss"
            name = "\(kind)_\(format.string(from: date)).json"
        } else {
            name = "\(kind)_\(UUID().uuidString).json"
        }
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    func testTheLoaderMeasuresAgainstTheComputersFileTime() throws {
        let dir = try dataDir()
        let computersFile = try write("[]", kind: "protect-computers", at: now, in: dir)
        XCTAssertEqual(CloudStorage.snapshotTimestamp(of: computersFile)?.timeIntervalSince1970
                       .rounded(), now.timeIntervalSince1970.rounded())
        try write(#"[{"id":"101","created":"\#(ISO8601Time.string(hoursAgo(30)))"},"#
                  + #"{"id":100,"created":"\#(ISO8601Time.string(hoursAgo(72)))"}]"#,
                  kind: ReportEngine.protectSignatureVersionsKind, at: hoursAgo(1), in: dir)
        try write(#"[{"installerVersion":"5.0"}]"#, kind: ReportEngine.protectInstallerKind,
                  at: hoursAgo(100), in: dir)
        try write(#"[{"installerVersion":"5.1"}]"#, kind: ReportEngine.protectInstallerKind,
                  at: hoursAgo(50), in: dir)
        try write(#"[{"installerVersion":"5.1"}]"#, kind: ReportEngine.protectInstallerKind,
                  at: hoursAgo(1), in: dir)
        let computers = try rows(#"[{"signaturesVersion":100,"version":"5.0"}]"#)
        let result = try XCTUnwrap(ProtectAgentHealthLoader.load(
            dataDir: dir, computers: computers, computersFile: computersFile))
        XCTAssertEqual(result.health.signaturesBehind.share, .init(met: 1, of: 1))
        XCTAssertEqual(result.health.agentBehind.share, .init(met: 1, of: 1))
        guard case .installer(_, let firstSeen) = result.health.agentBehind.baseline else {
            return XCTFail("installer baseline")
        }
        XCTAssertEqual(firstSeen.timeIntervalSince1970.rounded(),
                       hoursAgo(50).timeIntervalSince1970.rounded(),
                       "first seen is the oldest snapshot holding the current version")
        XCTAssertEqual(result.unreadableKinds, [])
    }

    func testAComputersFileWithNoStampEvaluatesNothing() throws {
        let dir = try dataDir()
        let file = try write("[]", kind: "protect-computers", at: nil, in: dir)
        let result = try XCTUnwrap(ProtectAgentHealthLoader.load(
            dataDir: dir, computers: try rows(#"[{"connectionStatus":"Connected"}]"#),
            computersFile: file))
        XCTAssertEqual(result.health.disconnected, .unavailable(.noCollectionTime))
        XCTAssertNil(
            ProtectAgentHealthLoader.load(dataDir: dir, computers: [], computersFile: file))
    }

    func testUnreadableNotCollectedAndEmptyAreToldApart() throws {
        let dir = try dataDir()
        var unreadable: [String] = []
        XCTAssertEqual(
            ProtectAgentHealthLoader.loadPublished(dataDir: dir, unreadable: &unreadable),
                       .unavailable(.notCollected(kind: ReportEngine.protectSignatureVersionsKind)))
        try write("{not json", kind: ReportEngine.protectSignatureVersionsKind, at: now, in: dir)
        XCTAssertEqual(
            ProtectAgentHealthLoader.loadPublished(dataDir: dir, unreadable: &unreadable),
                       .unavailable(.unreadable(kind: ReportEngine.protectSignatureVersionsKind)))
        XCTAssertEqual(unreadable, [ReportEngine.protectSignatureVersionsKind])
        try write("[]", kind: ReportEngine.protectInstallerKind, at: now, in: dir)
        XCTAssertEqual(
            ProtectAgentHealthLoader.loadInstaller(dataDir: dir, now: now, unreadable: &unreadable),
            .unavailable(.noInstallerVersion))
    }

    func testFirstSeenClampsAFutureStampAndSkipsUnstampedFiles() throws {
        let dir = try dataDir()
        let folder = dir.appendingPathComponent(ReportEngine.protectInstallerKind)
        try write(#"[{"installerVersion":"5.1"}]"#, kind: ReportEngine.protectInstallerKind,
                  at: nil, in: dir)
        try write(#"[{"installerVersion":"5.1"}]"#, kind: ReportEngine.protectInstallerKind,
                  at: now.addingTimeInterval(7_200), in: dir)
        XCTAssertEqual(ProtectAgentHealthLoader.firstSeen([5, 1], in: folder, now: now), now,
                       "a stamp from the future reads as now, so it never starts the grace early")
    }

    func testFirstSeenSkipsAnUnreadableFileAndMatchesEqualVersions() throws {
        let dir = try dataDir()
        let folder = dir.appendingPathComponent(ReportEngine.protectInstallerKind)
        try write("{broken", kind: ReportEngine.protectInstallerKind, at: hoursAgo(90), in: dir)
        try write(#"[{"installerVersion":"5.1.0"}]"#, kind: ReportEngine.protectInstallerKind,
                  at: hoursAgo(60), in: dir)
        XCTAssertEqual(
            ProtectAgentHealthLoader.firstSeen([5, 1], in: folder, now: now)?
                .timeIntervalSince1970.rounded(),
            hoursAgo(60).timeIntervalSince1970.rounded(), "5.1.0 is the same version as 5.1")
    }

    /// Past the cap no date is guessed: a date older than the truth would start the grace early.
    func testFirstSeenPastTheCapWithNoMatchIsUnknown() throws {
        let dir = try dataDir()
        let folder = dir.appendingPathComponent(ReportEngine.protectInstallerKind)
        for index in 0...ProtectAgentHealth.maxInstallerFiles {
            try write(#"[{"installerVersion":"4.0"}]"#, kind: ReportEngine.protectInstallerKind,
                      at: hoursAgo(Double(1_000 - index)), in: dir)
        }
        XCTAssertNil(ProtectAgentHealthLoader.firstSeen([5, 1], in: folder, now: now))
        try write(#"[{"installerVersion":"5.1"}]"#, kind: ReportEngine.protectInstallerKind,
                  at: hoursAgo(1), in: dir)
        XCTAssertNotNil(ProtectAgentHealthLoader.firstSeen([5, 1], in: folder, now: now),
                        "the newest files are the ones read")
    }

    func testPublishedIDsDecodeAsDigitTextOrWholeNumbers() {
        let created = ISO8601Time.string(now)
        let data = Data("""
        [{"id":"7","created":"\(created)"},{"id":8,"created":"\(created)"},
         {"id":8.5,"created":"\(created)"},{"id":"x9","created":"\(created)"},
         {"id":true,"created":"\(created)"},{"id":"10"}]
        """.utf8)
        XCTAssertEqual(ProtectAgentHealthLoader.decodePublished(data)?.map(\.id), [7, 8])
        XCTAssertEqual(ProtectAgentHealthLoader.decodePublished(
            Data(#"[{"id":"1","created":"2026-11-20T10:00:00.123456789Z"}]"#.utf8))?.count, 1,
            "jamf-cli's 27-character timestamps parse")
        XCTAssertNil(ProtectAgentHealthLoader.decodePublished(Data("{}".utf8)))
    }

    // MARK: - Wiring

    func testTheDashboardServiceCarriesAgentHealthAndTheNewSourceDates() throws {
        let dir = try dataDir()
        try write(#"[{"connectionStatus":"Connected","signaturesVersion":100}]"#,
                  kind: "protect-computers", at: now, in: dir)
        try write(#"[{"installerVersion":"5.1"}]"#, kind: ReportEngine.protectInstallerKind,
                  at: hoursAgo(1), in: dir)
        let snapshot = ProtectDashboardService.load(dataDir: dir)
        let health = try XCTUnwrap(snapshot.agentHealth)
        XCTAssertEqual(health.disconnected.share, .init(met: 0, of: 1))
        XCTAssertNotNil(snapshot.sourceDates[ReportEngine.protectInstallerKind])
        XCTAssertEqual(snapshot.unreadableKinds, [])
        try write("{broken", kind: ReportEngine.protectSignatureVersionsKind, at: now, in: dir)
        let broken = ProtectDashboardService.load(dataDir: dir)
        XCTAssertEqual(broken.unreadableKinds, [ReportEngine.protectSignatureVersionsKind])
        XCTAssertNotNil(broken.sourceDates[ReportEngine.protectSignatureVersionsKind])
        var other = snapshot
        other.agentHealth = nil
        XCTAssertNotEqual(snapshot, other, "== sees agent health")
    }

    func testTheDemoShowsEveryFinding() throws {
        let health = try XCTUnwrap(DemoData.protectSnapshot.agentHealth)
        XCTAssertEqual(health.macs.count, DemoData.protectSnapshot.computers.count)
        XCTAssertEqual(health.signaturesBehind.share, .init(met: 3, of: 11))
        XCTAssertEqual(health.agentBehind.share, .init(met: 3, of: 11))
        XCTAssertEqual(health.disconnected.share, .init(met: 1, of: 12))
    }
}
