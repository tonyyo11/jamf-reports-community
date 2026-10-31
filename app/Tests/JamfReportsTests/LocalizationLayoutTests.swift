import AppKit
import ObjectiveC
import SwiftUI
import XCTest
@testable import JamfReports

/// Renders every tab in demo mode under each language at `PageScaffold.minSupportedWidth`: a page
/// wider than that and than its English self is a failure, and the PNGs are for a person. Opt-in, because it swaps the main
/// bundle for the whole process: `JRC_L10N_LAYOUT=1 swift test --filter LocalizationLayoutTests`.
/// `JRC_PREVIEW_OUT` names the folder for the PNGs. Keep them off GitHub.
@MainActor
final class LocalizationLayoutTests: XCTestCase {
    /// What `NSBundle.mainBundle` returns while `swizzled` is set.
    nonisolated(unsafe) private static var replacement: Bundle?

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["JRC_L10N_LAYOUT"] == "1", "layout render is opt-in")
    }

    private static let swizzle: Void = {
        guard let original = class_getClassMethod(Bundle.self, NSSelectorFromString("mainBundle")),
              let stand = class_getClassMethod(Bundle.self, #selector(Bundle.l10nTestMainBundle))
        else { return }
        method_exchangeImplementations(original, stand)
    }()

    nonisolated fileprivate static func currentMain() -> Bundle? { replacement }

    /// Compiles one language of the catalog into a bundle of its own, so it is the only choice.
    private func bundle(for language: String, in folder: URL) throws -> Bundle {
        let root = LocalizationCatalogTests.appDirectory
        let path = folder.appendingPathComponent("\(language).bundle")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let tool = Process()
        tool.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        tool.arguments = [
            "xcstringstool", "compile",
            root.appendingPathComponent("Localization/Localizable.xcstrings").path,
            "--output-directory", path.path, "--language", language,
        ]
        try tool.run()
        tool.waitUntilExit()
        XCTAssertEqual(tool.terminationStatus, 0)
        return try XCTUnwrap(Bundle(path: path.path))
    }

    func testEveryTabFitsAtTheMinimumWidthInEveryLanguage() throws {
        let environment = ProcessInfo.processInfo.environment
        let out = URL(fileURLWithPath: environment["JRC_PREVIEW_OUT"]
            ?? NSTemporaryDirectory() + "jrc-l10n-layout", isDirectory: true)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-l10n-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        _ = Self.swizzle
        Localization.useAppLanguage()
        let width = PageScaffold<EmptyView>.minSupportedWidth
        var overflows: [String] = []
        var englishWidth: [JamfReports.Tab: CGFloat] = [:]
        for language in ["en"] + LocalizationCatalogTests.languages {
            Self.replacement = language == "en" ? nil : try bundle(for: language, in: folder)
            if language != "en" {
                XCTAssertNotEqual(L("Settings"), "Settings", "\(language) table not in use")
            }
            let workspace = WorkspaceStore(demoMode: true)
            for tab in Tab.allCases where tab != .onboarding {
                let page = TabPage(tab: tab, onboardingRun: 0)
                    .environment(workspace)
                    .environment(\.locale, Locale(identifier: language))
                    .environment(\.colorScheme, .dark)
                    .background(Theme.Colors.winBG)
                let controller = NSHostingController(rootView: AnyView(page))
                controller.sizingOptions = []
                let host = controller.view
                host.frame = NSRect(x: 0, y: 0, width: width, height: 900)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                                      backing: .buffered, defer: false)
                window.contentViewController = controller
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                host.layoutSubtreeIfNeeded()
                let needed = controller.sizeThatFits(
                    in: NSSize(width: width, height: .greatestFiniteMagnitude)).width
                if language == "en" {
                    englishWidth[tab] = needed
                } else if needed > max(width, englishWidth[tab] ?? width) + 1 {
                    overflows.append("\(language) \(tab.rawValue): \(Int(needed)) pt, "
                        + "English \(Int(englishWidth[tab] ?? 0)) pt")
                }
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try rep.representation(using: .png, properties: [:])?
                        .write(to: out.appendingPathComponent("\(language)-\(tab.rawValue).png"))
                }
                window.contentViewController = nil
            }
        }
        Self.replacement = nil
        XCTAssertTrue(overflows.isEmpty, "wider than \(Int(width)) pt: \(overflows)")
    }
}

extension Bundle {
    /// Exchanged with `+mainBundle`, so this call reaches the real one.
    @objc fileprivate class func l10nTestMainBundle() -> Bundle {
        LocalizationLayoutTests.currentMain() ?? l10nTestMainBundle()
    }
}
