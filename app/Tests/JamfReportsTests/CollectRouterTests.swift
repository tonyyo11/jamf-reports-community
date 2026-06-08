import Foundation
import XCTest
@testable import JamfReports

// MARK: - CollectRouterTests
//
// Tests for ProfileProductType.detect and CollectRouter.run product-type dispatch.
//
// All tests are fully offline — no jamf-cli required. Routing is verified by
// counting how many times each spy closure was called, not by inspecting actual
// jamf-cli output.
//
// Swift 6 / XCTest concurrency: @MainActor class-level annotation, per the
// established project pattern (see swift_test_concurrency_pattern.md memory).

@MainActor
final class CollectRouterTests: XCTestCase {

    // MARK: - SchoolCLIConfig decoding

    /// ConfigLoader must parse school_cli.enabled and school_cli.profile from YAML.
    func test_schoolCLIConfig_decodesFromYAML() throws {
        let yaml = """
        school_cli:
          enabled: true
          profile: my-school-profile
        """
        let config = try ConfigLoader.loadFromString(yaml)
        XCTAssertEqual(config.schoolCli?.isEnabled, true,
                       "school_cli.enabled must decode to true")
        XCTAssertEqual(config.schoolCli?.resolvedProfile, "my-school-profile",
                       "school_cli.profile must decode to the configured value")
    }

    /// When school_cli.enabled is false, the key is parsed but isEnabled returns false.
    func test_schoolCLIConfig_enabledFalse() throws {
        let yaml = """
        school_cli:
          enabled: false
          profile: unused
        """
        let config = try ConfigLoader.loadFromString(yaml)
        XCTAssertEqual(config.schoolCli?.isEnabled, false)
    }

    /// When school_cli is absent entirely, schoolCli is nil.
    func test_schoolCLIConfig_absentIsNil() throws {
        let config = try ConfigLoader.loadFromString("jamf_cli:\n  data_dir: data\n")
        XCTAssertNil(config.schoolCli, "schoolCli must be nil when school_cli key is absent")
    }

    // MARK: - ProfileProductType.detect

    /// A nil config (load failure) must degrade to .jamfPro with no Protect.
    func test_detect_nilConfig_returnsPro() {
        let result = ProfileProductType.detect(from: nil)
        XCTAssertEqual(result.type, .jamfPro)
        XCTAssertFalse(result.runsProtect)
    }

    /// school_cli.enabled == true → .jamfSchool, no Protect.
    func test_detect_schoolEnabled_returnsSchool() throws {
        let config = try ConfigLoader.loadFromString("""
        school_cli:
          enabled: true
          profile: school
        """)
        let result = ProfileProductType.detect(from: config)
        XCTAssertEqual(result.type, .jamfSchool)
        XCTAssertFalse(result.runsProtect, "School profiles never run Protect")
    }

    /// school_cli.enabled == false → .jamfPro (disabled School key is not enough).
    func test_detect_schoolDisabled_returnsPro() throws {
        let config = try ConfigLoader.loadFromString("""
        school_cli:
          enabled: false
          profile: school
        """)
        let result = ProfileProductType.detect(from: config)
        XCTAssertEqual(result.type, .jamfPro)
    }

    /// Absent school_cli → .jamfPro.
    func test_detect_noSchoolKey_returnsPro() throws {
        let config = try ConfigLoader.loadFromString("jamf_cli:\n  data_dir: data\n")
        let result = ProfileProductType.detect(from: config)
        XCTAssertEqual(result.type, .jamfPro)
    }

    /// Jamf Pro with protect.enabled == true → .jamfPro, runsProtect == true.
    func test_detect_proWithProtect_returnsProRunsProtect() throws {
        let config = try ConfigLoader.loadFromString("""
        protect:
          enabled: true
          profile: protect-profile
        """)
        let result = ProfileProductType.detect(from: config)
        XCTAssertEqual(result.type, .jamfPro)
        XCTAssertTrue(result.runsProtect)
    }

