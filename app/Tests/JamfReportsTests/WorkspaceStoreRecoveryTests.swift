import XCTest
@testable import JamfReports

/// `runFirstCollect` exit-code triage/run-recording and `restoreDefaultConfig`
/// preservation guarantees (post-2.2.1 review batch — both shipped untested).
@MainActor
final class WorkspaceStoreRecoveryTests: XCTestCase {

    private func makeStore(slug: String) -> WorkspaceStore {
        let store = WorkspaceStore()
        store.demoMode = false
        store.profile = slug
        return store
    }

    private func temporarySlug(_ stem: String) throws -> (slug: String, root: URL) {
        let slug = "jrc-test-\(stem)-\(UUID().uuidString.prefix(8))".lowercased()
        guard let root = ProfileService.workspaceURL(for: slug) else {
            throw XCTSkip("workspace root unavailable for test profile")
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (slug, root)
    }

    // MARK: - firstCollectToast triage

    func testFirstCollectToastTriage() {
        let success = WorkspaceStore.firstCollectToast(exitCode: 0)
        XCTAssertTrue(success.message.contains("complete"))

        let auth = WorkspaceStore.firstCollectToast(exitCode: CLIBridge.exitCodeUnauthorized)
        XCTAssertTrue(auth.message.contains("credentials expired"))

        // The #181 misattribution regression guard: exit 1 must NOT blame auth.
        let partial = WorkspaceStore.firstCollectToast(exitCode: 1)
        XCTAssertFalse(partial.message.contains("credentials"))
        XCTAssertTrue(partial.message.contains("Run History"))

        // When the run was not recorded, point at the app log — not a run log
        // that does not exist for this run.
        let unrecorded = WorkspaceStore.firstCollectToast(exitCode: 1, runRecorded: false)
        XCTAssertFalse(unrecorded.message.contains("Run History"))
        XCTAssertTrue(unrecorded.message.contains("app log"))
    }

    // MARK: - runFirstCollect

    func testRunFirstCollectRecordsRunAndReportsPartialFailure() async throws {
        let (slug, root) = try temporarySlug("firstcollect")
        let store = makeStore(slug: slug)

        await store.runFirstCollect { _, onLine in
            onLine(.init(timestamp: Date(), level: .warn, text: "[warn] patch-status: exit 1"))
            return 1
        }

        let toast = try XCTUnwrap(store.toast)
        XCTAssertTrue(toast.message.contains("Run History"))
        XCTAssertFalse(toast.message.contains("credentials"))

        // "see Run History" must be true: the run log exists and holds the line.
        let logsDir = root.appendingPathComponent("automation/logs")
        let logs = (try? FileManager.default.contentsOfDirectory(atPath: logsDir.path)) ?? []
        let runLog = try XCTUnwrap(
            logs.first { $0.hasPrefix(WorkspaceStore.firstCollectRunLabel + ".") },
            "first collect must record a Run History log"
        )
        let contents = try String(contentsOf: logsDir.appendingPathComponent(runLog), encoding: .utf8)
        XCTAssertTrue(contents.contains("[warn] patch-status: exit 1"))
    }

    func testRunFirstCollectSuccessToast() async throws {
        let (slug, _) = try temporarySlug("firstcollect-ok")
        let store = makeStore(slug: slug)

        await store.runFirstCollect { _, _ in 0 }

        XCTAssertTrue(store.toast?.message.contains("complete") ?? false)
    }

    func testRunFirstCollectThrownErrorSurfacesToast() async throws {
        let (slug, _) = try temporarySlug("firstcollect-throw")
        let store = makeStore(slug: slug)

        await store.runFirstCollect { _, _ in
            throw CLIBridgeError.executableNotFound
        }

        let toast = try XCTUnwrap(store.toast)
        XCTAssertTrue(toast.message.contains("Collect failed"))
    }

    func testRunFirstCollectBailIsNotSilent() async {
        let store = WorkspaceStore()
        store.demoMode = false
        store.profile = "INVALID SLUG"

        await store.runFirstCollect { _, _ in
            XCTFail("collect must not run for an invalid profile")
            return 0
        }

        XCTAssertNotNil(store.toast, "a refused button click must say something")
    }

    // MARK: - restoreDefaultConfig

    func testRestoreDefaultConfigPreservesBrokenFileAndReseeds() async throws {
        let (slug, root) = try temporarySlug("restore")
        let store = makeStore(slug: slug)

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let config = root.appendingPathComponent("config.yaml")
        let brokenContent = "{{{{ not yaml at all"
        try Data(brokenContent.utf8).write(to: config)

        let failure = await store.restoreDefaultConfig()
        XCTAssertNil(failure)

        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        let backupName = try XCTUnwrap(
            names.first { $0.hasPrefix("config.yaml.broken-") },
            "the broken file must be preserved, never deleted"
        )
        let preserved = try String(
            contentsOf: root.appendingPathComponent(backupName), encoding: .utf8
        )
        XCTAssertEqual(preserved, brokenContent, "backup must be byte-identical")

        XCTAssertTrue(FileManager.default.fileExists(atPath: config.path))
        XCTAssertNoThrow(try ConfigLoader.load(from: config),
                         "the reseeded config must parse with the app's own loader")
    }

    func testRestoreDefaultConfigIsNoOpInDemoMode() async {
        let store = WorkspaceStore()
        store.demoMode = true

        let failure = await store.restoreDefaultConfig()
        XCTAssertNil(failure)
    }
}
