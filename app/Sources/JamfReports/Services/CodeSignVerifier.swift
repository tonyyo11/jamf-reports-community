import Foundation
import Security

/// Verifies code signatures on external binaries before the app invokes them.
///
/// Used to validate that `jamf-cli` at a discovered path is signed by the expected
/// publisher before passing credentials to it via stdin. A malicious shim at a
/// user-writable Homebrew path (e.g. `/opt/homebrew/bin`) would otherwise receive
/// the Jamf API client secret.
///
/// Usage:
/// ```swift
/// guard CodeSignVerifier.verify(url: jamfCLIURL, expectedTeamID: JamfCLITeamID) else {
///     throw CLIBridgeError.untrustedJamfCLI(path: jamfCLIURL.path, teamID: nil)
/// }
/// ```
enum CodeSignVerifier {

    /// Returns the Team ID embedded in the code signature of the binary at `url`.
    ///
    /// Uses `SecStaticCodeCreateWithPath` + `SecCodeCopySigningInformation` to extract
    /// the signing identity without executing the binary.
    ///
    /// - Parameter url: Absolute file URL of the binary to inspect.
    /// - Returns: The Team ID string (e.g. `"9CKFZ3A4YR"`), or `nil` if the binary is
    ///   unsigned, the path does not exist, or signature extraction fails.
    static func teamID(of url: URL) -> String? {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(
            url as CFURL,
            SecCSFlags(rawValue: 0),
            &staticCode
        )
        guard createStatus == errSecSuccess, let code = staticCode else { return nil }

        var info: CFDictionary?
        let copyStatus = SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &info
        )
        guard copyStatus == errSecSuccess, let dict = info as? [String: Any] else { return nil }

        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Returns `true` if the binary at `url` has a valid signature issued by `expectedTeamID`.
    ///
    /// Performs both a static validity check (the binary has not been modified since
    /// signing) and a Team ID comparison. Both must pass.
    ///
    /// - Parameters:
    ///   - url: Absolute file URL of the binary to verify.
    ///   - expectedTeamID: The Team ID that must appear in the signing certificate chain.
    /// - Returns: `true` if the binary is validly signed by the expected team, `false` otherwise.
    static func verify(url: URL, expectedTeamID: String) -> Bool {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(
            url as CFURL,
            SecCSFlags(rawValue: 0),
            &staticCode
        )
        guard createStatus == errSecSuccess, let code = staticCode else { return false }

        // Verify the binary has not been modified since signing.
        let validityStatus = SecStaticCodeCheckValidity(
            code,
            SecCSFlags(rawValue: kSecCSCheckAllArchitectures),
            nil
        )
        guard validityStatus == errSecSuccess else { return false }

        guard let foundTeamID = teamID(of: url) else { return false }
        return foundTeamID == expectedTeamID
    }
}