    /// Jamf Pro without protect key → .jamfPro, runsProtect == false.
    func test_detect_proNoProtect_returnsProNoProtect() throws {
        let config = try ConfigLoader.loadFromString("jamf_cli:\n  data_dir: data\n")
        let result = ProfileProductType.detect(from: config)
        XCTAssertEqual(result.type, .jamfPro)
        XCTAssertFalse(result.runsProtect)
    }

    /// School + protect.enabled present → School wins; runsProtect is false.
    func test_detect_schoolTakesPrecedenceOverProtect() throws {
        let config = try ConfigLoader.loadFromString("""
        school_cli:
          enabled: true
          profile: school
        protect:
          enabled: true
          profile: protect
        """)
        let result = ProfileProductType.detect(from: config)
        XCTAssertEqual(result.type, .jamfSchool)
        XCTAssertFalse(result.runsProtect, "School profiles never augment with Protect")
    }

    // MARK: - CollectRouter.run dispatch

    /// For a Jamf Pro profile, only proCollect is called; school and protect are not called.
    func test_router_proProfile_callsProCollectOnly() async throws {
        let config = try ConfigLoader.loadFromString("jamf_cli:\n  data_dir: data\n")
        let spy = RouterSpy()

        try await CollectRouter.run(
            profile: "testpro",
            config: config,
            workspacePaths: WorkspacePaths.self,
            proCollect: spy.proCollect,
            schoolCollect: spy.schoolCollect,
            protectCollect: spy.protectCollect,
            onLine: { _ in }
        )

        XCTAssertEqual(spy.proCallCount, 1, "Pro collect must be called exactly once")
        XCTAssertEqual(spy.schoolCallCount, 0, "School collect must not be called for a Pro profile")
        XCTAssertEqual(spy.protectCallCount, 0, "Protect collect must not be called without protect.enabled")
    }

    /// For a School profile, only schoolCollect is called; pro and protect are not called.
    func test_router_schoolProfile_callsSchoolCollectOnly() async throws {
        let config = try ConfigLoader.loadFromString("""
        school_cli:
          enabled: true
          profile: school
        """)
        let spy = RouterSpy()

        try await CollectRouter.run(
            profile: "testschool",
            config: config,
            workspacePaths: WorkspacePaths.self,
            proCollect: spy.proCollect,
            schoolCollect: spy.schoolCollect,
            protectCollect: spy.protectCollect,
            onLine: { _ in }
        )

        XCTAssertEqual(spy.schoolCallCount, 1, "School collect must be called exactly once")
        XCTAssertEqual(spy.proCallCount, 0, "Pro collect must not be called for a School profile")
        XCTAssertEqual(spy.protectCallCount, 0, "Protect collect must not be called for a School profile")
    }

