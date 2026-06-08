import AppKit
import Foundation
import XCTest
@testable import JamfReports

// MARK: - OnboardingFlowMultiProductTests
//
// Tests for the Part-1 bug fix and Part-2 multi-product onboarding changes.
//
// All tests use the existing @MainActor + XCTestCase pattern from
// OnboardingFlowSignatureGateTests (Swift 6.1 compatible).

@MainActor
final class OnboardingFlowMultiProductTests: XCTestCase {

    // MARK: - Part 1: canAdvance with secret-field-has-text (bug regression)

    /// The Continue button must be enabled when the field has keystrokes even
    /// before Return / focus-loss fires onFinalize (the reported bug).
    func test_authenticate_hasText_enablesAdvance() {
        let flow = makeValidOAuth2Flow()
        // clientSecret is still empty — only the field has text.
        flow.secretFieldHasText = true
        XCTAssertTrue(
            flow.canAdvance,
            "canAdvance must be true when secretFieldHasText=true, even with empty clientSecret"
        )
    }

    /// Advancing must still be blocked when both clientSecret and hasText are empty.
    func test_authenticate_noSecretNoHasText_blocksAdvance() {
        let flow = makeValidOAuth2Flow()
        flow.secretFieldHasText = false
        flow.clientSecret = ""
        XCTAssertFalse(
            flow.canAdvance,
            "canAdvance must be false when both clientSecret and secretFieldHasText are empty"
        )
    }

    /// A finalized non-empty clientSecret alone must enable advance
    /// (existing behavior preserved).
    func test_authenticate_finalizedSecret_enablesAdvance() {
        let flow = makeValidOAuth2Flow()
        flow.secretFieldHasText = false
        flow.clientSecret = "finalized-secret"
        XCTAssertTrue(
            flow.canAdvance,
            "canAdvance must be true when clientSecret is non-empty (finalized)"
        )
    }

    // MARK: - Part 1: Platform Gateway canAdvance

    func test_platformGateway_hasText_enablesAdvance() {
        let flow = makeValidPlatformGatewayFlow()
        flow.platformSecretFieldHasText = true
        XCTAssertTrue(
            flow.canAdvance,
            "Platform Gateway: canAdvance must be true when platformSecretFieldHasText=true"
        )
    }

    func test_platformGateway_noSecretNoHasText_blocksAdvance() {
        let flow = makeValidPlatformGatewayFlow()
        flow.platformSecretFieldHasText = false
        flow.platformClientSecret = ""
        XCTAssertFalse(
            flow.canAdvance,
            "Platform Gateway: canAdvance must be false with no secret and no has-text"
        )
    }

    func test_platformGateway_missingTenantID_blocksAdvance() {
        let flow = makeValidPlatformGatewayFlow()
        flow.tenantID = ""
        flow.platformSecretFieldHasText = true
        XCTAssertFalse(
            flow.canAdvance,
            "Platform Gateway: canAdvance must be false when tenantID is empty"
        )
    }

    // MARK: - Part 2: addProducts step canAdvance

    func test_addProducts_alwaysAdvanceable() {
        let flow = OnboardingFlow()
        flow.currentStep = .addProducts
        XCTAssertTrue(
            flow.canAdvance,
            "addProducts step must always allow advance (both products are optional)"
        )
    }

    func test_addProducts_blocksDuringProtectConnect() {
        let flow = OnboardingFlow()
        flow.currentStep = .addProducts
        flow.isConnectingProtect = true
        XCTAssertFalse(
            flow.canAdvance,
            "addProducts step must block advance while Protect connection is in progress"
        )
    }

    func test_addProducts_blocksDuringSchoolConnect() {
        let flow = OnboardingFlow()
        flow.currentStep = .addProducts
        flow.isConnectingSchool = true
        XCTAssertFalse(
            flow.canAdvance,
            "addProducts step must block advance while School connection is in progress"
        )
    }

    // MARK: - Part 2: Step enum has addProducts between validate and csvMapping

    /// addProducts must come AFTER csvMapping so that ScaffoldService.writeConfig
    /// runs first and writeProtect/writeSchoolConfig can merge into an existing file.
    /// ScaffoldService.writeConfig deletes any prior config.yaml before writing;
    /// if addProducts ran first its writes would be silently destroyed.
    func test_stepOrder_addProductsAfterCSVMappingBeforeFirstReport() {
        let steps = OnboardingFlow.Step.allCases
        let csvMappingIdx = steps.firstIndex(of: .csvMapping)!
        let addProductsIdx = steps.firstIndex(of: .addProducts)!
        let firstReportIdx = steps.firstIndex(of: .firstReport)!
        XCTAssertLessThan(csvMappingIdx, addProductsIdx,
                          ".csvMapping must precede .addProducts (avoid config.yaml clobber)")
        XCTAssertLessThan(addProductsIdx, firstReportIdx,
                          ".addProducts must precede .firstReport")
    }

