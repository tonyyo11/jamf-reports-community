import Foundation
import XCTest
@testable import JamfReports

// MARK: - OnboardingFlowRedactionTests
//
// Tests for secret-redaction and credential-clearing behavior in OnboardingFlow.
//
// SEAM GAP (documented, not worked around):
// `redactedCredentialOutput`, `platformRedactedOutput`, `protectRedactedOutput`, and
// `schoolRedactedOutput` are all `private` instance methods. `@testable import` exposes
// `internal` but NOT `private` — these four methods have no callable seam from the test
// target. Adding `internal` modifiers to them (or introducing an `internal` wrapper
// that delegates to the private ones) would create a testable seam without weakening
// the security model. Until that seam exists, the redaction logic is covered only at
// the integration boundary (an actual PTY run, which is not exercised here).
//
// What IS testable without source changes:
// 1. Clearing properties via `previousStep()` (the only caller of the `clear*` family
//    that is reachable without spawning a process).
// 2. The `set*` finalization methods, which are `func` (non-private) and prove the
//    round-trip through `Data` bytes.
// 3. The static stdin builders: confirm that the secret value appears as raw bytes in
//    the correct position, and that the argument lists contain NO secret value —
//    secrets route exclusively through stdin bytes and never through argv.
// 4. Metacharacter safety of the static stdin builders (the only output surface that
//    can be inspected without a PTY).
//
// All tests follow the @MainActor XCTestCase pattern from
// OnboardingFlowSignatureGateTests (Swift 6.1 compatible).

@MainActor
final class OnboardingFlowRedactionTests: XCTestCase {

    // MARK: - Clearing: OAuth2 (Pro) credentials

    /// After navigating backwards from the authenticate step, `clientSecret`
    /// must be emptied and `secretFieldHasText` must be false.
    func test_previousStep_fromAuthenticate_clearsOAuth2Secret() {
        let flow = OnboardingFlow()
        flow.currentStep = .authenticate
        flow.proConnectionType = .oauth2
        flow.clientSecret = "super-secret-oauth-value"
        flow.secretFieldHasText = true

        flow.previousStep()

        XCTAssertTrue(
            flow.clientSecret.isEmpty,
            "clientSecret must be empty after previousStep() from .authenticate"
        )
        XCTAssertFalse(
            flow.secretFieldHasText,
            "secretFieldHasText must be false after previousStep() from .authenticate"
        )
    }

    /// After navigating backwards from the authenticate step on Platform Gateway,
    /// `platformClientSecret` must be emptied and `platformSecretFieldHasText` false.
    func test_previousStep_fromAuthenticate_clearsPlatformSecret() {
        let flow = OnboardingFlow()
        flow.currentStep = .authenticate
        flow.proConnectionType = .platformGateway
        flow.platformClientSecret = "platform-secret-xyz"
        flow.platformSecretFieldHasText = true

        flow.previousStep()

        XCTAssertTrue(
            flow.platformClientSecret.isEmpty,
            "platformClientSecret must be empty after previousStep() from .authenticate"
        )
        XCTAssertFalse(
            flow.platformSecretFieldHasText,
            "platformSecretFieldHasText must be false after previousStep() from .authenticate"
        )
    }

    /// Navigating backwards from .authenticate clears both OAuth2 AND Platform secrets
    /// regardless of which flow type is active, since both may have been populated.
    func test_previousStep_fromAuthenticate_clearsBothFlowSecrets() {
        let flow = OnboardingFlow()
        flow.currentStep = .authenticate
        flow.clientSecret = "oauth-secret"
        flow.secretFieldHasText = true
        flow.platformClientSecret = "platform-secret"
        flow.platformSecretFieldHasText = true

        flow.previousStep()

        XCTAssertTrue(flow.clientSecret.isEmpty, "clientSecret must be cleared")
        XCTAssertFalse(flow.secretFieldHasText, "secretFieldHasText must be false")
        XCTAssertTrue(flow.platformClientSecret.isEmpty, "platformClientSecret must be cleared")
        XCTAssertFalse(flow.platformSecretFieldHasText, "platformSecretFieldHasText must be false")
    }

    // MARK: - Clearing: addProducts (Protect + School) credentials

