import Foundation
import XCTest
@testable import JamfReports

/// The Reports screen lists, and Finder actions open, the folder `output.output_dir` names:
/// the one `WorkspacePaths.reportsDir` hands the writers.
final class ReportsFolderFollowsOutputDirTests: XCTestCase {

    private let profile = "teamfolder"
    private let fm = FileManager.default

    private struct Layout {
        let workspace: URL
        let published: URL
        let elsewhere: URL
    }

    // MARK: - ReportLibrary

    func testTheLibraryListsTheFolderOutputDirNames() throws {
        let layout = try makeLayout { published in
            "output:\n  output_dir: \"\(published.path)\"\n  allow_absolute_paths: true\n"
        }
        try touch(layout.published, "report_published.html")
        try touch(layout.workspace.appendingPathComponent("Generated Reports"), "report_local.html")

        let library = ReportLibrary()
        XCTAssertEqual(library.list(profile: profile).map(\.name), ["report_published.html"])
        XCTAssertNotNil(library.url(profile: profile, reportName: "report_published.html"))
        XCTAssertNil(library.url(profile: profile, reportName: "report_local.html"))
        XCTAssertEqual(library.stats(profile: profile).count, 1)
    }

    func testTheLibraryFollowsTheWritersFallbackWithoutTheOptIn() throws {
        let layout = try makeLayout { published in
            "output:\n  output_dir: \"\(published.path)\"\n"
        }
        try touch(layout.published, "report_published.html")
        try touch(layout.workspace.appendingPathComponent("Generated Reports"), "report_local.html")

        XCTAssertEqual(ReportLibrary().list(profile: profile).map(\.name), ["report_local.html"])
    }

    func testTheLibraryFollowsTheWritersFallbackForASystemFolder() throws {
        _ = try makeLayout { _ in
            "output:\n  output_dir: \"/etc/jrc-reports\"\n  allow_absolute_paths: true\n"
        }
        let local = try XCTUnwrap(ProfileService.workspaceURL(for: profile))
            .appendingPathComponent("Generated Reports")
        try touch(local, "report_local.html")

        XCTAssertEqual(ReportLibrary().list(profile: profile).map(\.name), ["report_local.html"])
    }

    func testTheDefaultLayoutStillListsGeneratedReports() throws {
        let layout = try makeLayout { _ in "" }
        try touch(layout.workspace.appendingPathComponent("Generated Reports"), "report_local.html")

        XCTAssertEqual(ReportLibrary().list(profile: profile).map(\.name), ["report_local.html"])
    }

    func testTheArchiveBesideAPublishedFolderIsListedAndCounted() throws {
        let layout = try makeLayout { published in
            "output:\n  output_dir: \"\(published.path)\"\n  allow_absolute_paths: true\n"
        }
        try touch(layout.published, "report_new.html")
        try touch(layout.published.appendingPathComponent("archive"), "report_old.html")

        let library = ReportLibrary()
        XCTAssertEqual(Set(library.list(profile: profile).map(\.name)),
                       ["report_new.html", "report_old.html"])
        XCTAssertEqual(library.stats(profile: profile).archivedCount, 1)
    }

    func testASymlinkOutOfThePublishedFolderIsNotListed() throws {
        let layout = try makeLayout { published in
            "output:\n  output_dir: \"\(published.path)\"\n  allow_absolute_paths: true\n"
        }
        try touch(layout.published, "report_published.html")
        try touch(layout.elsewhere, "secret.html")
        try fm.createSymbolicLink(
            at: layout.published.appendingPathComponent("leak.html"),
            withDestinationURL: layout.elsewhere.appendingPathComponent("secret.html"))

        XCTAssertEqual(ReportLibrary().list(profile: profile).map(\.name),
                       ["report_published.html"])
    }

    func testAGeneratedReportsSymlinkOutOfTheWorkspaceListsNothing() throws {
        let layout = try makeLayout { _ in "" }
        try touch(layout.elsewhere, "secret.html")
        try fm.createSymbolicLink(
            at: layout.workspace.appendingPathComponent("Generated Reports"),
            withDestinationURL: layout.elsewhere)

        XCTAssertNil(WorkspacePaths.readableReportsDir(for: profile))
        XCTAssertEqual(ReportLibrary().list(profile: profile).count, 0)
    }

    // MARK: - SystemActions

    func testARevealInsideTheResolvedFolderIsAllowedForItsProfileOnly() throws {
        let layout = try makeLayout { published in
            "output:\n  output_dir: \"\(published.path)\"\n  allow_absolute_paths: true\n"
        }
        let report = layout.published.appendingPathComponent("report.xlsx")

        XCTAssertTrue(SystemActions.isURLAllowed(report, profile: profile))
        XCTAssertTrue(SystemActions.isURLAllowed(layout.published, profile: profile))
        XCTAssertFalse(SystemActions.isURLAllowed(report), "no profile, no extra folder")
        XCTAssertFalse(SystemActions.isURLAllowed(report, profile: "another-profile"))
    }

