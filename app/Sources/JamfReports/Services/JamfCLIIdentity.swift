import Foundation

/// Pinned identity values used to verify the jamf-cli binary's code signature
/// before passing user-supplied OAuth credentials to it (P9-A-07 follow-up),
/// and before launching the binary on routine command paths (M-01 follow-up).
///
/// The Team ID is the 10-character developer team identifier embedded in
/// jamf-cli's signing certificate chain. It can be confirmed on a trusted
/// Mac with:
///
///     codesign -dv --verbose=4 $(which jamf-cli) 2>&1 | grep TeamIdentifier
///
/// MUST be filled in with the real Jamf Software, LLC Team ID before any
/// production release. Leaving the value `nil` here keeps the verification
/// hook advisory (logged but not enforced) so dev builds against an
/// unsigned local jamf-cli still work.
enum JamfCLIIdentity {

    /// Pinned Team ID for jamf-cli releases published by Jamf Software, LLC.
    ///
    /// Confirmed via: codesign -dv --verbose=4 $(which jamf-cli) 2>&1 | grep TeamIdentifier
    /// Signature verification is enforced as a hard gate in OnboardingFlow.registerJamfCLIProfile
    /// before OAuth credentials are written to the binary's stdin, and in
    /// `CLIBridge.run` / `runAndCapture` before each process is spawned on
    /// routine command paths.
    static let expectedTeamID: String? = "483DWKW443"

    /// Whether to enforce a successful signature check on jamf-cli before
    /// handing it OAuth credentials or invoking it for a command. Driven by
    /// `expectedTeamID` being set.
    static var enforceSignatureCheck: Bool { expectedTeamID != nil }

    // MARK: - Verified-fingerprint cache (M-01)
    //
    // Onboarding and JamfCLIInstaller verify the binary signature once,
    // but `CLIBridge.run` previously launched it on every routine command
    // (collect, audit, backup, …) without re-checking. On Homebrew installs
    // `/opt/homebrew/bin/` is user-writable; a post-onboarding swap would
    // receive credentials. The cache below lets us re-verify cheaply on
    // every spawn, short-circuiting when the binary's (path, size, mtime)
    // matches a previously-verified entry.

    /// Errors surfaced by `ensureVerifiedJamfCLI`. Distinct cases let the
    /// caller emit a precise user-facing diagnostic and let post-mortem
    /// log lines disambiguate failure modes.
    enum VerifyError: Error, Equatable {
        /// Codesign verifier returned `false`. Either the binary is
        /// unsigned, the signature is invalid, or the Team ID does not
        /// match the pinned `expectedTeamID`.
        case untrusted(path: String, teamID: String)
        /// `FileManager.attributesOfItem` failed — the file does not
        /// exist, is unreadable, or has no size/mtime attributes.
        case probeFailed(path: String)
    }

    /// Fingerprint stored in the verified-binary cache. Keyed on path,
    /// size, and modification time so any rewrite (homebrew upgrade,
    /// malicious swap, even a same-content `touch`) invalidates the
    /// cached approval.
    struct Fingerprint: Hashable {
        let path: String
        let size: Int64
        let mtime: TimeInterval
    }

    nonisolated(unsafe) private static var verifiedFingerprints: Set<Fingerprint> = []
    private static let cacheLock = NSLock()

    /// Verify the jamf-cli binary at `executable` if enforcement is
    /// active. Returns `.success` when the binary is trusted (either
    /// from cache or from a fresh verify), `.failure` otherwise. The
    /// `verify` closure is injected for testability; production code
    /// uses `CodeSignVerifier.verify(url:expectedTeamID:)`.
    ///
    /// Cache contract: a successful verify inserts the binary's
    /// `(path, size, mtime)` fingerprint into a process-local set. The
    /// next call with the same fingerprint short-circuits. A binary
    /// swap (different size) or a homebrew upgrade (different mtime)
    /// produces a different fingerprint and forces re-verification.
    /// Failed verifies are never cached.
    ///
    /// - Parameters:
    ///   - executable: Absolute file URL of the binary to verify.
    ///   - expectedTeamID: Override for `JamfCLIIdentity.expectedTeamID`.
    ///     `nil` disables the gate (returns `.success` immediately) —
    ///     used in unit tests and in dev builds without a pinned ID.
    ///   - verify: Closure performing the actual signature check.
    ///     Default delegates to `CodeSignVerifier`.
    static func ensureVerifiedJamfCLI(
        executable: URL,
        expectedTeamID: String? = JamfCLIIdentity.expectedTeamID,
        verify: @Sendable (URL, String) -> Bool = { url, teamID in
            CodeSignVerifier.verify(url: url, expectedTeamID: teamID)
        }
    ) -> Result<Void, VerifyError> {
        guard let teamID = expectedTeamID else {
            return .success(())
        }

        guard let fingerprint = makeFingerprint(executable: executable) else {
            return .failure(.probeFailed(path: executable.path))
        }

        if cacheContains(fingerprint) {
            return .success(())
        }

        guard verify(executable, teamID) else {
            return .failure(.untrusted(path: executable.path, teamID: teamID))
        }

        cacheInsert(fingerprint)
        return .success(())
    }

    /// Drop every cached fingerprint. Exposed for tests; not used in
    /// production. Calling between tests prevents one test's verifier
    /// stub from contaminating another.
    static func clearVerificationCacheForTesting() {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        verifiedFingerprints.removeAll()
    }

    // MARK: - Cache primitives

    private static func makeFingerprint(executable: URL) -> Fingerprint? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: executable.path) else {
            return nil
        }
        let size: Int64
        if let n = attrs[.size] as? Int64 {
            size = n
        } else if let n = attrs[.size] as? NSNumber {
            size = n.int64Value
        } else {
            return nil
        }
        guard let mtime = attrs[.modificationDate] as? Date else {
            return nil
        }
        return Fingerprint(path: executable.path, size: size, mtime: mtime.timeIntervalSinceReferenceDate)
    }

    private static func cacheContains(_ fp: Fingerprint) -> Bool {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return verifiedFingerprints.contains(fp)
    }

    private static func cacheInsert(_ fp: Fingerprint) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        verifiedFingerprints.insert(fp)
    }
}
