import Foundation

/// Pinned identity values used to verify the jamf-cli binary's code signature
/// before passing user-supplied OAuth credentials to it (P9-A-07 follow-up).
///
/// The Team ID is the 10-character developer team identifier embedded in
/// jamf-cli's signing certificate chain. It can be confirmed on a trusted
/// Mac with:
///
///     codesign -dv --verbose=4 $(which jamf-cli) 2>&1 | grep TeamIdentifier
///
/// MUST be filled in with the real Jamf Software, LLC Team ID before any
/// production release. Leaving the value `nil` here keeps the verification
/// hook in `OnboardingFlow.registerJamfCLIProfile` advisory (logged but not
/// enforced) so dev builds against an unsigned local jamf-cli still work.
enum JamfCLIIdentity {

    /// Pinned Team ID for jamf-cli releases published by Jamf Software, LLC.
    ///
    /// TODO(release): replace `nil` with the real value (10 alphanumeric chars)
    /// before the first signed/notarized release. Once set, signature
    /// verification becomes a hard gate on credential passing.
    static let expectedTeamID: String? = nil

    /// Whether to enforce a successful signature check on jamf-cli before
    /// handing it OAuth credentials. Driven by `expectedTeamID` being set.
    static var enforceSignatureCheck: Bool { expectedTeamID != nil }
}
