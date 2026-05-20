import XCTest
@testable import JamfReports

/// Tests for the B-07 codesign gate in OnboardingFlow.registerJamfCLIProfile.
///
/// Exercises the three scenarios flagged in the Codex GPT-5.5 security review:
/// 1. reject-untrusted: enforcement on, verifier returns false → FlowError thrown
/// 2. enforcement-disabled: enforce=false → no throw, verifier not called
/// 3. redacted output: failure message must not leak the team ID value
///
/// Tests target `verifyJamfCLISignatureGate(binary:enforce:expectedTeamID:verify:)`
/// directly — the seam added to make the gate testable without spawning a PTY or
/// requiring a live signed binary.
@MainActor
final class OnboardingFlowSignatureGateTests: XCTestCase {

    // Shared dummy binary URL — the verifier closure is stubbed, so the file
    // doesn't need to exist.
    private let dummyBinary = URL(fileURLWithPath: "/tmp/fake-jamf-cli")

    // MARK: - reject-untrusted

    /// When enforcement is active and the verifier returns false, the gate must
    /// throw FlowError.processFailed with a generic, non-sensitive message.
    func test_rejectUntrusted_throwsWhenVerifierReturnsFalse() throws {
        let flow = OnboardingFlow()

        XCTAssertThrowsError(
            try flow.verifyJamfCLISignatureGate(
                binary: dummyBinary,
                enforce: true,
                expectedTeamID: "483DWKW443",
                verify: { _, _ in false }
            )
        ) { error in
            guard let flowError = error as? OnboardingFlow.FlowError else {
                XCTFail("Expected FlowError, got \(type(of: error))")
                return
            }
            guard case .processFailed(let message) = flowError else {
                XCTFail("Expected processFailed, got \(flowError)")
                return
            }
            XCTAssertTrue(
                message.contains("signature verification failed"),
                "Error message must describe the failure; got: \(message)"
            )
        }
    }

    /// When enforcement is active but expectedTeamID is nil, the gate must throw
    /// rather than silently skipping — nil team ID with enforce=true is a
    /// misconfiguration, not a skip path.
    func test_rejectUntrusted_throwsWhenTeamIDIsNil() throws {
        let flow = OnboardingFlow()
        var verifierCalled = false

        XCTAssertThrowsError(
            try flow.verifyJamfCLISignatureGate(
                binary: dummyBinary,
                enforce: true,
                expectedTeamID: nil,
                verify: { _, _ in
                    verifierCalled = true
                    return true
                }
            )
        )
        XCTAssertFalse(verifierCalled, "Verifier must not be called when teamID is nil")
    }

    // MARK: - enforcement-disabled

    /// When enforce=false the gate must not call the verifier and must not throw.
    func test_enforcementDisabled_doesNotCallVerifierAndDoesNotThrow() throws {
        let flow = OnboardingFlow()
        var verifierCallCount = 0

        XCTAssertNoThrow(
            try flow.verifyJamfCLISignatureGate(
                binary: dummyBinary,
                enforce: false,
                expectedTeamID: "483DWKW443",
                verify: { _, _ in
                    verifierCallCount += 1
                    return false  // Would fail if reached
                }
            )
        )
        XCTAssertEqual(
            verifierCallCount, 0,
            "Verifier must not be invoked when enforcement is disabled"
        )
    }

    /// When enforce=false and teamID is nil the gate must still not throw —
    /// the skip path is the same regardless of team ID presence.
    func test_enforcementDisabled_nilTeamIDDoesNotThrow() throws {
        let flow = OnboardingFlow()

        XCTAssertNoThrow(
            try flow.verifyJamfCLISignatureGate(
                binary: dummyBinary,
                enforce: false,
                expectedTeamID: nil,
                verify: { _, _ in false }
            )
        )
    }

    // MARK: - redacted output

    /// The error message surfaced to the user must not contain the raw team ID
    /// value. The message is a hardcoded generic string; the team ID must stay
    /// internal to the gate's log output only, never leaked to the UI.
    func test_redactedOutput_errorMessageDoesNotLeakTeamID() throws {
        let flow = OnboardingFlow()
        let sensitiveTeamID = "SENSITIVE-TEAM-ID-123"

        var capturedMessage: String?
        XCTAssertThrowsError(
            try flow.verifyJamfCLISignatureGate(
                binary: dummyBinary,
                enforce: true,
                expectedTeamID: sensitiveTeamID,
                verify: { _, _ in false }
            )
        ) { error in
            if let flowError = error as? OnboardingFlow.FlowError,
               case .processFailed(let message) = flowError {
                capturedMessage = message
            }
        }

        let message = try XCTUnwrap(capturedMessage, "Expected a processFailed error")
        XCTAssertFalse(
            message.contains(sensitiveTeamID),
            "Error message must not contain the raw team ID; got: \(message)"
        )
        XCTAssertFalse(
            message.contains("SENSITIVE"),
            "Error message must not contain any fragment of the team ID; got: \(message)"
        )
    }

    /// Passing a failure message with a simulated sensitive token through the
    /// verify closure must not cause that token to appear in the thrown error —
    /// confirming the gate always throws its own generic string, not verifier output.
    func test_redactedOutput_genericMessageIsIndependentOfVerifierOutput() throws {
        let flow = OnboardingFlow()

        // The verifier is a black box; whatever "internal" string it might
        // associate with failure must not leak. The gate synthesizes its own message.
        var capturedMessage: String?
        XCTAssertThrowsError(
            try flow.verifyJamfCLISignatureGate(
                binary: dummyBinary,
                enforce: true,
                expectedTeamID: "AnyTeamID",
                verify: { _, _ in false }
            )
        ) { error in
            if let flowError = error as? OnboardingFlow.FlowError,
               case .processFailed(let message) = flowError {
                capturedMessage = message
            }
        }

        let message = try XCTUnwrap(capturedMessage)
        // The exact wording is hardcoded in the gate — assert it matches the
        // documented generic string so a future edit can't silently interpolate
        // dynamic values into it.
        XCTAssertEqual(
            message,
            "jamf-cli signature verification failed — binary may be untrusted",
            "Error message must be the hardcoded generic string, not interpolated"
        )
    }
}
