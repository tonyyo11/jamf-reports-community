import XCTest
@testable import JamfReports

/// The deny-list `output.allow_absolute_paths` cannot override. The volume is
/// case-insensitive by default and a peer-edited config.yaml can name a folder that
/// does not exist yet, so the check must not depend on either.
final class WorkspacePathsSensitiveTests: XCTestCase {

    private let home = NSString(string: "~").expandingTildeInPath

    private func sensitive(_ path: String) -> Bool {
        WorkspacePaths.isSensitiveAbsolutePath(URL(fileURLWithPath: path))
    }

    func testLibraryIsDeniedWhateverTheCaseAndEvenWhenTheLeafDoesNotExist() {
        for path in ["Library/LaunchAgents/jr", "library/LaunchAgents/new-dir",
                     "LIBRARY/launchagents", "Library/Application Support/Foo"] {
            XCTAssertTrue(sensitive("\(home)/\(path)"), path)
        }
    }

    func testDotEntriesDirectlyUnderHomeAreDenied() {
        for name in [".zshrc", ".zprofile", ".zshenv", ".bash_profile", ".netrc", ".gitconfig",
                     ".npmrc", ".docker/config.json", ".ssh", ".config/jr", ".brand-new-dir/x"] {
            XCTAssertTrue(sensitive("\(home)/\(name)"), name)
        }
    }

    func testTheCloudStorageMountPointStaysReachableInAnyCase() {
        for path in ["Library/CloudStorage/OneDrive-Contoso/Team/Reports",
                     "library/cloudstorage/OneDrive-Contoso/Team/Reports"] {
            XCTAssertFalse(sensitive("\(home)/\(path)"), path)
        }
    }

    func testTheCloudStorageCarveOutDoesNotReachBackIntoLibrary() {
        XCTAssertTrue(sensitive("\(home)/Library/CloudStorage/../LaunchAgents/jr"))
        XCTAssertTrue(sensitive("\(home)/Library/CloudStorage"))
    }

    func testApplicationsAndTheSystemFoldersAreDenied() {
        for path in ["/Applications/x", "/applications/x", "/System/x", "/Library/x", "/etc/x",
                     "/usr/local/x", "/private/etc/x", "/var/folders/x"] {
            XCTAssertTrue(sensitive(path), path)
        }
    }

    /// A workspace root under another dot-folder stays usable, so a root stored before this
    /// rule does not fall back to the default; the credential folders stay refused.
    func testAWorkspaceRootMayLiveInADotFolderButNotACredentialFolder() {
        func root(_ name: String) -> Bool {
            WorkspacePaths.isSensitiveAbsolutePath(
                URL(fileURLWithPath: "\(home)/\(name)"), workspaceRoot: true)
        }
        XCTAssertFalse(root(".jamf-reports"))
        XCTAssertFalse(root(".local/share/Jamf-Reports"))
        for name in [".ssh/x", ".config/jr", ".aws", ".gnupg", ".kube/x", "Library/x"] {
            XCTAssertTrue(root(name), name)
        }
    }

    func testOrdinaryFoldersUnderHomeAreAllowed() {
        for path in ["Documents/Reports", "Jamf-Reports/prod", "Desktop/new-folder/x"] {
            XCTAssertFalse(sensitive("\(home)/\(path)"), path)
        }
    }
}
