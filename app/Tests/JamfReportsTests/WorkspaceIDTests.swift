import XCTest
@testable import JamfReports

/// A workspace's ID is the name its folder encodes, so every folder, label and file name a
/// workspace made before 2.12 has stays where it is.
final class WorkspaceIDTests: XCTestCase {

    func testRefusesTheNamesProfileServiceRefuses() {
        for name in ["", " lead", "trail ", "line\nbreak", String(repeating: "x", count: 200)] {
            XCTAssertNil(WorkspaceID(name), name)
        }
        XCTAssertEqual(WorkspaceID("Client A Prod")?.name, "Client A Prod")
    }

    func testFolderAndLabelPartsAreTheProfileNameEncodings() throws {
        for name in ["prod", ".hidden", "_lead", "a/b:c", "ß-tenant", "Acme Prod 50%"] {
            let id = try XCTUnwrap(WorkspaceID(name), name)
            XCTAssertEqual(id.pathComponent, ProfileName.pathComponent(name))
            XCTAssertEqual(id.labelComponent, ProfileName.labelComponent(name))
            XCTAssertEqual(ProfileName.name(fromPathComponent: id.pathComponent), name)
        }
    }

    func testWorkspaceURLIsTheFolderEveryExistingWorkspaceAlreadyHas() throws {
        let root = URL(fileURLWithPath: "/tmp/jrc-root", isDirectory: true)
        for name in ["prod", ".hidden", "a/b"] {
            let id = try XCTUnwrap(WorkspaceID(name))
            XCTAssertEqual(
                WorkspacePaths.workspaceURL(for: id, under: root),
                root.appendingPathComponent(ProfileName.pathComponent(name), isDirectory: true))
        }
        XCTAssertNil(ProfileService.workspaceURL(for: ""))
    }
}
