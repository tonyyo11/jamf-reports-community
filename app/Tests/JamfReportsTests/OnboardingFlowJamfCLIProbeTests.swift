import Foundation
import XCTest
@testable import JamfReports

/// `OnboardingFlow.init()` runs while SwiftUI builds a view's `@State`. The jamf-cli probe waits
/// on child processes, and that wait inside a view update aborts AttributeGraph, so init runs no
/// probe and `refreshJamfCLIStatus()` runs it off the main actor.
@MainActor
final class OnboardingFlowJamfCLIProbeTests: XCTestCase {

    private final class ProbeLog: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var sawMainThread = false

        func record() {
            lock.lock()
            defer { lock.unlock() }
            count += 1
            if Thread.isMainThread { sawMainThread = true }
        }

        var calls: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }

        var ranOnMainThread: Bool {
            lock.lock()
            defer { lock.unlock() }
            return sawMainThread
        }
    }

    private func installation(version: String?) -> JamfCLIInstaller.Installation {
        JamfCLIInstaller.Installation(
            path: "/usr/local/bin/jamf-cli", resolvedPath: "/usr/local/bin/jamf-cli",
            version: version, source: .githubRelease, brewPath: nil,
            codesignVerified: true, specProVersion: nil
        )
    }

    private func makeFlow(
        log: ProbeLog, answering result: JamfCLIInstaller.Installation?
    ) -> OnboardingFlow {
        OnboardingFlow(installationProbe: {
            log.record()
            return result
        })
    }

    func test_init_runsNoProbe() {
        let log = ProbeLog()
        let flow = makeFlow(log: log, answering: installation(version: "1.31.1"))
        XCTAssertEqual(log.calls, 0, "init must not touch jamf-cli: it runs inside a view update")
        XCTAssertTrue(flow.isCheckingJamfCLI)
        XCTAssertFalse(flow.jamfCLIInstalled)
        XCTAssertNil(flow.jamfCLIVersion)
    }

    func test_refresh_probesOnceOffTheMainThreadAndPublishesTheVersion() async {
        let log = ProbeLog()
        let flow = makeFlow(log: log, answering: installation(version: "1.31.1"))
        await flow.refreshJamfCLIStatus()
        XCTAssertEqual(log.calls, 1, "one probe, not one for installed and one for version")
        XCTAssertFalse(log.ranOnMainThread, "the probe waits on child processes")
        XCTAssertEqual(flow.jamfCLIStatus, .installed(version: "1.31.1"))
        XCTAssertTrue(flow.jamfCLIInstalled)
        XCTAssertEqual(flow.jamfCLIVersion, "1.31.1")
        XCTAssertFalse(flow.isCheckingJamfCLI)
    }

    func test_refresh_withNoJamfCLI_settlesOnMissing() async {
        let flow = makeFlow(log: ProbeLog(), answering: nil)
        await flow.refreshJamfCLIStatus()
        XCTAssertEqual(flow.jamfCLIStatus, .missing)
        XCTAssertFalse(flow.jamfCLIInstalled)
        XCTAssertFalse(flow.isCheckingJamfCLI, "missing is an answer; checking is not")
    }

    func test_statusStaysChecking_untilTheProbeReturns() async throws {
        let log = ProbeLog()
        let release = DispatchSemaphore(value: 0)
        let found = installation(version: "1.31.1")
        let flow = OnboardingFlow(installationProbe: {
            log.record()
            release.wait()
            return found
        })
        let refresh = Task { await flow.refreshJamfCLIStatus() }
        var waited = 0
        while log.calls == 0 && waited < 500 {
            try await Task.sleep(for: .milliseconds(10))
            waited += 1
        }
        XCTAssertEqual(log.calls, 1, "the probe never started")
        XCTAssertTrue(flow.isCheckingJamfCLI)
        XCTAssertFalse(flow.jamfCLIInstalled)
        flow.currentStep = .installCLI
        XCTAssertFalse(flow.canAdvance, "Continue waits for an answer")
        release.signal()
        await refresh.value
        XCTAssertFalse(flow.isCheckingJamfCLI)
        XCTAssertTrue(flow.canAdvance)
    }

    func test_recheck_probesAgainAndPicksUpAnInstall() async {
        let log = ProbeLog()
        let answers = AnswerBox(nil)
        let flow = OnboardingFlow(installationProbe: {
            log.record()
            return answers.value
        })
        await flow.refreshJamfCLIStatus()
        XCTAssertEqual(flow.jamfCLIStatus, .missing)
        answers.value = installation(version: "1.29.0")
        await flow.refreshJamfCLIStatus()
        XCTAssertEqual(log.calls, 2)
        XCTAssertEqual(flow.jamfCLIStatus, .installed(version: "1.29.0"))
    }

    func test_refresh_setsThePlatformScopeDefaultFromTheVersion() async {
        let old = makeFlow(log: ProbeLog(), answering: installation(version: "1.27.0"))
        await old.refreshJamfCLIStatus()
        XCTAssertEqual(old.platformScope, .tenant, "pre-1.28 rejects --environment-id")

        let current = makeFlow(log: ProbeLog(), answering: installation(version: "1.31.1"))
        await current.refreshJamfCLIStatus()
        XCTAssertEqual(current.platformScope, .environment)
    }

    func test_refresh_keepsAScopeTheUserAlreadyChose() async {
        let chosenEnvironment = makeFlow(
            log: ProbeLog(), answering: installation(version: "1.27.0"))
        chosenEnvironment.choosePlatformScope(.environment)
        await chosenEnvironment.refreshJamfCLIStatus()
        XCTAssertEqual(chosenEnvironment.platformScope, .environment)

        let chosenTenant = makeFlow(
            log: ProbeLog(), answering: installation(version: "1.31.1"))
        chosenTenant.choosePlatformScope(.tenant)
        await chosenTenant.refreshJamfCLIStatus()
        XCTAssertEqual(chosenTenant.platformScope, .tenant)
    }

    private final class AnswerBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: JamfCLIInstaller.Installation?

        init(_ initial: JamfCLIInstaller.Installation?) { stored = initial }

        var value: JamfCLIInstaller.Installation? {
            get {
                lock.lock()
                defer { lock.unlock() }
                return stored
            }
            set {
                lock.lock()
                defer { lock.unlock() }
                stored = newValue
            }
        }
    }
}
