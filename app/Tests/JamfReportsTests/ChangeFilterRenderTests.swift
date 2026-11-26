import AppKit
import SwiftUI
import XCTest
@testable import JamfReports

/// Renders the demo Computers screen opened from a "Since last collect" count, at
/// `PageScaffold.minSupportedWidth`, for a person to look at. Opt-in:
/// `JRC_CHANGE_RENDER_OUT=<folder> swift test --filter ChangeFilterRenderTests`. Keep the
/// PNGs off GitHub.
@MainActor
final class ChangeFilterRenderTests: XCTestCase {
    func testRenderDemoChangeLists() throws {
        guard let path = ProcessInfo.processInfo.environment["JRC_CHANGE_RENDER_OUT"] else {
            throw XCTSkip("render is opt-in")
        }
        let out = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let computers = try XCTUnwrap(DemoData.fleetChanges.computers)
        let patch = try XCTUnwrap(DemoData.fleetChanges.patch)
        let filters = [
            ChangeFilter.from(computers, kind: .osChanged),
            ChangeFilter.from(computers, kind: .left),
            ChangeFilter.from(patch, kind: .patchStarted),
        ].compactMap { $0 }
        XCTAssertEqual(filters.count, 3)
        let width = PageScaffold<EmptyView>.minSupportedWidth
        for filter in filters {
            let workspace = WorkspaceStore(demoMode: true)
            workspace.pendingChangeFilter = try XCTUnwrap(filter.json)
            let page = TabPage(tab: .devices, onboardingRun: 0)
                .environment(workspace)
                .environment(\.colorScheme, .dark)
                .background(Theme.Colors.winBG)
            let controller = NSHostingController(rootView: AnyView(page))
            controller.sizingOptions = []
            let host = controller.view
            host.frame = NSRect(x: 0, y: 0, width: width, height: 1100)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.contentViewController = controller
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            host.layoutSubtreeIfNeeded()
            let needed = controller.sizeThatFits(
                in: NSSize(width: width, height: .greatestFiniteMagnitude)).width
            XCTAssertLessThanOrEqual(needed, width + 1, "\(filter.kind)")
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])?
                    .write(to: out.appendingPathComponent("computers-\(filter.kind.rawValue).png"))
            }
            window.contentViewController = nil
        }
    }
}