    /// Navigating backwards from .addProducts clears the Protect secret and
    /// the School API key.
    func test_previousStep_fromAddProducts_clearsProductSecrets() {
        let flow = OnboardingFlow()
        flow.currentStep = .addProducts
        flow.protectClientSecret = "protect-secret-abc"
        flow.protectSecretFieldHasText = true
        flow.schoolAPIKey = "school-api-key-def"
        flow.schoolAPIKeyFieldHasText = true

        flow.previousStep()

        XCTAssertTrue(
            flow.protectClientSecret.isEmpty,
            "protectClientSecret must be empty after previousStep() from .addProducts"
        )
        XCTAssertFalse(
            flow.protectSecretFieldHasText,
            "protectSecretFieldHasText must be false after previousStep() from .addProducts"
        )
        XCTAssertTrue(
            flow.schoolAPIKey.isEmpty,
            "schoolAPIKey must be empty after previousStep() from .addProducts"
        )
        XCTAssertFalse(
            flow.schoolAPIKeyFieldHasText,
            "schoolAPIKeyFieldHasText must be false after previousStep() from .addProducts"
        )
    }

    // MARK: - setClientSecret / round-trip through Data

    /// `setClientSecret(_:)` converts UTF-8 bytes into the `clientSecret` property.
    func test_setClientSecret_roundTrip() {
        let flow = OnboardingFlow()
        let secret = "r0und-tr1p-secret!"
        let data = Data(secret.utf8)
        flow.setClientSecret(data)
        XCTAssertEqual(flow.clientSecret, secret, "setClientSecret must decode UTF-8 bytes faithfully")
    }

    /// `setPlatformClientSecret(_:)` converts UTF-8 bytes into `platformClientSecret`.
    func test_setPlatformClientSecret_roundTrip() {
        let flow = OnboardingFlow()
        let secret = "platform-r0und-tr1p"
        flow.setPlatformClientSecret(Data(secret.utf8))
        XCTAssertEqual(flow.platformClientSecret, secret)
    }

    /// `setProtectClientSecret(_:)` converts UTF-8 bytes into `protectClientSecret`.
    func test_setProtectClientSecret_roundTrip() {
        let flow = OnboardingFlow()
        let secret = "protect-s3cr3t"
        flow.setProtectClientSecret(Data(secret.utf8))
        XCTAssertEqual(flow.protectClientSecret, secret)
    }

    /// `setSchoolAPIKey(_:)` converts UTF-8 bytes into `schoolAPIKey`.
    func test_setSchoolAPIKey_roundTrip() {
        let flow = OnboardingFlow()
        let key = "school-4pi-k3y"
        flow.setSchoolAPIKey(Data(key.utf8))
        XCTAssertEqual(flow.schoolAPIKey, key)
    }

    // MARK: - stdin builders: secret appears in bytes, not in argv

    /// The OAuth2 secret appears in the stdin byte stream at the correct position
    /// (after the client ID) and does NOT appear in the argument list.
    func test_oAuth2_secretInStdin_notInArgv() {
        let secret = "my-oauth2-secret"
        let clientID = "my-client-id"
        let data = OnboardingFlow.proOAuth2Stdin(clientID: clientID, clientSecret: secret)
        let args = OnboardingFlow.proOAuth2Arguments(
            profile: "testprofile", url: "https://jamf.example.com"
        )

        // Secret must be present in stdin bytes.
        let stdin = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(
            stdin.contains(secret),
            "OAuth2 secret must be present in stdin bytes"
        )
        // Secret must NOT appear anywhere in argv.
        let argv = args.joined(separator: "\u{1F}")
        XCTAssertFalse(
            argv.contains(secret),
            "OAuth2 secret must not appear in argv; would be visible in ps output"
        )
    }

    /// The Platform Gateway secret appears in stdin bytes and not in argv.
    func test_platformGateway_secretInStdin_notInArgv() {
        let secret = "platform-secret-value"
        let clientID = "platform-client-id"
        let data = OnboardingFlow.platformGatewayStdin(clientID: clientID, clientSecret: secret)
        let args = OnboardingFlow.platformGatewayArguments(
            profile: "testprofile",
            gatewayURL: "https://us.apigw.jamf.com",
            tenantID: "tenant-abc"
        )

        let stdin = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(stdin.contains(secret), "Platform secret must be in stdin bytes")
        XCTAssertFalse(
            args.joined(separator: "\u{1F}").contains(secret),
            "Platform secret must not appear in argv"
        )
    }

