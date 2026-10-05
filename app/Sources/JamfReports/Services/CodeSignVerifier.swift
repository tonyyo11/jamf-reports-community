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
    /// the signing identity without executing the binary. The value is what the code
    /// directory claims, so it is never a trust decision; `verify(url:expectedTeamID:)` is.
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

    /// Returns `true` if the binary at `url` is validly signed by a Developer ID or Apple
    /// certificate chain whose leaf belongs to `expectedTeamID`.
    ///
    /// Checks the signature against a code requirement rather than comparing the Team ID
    /// read from the code directory: an ad-hoc signature can carry any Team ID string
    /// (`codesign --team-identifier`), but it cannot satisfy `anchor apple generic` with
    /// the team's certificate as leaf.
    ///
    /// - Parameters:
    ///   - url: Absolute file URL of the binary to verify.
    ///   - expectedTeamID: The Team ID in the signing certificate's subject OU: ten
    ///     uppercase letters or digits. Anything else returns `false` without building a
    ///     requirement, so the value cannot add requirement syntax.
    /// - Returns: `true` if the binary satisfies the requirement, `false` otherwise.
    static func verify(url: URL, expectedTeamID: String) -> Bool {
        guard isWellFormedTeamID(expectedTeamID) else { return false }

        var requirement: SecRequirement?
        let requirementText =
            "anchor apple generic and certificate leaf[subject.OU] = \"\(expectedTeamID)\""
        let requirementStatus = SecRequirementCreateWithString(
            requirementText as CFString,
            SecCSFlags(rawValue: 0),
            &requirement
        )
        guard requirementStatus == errSecSuccess, let requirement else { return false }

        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(
            url as CFURL,
            SecCSFlags(rawValue: 0),
            &staticCode
        )
        guard createStatus == errSecSuccess, let code = staticCode else { return false }

        let validityStatus = SecStaticCodeCheckValidity(
            code,
            SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate),
            requirement
        )
        return validityStatus == errSecSuccess
    }

    /// Apple Team IDs are ten uppercase ASCII letters or digits.
    private static func isWellFormedTeamID(_ value: String) -> Bool {
        value.utf8.count == 10
            && value.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) }
    }
}