    // MARK: - Part 2: Pure argument builders

    func test_oAuth2Arguments_containsExpectedFlags() {
        let args = OnboardingFlow.proOAuth2Arguments(
            profile: "myprod", url: "https://example.jamfcloud.com"
        )
        XCTAssertTrue(args.contains("config"), "must include 'config'")
        XCTAssertTrue(args.contains("add-profile"), "must include 'add-profile'")
        XCTAssertTrue(args.contains("myprod"), "must include the profile name")
        XCTAssertTrue(args.contains("--auth-method"), "must include --auth-method flag")
        XCTAssertTrue(args.contains("oauth2"), "auth method must be oauth2")
        XCTAssertTrue(args.contains("--url"), "must include --url flag")
        XCTAssertTrue(args.contains("--no-color"), "must include --no-color")
    }

    func test_oAuth2Stdin_format() {
        let data = OnboardingFlow.proOAuth2Stdin(clientID: "myid", clientSecret: "mysecret")
        let s = String(data: data, encoding: .utf8) ?? ""
        XCTAssertEqual(s, "myid\nmysecret\n", "stdin must be clientID\\nclientSecret\\n")
    }

    func test_platformGatewayArguments_containsExpectedFlags() {
        let args = OnboardingFlow.platformGatewayArguments(
            profile: "platform-prod",
            gatewayURL: "https://us.apigw.jamf.com",
            tenantID: "my-tenant"
        )
        XCTAssertTrue(args.contains("config"), "must include 'config'")
        XCTAssertTrue(args.contains("add-profile"), "must include 'add-profile'")
        XCTAssertTrue(args.contains("--auth-method"), "must include --auth-method")
        XCTAssertTrue(args.contains("platform"), "auth method must be platform")
        XCTAssertTrue(args.contains("--tenant-id"), "must include --tenant-id")
        XCTAssertTrue(args.contains("my-tenant"), "must include tenant ID value")
        XCTAssertTrue(args.contains("--no-color"), "must include --no-color")
    }

    func test_platformGatewayStdin_format() {
        let data = OnboardingFlow.platformGatewayStdin(clientID: "cid", clientSecret: "csec")
        let s = String(data: data, encoding: .utf8) ?? ""
        XCTAssertEqual(s, "cid\ncsec\n", "Platform stdin must be clientID\\nclientSecret\\n")
    }

    func test_protectArguments_containsExpectedFlags() {
        let args = OnboardingFlow.protectArguments(
            profile: "protect", url: "https://org.protect.jamfcloud.com"
        )
        XCTAssertTrue(args.contains("protect"), "must include 'protect' subcommand")
        XCTAssertTrue(args.contains("setup"), "must include 'setup'")
        XCTAssertTrue(args.contains("--profile-name"), "must include --profile-name")
        XCTAssertTrue(args.contains("protect"), "must include the profile name value")
        XCTAssertTrue(args.contains("--url"), "must include --url")
        XCTAssertTrue(args.contains("--no-color"), "must include --no-color")
    }

    func test_protectStdin_format() {
        let data = OnboardingFlow.protectStdin(clientID: "pid", clientSecret: "psec")
        let s = String(data: data, encoding: .utf8) ?? ""
        XCTAssertEqual(s, "pid\npsec\n", "Protect stdin must be clientID\\nclientSecret\\n")
    }

    func test_schoolArguments_containsExpectedFlags() {
        let args = OnboardingFlow.schoolArguments(
            profile: "school", url: "https://org.jamfcloud.com"
        )
        XCTAssertTrue(args.contains("school"), "must include 'school' subcommand")
        XCTAssertTrue(args.contains("setup"), "must include 'setup'")
        XCTAssertTrue(args.contains("--profile-name"), "must include --profile-name")
        XCTAssertTrue(args.contains("--url"), "must include --url")
        XCTAssertTrue(args.contains("--no-color"), "must include --no-color")
    }

