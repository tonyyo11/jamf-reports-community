import XCTest
@testable import JamfReports

/// Attention items (2.11): kept in status files, coalesced per code, cleared by the check that
/// passes, and never written into a workspace a run refused.
final class AttentionLogTests: XCTestCase {
    nonisolated(unsafe) private var root: URL!
    private let profile = "attn"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("attention-\(UUID().uuidString)", isDirectory: true)
        let workspaces = root.appendingPathComponent("Jamf-Reports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspaces.appendingPathComponent(profile).appendingPathComponent("automation"),
            withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", workspaces.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        try? FileManager.default.removeItem(at: root)
    }

    private func automation() throws -> URL {
        try XCTUnwrap(ProfileService.workspaceURL(for: profile))
            .appendingPathComponent("automation", isDirectory: true)
    }

    private func at(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_790_000_000 + seconds)
    }

    /// One run: `body` inside a log for `profile`, committed at `now`.
    private func run(
        into status: String? = nil, usesAppRecord: Bool = true, now: Date,
        _ body: () -> Void
    ) throws {
        let log = AttentionLog(profile: profile, usesAppRecord: usesAppRecord)
        if let status {
            log.record(into: try automation().appendingPathComponent("\(status)_status.json"),
                       runLog: "\(status).20261020-090000.log")
        }
        AttentionLog.$current.withValue(log) { body() }
        log.commit(now: now)
    }

    private func item(_ code: AttentionCode, profile: String? = nil, seen: Date) -> AttentionItem {
        AttentionItem(code: code, message: code.rawValue, firstSeen: seen, lastSeen: seen,
                      count: 1, profile: profile ?? self.profile, runLog: nil)
    }

    // MARK: - Merging

    func testARepeatCountsUpAndKeepsTheFirstSighting() {
        let first = AttentionItem.merging(
            [], [.schoolZeroDevices: .raised("a")], profile: profile, runLog: "1.log", now: at(0))
        let again = AttentionItem.merging(
            first, [.schoolZeroDevices: .raised("b")], profile: profile, runLog: "2.log",
            now: at(3600))
        XCTAssertEqual(again.count, 1)
        XCTAssertEqual(again[0].count, 2)
        XCTAssertEqual(again[0].firstSeen, at(0))
        XCTAssertEqual(again[0].lastSeen, at(3600))
        XCTAssertEqual(again[0].message, "b")
        XCTAssertEqual(again[0].runLog, "2.log")
    }

    func testACountAtTheTopStopsThereInsteadOfOverflowing() {
        var top = item(.schoolZeroDevices, seen: at(0))
        top.count = Int.max
        let merged = AttentionItem.merging(
            [top], [.schoolZeroDevices: .raised("a")], profile: profile, runLog: nil, now: at(1))
        XCTAssertEqual(merged[0].count, AttentionItem.maxCount)
    }

    func testAPlantedCountIsClampedWhenReadAndARepeatAfterItDoesNotCrash() throws {
        let planted = #"{"code":"eaSnapshotUnreadable","message":"x","count":9223372036854775807,"#
            + #""profile":"attn","first_seen":"2026-10-20T08:00:00Z","#
            + #""last_seen":"2026-10-20T09:00:00Z"}"#
        let negative = #"{"code":"schoolZeroDevices","message":"x","count":-5,"profile":"attn","#
            + #""first_seen":"2026-10-20T08:00:00Z","last_seen":"2026-10-20T09:00:00Z"}"#
        try Data(#"{"label":"peer","attention_at":1e15,"attention":[\#(planted),\#(negative)]}"#
            .utf8).write(to: try automation().appendingPathComponent("peer_status.json"))
        XCTAssertTrue(AttentionLog.openItems(profile: profile).isEmpty,
                      "a record stamped past the year 3000 is not read")

        try Data((#"{"label":"peer","attention_at":1790000000,"#
            + #""attention":[\#(planted),\#(negative)]}"#).utf8).write(to: try automation().appendingPathComponent("peer_status.json"))
        XCTAssertEqual(AttentionLog.openItems(profile: profile).map(\.count),
                       [AttentionItem.maxCount, 1])
        try run(into: "mine", now: at(60)) {
            AttentionLog.raise(.eaSnapshotUnreadable, "again")
        }
        let item = AttentionLog.openItems(profile: profile)
            .first { $0.code == .eaSnapshotUnreadable }
        XCTAssertEqual(item?.count, AttentionItem.maxCount)
        XCTAssertEqual(item?.message, "again")
    }

    func testAClearRemovesOnlyThatCodeOfThatProfile() {
        let open = [item(.schoolZeroDevices, seen: at(0)), item(.webhookRejected, seen: at(0)),
                    item(.schoolZeroDevices, profile: "other", seen: at(0))]
        let merged = AttentionItem.merging(
            open, [.schoolZeroDevices: .cleared], profile: profile, runLog: nil, now: at(1))
        XCTAssertEqual(merged.map(\.code), [.webhookRejected, .schoolZeroDevices])
        XCTAssertEqual(merged.last?.profile, "other")
    }

    func testAMessageCarriesNoURL() {
        let text = "webhook rejected (HTTP 404) posting to "
            + "https://hooks.example.test/incoming/abc?sig=s3cr3t"
        let clean = AttentionItem.sanitized(text, profile: profile)
        XCTAssertTrue(clean.contains("HTTP 404"), clean)
        XCTAssertFalse(clean.contains("://"), clean)
        XCTAssertFalse(clean.contains("hooks.example.test"), clean)
        XCTAssertFalse(clean.contains("s3cr3t"), clean)
    }

    // MARK: - Persistence

    func testARunsItemsLandInItsStatusFileCoalesceAndALaterPassingCheckClearsThem() throws {
        try run(into: "a", now: at(0)) { AttentionLog.raise(.schoolZeroDevices, "0 devices") }
        var open = AttentionLog.openItems(profile: profile)
        XCTAssertEqual(open.map(\.code), [.schoolZeroDevices])
        XCTAssertEqual(open.first?.runLog, "a.20261020-090000.log")
        let file = try automation().appendingPathComponent("a_status.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        try run(into: "b", now: at(3600)) { AttentionLog.raise(.schoolZeroDevices, "0 devices") }
        open = AttentionLog.openItems(profile: profile)
        XCTAssertEqual(open.count, 1, "an hourly repeat is one item")
        XCTAssertEqual(open.first?.count, 2)
        XCTAssertEqual(open.first?.firstSeen, at(0))
        XCTAssertEqual(open.first?.lastSeen, at(3600))

        // A GUI collect, which writes the app record, lands devices.
        try run(now: at(7200)) { AttentionLog.clear(.schoolZeroDevices) }
        XCTAssertTrue(AttentionLog.openItems(profile: profile).isEmpty)
    }

    func testAPeerWithAClockAheadCannotHideThisMacsLaterCommits() throws {
        // A peer stamped its set an hour ahead of this Mac's clock.
        let peer = #"{"code":"schoolZeroDevices","message":"0","count":1,"profile":"attn","#
            + #""first_seen":"2026-10-20T08:00:00Z","last_seen":"2026-10-20T08:00:00Z"}"#
        try Data((#"{"label":"peer","attention_at":\#(at(3600).timeIntervalSince1970),"#
            + #""attention":[\#(peer)]}"#).utf8)
            .write(to: try automation().appendingPathComponent("peer_status.json"))

        try run(into: "a", now: at(0)) { AttentionLog.raise(.webhookRejected, "HTTP 404") }
        XCTAssertEqual(Set(AttentionLog.openItems(profile: profile).map(\.code)),
                       [.schoolZeroDevices, .webhookRejected], "the raise is not lost")
        try run(into: "b", now: at(60)) { AttentionLog.clear(.webhookRejected) }
        XCTAssertEqual(AttentionLog.openItems(profile: profile).map(\.code), [.schoolZeroDevices],
                       "nor is the clear")
    }

    func testARunThatCheckedNothingChangesNothing() throws {
        try run(into: "a", now: at(0)) { AttentionLog.raise(.webhookRejected, "HTTP 404") }
        try run(into: "b", now: at(60)) {}
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: try automation().appendingPathComponent("b_status.json").path))
        XCTAssertEqual(AttentionLog.openItems(profile: profile).map(\.code), [.webhookRejected])
    }

    func testAScheduledRunRefusedBeforeItsRecorderWritesNothing() throws {
        try run(usesAppRecord: false, now: at(0)) {
            AttentionLog.raise(.webhookRejected, "HTTP 404")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            atPath: try automation().path), [])
    }

    func testNoAutomationFolderIsCreated() throws {
        try FileManager.default.removeItem(at: try automation())
        try run(now: at(0)) { AttentionLog.raise(.webhookRejected, "HTTP 404") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: try automation().path))
    }

    func testStatusFilesWithoutAttentionOrWithAnUnknownCodeReadLeniently() throws {
        let folder = try automation()
        try Data(#"{"label":"old","finished_at":"2026-10-20T09:00:00Z","success":true}"#.utf8)
            .write(to: folder.appendingPathComponent("old_status.json"))
        XCTAssertTrue(AttentionLog.openItems(profile: profile).isEmpty)

        let known = #"{"code":"webhookRejected","message":"HTTP 404","count":3,"profile":"attn","#
            + #""first_seen":"2026-10-20T08:00:00Z","last_seen":"2026-10-20T09:00:00Z"}"#
        let unknown = #"{"code":"fromANewerBuild","message":"x","count":1,"profile":"attn","#
            + #""first_seen":"2026-10-20T08:00:00Z","last_seen":"2026-10-20T09:00:00Z"}"#
        try Data(#"{"label":"new","attention_at":1790000000,"attention":[\#(unknown),\#(known)]}"#
            .utf8).write(to: folder.appendingPathComponent("new_status.json"))
        let open = AttentionLog.openItems(profile: profile)
        XCTAssertEqual(open.map(\.code), [.webhookRejected])
        XCTAssertEqual(open.first?.count, 3)
        XCTAssertNil(open.first?.runLog)
    }

    func testTheRecorderKeepsTheOpenItemsWhenItRewritesItsStatusFile() throws {
        let workspace = try XCTUnwrap(ProfileService.workspaceURL(for: profile))
        let recorder = try XCTUnwrap(
            ScheduledRunRecorder(workspace: workspace, label: WorkspaceStore.appCollectRunLabel))
        try run(now: at(0)) { AttentionLog.raise(.lostModeStripFailed, "not saved") }
        recorder.finish(exitCode: 0)
        XCTAssertEqual(AttentionLog.openItems(profile: profile).map(\.code), [.lostModeStripFailed])
        let json = try JSONSerialization.jsonObject(
            with: Data(contentsOf: recorder.statusURL)) as? [String: Any]
        XCTAssertEqual(json?["exit_code"] as? Int, 0)
    }

    func testRecordingJoinsARunOfTheSameProfileOnly() async {
        let outer = AttentionLog(profile: profile, usesAppRecord: false)
        await AttentionLog.$current.withValue(outer) {
            await AttentionLog.recording(profile: profile) {
                AttentionLog.raise(.webhookRejected, "HTTP 404")
            }
            await AttentionLog.recording(profile: "other") {
                AttentionLog.raise(.schoolZeroDevices, "0 devices")
            }
        }
        XCTAssertEqual(Array(outer.changes.keys), [.webhookRejected])
    }

    // MARK: - Webhook

    private func writeNotify(heartbeat: Bool) throws {
        let config = try XCTUnwrap(ProfileService.workspaceURL(for: profile))
            .appendingPathComponent("config.yaml")
        try ("notify:\n  enabled: true\n  provider: teams\n  url: \"\(WebhookCapture.webhookURL)\"\n"
            + (heartbeat ? "  heartbeat: true\n" : ""))
            .write(to: config, atomically: true, encoding: .utf8)
    }

    func testARejectedHeartbeatNeedsAttentionWithItsStatusAndTheNextSendClearsIt() async throws {
        WebhookCapture.start()
        defer { WebhookCapture.stop(); WebhookCapture.respond(with: 200) }
        try writeNotify(heartbeat: true)
        let beats = root.appendingPathComponent("beats")
        WebhookCapture.respond(with: 404)
        await ScheduledRunSignals.notifyHeartbeats(profiles: [profile], stateRoot: beats)
        let open = AttentionLog.openItems(profile: profile)
        XCTAssertEqual(open.map(\.code), [.webhookRejected])
        let message = try XCTUnwrap(open.first?.message)
        XCTAssertTrue(message.contains("HTTP 404"), message)
        XCTAssertFalse(message.contains(WebhookCapture.captureHost), message)

        WebhookCapture.respond(with: 200)
        await ScheduledRunSignals.notifyHeartbeats(profiles: [profile], stateRoot: beats)
        XCTAssertTrue(AttentionLog.openItems(profile: profile).isEmpty)
    }

    func testARejectedFailureCardIsTheRunsAndARefusedRunKeepsNone() async throws {
        WebhookCapture.start()
        defer { WebhookCapture.stop(); WebhookCapture.respond(with: 200) }
        try writeNotify(heartbeat: false)
        let config = try ConfigLoader.load(from: try XCTUnwrap(
            ProfileService.workspaceURL(for: profile)).appendingPathComponent("config.yaml"))
        WebhookCapture.respond(with: 403)
        func card(_ key: String) async {
            await ScheduledRunSignals.notifyScheduledRunFailure(
                config: config, profile: profile, mode: .snapshotOnly,
                errorDescription: "collect failed", recorder: nil, scheduleKey: key,
                stateRoot: root.appendingPathComponent("cards"))
        }
        // Refused: no recorder, so nothing is written.
        await AttentionLog.recording(profile: profile, usesAppRecord: false) { await card("r") }
        XCTAssertTrue(AttentionLog.openItems(profile: profile).isEmpty)

        let status = try automation().appendingPathComponent("run_status.json")
        await AttentionLog.recording(profile: profile, usesAppRecord: false) {
            AttentionLog.current?.record(into: status, runLog: "run.log")
            await card("s")
        }
        let open = AttentionLog.openItems(profile: profile)
        XCTAssertEqual(open.map(\.code), [.webhookRejected])
        XCTAssertTrue(open.first?.message.contains("HTTP 403") == true)
        XCTAssertEqual(open.first?.runLog, "run.log")
    }

    func testARejectedRunDigestNeedsAttentionWithItsStatus() async throws {
        WebhookCapture.start()
        defer { WebhookCapture.stop(); WebhookCapture.respond(with: 200) }
        let status = try automation().appendingPathComponent("run_status.json")
        WebhookCapture.respond(with: 410)
        let workspace = try XCTUnwrap(ProfileService.workspaceURL(for: profile))
        try ("notify:\n  enabled: true\n  provider: teams\n  url: \"\(WebhookCapture.webhookURL)\"\n")
            .write(to: workspace.appendingPathComponent("config.yaml"),
                   atomically: true, encoding: .utf8)
        let config = try ConfigLoader.load(from: workspace.appendingPathComponent("config.yaml"))
        await AttentionLog.recording(profile: profile, usesAppRecord: false) {
            AttentionLog.current?.record(into: status, runLog: "run.log")
            await ScheduledRunSignals.notifyScheduledRun(
                config: config, profile: profile, mode: .snapshotOnly, artifact: nil,
                recorder: nil)
        }
        let open = AttentionLog.openItems(profile: profile)
        XCTAssertEqual(open.map(\.code), [.webhookRejected])
        XCTAssertTrue(open.first?.message.contains("HTTP 410") == true, "\(open)")
    }

    func testARejectedAlertCardNeedsAttentionAndAnAcceptedOneClearsIt() async throws {
        WebhookCapture.start()
        defer { WebhookCapture.stop(); WebhookCapture.respond(with: 200) }
        let status = try automation().appendingPathComponent("run_status.json")
        let workspace = try XCTUnwrap(ProfileService.workspaceURL(for: profile))
        try ("notify:\n  enabled: true\n  provider: teams\n  url: \"\(WebhookCapture.webhookURL)\"\n"
            + "alerts:\n  enabled: true\n  rules:\n"
            + "    - {metric: \"total_devices\", when: \"above\", threshold: 0}\n")
            .write(to: workspace.appendingPathComponent("config.yaml"),
                   atomically: true, encoding: .utf8)
        let config = try ConfigLoader.load(from: workspace.appendingPathComponent("config.yaml"))
        let summaries = try WorkspacePaths.summariesDir(for: profile)
        try FileManager.default.createDirectory(at: summaries, withIntermediateDirectories: true)
        let today = SummaryJSONParser.dateFormatter.string(from: .testNoon)
        try #"{"date":"\#(today)","totalDevices":5,"source":"jamf-cli"}"#.write(
            to: summaries.appendingPathComponent("summary_\(today).json"),
            atomically: true, encoding: .utf8)
        func alert() async {
            await AttentionLog.recording(profile: profile, usesAppRecord: false) {
                AttentionLog.current?.record(into: status, runLog: "run.log")
                await ScheduledRunSignals.notifyMetricAlerts(
                    config: config, profile: profile, workspace: workspace, recorder: nil,
                    now: .testNoon)
            }
        }
        WebhookCapture.respond(with: 429)
        await alert()
        XCTAssertEqual(WebhookCapture.posted.count, 1)
        let open = AttentionLog.openItems(profile: profile)
        XCTAssertEqual(open.map(\.code), [.webhookRejected])
        XCTAssertTrue(open.first?.message.contains("HTTP 429") == true, "\(open)")

        WebhookCapture.respond(with: 200)
        await alert()
        XCTAssertEqual(WebhookCapture.posted.count, 2, "the unsent card is tried again")
        XCTAssertTrue(AttentionLog.openItems(profile: profile).isEmpty)
    }

    func testARejectedOverdueCardNeedsAttentionForEveryProfileOnItAndASentOneClearsIt()
        async throws {
        WebhookCapture.start()
        defer { WebhookCapture.stop(); WebhookCapture.respond(with: 200) }
        let other = "attn-b"
        let otherWorkspace = try XCTUnwrap(ProfileService.workspaceURL(for: other))
        try FileManager.default.createDirectory(
            at: otherWorkspace.appendingPathComponent("automation"),
            withIntermediateDirectories: true)
        let notify = NotifyConfig(
            enabled: true, provider: "teams", url: WebhookCapture.webhookURL, detail: nil)
        let targets = try [profile, other].map { name in
            OverdueDigestRouting.Target(
                profile: name, notify: notify,
                workspace: try XCTUnwrap(ProfileService.workspaceURL(for: name)),
                sentToday: false)
        }
        let issue = AutomationHealthIssue(
            label: "fleet", displayName: "fleet", kind: .overdue, isMulti: true,
            profile: "", expectedFire: nil, lastRunFinishedAt: nil)
        let batch = OverdueDigestRouting.Batch(targets: targets, notify: notify, issues: [issue])
        let marker = DayMarker(name: "overdue-notify")

        WebhookCapture.respond(with: 404)
        let failed = await postOverdueDigest(batch, marker: marker, today: "2026-10-20")
        XCTAssertEqual(failed, .failed)
        XCTAssertEqual(WebhookCapture.posted.count, 1, "one card for both profiles")
        for name in [profile, other] {
            let open = AttentionLog.openItems(profile: name)
            XCTAssertEqual(open.map(\.code), [.webhookRejected], name)
            XCTAssertTrue(open.first?.message.contains("HTTP 404") == true, "\(open)")
        }

        WebhookCapture.respond(with: 200)
        let sent = await postOverdueDigest(batch, marker: marker, today: "2026-10-20")
        XCTAssertEqual(sent, .sent)
        for name in [profile, other] {
            XCTAssertTrue(AttentionLog.openItems(profile: name).isEmpty, name)
        }
    }
}
