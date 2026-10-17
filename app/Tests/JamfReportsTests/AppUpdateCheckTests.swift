import Foundation
import XCTest
@testable import JamfReports

/// The app reports a newer stable release and never downloads one. No test reaches GitHub:
/// every model gets a fetch that answers from memory.
@MainActor
final class AppUpdateCheckTests: XCTestCase {

    nonisolated(unsafe) private var defaults: UserDefaults!
    nonisolated(unsafe) private var suite = ""

    override func setUpWithError() throws {
        suite = "AppUpdateCheckTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func releaseJSON(
        tag: String, prerelease: Bool = false, draft: Bool = false,
        page: String = "https://github.com/tonyyo11/jamf-reports-community/releases/tag/v2.10.1"
    ) -> Data {
        Data("""
        {"tag_name": "\(tag)", "prerelease": \(prerelease), "draft": \(draft),
         "html_url": "\(page)", "body": "notes"}
        """.utf8)
    }

    /// Counts requests and answers with `answer`.
    private final class FakeGitHub: @unchecked Sendable {
        var answer: Result<Data, Error>
        private(set) var requests = 0
        init(_ answer: Result<Data, Error>) { self.answer = answer }
        var fetch: AppUpdateCheck.Fetch {
            { [self] _ in requests += 1; return try answer.get() }
        }
    }

    private func stable(_ tag: String) -> AppUpdateCheck.Release {
        guard let release = AppUpdateCheck.Release(tag: tag) else {
            preconditionFailure("\(tag) is not a stable tag")
        }
        return release
    }

    private func model(current: String, github: FakeGitHub) -> AppUpdateModel {
        AppUpdateModel(defaults: defaults, currentVersion: current, fetch: github.fetch)
    }

    // MARK: - Stable releases only

    func testAStableReleaseIsRead() throws {
        let release = try AppUpdateCheck.release(from: releaseJSON(tag: "v2.10.1"))
        XCTAssertEqual(release.version, "2.10.1")
        XCTAssertEqual(release.page?.absoluteString,
                       "https://github.com/tonyyo11/jamf-reports-community/releases/tag/v2.10.1")
    }

    func testPreReleasesAndDraftsAreNeverOffered() {
        for data in [
            releaseJSON(tag: "v2.11.0", prerelease: true),
            releaseJSON(tag: "v2.11.0", draft: true),
            releaseJSON(tag: "v2.11.0-rc1"),
            releaseJSON(tag: "v2.11.0-beta2"),
        ] {
            XCTAssertThrowsError(try AppUpdateCheck.release(from: data)) { error in
                XCTAssertEqual(error as? AppUpdateCheck.CheckError, .notAStableRelease)
            }
        }
        XCTAssertNil(AppUpdateCheck.stableVersion(fromTag: "v2.11.0 "))
        XCTAssertNil(AppUpdateCheck.stableVersion(fromTag: "v2.<b>1"))
        XCTAssertNil(AppUpdateCheck.stableVersion(fromTag: "v2"))
        XCTAssertEqual(AppUpdateCheck.stableVersion(fromTag: "2.11"), "2.11")
    }

    /// The page comes from the version, never from the answer's `html_url`.
    func testThePageIsThisProjectsReleaseWhateverTheAnswerSays() throws {
        let release = try AppUpdateCheck.release(from: releaseJSON(
            tag: "v2.10.1", page: "https://evil.example/tonyyo11/releases/x"))
        XCTAssertEqual(release.page?.absoluteString,
                       "https://github.com/tonyyo11/jamf-reports-community/releases/tag/v2.10.1")
    }

    /// The page names the tag as GitHub has it, so a tag without the `v` still opens.
    func testThePageUsesTheTagAsWritten() {
        XCTAssertEqual(stable("2.11.0").page?.absoluteString,
                       "https://github.com/tonyyo11/jamf-reports-community/releases/tag/2.11.0")
        XCTAssertEqual(stable("V2.11.0").page?.lastPathComponent, "V2.11.0")
        XCTAssertEqual(stable("V2.11.0").version, "2.11.0")
    }

    // MARK: - Version comparison

    func testOnlyANewerReleaseIsOffered() {
        let release = stable("v2.10.1")
        XCTAssertEqual(AppUpdateCheck.outcome(current: "2.10.0", release: release),
                       .available(release))
        XCTAssertEqual(AppUpdateCheck.outcome(current: "2.10.1", release: release),
                       .upToDate(latest: "2.10.1"))
        XCTAssertEqual(AppUpdateCheck.outcome(current: "2.11.0", release: release),
                       .upToDate(latest: "2.10.1"))
    }

    /// Someone on a beta of the next version is not offered the older stable release, and is
    /// offered that version's final release when it ships.
    func testABetaOfTheNextVersionWaitsForItsRelease() {
        let older = stable("v2.10.1")
        let final = stable("v2.11.0")
        XCTAssertEqual(AppUpdateCheck.outcome(current: "2.11.0-beta1", release: older),
                       .upToDate(latest: "2.10.1"))
        XCTAssertEqual(AppUpdateCheck.outcome(current: "2.11.0-beta1", release: final),
                       .available(final))
    }

    // MARK: - Throttle and size cap

    func testTheCheckRunsAtMostOnceADay() {
        let now = Date()
        XCTAssertTrue(AppUpdateCheck.isDue(lastCheck: nil, now: now))
        XCTAssertFalse(
            AppUpdateCheck.isDue(lastCheck: now.addingTimeInterval(-23 * 3600), now: now))
        XCTAssertTrue(AppUpdateCheck.isDue(lastCheck: now.addingTimeInterval(-25 * 3600), now: now))
        XCTAssertTrue(AppUpdateCheck.isDue(lastCheck: now.addingTimeInterval(3600), now: now),
                      "a clock that went backwards does not stop the check for good")
    }