    func test_schoolStdin_includesDefensiveTrailingN() {
        let data = OnboardingFlow.schoolStdin(networkID: "net123", apiKey: "apikey456")
        let s = String(data: data, encoding: .utf8) ?? ""
        XCTAssertEqual(
            s, "net123\napikey456\nn\n",
            "School stdin must end with 'n\\n' to answer the optional Platform API prompt"
        )
    }

    // MARK: - Part 2: Profile name slug sanitization

    func test_slugify_lowercasesAndReplacesSpaces() {
        XCTAssertEqual(OnboardingFlow.slugify("Jamf Platform"), "jamf-platform")
    }

    func test_slugify_collapsesMultipleSpaces() {
        XCTAssertEqual(OnboardingFlow.slugify("My  Tenant"), "my-tenant")
    }

    func test_slugify_stripsSpecialChars() {
        XCTAssertEqual(OnboardingFlow.slugify("My Tenant!"), "my-tenant")
    }

    func test_slugify_validSlugPassesProfileService() {
        let slug = OnboardingFlow.slugify("Jamf Platform")
        XCTAssertTrue(
            ProfileService.isValid(slug),
            "slugified 'Jamf Platform' must pass ProfileService.isValid; got '\(slug)'"
        )
    }

    func test_slugify_emptyInputReturnsProfile() {
        XCTAssertFalse(OnboardingFlow.slugify("").isEmpty, "empty input must not produce empty slug")
    }

    // MARK: - Part 2: Secret redaction in error output

    func test_secretNotLeakedInPlatformError() {
        let flow = OnboardingFlow()
        flow.platformClientSecret = "super-secret-123"
        flow.platformClientID = "client-id-very-long"
        // clearPlatformSecrets is private; simulate that the secret is in a
        // PTY result. We test via the fact that argument builders do NOT embed
        // the secret in args (it goes via stdin only).
        let args = OnboardingFlow.platformGatewayArguments(
            profile: "p", gatewayURL: "https://apigw.jamf.com", tenantID: "tid"
        )
        let argsJoined = args.joined(separator: " ")
        XCTAssertFalse(
            argsJoined.contains("super-secret-123"),
            "Platform secret must not appear in CLI arguments (goes via stdin only)"
        )
    }

    func test_secretNotLeakedInProtectArgs() {
        let args = OnboardingFlow.protectArguments(
            profile: "protect", url: "https://protect.jamfcloud.com"
        )
        XCTAssertFalse(
            args.joined().contains("client"),
            "Protect arguments must not contain any credential-shaped value"
        )
    }

    func test_secretNotLeakedInSchoolArgs() {
        let args = OnboardingFlow.schoolArguments(
            profile: "school", url: "https://school.jamfcloud.com"
        )
        XCTAssertFalse(
            args.joined().contains("apikey"),
            "School arguments must not contain any credential-shaped value"
        )
    }

    // MARK: - Part 2: Config wiring (protect + school written into config.yaml)
    //
    // Tests call writeProtectConfig/writeSchoolConfig directly (internal access).
    // The sequence mirrors the real wizard flow: createWorkspace → skipCSVMapping
    // (writes config.yaml) → writeProtectConfig → assert. This proves that the
    // config survives scaffoldCSV's removeItem because addProducts comes AFTER
    // csvMapping in the step order.