    /// The Protect secret appears in stdin bytes and not in argv.
    func test_protect_secretInStdin_notInArgv() {
        let secret = "protect-client-secret"
        let data = OnboardingFlow.protectStdin(clientID: "protect-id", clientSecret: secret)
        let args = OnboardingFlow.protectArguments(
            profile: "protect-profile", url: "https://protect.jamfcloud.com"
        )

        let stdin = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(stdin.contains(secret), "Protect secret must be in stdin bytes")
        XCTAssertFalse(
            args.joined(separator: "\u{1F}").contains(secret),
            "Protect secret must not appear in argv"
        )
    }

    /// The School API key appears in stdin bytes and not in argv.
    func test_school_apiKeyInStdin_notInArgv() {
        let apiKey = "school-api-key-value"
        let data = OnboardingFlow.schoolStdin(networkID: "net-123", apiKey: apiKey)
        let args = OnboardingFlow.schoolArguments(
            profile: "school-profile", url: "https://school.jamfcloud.com"
        )

        let stdin = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(stdin.contains(apiKey), "School API key must be in stdin bytes")
        XCTAssertFalse(
            args.joined(separator: "\u{1F}").contains(apiKey),
            "School API key must not appear in argv"
        )
    }

    // MARK: - stdin builders: regex metacharacter safety in secret value

    /// A secret containing regex metacharacters must round-trip through the
    /// stdin byte builder without corruption or escaping.
    /// This matters because the redaction helpers call
    /// `replacingOccurrences(of:with:)` (literal, not regex), but a metacharacter-
    /// containing secret must still produce valid UTF-8 stdin bytes.
    func test_oAuth2Stdin_metacharacterSecret_roundTripsClean() {
        let metacharSecret = "s3cr3t.*+?[]{}()|^$\\"
        let data = OnboardingFlow.proOAuth2Stdin(clientID: "cid", clientSecret: metacharSecret)
        let stdin = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(
            stdin.contains(metacharSecret),
            "Metacharacter secret must appear verbatim in stdin bytes; got: \(stdin)"
        )
    }

    /// A Platform Gateway secret containing regex metacharacters round-trips cleanly.
    func test_platformGatewayStdin_metacharacterSecret_roundTripsClean() {
        let metacharSecret = "pl@t!f0rm.*+?[]"
        let data = OnboardingFlow.platformGatewayStdin(clientID: "cid", clientSecret: metacharSecret)
        let stdin = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(stdin.contains(metacharSecret))
    }

    /// A Protect secret containing regex metacharacters round-trips cleanly.
    func test_protectStdin_metacharacterSecret_roundTripsClean() {
        let metacharSecret = "pr0t3ct.[*+?|\\]"
        let data = OnboardingFlow.protectStdin(clientID: "cid", clientSecret: metacharSecret)
        let stdin = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(stdin.contains(metacharSecret))
    }

    /// A School API key containing regex metacharacters round-trips cleanly.
    func test_schoolStdin_metacharacterAPIKey_roundTripsClean() {
        let metacharKey = "sch00l-k3y.[*+?|\\]"
        let data = OnboardingFlow.schoolStdin(networkID: "net", apiKey: metacharKey)
        let stdin = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(stdin.contains(metacharKey))
    }

    // MARK: - stdin structure: delimiter bytes

    /// The OAuth2 stdin bytes must be structured as `clientID\nclientSecret\n`
    /// (0x0A delimiters, not CRLF). The term reader in jamf-cli uses LF.
    func test_oAuth2Stdin_structure_lfDelimiters() {
        let data = OnboardingFlow.proOAuth2Stdin(clientID: "id", clientSecret: "sec")
        let bytes = Array(data)
        // id\nsec\n = ['i','d',0x0A,'s','e','c',0x0A]
        XCTAssertEqual(bytes.filter { $0 == 0x0A }.count, 2, "Must have exactly two 0x0A bytes")
        XCTAssertFalse(data.contains(0x0D), "Must not contain 0x0D (CRLF not expected)")
    }