    /// A check that failed (no network yet at launch) is tried again within the hour, not
    /// a day later.
    func testAFailedCheckIsRetriedAfterAnHour() {
        let now = Date()
        XCTAssertFalse(AppUpdateCheck.isDue(
            lastCheck: now.addingTimeInterval(-59 * 60), failed: true, now: now))
        XCTAssertTrue(AppUpdateCheck.isDue(
            lastCheck: now.addingTimeInterval(-61 * 60), failed: true, now: now))
    }

    func testTheModelRetriesAFailedCheckSoonAndRemembersItAcrossLaunches() async {
        let github = FakeGitHub(.failure(AppUpdateCheck.CheckError.httpStatus(503)))
        let start = Date()
        await model(current: "2.10.0", github: github).checkNow(now: start)
        github.answer = .success(releaseJSON(tag: "v2.10.1"))

        let relaunched = model(current: "2.10.0", github: github)
        await relaunched.checkIfDue(now: start.addingTimeInterval(30 * 60))
        XCTAssertEqual(github.requests, 1, "not yet: half an hour after the failure")
        await relaunched.checkIfDue(now: start.addingTimeInterval(2 * 3600))
        XCTAssertEqual(github.requests, 2)
        XCTAssertEqual(relaunched.bannerRelease?.version, "2.10.1")
        XCTAssertFalse(relaunched.lastCheckFailed)
    }

    func testAnAnswerLargerThanTheCapIsRefused() async {
        let stream = AsyncStream<UInt8> { continuation in
            for _ in 0..<11 { continuation.yield(0x41) }
            continuation.finish()
        }
        do {
            _ = try await AppUpdateCheck.collect(stream, limit: 10)
            XCTFail("11 bytes passed a 10-byte cap")
        } catch {
            XCTAssertEqual(error as? AppUpdateCheck.CheckError, .tooLarge)
        }
    }

    // MARK: - Model

    func testANewerReleaseShowsTheBannerAndIsRemembered() async {
        let github = FakeGitHub(.success(releaseJSON(tag: "v2.10.1")))
        let updates = model(current: "2.10.0", github: github)
        await updates.checkIfDue()
        XCTAssertEqual(updates.bannerRelease?.version, "2.10.1")
        XCTAssertEqual(github.requests, 1)

        let relaunched = model(current: "2.10.0", github: github)
        XCTAssertEqual(relaunched.bannerRelease?.version, "2.10.1", "kept across launches")
        await relaunched.checkIfDue()
        XCTAssertEqual(github.requests, 1, "not due again within the day")
    }

    func testTurnedOffMakesNoRequestAndHidesTheBanner() async {
        let github = FakeGitHub(.success(releaseJSON(tag: "v2.10.1")))
        let updates = model(current: "2.10.0", github: github)
        await updates.checkNow()
        XCTAssertNotNil(updates.bannerRelease)

        updates.setEnabled(false)
        XCTAssertNil(updates.bannerRelease)
        await updates.checkNow()
        await updates.checkIfDue(now: Date().addingTimeInterval(3 * 86_400))
        XCTAssertEqual(github.requests, 1, "no request while the switch is off")

        let relaunched = model(current: "2.10.0", github: github)
        XCTAssertFalse(relaunched.isEnabled)
        XCTAssertTrue(model(current: "2.10.0", github: github).statusText.hasPrefix("Off."))
    }

    func testOnByDefault() {
        XCTAssertTrue(model(current: "2.10.0", github: FakeGitHub(.success(Data()))).isEnabled)
    }

    func testSkippingHidesThatVersionButNotALaterOne() async {
        let github = FakeGitHub(.success(releaseJSON(tag: "v2.10.1")))
        let updates = model(current: "2.10.0", github: github)
        await updates.checkNow()
        updates.skip("2.10.1")
        XCTAssertNil(updates.bannerRelease)

        github.answer = .success(releaseJSON(
            tag: "v2.10.2",
            page: "https://github.com/tonyyo11/jamf-reports-community/releases/tag/v2.10.2"))
        await updates.checkNow()
        XCTAssertEqual(updates.bannerRelease?.version, "2.10.2")
    }

    func testAFailedCheckShowsNoBannerAndSaysWhy() async {
        let github = FakeGitHub(.failure(AppUpdateCheck.CheckError.httpStatus(403)))
        let updates = model(current: "2.10.0", github: github)
        await updates.checkNow()
        XCTAssertNil(updates.bannerRelease)
        XCTAssertEqual(updates.lastError, "GitHub answered HTTP 403")
        XCTAssertTrue(updates.statusText.contains("HTTP 403"))
    }

    func testUpToDateClearsAnEarlierOffer() async {
        let github = FakeGitHub(.success(releaseJSON(tag: "v2.10.1")))
        let updates = model(current: "2.10.0", github: github)
        await updates.checkNow()
        github.answer = .success(releaseJSON(tag: "v2.10.0"))
        await updates.checkNow()
        XCTAssertNil(updates.latest, "a pulled release is no longer offered")
        XCTAssertNil(model(current: "2.10.0", github: github).latest)
    }

    func testTheRequestGoesOnlyToThisProjectsLatestRelease() {
        guard let request = AppUpdateCheck.request else { return XCTFail("no request") }
        XCTAssertEqual(request.url, URL(string:
            "https://api.github.com/repos/tonyyo11/jamf-reports-community/releases/latest"))
        XCTAssertEqual(request.httpMethod ?? "GET", "GET")
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(request.timeoutInterval, AppUpdateCheck.requestTimeout)
    }
}
