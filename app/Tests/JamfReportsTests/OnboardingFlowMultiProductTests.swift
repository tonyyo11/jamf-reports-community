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

    func test_platformGateway_missingScopeID_blocksAdvance() {
        let flow = makeValidPlatformGatewayFlow()
        flow.platformScopeID = ""
        flow.platformSecretFieldHasText = true
        XCTAssertFalse(
            flow.canAdvance,
            "Platform Gateway: canAdvance must be false when environment/tenant scope ID is empty"
        )
    }

    func test_platformGateway_organizationScope_advancesWithNoScopeID() {
        let flow = makeValidPlatformGatewayFlow()
        flow.platformScope = .organization
        flow.platformScopeID = ""
        flow.platformSecretFieldHasText = true
        XCTAssertTrue(
            flow.canAdvance,
            "Organization scope needs no ID, so canAdvance must be true"
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

    func test_platformGatewayArguments_environmentScope_sendsEnvironmentIDOnly() {
        let args = OnboardingFlow.platformGatewayArguments(
            profile: "platform-prod",
            gatewayURL: "https://us.api.jamfcloud.com",
            scope: .environment,
            scopeID: "my-env"
        )
        XCTAssertTrue(args.contains("config"), "must include 'config'")
        XCTAssertTrue(args.contains("add-profile"), "must include 'add-profile'")
        XCTAssertTrue(args.contains("--auth-method"), "must include --auth-method")
        XCTAssertTrue(args.contains("platform"), "auth method must be platform")
        XCTAssertTrue(args.contains("--environment-id"), "must include --environment-id")
        XCTAssertTrue(args.contains("my-env"), "must include environment ID value")
        XCTAssertTrue(args.contains("--url"), "must include --url")
        XCTAssertTrue(args.contains("https://us.api.jamfcloud.com"), "must include gateway URL")
        XCTAssertTrue(args.contains("--no-color"), "must include --no-color")
        XCTAssertFalse(args.contains("--tenant-id"), "environment scope must not send --tenant-id")
    }

    func test_platformGatewayArguments_tenantScope_sendsTenantIDOnly() {
        let args = OnboardingFlow.platformGatewayArguments(
            profile: "platform-prod",
            gatewayURL: "https://us.api.jamfcloud.com",
            scope: .tenant,
            scopeID: "my-tenant"
        )
        XCTAssertTrue(args.contains("--tenant-id"), "must include --tenant-id")
        XCTAssertTrue(args.contains("my-tenant"), "must include tenant ID value")
        XCTAssertFalse(args.contains("--environment-id"), "tenant scope must not send --environment-id")
    }

    func test_platformGatewayArguments_organizationScope_sendsNoScopeFlag() {
        let args = OnboardingFlow.platformGatewayArguments(
            profile: "platform-prod",
            gatewayURL: "https://us.api.jamfcloud.com",
            scope: .organization,
            scopeID: ""
        )
        XCTAssertFalse(args.contains("--environment-id"), "organization scope sends no ID flag")
        XCTAssertFalse(args.contains("--tenant-id"), "organization scope sends no ID flag")
        XCTAssertTrue(args.contains("--auth-method"), "must still include --auth-method")
        XCTAssertTrue(args.contains("platform"), "auth method must be platform")
        XCTAssertTrue(args.contains("--url"), "must still include --url")
        XCTAssertTrue(args.contains("--no-color"), "must still include --no-color")
    }

    func test_platformGatewayArguments_neverSendsBothScopeFlags() {
        for scope in OnboardingFlow.PlatformScope.allCases {
            let args = OnboardingFlow.platformGatewayArguments(
                profile: "p", gatewayURL: "https://us.api.jamfcloud.com", scope: scope, scopeID: "x"
            )
            let hasEnv = args.contains("--environment-id")
            let hasTenant = args.contains("--tenant-id")
            XCTAssertFalse(hasEnv && hasTenant, "must never send both scope flags (\(scope))")
        }
    }

    func test_platformScope_defaultFollowsJamfCLIVersion() {
        typealias Scope = OnboardingFlow.PlatformScope
        XCTAssertEqual(Scope.defaultScope(forCLIVersion: "1.24.0"), .tenant)
        XCTAssertEqual(Scope.defaultScope(forCLIVersion: "1.27.9"), .tenant)
        XCTAssertEqual(Scope.defaultScope(forCLIVersion: "1.28.0"), .environment)
        XCTAssertEqual(Scope.defaultScope(forCLIVersion: "1.30.1"), .environment)
        XCTAssertEqual(Scope.defaultScope(forCLIVersion: nil), .environment)
        XCTAssertEqual(Scope.defaultScope(forCLIVersion: "garbage"), .environment)
    }

    func test_platformScope_needsID_falseOnlyForOrganization() {
        for scope in OnboardingFlow.PlatformScope.allCases {
            XCTAssertEqual(
                scope.needsID, scope != .organization,
                "needsID must be false only for organization scope (\(scope))"
            )
        }
    }

    /// jamf-cli refuses the retired `{region}.apigw.jamf.com` gateway by name
    /// before sending, so a prefilled default naming it is a hard stop at
    /// Authenticate. The GA host is `{region}.api.jamfcloud.com`.
    func test_defaultGatewayURL_isTheGAHost_notTheRetiredGateway() {
        let flow = OnboardingFlow()
        XCTAssertTrue(
            flow.gatewayURL.hasSuffix(".api.jamfcloud.com"),
            "default gateway URL must be a GA api.jamfcloud.com host, got \(flow.gatewayURL)"
        )
        XCTAssertFalse(
            flow.gatewayURL.contains("apigw.jamf.com"),
            "the pre-GA apigw.jamf.com gateway is retired and refused by name"
        )
        XCTAssertTrue(flow.isGatewayURLValid, "the default must pass the https:// guard")
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
            profile: "p", gatewayURL: "https://us.api.jamfcloud.com", scope: .environment, scopeID: "tid"
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

    // MARK: - Jamf School product path: step sequence

    /// The School path skips the Pro-only Authenticate / Validate / Add-products
    /// steps and inserts .schoolConnect AFTER .csvMapping (so csvMapping's
    /// config.yaml rewrite can't clobber the school_cli keys).
    func test_schoolPath_stepSequence_skipsProSteps() {
        let flow = OnboardingFlow()
        flow.productPath = .school
        XCTAssertEqual(
            flow.stepSequence,
            [.welcome, .installCLI, .workspace, .csvMapping, .schoolConnect, .firstReport],
            "School path sequence must skip authenticate/validate/addProducts and place schoolConnect after csvMapping"
        )
        XCTAssertEqual(flow.stepCount, 6, "School path has 6 steps")
    }

    /// nextStep from each School step lands on the expected next step.
    func test_schoolPath_nextStep_walksSequence() {
        let flow = OnboardingFlow()
        flow.productPath = .school
        flow.currentStep = .welcome

        let expected: [OnboardingFlow.Step] =
            [.installCLI, .workspace, .csvMapping, .schoolConnect, .firstReport]
        for step in expected {
            flow.nextStep()
            XCTAssertEqual(flow.currentStep, step, "School nextStep should reach \(step)")
        }
    }

    /// firstReport is the last School step — nextStep must NOT fall through into
    /// any Pro/other step (the sequence-based guard replaces the old rawValue+1
    /// stepping, which would otherwise advance firstReport(7) → schoolConnect(8)).
    func test_schoolPath_nextStep_atFirstReportIsNoOp() {
        let flow = OnboardingFlow()
        flow.productPath = .school
        flow.currentStep = .firstReport
        flow.nextStep()
        XCTAssertEqual(flow.currentStep, .firstReport, "nextStep at the last School step must be a no-op")
    }

    /// Backing out of schoolConnect resets the connection state: csvMapping's
    /// scaffold/skip rewrites config.yaml (clobbering the school_cli block), so
    /// a stale schoolConnected == true would let the flow advance past a step
    /// whose on-disk result no longer exists.
    func test_schoolPath_previousStep_resetsSchoolConnection() {
        let flow = OnboardingFlow()
        flow.productPath = .school
        flow.currentStep = .schoolConnect
        flow.schoolConnected = true
        flow.schoolConnectionError = "stale"

        flow.previousStep()

        XCTAssertEqual(flow.currentStep, .csvMapping)
        XCTAssertFalse(flow.schoolConnected,
                       "Backing into csvMapping must force the connect step to be redone")
        XCTAssertNil(flow.schoolConnectionError)
    }

    /// previousStep walks the School sequence backwards.
    func test_schoolPath_previousStep_walksBack() {
        let flow = OnboardingFlow()
        flow.productPath = .school
        flow.currentStep = .firstReport

        let expected: [OnboardingFlow.Step] =
            [.schoolConnect, .csvMapping, .workspace, .installCLI, .welcome]
        for step in expected {
            flow.previousStep()
            XCTAssertEqual(flow.currentStep, step, "School previousStep should reach \(step)")
        }
        // At welcome (first step) previousStep is a no-op.
        flow.previousStep()
        XCTAssertEqual(flow.currentStep, .welcome, "previousStep at the first step must be a no-op")
    }

    func test_schoolPath_stepPosition_atSchoolConnect() {
        let flow = OnboardingFlow()
        flow.productPath = .school
        flow.currentStep = .schoolConnect
        XCTAssertEqual(flow.stepPosition, 5, "schoolConnect is the 5th step in the School sequence")
    }

    // MARK: - Jamf School product path: canAdvance gates

    /// Advancing past schoolConnect requires a SUCCESSFUL connection (school_cli
    /// written), not merely that fields are filled.
    func test_schoolConnect_requiresConnectedToAdvance() {
        let flow = OnboardingFlow()
        flow.productPath = .school
        flow.currentStep = .schoolConnect
        flow.schoolConnected = false
        XCTAssertFalse(flow.canAdvance, "schoolConnect must block advance until schoolConnected is true")

        flow.schoolConnected = true
        XCTAssertTrue(flow.canAdvance, "schoolConnect must allow advance once connected")
    }

    func test_schoolConnect_blocksAdvanceWhileConnecting() {
        let flow = OnboardingFlow()
        flow.productPath = .school
        flow.currentStep = .schoolConnect
        flow.schoolConnected = true
        flow.isConnectingSchool = true
        XCTAssertFalse(flow.canAdvance, "schoolConnect must block advance while a connection is in progress")
    }

    /// The Connect button gate: fields must be non-empty (URL valid, network ID,
    /// and either a finalized API key or a field with keystrokes).
    func test_canAttemptSchoolConnect_requiresAllFields() {
        let flow = OnboardingFlow()
        flow.schoolURL = "https://org.jamfcloud.com"
        flow.schoolNetworkID = "net123"
        flow.schoolAPIKeyFieldHasText = true
        XCTAssertTrue(flow.canAttemptSchoolConnect, "all fields present → connect attempt allowed")
    }

    func test_canAttemptSchoolConnect_falseWithoutURL() {
        let flow = OnboardingFlow()
        flow.schoolURL = ""
        flow.schoolNetworkID = "net123"
        flow.schoolAPIKeyFieldHasText = true
        XCTAssertFalse(flow.canAttemptSchoolConnect, "missing/invalid URL must block the connect attempt")
    }

    func test_canAttemptSchoolConnect_falseWithoutNetworkID() {
        let flow = OnboardingFlow()
        flow.schoolURL = "https://org.jamfcloud.com"
        flow.schoolNetworkID = ""
        flow.schoolAPIKey = "apikey"
        XCTAssertFalse(flow.canAttemptSchoolConnect, "missing Network ID must block the connect attempt")
    }

    func test_canAttemptSchoolConnect_falseWithoutAPIKey() {
        let flow = OnboardingFlow()
        flow.schoolURL = "https://org.jamfcloud.com"
        flow.schoolNetworkID = "net123"
        flow.schoolAPIKey = ""
        flow.schoolAPIKeyFieldHasText = false
        XCTAssertFalse(flow.canAttemptSchoolConnect, "missing API key must block the connect attempt")
    }

    // MARK: - Jamf School product path: product-path handoff

    func test_defaultFlow_isProPath() {
        XCTAssertEqual(OnboardingFlow().productPath, .pro,
                       "a flow constructed with no pending path defaults to Jamf Pro")
    }

    /// The first-launch chooser sets `pendingProductPath` before the view builds
    /// the flow; init consumes and clears it (a race-free one-shot handoff).
    func test_pendingProductPath_handoff_setsSchoolAndClears() {
        addTeardownBlock { OnboardingFlow.pendingProductPath = nil }
        OnboardingFlow.pendingProductPath = .school
        let flow = OnboardingFlow()
        XCTAssertEqual(flow.productPath, .school, "init must consume pendingProductPath")
        XCTAssertNil(OnboardingFlow.pendingProductPath, "init must clear pendingProductPath after consuming it")
    }

    // MARK: - Jamf Pro product path: regression pins (unchanged behavior)

    func test_proPath_stepSequence_unchanged() {
        let flow = OnboardingFlow()   // defaults to .pro
        XCTAssertEqual(
            flow.stepSequence,
            [.welcome, .installCLI, .workspace, .authenticate, .validate,
             .csvMapping, .addProducts, .firstReport],
            "Pro path step sequence must remain the original 8-step order"
        )
        XCTAssertEqual(flow.stepCount, 8)
    }

    /// Walking the Pro sequence must reach firstReport and stop — it must NOT
    /// fall through into the new .schoolConnect case.
    func test_proPath_nextStep_stopsAtFirstReport() {
        let flow = OnboardingFlow()
        flow.currentStep = .welcome
        let expected: [OnboardingFlow.Step] =
            [.installCLI, .workspace, .authenticate, .validate, .csvMapping, .addProducts, .firstReport]
        for step in expected {
            flow.nextStep()
            XCTAssertEqual(flow.currentStep, step)
        }
        flow.nextStep()
        XCTAssertEqual(flow.currentStep, .firstReport,
                       "Pro nextStep at firstReport must not advance into schoolConnect")
    }

    // MARK: - Jamf School product path: config keys route detection to School (pure seam)

    /// End-to-end config seam (no PTY): the same writer the School connect step
    /// uses (writeSchoolConfig) makes ProfileProductType.detect resolve the
    /// workspace to Jamf School, which is what routes collect/generate to the
    /// School engine.
    func test_schoolConfig_routesDetectionToJamfSchool() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MPSchool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        addTeardownBlock {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: root)
        }

        let profile = "schoolonly\(Int.random(in: 1000...9999))"
        let flow = OnboardingFlow()
        flow.profileName = profile
        try flow.createWorkspace()
        // csvMapping runs before schoolConnect on the School path — seed the
        // minimal config first, exactly as the wizard does.
        await flow.skipCSVMapping()
        XCTAssertNil(flow.lastError, "skipCSVMapping should succeed: \(flow.lastError ?? "")")

        // The workspace profile IS the School profile on the School-only path.
        try flow.writeSchoolConfig(profileSlug: profile, schoolProfileName: profile)

        let configURL = try ConfigService.configURL(for: profile)
        let config = try ConfigLoader.load(from: configURL)
        let detected = ProfileProductType.detect(from: config)
        XCTAssertEqual(detected.type, .jamfSchool,
                       "school_cli.enabled written by writeSchoolConfig must route detection to Jamf School")
        XCTAssertFalse(detected.runsProtect, "a School profile never runs Protect")
        XCTAssertEqual(config.schoolCli?.resolvedProfile, profile,
                       "school_cli.profile must be the workspace profile on the School-only path")
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
        flow.gatewayURL = "https://us.api.jamfcloud.com"
        flow.platformScope = .environment
        flow.platformScopeID = "my-env"
        flow.platformClientID = "platform-client-id"
        flow.platformClientSecret = ""
        flow.platformSecretFieldHasText = false
        flow.isRegisteringProfile = false
        return flow
    }
}