    func testASiblingFolderWithTheSamePrefixIsRefused() throws {
        let layout = try makeLayout { published in
            "output:\n  output_dir: \"\(published.path)\"\n  allow_absolute_paths: true\n"
        }
        let sibling = layout.published.deletingLastPathComponent()
            .appendingPathComponent(layout.published.lastPathComponent + "2")

        XCTAssertFalse(SystemActions.isURLAllowed(
            sibling.appendingPathComponent("report.xlsx"), profile: profile))
        XCTAssertFalse(SystemActions.isURLAllowed(sibling, profile: profile))
    }

    func testASystemFolderTypedAsOutputDirIsStillRefused() throws {
        _ = try makeLayout { _ in
            "output:\n  output_dir: \"/etc\"\n  allow_absolute_paths: true\n"
        }

        XCTAssertFalse(SystemActions.isURLAllowed(
            URL(fileURLWithPath: "/etc/hosts"), profile: profile))
        XCTAssertFalse(SystemActions.isURLAllowed(
            URL(fileURLWithPath: "/etc"), profile: profile))
    }

    func testAFolderOutsideTheWorkspaceNeedsTheOptIn() throws {
        let layout = try makeLayout { published in
            "output:\n  output_dir: \"\(published.path)\"\n"
        }

        XCTAssertFalse(SystemActions.isURLAllowed(
            layout.published.appendingPathComponent("report.xlsx"), profile: profile))
    }

    func testASymlinkOutOfTheResolvedFolderIsRefused() throws {
        let layout = try makeLayout { published in
            "output:\n  output_dir: \"\(published.path)\"\n  allow_absolute_paths: true\n"
        }
        try touch(layout.elsewhere, "secret.html")
        let link = layout.published.appendingPathComponent("leak", isDirectory: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: layout.elsewhere)

        XCTAssertFalse(SystemActions.isURLAllowed(
            link.appendingPathComponent("secret.html"), profile: profile))
    }

    // MARK: - Header path

    func testTheHeaderNamesTheFolderUnderTheWorkspaceAsItAlwaysDid() throws {
        let layout = try makeLayout { _ in "" }
        let folder = layout.workspace.appendingPathComponent("Generated Reports")

        XCTAssertEqual(
            WorkspaceRootStore.displayPath(of: folder, profile: profile),
            WorkspaceRootStore.displayPath(profile: profile, subpath: "Generated Reports"))
    }

    func testTheHeaderNamesAFolderOutsideTheWorkspaceByItsOwnPath() throws {
        let layout = try makeLayout { _ in "" }

        XCTAssertEqual(
            WorkspaceRootStore.displayPath(of: layout.published, profile: profile),
            "~/" + layout.published.lastPathComponent)
    }

    // MARK: - Helpers

    /// A workspaces root, a published folder and a third folder, all under the home folder:
    /// the temp folder resolves under /private, which the path rules refuse even with the
    /// opt-in. Hidden and removed at teardown, like `OutputDirResolutionTests`.
    private func makeLayout(config: (URL) -> String) throws -> Layout {
        let home = fm.homeDirectoryForCurrentUser
        let token = UUID().uuidString
        let root = home.appendingPathComponent(".jrc-test-reports-root-\(token)")
        let published = home.appendingPathComponent(".jrc-test-reports-published-\(token)")
        let elsewhere = home.appendingPathComponent(".jrc-test-reports-elsewhere-\(token)")
        let workspace = root.appendingPathComponent(profile, isDirectory: true)
        for dir in [workspace, published, elsewhere] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try config(published).write(
            to: workspace.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)

        let saved = ProcessInfo.processInfo.environment["JRC_TEST_WORKSPACES_ROOT"]
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        addTeardownBlock {
            if let saved { setenv("JRC_TEST_WORKSPACES_ROOT", saved, 1) }
            else { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
            for dir in [root, published, elsewhere] { try? FileManager.default.removeItem(at: dir) }
        }
        return Layout(
            workspace: workspace.resolvingSymlinksInPath().standardizedFileURL,
            published: published.resolvingSymlinksInPath().standardizedFileURL,
            elsewhere: elsewhere.resolvingSymlinksInPath().standardizedFileURL)
    }

    private func touch(_ directory: URL, _ name: String) throws {
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("<html></html>".utf8).write(to: directory.appendingPathComponent(name))
    }
}