    /// The School stdin must end with `n\n` as the defensive Platform API prompt answer.
    func test_schoolStdin_endsWithDefensiveN() {
        let data = OnboardingFlow.schoolStdin(networkID: "net", apiKey: "key")
        let s = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(
            s.hasSuffix("n\n"),
            "School stdin must end with 'n\\n' to answer the optional Platform API prompt; got: \(s)"
        )
    }

    // MARK: - Clearing does not affect unrelated credential properties

    /// Navigating backwards from .authenticate must NOT touch Protect or School secrets.
    func test_previousStep_fromAuthenticate_doesNotClearProductSecrets() {
        let flow = OnboardingFlow()
        flow.currentStep = .authenticate
        flow.protectClientSecret = "protect-should-survive"
        flow.schoolAPIKey = "school-should-survive"

        flow.previousStep()

        XCTAssertEqual(
            flow.protectClientSecret, "protect-should-survive",
            "previousStep() from .authenticate must not clear protectClientSecret"
        )
        XCTAssertEqual(
            flow.schoolAPIKey, "school-should-survive",
            "previousStep() from .authenticate must not clear schoolAPIKey"
        )
    }

    /// Navigating backwards from .addProducts must NOT touch the OAuth2 or Platform secrets.
    func test_previousStep_fromAddProducts_doesNotClearProSecrets() {
        let flow = OnboardingFlow()
        flow.currentStep = .addProducts
        flow.clientSecret = "oauth2-should-survive"
        flow.platformClientSecret = "platform-should-survive"

        flow.previousStep()

        XCTAssertEqual(
            flow.clientSecret, "oauth2-should-survive",
            "previousStep() from .addProducts must not clear clientSecret"
        )
        XCTAssertEqual(
            flow.platformClientSecret, "platform-should-survive",
            "previousStep() from .addProducts must not clear platformClientSecret"
        )
    }

    // MARK: - URL validation: http:// URLs rejected before secret reaches PTY (S1 guard)

    /// isGatewayURLValid must reject http:// URLs so secrets never route to an
    /// unencrypted endpoint.
    func test_gatewayURL_httpScheme_isInvalid() {
        let flow = OnboardingFlow()
        flow.gatewayURL = "http://apigw.jamf.com"
        XCTAssertFalse(
            flow.isGatewayURLValid,
            "http:// gateway URL must be rejected (S1: TLS required before secret send)"
        )
    }

    /// isProtectURLValid must reject http:// URLs.
    func test_protectURL_httpScheme_isInvalid() {
        let flow = OnboardingFlow()
        flow.protectURL = "http://protect.jamfcloud.com"
        XCTAssertFalse(
            flow.isProtectURLValid,
            "http:// Protect URL must be rejected"
        )
    }

    /// isSchoolURLValid must reject http:// URLs.
    func test_schoolURL_httpScheme_isInvalid() {
        let flow = OnboardingFlow()
        flow.schoolURL = "http://school.jamfcloud.com"
        XCTAssertFalse(
            flow.isSchoolURLValid,
            "http:// School URL must be rejected"
        )
    }

    /// isGatewayURLValid must accept https:// URLs.
    func test_gatewayURL_httpsScheme_isValid() {
        let flow = OnboardingFlow()
        flow.gatewayURL = "https://us.apigw.jamf.com"
        XCTAssertTrue(flow.isGatewayURLValid)
    }

    /// isProtectURLValid must accept https:// URLs.
    func test_protectURL_httpsScheme_isValid() {
        let flow = OnboardingFlow()
        flow.protectURL = "https://org.protect.jamfcloud.com"
        XCTAssertTrue(flow.isProtectURLValid)
    }

    /// isSchoolURLValid must accept https:// URLs.
    func test_schoolURL_httpsScheme_isValid() {
        let flow = OnboardingFlow()
        flow.schoolURL = "https://org.jamfcloud.com"
        XCTAssertTrue(flow.isSchoolURLValid)
    }
}