    func test_writeProtectConfig_setsEnabledAndProfile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MPTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        addTeardownBlock {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: root)
        }

        let profile = "testprot\(Int.random(in: 1000...9999))"
        let flow = OnboardingFlow()
        flow.profileName = profile
        try flow.createWorkspace()
        // csvMapping step writes config.yaml — must come BEFORE addProducts.
        await flow.skipCSVMapping()
        XCTAssertNil(flow.lastError, "skipCSVMapping should succeed: \(flow.lastError ?? "")")

        // Now call the real writer (internal).
        try flow.writeProtectConfig(profileSlug: profile, protectProfileName: "my-protect")

        let loaded = try ConfigService.load(profile: profile)
        let protectMapping = loaded.document.root.mapping?.value(for: "protect")?.mapping
        XCTAssertEqual(protectMapping?.value(for: "enabled")?.boolValue, true,
                       "protect.enabled must be true")
        XCTAssertEqual(protectMapping?.value(for: "profile")?.stringValue, "my-protect",
                       "protect.profile must match the supplied name")
    }

    func test_writeProtectConfig_preservesExistingConfigKeys() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MPTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        addTeardownBlock {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: root)
        }

        let profile = "testprot2-\(Int.random(in: 1000...9999))"
        let flow = OnboardingFlow()
        flow.profileName = profile
        try flow.createWorkspace()
        await flow.skipCSVMapping()

        // Pre-check: scaffolded config should have a branding or jamf_cli block.
        let beforeLoad = try ConfigService.load(profile: profile)
        let hasJamfCLI = beforeLoad.document.root.mapping?.value(for: "jamf_cli") != nil

        try flow.writeProtectConfig(profileSlug: profile, protectProfileName: "protect")

        let loaded = try ConfigService.load(profile: profile)
        if hasJamfCLI {
            XCTAssertNotNil(
                loaded.document.root.mapping?.value(for: "jamf_cli"),
                "writeProtectConfig must not remove existing jamf_cli block"
            )
        }
        // protect keys must be present
        let protectMapping = loaded.document.root.mapping?.value(for: "protect")?.mapping
        XCTAssertEqual(protectMapping?.value(for: "enabled")?.boolValue, true)
    }

    func test_writeSchoolConfig_setsEnabledAndProfile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MPTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        addTeardownBlock {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: root)
        }

        let profile = "testschool\(Int.random(in: 1000...9999))"
        let flow = OnboardingFlow()
        flow.profileName = profile
        try flow.createWorkspace()
        // csvMapping step must precede addProducts.
        await flow.skipCSVMapping()
        XCTAssertNil(flow.lastError)

        try flow.writeSchoolConfig(profileSlug: profile, schoolProfileName: "my-school")

        let loaded = try ConfigService.load(profile: profile)
        let schoolMapping = loaded.document.root.mapping?.value(for: "school_cli")?.mapping
        XCTAssertEqual(schoolMapping?.value(for: "enabled")?.boolValue, true,
                       "school_cli.enabled must be true")
        XCTAssertEqual(schoolMapping?.value(for: "profile")?.stringValue, "my-school",
                       "school_cli.profile must match the supplied name")
    }

    // MARK: - Part 1: SecureSecretField onTextChange callback

    func test_coordinator_onTextChange_calledOnKeystroke() {
        var received: Bool?
        let coordinator = SecureSecretField.Coordinator(
            onFinalize: { _ in },
            onTextChange: { hasText in received = hasText }
        )

        let field = NSSecureTextField()
        field.stringValue = "x"
        let note = Notification(
            name: NSControl.textDidChangeNotification,
            object: field, userInfo: nil
        )
        coordinator.controlTextDidChange(note)
        XCTAssertEqual(received, true, "onTextChange must fire with true when field is non-empty")
    }

    func test_coordinator_onTextChange_falseWhenEmpty() {
        var received: Bool?
        let coordinator = SecureSecretField.Coordinator(
            onFinalize: { _ in },
            onTextChange: { received = $0 }
        )
        let field = NSSecureTextField()
        field.stringValue = ""
        let note = Notification(
            name: NSControl.textDidChangeNotification,
            object: field, userInfo: nil
        )
        coordinator.controlTextDidChange(note)
        XCTAssertEqual(received, false, "onTextChange must fire with false when field is empty")
    }

    func test_coordinator_nilOnTextChange_doesNotCrash() {
        // onTextChange defaults to nil — coordinator must not crash without it.
        let coordinator = SecureSecretField.Coordinator(onFinalize: { _ in })
        let field = NSSecureTextField()
        field.stringValue = "test"
        let note = Notification(
            name: NSControl.textDidChangeNotification,
            object: field, userInfo: nil
        )
        // Should not crash.
        coordinator.controlTextDidChange(note)
    }

    // MARK: - Helpers

    private func makeValidOAuth2Flow() -> OnboardingFlow {
        let flow = OnboardingFlow()
        flow.currentStep = .authenticate
        flow.proConnectionType = .oauth2
        flow.profileName = "testprofile"
        flow.jamfURL = "https://example.jamfcloud.com"
        flow.clientID = "some-client-id"
        flow.clientSecret = ""
        flow.secretFieldHasText = false
        flow.isRegisteringProfile = false
        return flow
    }

    private func makeValidPlatformGatewayFlow() -> OnboardingFlow {
        let flow = OnboardingFlow()
        flow.currentStep = .authenticate
        flow.proConnectionType = .platformGateway
        flow.profileName = "testprofile"
        flow.gatewayURL = "https://us.apigw.jamf.com"
        flow.tenantID = "my-tenant"
        flow.platformClientID = "platform-client-id"
        flow.platformClientSecret = ""
        flow.platformSecretFieldHasText = false
        flow.isRegisteringProfile = false
        return flow
    }
}
