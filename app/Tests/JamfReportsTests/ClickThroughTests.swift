import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import JamfReports

/// The shared pieces behind clickable tiles, toast buttons and the navigation guard (2.12).
@MainActor
final class ClickThroughTests: XCTestCase {

    func testNavigationLandsOnlyOnAScreenTheSidebarShows() {
        let school = TabVisibility().limited(to: SchoolWorkspaceTests.env(.jamfSchool))
        XCTAssertEqual(school.navigationRefusal(to: .audit),
                       "\(Tab.audit.label) is not available for this workspace")
        XCTAssertNil(school.navigationRefusal(to: .schoolDevices))

        let hidden = TabVisibility(hidden: [.patch]).limited(to: SchoolWorkspaceTests.fullPro)
        XCTAssertEqual(hidden.navigationRefusal(to: .patch),
                       "\(Tab.patch.label) is hidden; show it in Settings › Sidebar Visibility")
        XCTAssertNil(hidden.navigationRefusal(to: .devices))
        // A core tab can never be hidden, so a jump to it always lands.
        XCTAssertNil(TabVisibility(hidden: [.overview]).navigationRefusal(to: .overview))
    }

    func testWarningsToastOpensTheScreenItNames() {
        let history = WorkspaceStore.collectCompletedToast(
            "done", incomplete: true, warningsAt: .runHistory)
        XCTAssertEqual(history.action, .runHistory)
        XCTAssertEqual(history.action?.navigation, ["tab": Tab.runs.rawValue])
        let logging = WorkspaceStore.collectCompletedToast(
            "done", incomplete: true, warningsAt: .settingsLogging)
        XCTAssertEqual(logging.action, .settings)
        XCTAssertNil(WorkspaceStore.collectCompletedToast(
            "done", incomplete: false, warningsAt: .runHistory).action)
    }

    func testFailureToastsOfferTheFix() {
        XCTAssertEqual(WorkspaceStore.firstCollectToast(
            exitCode: CLIBridge.exitCodeUnauthorized).action, .settings)
        XCTAssertEqual(WorkspaceStore.firstCollectToast(exitCode: 1).action, .runHistory)
        // An unrecorded run has no log to open.
        XCTAssertNil(WorkspaceStore.firstCollectToast(exitCode: 1, runRecorded: false).action)
    }

    func testAToastWithAButtonStaysUpLongEnoughToClick() {
        XCTAssertEqual(Toast(message: "m", style: .info).displaySeconds, Toast.displaySeconds)
        XCTAssertEqual(Toast(message: "m", style: .info, action: .settings).displaySeconds,
                       Toast.actionDisplaySeconds)
        XCTAssertGreaterThan(Toast.actionDisplaySeconds, Toast.displaySeconds)
    }

    /// An actionable tile takes the same room as an inert one, alone and in a grid row.
    func testAnActionableTileIsLaidOutLikeAnInertOne() throws {
        let inert = StatTile(label: "Stale", value: "42", sub: "of 524 Macs")
        let live = StatTile(label: "Stale", value: "42", sub: "of 524 Macs",
                            action: {}, actionHint: "Opens Computers")
        XCTAssertEqual(try size(of: inert), try size(of: live))

        func row(_ first: StatTile) -> some View {
            EqualHeightTileGrid(minTileWidth: 200) {
                first
                StatTile(label: "Patch", value: "88%", sub: "a longer caption that wraps onto "
                         + "a second line", fillsHeight: true)
            }
        }
        var short = inert; short.fillsHeight = true
        var shortLive = live; shortLive.fillsHeight = true
        XCTAssertEqual(try size(of: row(short)), try size(of: row(shortLive)))
        if let dir = ProcessInfo.processInfo.environment["JRC_TILE_PREVIEW_DIR"] {
            try write(row(shortLive), to: URL(fileURLWithPath: dir)
                .appendingPathComponent("tile-row.png"))
        }
    }

    private func image(_ view: some View) throws -> NSImage {
        let renderer = ImageRenderer(content: view.frame(width: 440).padding(16)
            .background(Theme.Colors.winBG).environment(\.colorScheme, .dark))
        renderer.scale = 2
        return try XCTUnwrap(renderer.nsImage)
    }

    private func size(of view: some View) throws -> CGSize { try image(view).size }

    private func write(_ view: some View, to url: URL) throws {
        let cg = try XCTUnwrap(try image(view).cgImage(forProposedRect: nil, context: nil, hints: nil))
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, cg, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }
}