    /// For a Pro profile with protect.enabled, proCollect then protectCollect are both called.
    func test_router_proWithProtect_callsBothProAndProtect() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CollectRouterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        addTeardownBlock {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: root)
        }

        // Create a workspace so WorkspacePaths.dataDir(for:) resolves.
        let profile = "testprotect\(Int.random(in: 1000...9999))"
        let ws = root.appendingPathComponent(profile, isDirectory: true)
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)

        let config = try ConfigLoader.loadFromString("""
        protect:
          enabled: true
          profile: my-protect
        """)
        let spy = RouterSpy()

        try await CollectRouter.run(
            profile: profile,
            config: config,
            workspacePaths: WorkspacePaths.self,
            proCollect: spy.proCollect,
            schoolCollect: spy.schoolCollect,
            protectCollect: spy.protectCollect,
            onLine: { _ in }
        )

        XCTAssertEqual(spy.proCallCount, 1, "Pro collect must be called")
        XCTAssertEqual(spy.protectCallCount, 1, "Protect collect must be called after Pro")
        XCTAssertEqual(spy.schoolCallCount, 0, "School collect must not be called")
    }

    /// A protect-collect failure must not rethrow — Pro run already succeeded.
    func test_router_protectFailure_isNonFatal() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CollectRouterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        addTeardownBlock {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: root)
        }

        let profile = "testprotfail\(Int.random(in: 1000...9999))"
        let ws = root.appendingPathComponent(profile, isDirectory: true)
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)

        let config = try ConfigLoader.loadFromString("""
        protect:
          enabled: true
          profile: my-protect
        """)
        let warnEmitted = RouterValueBox<Bool>(false)

        // Does not throw despite protectCollect throwing.
        try await CollectRouter.run(
            profile: profile,
            config: config,
            workspacePaths: WorkspacePaths.self,
            proCollect: { _, _, _, _, _, _ in },
            schoolCollect: { _, _, _ in },
            protectCollect: { _, _, _ in throw NSError(domain: "test", code: 42) },
            onLine: { line in
                if line.level == .warn { warnEmitted.set(true) }
            }
        )

        XCTAssertTrue(warnEmitted.value, "A warning must be emitted when protect collect fails")
    }

    /// Nil config must degrade to Jamf Pro without crashing (regression guard).
    func test_router_nilConfig_degradesToPro() async throws {
        let spy = RouterSpy()

        try await CollectRouter.run(
            profile: "testnil",
            config: nil,
            workspacePaths: WorkspacePaths.self,
            proCollect: spy.proCollect,
            schoolCollect: spy.schoolCollect,
            protectCollect: spy.protectCollect,
            onLine: { _ in }
        )

        XCTAssertEqual(spy.proCallCount, 1, "Nil config must default to Pro collect")
        XCTAssertEqual(spy.schoolCallCount, 0)
        XCTAssertEqual(spy.protectCallCount, 0)
    }

    /// Regression guard: Pro path receives the same force and skipExpensive values
    /// that the caller passes — no silent flipping.
    func test_router_forceAndSkipPassedThroughToPro() async throws {
        let config = try ConfigLoader.loadFromString("jamf_cli:\n  data_dir: data\n")
        let capturedForce = RouterValueBox<Bool?>(nil)
        let capturedSkip = RouterValueBox<Bool?>(nil)

        try await CollectRouter.run(
            profile: "testpro",
            skipExpensive: true,
            force: true,
            config: config,
            workspacePaths: WorkspacePaths.self,
            proCollect: { _, _, _, skipExpensive, force, _ in
                capturedSkip.set(skipExpensive)
                capturedForce.set(force)
            },
            schoolCollect: { _, _, _ in },
            protectCollect: { _, _, _ in },
            onLine: { _ in }
        )

        XCTAssertEqual(capturedForce.value, true, "force must be passed through unchanged")
        XCTAssertEqual(capturedSkip.value, true, "skipExpensive must be passed through unchanged")
    }
}

// MARK: - RouterSpy

/// Thread-safe call counter for CollectRouter spy closures.
/// Uses a plain struct wrapping a class-backed counter so the @Sendable closures
/// can capture it without capturing self, which avoids the lazy-var/@Sendable conflict.
private final class RouterCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int { lock.withLock { _value } }
    func increment() { lock.withLock { _value += 1 } }
}

/// Thread-safe box for a single value captured inside a @Sendable router closure.
private final class RouterValueBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ initial: T) { _value = initial }
    var value: T { lock.withLock { _value } }
    func set(_ newValue: T) { lock.withLock { _value = newValue } }
}

private struct RouterSpy {
    let proCounter = RouterCallCounter()
    let schoolCounter = RouterCallCounter()
    let protectCounter = RouterCallCounter()

    var proCallCount: Int { proCounter.value }
    var schoolCallCount: Int { schoolCounter.value }
    var protectCallCount: Int { protectCounter.value }

    var proCollect: CollectRouter.ProCollect {
        let counter = proCounter
        return { _, _, _, _, _, _ in counter.increment() }
    }

    var schoolCollect: CollectRouter.SchoolCollect {
        let counter = schoolCounter
        return { _, _, _ in counter.increment() }
    }

    var protectCollect: CollectRouter.ProtectCollect {
        let counter = protectCounter
        return { _, _, _ in counter.increment() }
    }
}
